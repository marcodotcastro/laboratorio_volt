#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/control-plane.sh
source "$SCRIPT_DIR/lib/control-plane.sh"

action="${1:-}"
[ "$#" -eq 1 ] && [ "$action" = render ] || die "Usage: runtime-env.sh render"

load_config
selected_issue_state
if [ "${WORKSPACE_ALLOW_MISSING_WORKTREES:-false}" = true ]; then
  [[ "$CRM_WORKTREE_PATH" = /* ]] || die 'CRM worktree path must be absolute'
  [[ "$AIO_WORKTREE_PATH" = /* ]] || die 'All In One worktree path must be absolute'
else
  validate_runtime_worktrees
fi
derive_runtime_routes

runtime_dir="$STATE_DIR/runtime/$ISSUE_ID"
mkdir -p "$runtime_dir"
chmod 700 "$runtime_dir"
runtime_env_file="$runtime_dir/compose.env"
temporary_env_file="$(mktemp "$runtime_dir/.compose.env.XXXXXX")"
trap 'rm -f "$temporary_env_file"' EXIT
umask 077

WORKSPACE_URL="http://${WORKTREE_PRIMARY_HOST}"
SHELL_URL="${WORKSPACE_URL}:${AIO_ALL_IN_ONE_PORT}"
IMOB_URL="${WORKSPACE_URL}:${AIO_IMOB_PORT}"
BACKEND_URL="${WORKSPACE_URL}:${CRM_WEB_PORT}"
STYLEGUIDE_URL="${WORKSPACE_URL}:${AIO_STYLEGUIDE_PORT}"
ALL_IN_ONE_URL="$SHELL_URL"
VITE_ALL_IN_ONE_PUBLIC_URL="$SHELL_URL"
VITE_IMOB_PUBLIC_URL="$IMOB_URL"
VITE_IMOB_REMOTE_URL="$IMOB_URL/remoteEntry.js"
VITE_AUTH_API_URL="$BACKEND_URL"
VITE_IMOB_API_URL="$BACKEND_URL"

{
  printf 'ISSUE_ID=%s\n' "$ISSUE_ID"
  printf 'ISSUE_NUMBER=%s\n' "$ISSUE_NUMBER"
  printf 'CRM_WORKTREE_PATH=%s\n' "$CRM_WORKTREE_PATH"
  printf 'AIO_WORKTREE_PATH=%s\n' "$AIO_WORKTREE_PATH"
  printf 'WORKSPACE_COMPOSE_PROJECT=%s\n' "$WORKSPACE_COMPOSE_PROJECT"
  printf 'CRM_WEB_PORT=%s\n' "$CRM_WEB_PORT"
  printf 'CRM_POSTGRES_PORT=%s\n' "$CRM_POSTGRES_PORT"
  printf 'CRM_REDIS_PORT=%s\n' "$CRM_REDIS_PORT"
  printf 'AIO_PORT_BASE=%s\n' "$AIO_PORT_BASE"
  printf 'AIO_ALL_IN_ONE_PORT=%s\n' "$AIO_ALL_IN_ONE_PORT"
  printf 'AIO_IMOB_PORT=%s\n' "$AIO_IMOB_PORT"
  printf 'AIO_STYLEGUIDE_PORT=%s\n' "$AIO_STYLEGUIDE_PORT"
  printf 'WORKSPACE_EDGE_NETWORK=%s\n' "$WORKSPACE_EDGE_NETWORK"
  printf 'WORKSPACE_BACKEND_ALIAS=%s\n' "$WORKSPACE_BACKEND_ALIAS"
  printf 'WORKSPACE_AIO_ALIAS=%s\n' "$WORKSPACE_AIO_ALIAS"
  printf 'WORKTREE_PRIMARY_HOST=%s\n' "$WORKTREE_PRIMARY_HOST"
  printf 'WORKTREE_SECONDARY_HOST=%s\n' "$WORKTREE_SECONDARY_HOST"
  printf 'APP_HOST=%s\n' "$WORKTREE_PRIMARY_HOST"
  printf 'WORKSPACE_URL=%s\n' "$WORKSPACE_URL"
  printf 'SHELL_URL=%s\n' "$SHELL_URL"
  printf 'BACKEND_URL=%s\n' "$BACKEND_URL"
  printf 'ALL_IN_ONE_URL=%s\n' "$ALL_IN_ONE_URL"
  printf 'IMOB_URL=%s\n' "$IMOB_URL"
  printf 'STYLEGUIDE_URL=%s\n' "$STYLEGUIDE_URL"
  printf 'APP_URL=%s\n' "$WORKSPACE_URL"
  printf 'VITE_ALL_IN_ONE_PUBLIC_URL=%s\n' "$VITE_ALL_IN_ONE_PUBLIC_URL"
  printf 'VITE_IMOB_PUBLIC_URL=%s\n' "$VITE_IMOB_PUBLIC_URL"
  printf 'VITE_IMOB_REMOTE_URL=%s\n' "$VITE_IMOB_REMOTE_URL"
  printf 'VITE_AUTH_API_URL=%s\n' "$VITE_AUTH_API_URL"
  printf 'VITE_IMOB_API_URL=%s\n' "$VITE_IMOB_API_URL"
} > "$temporary_env_file"
chmod 600 "$temporary_env_file"
mv -f "$temporary_env_file" "$runtime_env_file"
trap - EXIT

printf 'Rendered runtime environment for %s: %s\n' "$ISSUE_ID" "$runtime_env_file"
