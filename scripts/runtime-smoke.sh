#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/control-plane.sh
source "$SCRIPT_DIR/lib/control-plane.sh"

action="${1:-}"
[ "$#" -eq 1 ] && [[ "$action" =~ ^(render|check)$ ]] || die "Usage: runtime-smoke.sh {render|check}"

load_config
selected_issue_state
derive_runtime_routes

runtime_env_file="$STATE_DIR/runtime/$ISSUE_ID/compose.env"
runtime_value() {
  local key="$1" value
  value="$(sed -n "s/^${key}=//p" "$runtime_env_file" | head -n 1)"
  [ -n "$value" ] || die "Runtime environment is missing $key: $runtime_env_file"
  printf '%s\n' "$value"
}

if [ -f "$runtime_env_file" ]; then
  WORKSPACE_URL="$(runtime_value WORKSPACE_URL)"
  SHELL_URL="$(runtime_value SHELL_URL)"
  IMOB_URL="$(runtime_value IMOB_URL)"
  BACKEND_URL="$(runtime_value BACKEND_URL)"
  STYLEGUIDE_URL="$(runtime_value STYLEGUIDE_URL)"
else
  WORKSPACE_URL="http://$WORKTREE_PRIMARY_HOST"
  SHELL_URL="$WORKSPACE_URL:$AIO_ALL_IN_ONE_PORT"
  IMOB_URL="$WORKSPACE_URL:$AIO_IMOB_PORT"
  BACKEND_URL="$WORKSPACE_URL:$CRM_WEB_PORT"
  STYLEGUIDE_URL="$WORKSPACE_URL:$AIO_STYLEGUIDE_PORT"
fi

case "$action" in
  render)
    printf 'Workspace dashboard: %s\n' "$WORKSPACE_URL"
    printf 'Shell: %s\n' "$SHELL_URL"
    printf 'Imob: %s\n' "$IMOB_URL"
    printf 'Backend: %s\n' "$BACKEND_URL"
    printf 'Styleguide: %s\n' "$STYLEGUIDE_URL"
    exit 0
    ;;
esac

log_file="${WORKSPACE_LOG_FILE:-runtime log}"
smoke_attempts="${WORKSPACE_SMOKE_ATTEMPTS:-12}"
smoke_retry_delay="${WORKSPACE_SMOKE_RETRY_DELAY:-1}"
[[ "$smoke_attempts" =~ ^[1-9][0-9]*$ ]] || die "WORKSPACE_SMOKE_ATTEMPTS must be a positive integer"
[[ "$smoke_retry_delay" =~ ^[0-9]+([.][0-9]+)?$ ]] || die "WORKSPACE_SMOKE_RETRY_DELAY must be non-negative seconds"

check_endpoint() {
  local role="$1" url="$2" expected="$3"
  local response_file error_file code curl_status attempt last_error
  response_file="$(mktemp "${TMPDIR:-/tmp}/c2s-runtime-smoke.XXXXXX")"
  error_file="$(mktemp "${TMPDIR:-/tmp}/c2s-runtime-smoke-error.XXXXXX")"
  trap 'rm -f "$response_file" "$error_file"' RETURN

  for ((attempt = 1; attempt <= smoke_attempts; attempt++)); do
    code=''
    if code="$(curl --silent --show-error --output "$response_file" --max-time 5 \
      --write-out '%{http_code}' "$url" 2>"$error_file")"; then
      curl_status=0
    else
      curl_status=$?
    fi
    printf 'curl attempt %s/%s --silent --show-error --output /dev/null --max-time 5 %s -> HTTP %s (exit %s)\n' \
      "$attempt" "$smoke_attempts" "$url" "${code:-000}" "$curl_status"

    if [ "$curl_status" -eq 0 ] && [[ "$code" =~ ^[0-9]{3}$ ]] && [[ "$code" =~ $expected ]]; then
      if [ "$role" != 'Workspace dashboard' ] || grep -Fq -- "$ISSUE_ID" "$response_file"; then
        return 0
      fi
      last_error="$role unavailable: $url (missing $ISSUE_ID marker; see $log_file)"
    elif [ "$curl_status" -ne 0 ]; then
      last_error="$role unavailable: $url (see $log_file)"
    else
      last_error="$role unavailable: $url (HTTP ${code:-000}; see $log_file)"
    fi

    if [ "$attempt" -lt "$smoke_attempts" ]; then
      sleep "$smoke_retry_delay"
    fi
  done

  printf '%s\n' "$last_error"
  return 1
}

check_endpoint 'Workspace dashboard' "$WORKSPACE_URL/" '^200$'
check_endpoint 'Shell' "$SHELL_URL" '^200$'
check_endpoint 'Imob' "$IMOB_URL" '^200$'
check_endpoint 'Imob remote entry' "$IMOB_URL/remoteEntry.js" '^200$'
check_endpoint 'Backend' "$BACKEND_URL" '^(2[0-9]{2}|3[0-9]{2})$'
check_endpoint 'Styleguide' "$STYLEGUIDE_URL" '^200$'

printf 'Runtime smoke checks passed for %s.\n' "$ISSUE_ID"
