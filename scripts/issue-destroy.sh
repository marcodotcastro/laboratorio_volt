#!/usr/bin/env bash

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/control-plane.sh
source "$SCRIPT_DIR/lib/control-plane.sh"
# shellcheck source=lib/local-worktrees.sh
source "$SCRIPT_DIR/lib/local-worktrees.sh"
# shellcheck source=lib/logging.sh
source "$SCRIPT_DIR/lib/logging.sh"

load_config || exit 1
require_command jq || exit 1
[ -x "$(command -v "$ORCA_BIN" 2>/dev/null || true)" ] || {
  die "Required executable is missing: $ORCA_BIN"
  exit 1
}

raw_issue="${WORKSPACE_ISSUE_ID:-${ISSUE:-}}"
if [ -z "$raw_issue" ] && [ -f "$STATE_DIR/current_issue" ]; then
  IFS= read -r raw_issue < "$STATE_DIR/current_issue" || true
fi
if [ -z "$raw_issue" ]; then
  read -r -p "Issue number: " raw_issue || die "An issue number is required"
fi
normalize_destroy_issue "$raw_issue" || exit 1
WORKSPACE_CLEANUP_IMAGE="${WORKSPACE_CLEANUP_IMAGE:-$(workspace_compose_project)-aio-monorepo-dev:latest}"

state_file="$STATE_DIR/issues/$ISSUE_ID.env"
has_state=false
legacy_state=false
if [ -f "$state_file" ]; then
  if issue_state_is_legacy "$state_file"; then
    load_legacy_issue_state_for_destroy "$state_file" || exit 1
    legacy_state=true
    printf 'Legacy issue state detected; cleaning only recoverable local state.\n'
  else
    load_issue_state "$state_file" false true true || exit 1
  fi
  has_state=true
else
  WORKSPACE_REPO_ID=''
  WORKSPACE_WORKTREE_PATH=''
  WORKSPACE_ORCA_ID=''
  CRM_SOURCE_PATH="${CRM_REPO_PATH:-$WORKSPACE_SOURCE_ROOT/c2s-crm}"
  CRM_WORKTREE_PATH="$WORKTREE_ROOT/$ISSUE_ID/backend"
  AIO_SOURCE_PATH="${AIO_REPO_PATH:-$WORKSPACE_SOURCE_ROOT/c2s-all-in-one}"
  AIO_WORKTREE_PATH="$WORKTREE_ROOT/$ISSUE_ID/frontend"
  partial_local_unit=false
  if [ -e "$CRM_WORKTREE_PATH" ] || [ -L "$CRM_WORKTREE_PATH" ] ||
    [ -e "$AIO_WORKTREE_PATH" ] || [ -L "$AIO_WORKTREE_PATH" ]; then
    partial_local_unit=true
    printf 'Issue %s local state is absent; partial local units will be removed.\n' "$ISSUE_ID"
  else
    printf 'Issue %s local state is already absent.\n' "$ISSUE_ID"
  fi
fi

read -r -p "Confirm destruction of issue $ISSUE_ID. Type $ISSUE_NUMBER again to continue: " confirmation || {
  printf 'Destruction cancelled.\n' >&2
  exit 1
}
[ "$confirmation" = "$ISSUE_NUMBER" ] || {
  printf 'Destruction cancelled.\n' >&2
  exit 1
}

ensure_state_dirs
WORKSPACE_LOG_ROOT="$STATE_DIR/logs"
LOG_ROOT="$WORKSPACE_LOG_ROOT"
start_log "$ISSUE_ID" destroy

failures=0
last_failure=''
destroy_failure() {
  local description="$1" status="${2:-1}"
  log_event error 'destroy.failure' error "$description" "{\"exit\":$status}"
  last_failure="$description"
  failures=1
  return "$status"
}

remove_partial_local_unit() {
  local source_path="$1" worktree_path="$2"
  case "$worktree_path" in
    "$WORKTREE_ROOT/$ISSUE_ID/backend"|"$WORKTREE_ROOT/$ISSUE_ID/frontend") ;;
    *)
      printf 'ERROR: Refusing to remove an out-of-scope partial local unit: %s\n' "$worktree_path" >&2
      return 1
      ;;
  esac
  if [ -L "$WORKTREE_ROOT" ] || [ -L "$WORKTREE_ROOT/$ISSUE_ID" ] || [ -L "$worktree_path" ]; then
    printf 'ERROR: Refusing to remove a symlinked partial local unit: %s\n' "$worktree_path" >&2
    return 1
  fi

  if [ -d "$source_path" ] && local_worktree_record "$source_path" "$worktree_path" >/dev/null 2>&1; then
    remove_local_worktree "$source_path" "$worktree_path" true "$WORKSPACE_CLEANUP_IMAGE"
  else
    # The issue number was explicitly confirmed above and this path is one of
    # the two exact local-unit paths derived from WORKTREE_ROOT.
    remove_local_worktree_directory "$worktree_path" "$WORKSPACE_CLEANUP_IMAGE"
  fi
  [ ! -e "$worktree_path" ] && [ ! -L "$worktree_path" ]
}

report_destroy_failure() {
  printf '✗ Issue workspace could not be removed: %s\n' "$ISSUE_ID" >&2
  printf 'Cause: %s\n' "$last_failure" >&2
  printf 'Impact: local state was preserved for retry\n' >&2
  printf 'Next step: check the detailed log and retry\n' >&2
  printf 'Detailed log: %s\n' "$LOG_FILE" >&2
}

remove_orca_worktree() {
  local selector="$1" repo_id list_json exists
  [ -n "$selector" ] || return 0
  repo_id="${selector%%::*}"
  validate_worktree_selector "$selector" "$repo_id" || {
    printf 'ERROR: Invalid Orca worktree selector: %s\n' "$selector" >&2
    return 1
  }
  run_logged_capture "inspecting Orca coordinator $selector" \
    "$ORCA_BIN" worktree list --repo "id:$repo_id" --json || return 1
  list_json="$LOG_LAST_OUTPUT"
  exists="$(jq -r --arg selector "$selector" \
    '(.result.worktrees // .worktrees // []) | any(.[]?; (.id // .worktreeId // "") == $selector)' \
    <<< "$list_json" 2>/dev/null)" || {
    printf 'ERROR: Orca returned invalid worktree metadata for %s\n' "$selector" >&2
    return 1
  }
  case "$exists" in
    true)
      run_logged_visible "removing Orca coordinator $selector" \
        "$ORCA_BIN" worktree rm --worktree "$selector" --force --json || return 1
      ;;
    false) printf 'Orca coordinator %s is already absent.\n' "$selector" ;;
    *)
      printf 'ERROR: Orca returned invalid worktree metadata for %s\n' "$selector" >&2
      return 1
      ;;
  esac
}

recover_workspace_orca_id() {
  local list_json records count selector returned_repo path
  [ -n "$WORKSPACE_REPO_ID" ] || return 0
  run_logged_capture 'searching for the Workspace coordinator in Orca' \
    "$ORCA_BIN" worktree list --repo "id:$WORKSPACE_REPO_ID" --json || return 1
  list_json="$LOG_LAST_OUTPUT"
  records="$(jq -r --arg issue "$ISSUE_ID" --arg number "$ISSUE_NUMBER" \
    '(.result.worktrees // .worktrees // [])[]? |
     select((.linkedLinearIssue // "") == $issue or ((.linkedIssue // "") | tostring) == $number) |
     [(.id // .worktreeId // ""), (.repoId // .repo_id // ""), (.path // "")] | @tsv' \
    <<< "$list_json" 2>/dev/null)" || {
    printf 'ERROR: Orca returned invalid coordinator metadata\n' >&2
    return 1
  }
  count="$(printf '%s\n' "$records" | sed '/^$/d' | wc -l | tr -d ' ')"
  [ "$count" -le 1 ] || {
    printf 'ERROR: Orca has multiple Workspace coordinators linked to %s; refusing to choose one.\n' "$ISSUE_ID" >&2
    return 1
  }
  [ "$count" -eq 1 ] || return 0
  IFS=$'\t' read -r selector returned_repo path <<< "$records"
  [ "$returned_repo" = "$WORKSPACE_REPO_ID" ] || {
    printf 'ERROR: Orca returned a non-Workspace coordinator record\n' >&2
    return 1
  }
  validate_worktree_selector "$selector" "$WORKSPACE_REPO_ID" || {
    printf 'ERROR: Orca returned an invalid Workspace coordinator selector\n' >&2
    return 1
  }
  [ -n "$path" ] && [ "${selector#*::}" = "$path" ] || {
    printf 'ERROR: Orca coordinator selector does not match its path\n' >&2
    return 1
  }
  WORKSPACE_ORCA_ID="$selector"
}

log_event progress 'destroy.validate_manifest' running 'Validating issue manifest and context' '{"display":"audit"}'
if [ "$has_state" = true ]; then
  if ! run_logged_visible 'destroying issue Docker state' env \
    WORKSPACE_ISSUE_ID="$ISSUE_ID" WORKSPACE_ALLOW_MISSING_WORKTREES=true \
    WORKSPACE_ALLOW_MISSING_WORKSPACE_SELECTOR=true \
    WORKSPACE_ALLOW_LEGACY_STATE="$legacy_state" \
    WORKSPACE_EVENT_STREAM=false LOG_EMIT_HUMAN=false \
    "$SCRIPT_DIR/runtime.sh" destroy; then
    destroy_failure "Docker cleanup failed for $ISSUE_ID"
  fi
fi

if [ "$failures" -eq 0 ] && [ "$has_state" = true ]; then
  if [ "$legacy_state" = true ] && [ ! -e "$CRM_WORKTREE_PATH" ]; then
    printf 'Legacy CRM worktree is already absent: %s\n' "$CRM_WORKTREE_PATH"
  elif ! run_logged_visible 'removing local CRM backend worktree' \
      remove_local_worktree "$CRM_SOURCE_PATH" "$CRM_WORKTREE_PATH" true "$WORKSPACE_CLEANUP_IMAGE"; then
    destroy_failure "Could not remove CRM worktree: $CRM_WORKTREE_PATH"
  fi
  if [ "$failures" -eq 0 ] && [ "$legacy_state" = true ] && [ ! -e "$AIO_WORKTREE_PATH" ]; then
    printf 'Legacy All In One worktree is already absent: %s\n' "$AIO_WORKTREE_PATH"
  elif [ "$failures" -eq 0 ] && ! run_logged_visible 'removing local All In One frontend worktree' \
      remove_local_worktree "$AIO_SOURCE_PATH" "$AIO_WORKTREE_PATH" true "$WORKSPACE_CLEANUP_IMAGE"; then
    destroy_failure "Could not remove All In One worktree: $AIO_WORKTREE_PATH"
  fi
fi

if [ "$failures" -eq 0 ] && [ "$has_state" = false ] && [ "${partial_local_unit:-false}" = true ]; then
  if [ -e "$CRM_WORKTREE_PATH" ] || [ -L "$CRM_WORKTREE_PATH" ]; then
    if ! run_logged_visible 'removing local CRM backend worktree' \
      remove_partial_local_unit "$CRM_SOURCE_PATH" "$CRM_WORKTREE_PATH"; then
      destroy_failure "Could not remove partial CRM worktree: $CRM_WORKTREE_PATH"
    fi
  fi
  if [ "$failures" -eq 0 ] && { [ -e "$AIO_WORKTREE_PATH" ] || [ -L "$AIO_WORKTREE_PATH" ]; }; then
    if ! run_logged_visible 'removing local All In One frontend worktree' \
      remove_partial_local_unit "$AIO_SOURCE_PATH" "$AIO_WORKTREE_PATH"; then
      destroy_failure "Could not remove partial All In One worktree: $AIO_WORKTREE_PATH"
    fi
  fi
fi

if [ "$failures" -eq 0 ] && [ "$has_state" = true ]; then
  log_event progress 'destroy.remove_coordinator' running 'Removing Workspace coordinator' '{"display":"audit"}'
  if [ "$legacy_state" = true ]; then
    if [ -n "$WORKSPACE_REPO_ID" ]; then
      if recover_workspace_orca_id; then
        if [ -n "$WORKSPACE_ORCA_ID" ] && ! remove_orca_worktree "$WORKSPACE_ORCA_ID"; then
          destroy_failure "Could not remove the recovered Workspace coordinator"
        elif [ -z "$WORKSPACE_ORCA_ID" ]; then
          printf 'Legacy Workspace coordinator was not found in Orca.\n'
        fi
      else
        destroy_failure "Could not safely identify the legacy Workspace coordinator"
      fi
    else
      printf 'Legacy Workspace coordinator could not be located safely; skipping Orca removal.\n'
    fi
  elif [ -z "$WORKSPACE_ORCA_ID" ] && ! recover_workspace_orca_id; then
    destroy_failure "Could not safely identify the Workspace coordinator"
  fi
  if [ "$failures" -eq 0 ] && [ "$legacy_state" != true ] && ! remove_orca_worktree "$WORKSPACE_ORCA_ID"; then
    destroy_failure "Could not remove the Workspace coordinator"
  fi
fi

if [ "$failures" -ne 0 ]; then
  log_event progress 'destroy.preserve_state' running 'Preserving issue state for retry' '{"display":"terminal"}'
  report_destroy_failure
  finish_log failed
  printf 'Issue %s was not fully destroyed; local state was preserved for retry.\n' "$ISSUE_ID" >&2
  exit 1
fi

if [ -f "$STATE_DIR/current_issue" ] && grep -Fxq "$ISSUE_ID" "$STATE_DIR/current_issue"; then
  rm -f -- "$STATE_DIR/current_issue" || {
    destroy_failure 'Could not remove current issue pointer; local state was preserved for retry.'
    report_destroy_failure
    finish_log failed
    exit 1
  }
fi
if [ "$has_state" = true ] && ! rm -f -- "$state_file"; then
  destroy_failure 'Could not remove local issue state; local state was preserved for retry.'
  report_destroy_failure
  finish_log failed
  exit 1
fi

finish_log success
printf 'Destroyed issue %s.\n' "$ISSUE_ID"
