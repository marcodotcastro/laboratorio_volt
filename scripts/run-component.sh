#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/control-plane.sh
source "$SCRIPT_DIR/lib/control-plane.sh"

component="${1:-}"
action="${2:-}"
case "$component:$action" in
  back-end:start|back-end:stop|front-end:start|front-end:stop) ;;
  *) die "Usage: run-component.sh {back-end|front-end} {start|stop}" ;;
esac

load_config
require_command jq
current_issue_state
derive_runtime_routes

case "$component" in
  back-end)
    backend_script="$CRM_WORKTREE_PATH/bin/worktree-docker"
    [ -x "$backend_script" ] || die "CRM worktree has no executable bin/worktree-docker: $backend_script"
    printf '%s %s for issue %s\n' "$component" "$action" "$ISSUE_ID"
    "$backend_script" "$action" "$ISSUE_NUMBER"
    ;;
  front-end)
    [ -d "$AIO_WORKTREE_PATH" ] || die "All In One worktree does not exist: $AIO_WORKTREE_PATH"
    require_command "$MAKE_BIN"
    printf '%s %s for issue %s\n' "$component" "$action" "$ISSUE_ID"
    if [ "$action" = start ]; then
      die 'front-end start is managed by vdd up; use the VDD runtime'
    else
      COMPOSE_PROJECT_NAME="c2s-aio-$ISSUE_SLUG" \
        "$MAKE_BIN" -C "$AIO_WORKTREE_PATH" stop
    fi
    ;;
esac
