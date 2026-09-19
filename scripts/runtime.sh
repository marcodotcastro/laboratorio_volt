#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/control-plane.sh
source "$SCRIPT_DIR/lib/control-plane.sh"
# shellcheck source=lib/logging.sh
source "$SCRIPT_DIR/lib/logging.sh"

action="${1:-}"
[ "$#" -eq 1 ] || die "Usage: runtime.sh {up|down|restart|reset|destroy}"
case "$action" in
  up|down|restart|reset|destroy) ;;
  *) die "Usage: runtime.sh {up|down|restart|reset|destroy}" ;;
esac

load_config
require_command docker
selected_issue_state
if [ "$action" = destroy ] && [ "${WORKSPACE_ALLOW_MISSING_WORKTREES:-false}" = true ]; then
  [[ "$CRM_WORKTREE_PATH" = /* ]] || die 'CRM worktree path must be absolute'
  [[ "$AIO_WORKTREE_PATH" = /* ]] || die 'All In One worktree path must be absolute'
else
  validate_runtime_worktrees
fi
if [ "$action" = destroy ] && [ "${WORKSPACE_ALLOW_MISSING_WORKTREES:-false}" = true ] &&
   [ "${WORKSPACE_ALLOW_LEGACY_STATE:-false}" != true ]; then
  WORKSPACE_COMPOSE_PROJECT="$(workspace_compose_project)"
else
  derive_runtime_routes
fi

LOG_ROOT="$STATE_DIR/logs"
WORKSPACE_LOG_ROOT="$LOG_ROOT"
start_log "$ISSUE_ID" runtime
export WORKSPACE_LOG_FILE="$LOG_FILE"

runtime_log_dir="$STATE_DIR/runtime/$ISSUE_ID"
runtime_log="$runtime_log_dir/runtime.log"
mkdir -p "$runtime_log_dir"
chmod 700 "$runtime_log_dir"

runtime_failure() {
  local description="$1" status="${2:-1}" cause previous_emit_human
  if [ "$description" = 'checking runtime endpoints' ] && [ -n "${LOG_LAST_OUTPUT:-}" ]; then
    cause="$(printf '%s' "$LOG_LAST_OUTPUT" | grep -E ' unavailable: ' | tail -n 1 || true)"
    [ -n "$cause" ] || cause="Runtime endpoint checks exited with status $status"
    cause="${cause:0:240}"
  else
    cause="$description exited with status $status"
  fi
  if [ "${LOG_FINISHED:-false}" != true ]; then
    previous_emit_human="${LOG_EMIT_HUMAN:-true}"
    LOG_EMIT_HUMAN=false
    fail_with_log "$description" "$status" || true
    LOG_EMIT_HUMAN="$previous_emit_human"
  fi
  printf '✗ Runtime could not be completed for issue %s\n' "$ISSUE_ID" >&2
  printf 'Cause: %s\n' "$cause" >&2
  printf 'Next step: check the detailed log and retry\n' >&2
  printf 'Detailed log: %s\n' "$LOG_FILE" >&2
  return "$status"
}

run_compose_logged() {
  local description="$1"
  shift
  run_logged_visible "$description" "${compose_env_command[@]}" \
    "${compose_command[@]}" "$@"
}

log_event progress 'runtime.check_compose' running 'Checking runtime context' '{"display":"audit"}'
if [ "$action" = destroy ] && [ "${WORKSPACE_ALLOW_MISSING_WORKTREES:-false}" = true ] &&
   [ "${WORKSPACE_ALLOW_LEGACY_STATE:-false}" != true ]; then
  :
elif run_logged 'rendering runtime environment' "$SCRIPT_DIR/runtime-env.sh" render; then
  :
else
  status=$?
  runtime_failure 'rendering runtime environment' "$status"
  exit "$status"
fi

RUNTIME_ENV_FILE="$STATE_DIR/runtime/$ISSUE_ID/compose.env"
[ -f "$RUNTIME_ENV_FILE" ] || [ "$action" = destroy ] || {
  runtime_failure "runtime environment was not generated: $RUNTIME_ENV_FILE"
  exit $?
}

runtime_env_value() {
  local key="$1" value
  value="$(sed -n "s/^${key}=//p" "$RUNTIME_ENV_FILE" | head -n 1)"
  [ -n "$value" ] || {
    runtime_failure "runtime environment is missing $key: $RUNTIME_ENV_FILE"
    exit $?
  }
  printf '%s\n' "$value"
}

if [ "$action" != destroy ]; then
  WORKSPACE_URL="$(runtime_env_value WORKSPACE_URL)"
  SHELL_URL="$(runtime_env_value SHELL_URL)"
  BACKEND_URL="$(runtime_env_value BACKEND_URL)"
  ALL_IN_ONE_URL="$(runtime_env_value ALL_IN_ONE_URL)"
  IMOB_URL="$(runtime_env_value IMOB_URL)"
  STYLEGUIDE_URL="$(runtime_env_value STYLEGUIDE_URL)"
fi

compose_command=(docker compose --project-name "$WORKSPACE_COMPOSE_PROJECT")
[ -f "$RUNTIME_ENV_FILE" ] && compose_command+=(--env-file "$RUNTIME_ENV_FILE")
compose_command+=(-f "$ROOT_DIR/docker-compose.yml")
compose_env_command=(env)
if [ -f "$RUNTIME_ENV_FILE" ]; then
  while IFS='=' read -r key _; do
    [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
    compose_env_command+=(-u "$key")
  done < "$RUNTIME_ENV_FILE"
fi
compose_env_command+=(COMPOSE_PROJECT_NAME="$WORKSPACE_COMPOSE_PROJECT")

if [ "$action" = up ] || [ "$action" = restart ] || [ "$action" = reset ]; then
  WORKSPACE_EDGE_NETWORK="$(runtime_env_value WORKSPACE_EDGE_NETWORK)"
  if run_logged_visible 'preparing runtime edge network' ensure_runtime_edge_network; then
    :
  else
    status=$?
    runtime_failure "preparing runtime edge network $WORKSPACE_EDGE_NETWORK" "$status"
    exit "$status"
  fi
fi

if run_compose_logged 'checking Docker Compose' version; then
  :
else
  status=$?
  runtime_failure 'checking Docker Compose' "$status"
  exit "$status"
fi

if [ "$action" = down ] || [ "$action" = destroy ]; then
  if run_logged_visible 'unregistering proxy route' "$SCRIPT_DIR/proxy.sh" unregister; then
    :
  else
    status=$?
    runtime_failure 'unregistering proxy route' "$status"
    exit "$status"
  fi
fi

case "$action" in
  up)
    if run_compose_logged 'starting runtime' up -d --build; then
      :
    else
      status=$?
      runtime_failure 'starting runtime' "$status"
      exit "$status"
    fi
    ;;
  down)
    if run_compose_logged 'stopping runtime' down --remove-orphans; then
      :
    else
      status=$?
      runtime_failure 'stopping runtime' "$status"
      exit "$status"
    fi
    ;;
  restart)
    if run_compose_logged 'stopping runtime for restart' down --remove-orphans; then
      :
    else
      status=$?
      runtime_failure 'stopping runtime for restart' "$status"
      exit "$status"
    fi
    if run_compose_logged 'restarting runtime' up -d --build --force-recreate; then
      :
    else
      status=$?
      runtime_failure 'restarting runtime' "$status"
      exit "$status"
    fi
    ;;
  reset)
    if run_compose_logged 'resetting runtime state' down --volumes --remove-orphans; then
      :
    else
      status=$?
      runtime_failure 'resetting runtime state' "$status"
      exit "$status"
    fi
    if run_compose_logged 'rebuilding runtime' up -d --build --force-recreate; then
      :
    else
      status=$?
      runtime_failure 'rebuilding runtime' "$status"
      exit "$status"
    fi
    ;;
  destroy)
    if run_compose_logged 'destroying runtime state' down --volumes --remove-orphans; then
      :
    else
      status=$?
      runtime_failure 'destroying runtime state' "$status"
      exit "$status"
    fi
    ;;
esac

if [ "$action" != down ] && [ "$action" != destroy ]; then
  if run_logged_capture_visible 'checking running services' "${compose_env_command[@]}" \
    "${compose_command[@]}" ps --services --filter status=running; then
    :
  else
    status=$?
    runtime_failure 'checking running services' "$status"
    exit "$status"
  fi
  running_services="$LOG_LAST_OUTPUT"
  for service in crm-web crm-sidekiq crm-postgres crm-redis aio-monorepo-dev; do
    grep -Fxq "$service" <<< "$running_services" || {
      runtime_failure "service is not running: $service"
      exit $?
    }
  done
fi

if [ "$action" != down ] && [ "$action" != destroy ]; then
  if run_logged_visible 'preparing local development account' "$SCRIPT_DIR/runtime-dev-account.sh" ensure; then
    :
  else
    status=$?
    runtime_failure 'preparing local development account' "$status"
    exit "$status"
  fi
fi

if [ "$action" = up ]; then
  if run_logged_visible 'registering proxy route' "$SCRIPT_DIR/proxy.sh" register; then
    :
  else
    status=$?
    runtime_failure 'registering proxy route' "$status"
    exit "$status"
  fi
  if run_logged_visible 'checking runtime endpoints' "$SCRIPT_DIR/runtime-smoke.sh" check; then
    :
  else
    status=$?
    runtime_failure 'checking runtime endpoints' "$status"
    exit "$status"
  fi
fi

finish_log success
cp -- "$LOG_FILE" "$runtime_log"
chmod 600 "$runtime_log"

if [ "$action" = down ] || [ "$action" = destroy ]; then
  printf 'Issue: %s\n' "$ISSUE_ID"
else
  printf 'Workspace: %s\n' "$WORKSPACE_URL"
  printf 'Shell: %s\n' "$SHELL_URL"
  printf 'Imob: %s\n' "$IMOB_URL"
  printf 'Backend: %s\n' "$BACKEND_URL"
  printf 'Styleguide: %s\n' "$STYLEGUIDE_URL"
fi
printf 'Detailed log: %s\n' "$LOG_FILE"
