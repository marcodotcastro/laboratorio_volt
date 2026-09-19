#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/control-plane.sh
source "$SCRIPT_DIR/lib/control-plane.sh"

load_config
if [ ! -f "$STATE_DIR/current_issue" ] &&
   [ -z "${WORKSPACE_ISSUE_ID:-}" ] && [ -z "${ISSUE:-}" ]; then
  printf 'No issue selected.\n'
  exit 0
fi
selected_issue_state
printf 'Issue: %s (numeric %s)\n' "$ISSUE_ID" "$ISSUE_NUMBER"
printf 'Workspace coordinator: %s (Orca %s)\n' "$WORKSPACE_WORKTREE_PATH" "$WORKSPACE_ORCA_ID"
printf '  Branch: %s\n' "$WORKSPACE_BRANCH"
printf 'Backend local Git worktree: %s\n' "$CRM_WORKTREE_PATH"
printf '  Branch: %s\n' "$CRM_BRANCH"
printf 'Frontend local Git worktree: %s\n' "$AIO_WORKTREE_PATH"
printf '  Branch: %s\n' "$AIO_BRANCH"
printf 'State file: %s\n' "$issue_file"
log_directory="$STATE_DIR/logs/$ISSUE_ID"
printf 'Log directory: %s\n' "$log_directory"
if [ -d "$log_directory" ]; then
  latest_log="$(find "$log_directory" -maxdepth 1 -type f -name '*.log' -printf '%T@ %p\n' 2>/dev/null | sort -n | tail -n 1 | cut -d' ' -f2-)"
  [ -z "$latest_log" ] || printf 'Latest log: %s\n' "$latest_log"
fi
