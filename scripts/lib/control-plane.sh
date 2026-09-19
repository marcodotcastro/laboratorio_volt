#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

assert_absolute_safe_path() {
  local path="$1" label="$2"
  [ -n "$path" ] || die "$label is empty"
  [[ "$path" = /* ]] || die "$label must be an absolute path: $path"
  case "$path" in
    *$'\n'*|*$'\r'*) die "$label contains unsafe characters" ;;
  esac
  case "/$path/" in
    */../*|*/./*) die "$label contains an unsafe path component: $path" ;;
  esac
}

# A coordinator worktree carries a tiny, data-only context file.  Read it
# before deriving the shared state/config paths so commands launched from a
# coordinator cannot accidentally fall back to the parent Workspace issue.
load_workspace_context() {
  local context_file="${WORKSPACE_CONTEXT_FILE:-}" explicit_context=false
  local line key value seen_keys='' expected_key
  WORKSPACE_CONTEXT_LOADED=false

  if [ -n "$context_file" ]; then
    explicit_context=true
    assert_absolute_safe_path "$context_file" 'Workspace context file'
  fi

  if [ -z "$context_file" ] && [ -f "$PWD/.workspace/context.env" ]; then
    context_file="$PWD/.workspace/context.env"
  fi
  if [ -z "$context_file" ] && [ -f "$ROOT_DIR/.workspace/context.env" ]; then
    context_file="$ROOT_DIR/.workspace/context.env"
  fi
  if [ -z "$context_file" ]; then
    return 0
  fi
  assert_absolute_safe_path "$context_file" 'Workspace context file'
  [ -f "$context_file" ] || {
    [ "$explicit_context" = true ] && die "Workspace context file does not exist: $context_file"
    return 0
  }
  [ ! -L "$context_file" ] || die 'Workspace context file must not be a symlink'
  WORKSPACE_CONTEXT_LOADED=true

  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    case "$line" in
      ''|'#'*) continue ;;
    esac
    case "$line" in
      [A-Za-z_][A-Za-z0-9_]*=*) ;;
      *) die "Invalid context line in $context_file" ;;
    esac
    key="${line%%=*}"
    value="${line#*=}"
    [ -n "$value" ] || die "Context value is empty: $key"
    case " $seen_keys " in
      *" $key "*) die "Duplicate context key: $key" ;;
    esac
    case "$key" in
      WORKSPACE_STATE_DIR)
        assert_absolute_safe_path "$value" 'WORKSPACE_STATE_DIR'
        [ -d "$value" ] || die "WORKSPACE_STATE_DIR does not exist: $value"
        WORKSPACE_STATE_DIR="$value"
        ;;
      WORKSPACE_ISSUE_ID)
        [[ "$value" =~ ^CC-[1-9][0-9]*$ ]] || die "WORKSPACE_ISSUE_ID is invalid: $value"
        WORKSPACE_ISSUE_ID="$value"
        ;;
      WORKSPACE_CONFIG_FILE)
        assert_absolute_safe_path "$value" 'WORKSPACE_CONFIG_FILE'
        WORKSPACE_CONFIG_FILE="$value"
        ;;
      *) die "Unsupported context key in $context_file: $key" ;;
    esac
    seen_keys="$seen_keys $key"
  done < "$context_file"
  for expected_key in WORKSPACE_STATE_DIR WORKSPACE_ISSUE_ID WORKSPACE_CONFIG_FILE; do
    case " $seen_keys " in
      *" $expected_key "*) ;;
      *) die "Workspace context is missing required key: $expected_key" ;;
    esac
  done
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  return 1
}

load_workspace_context
STATE_DIR="${WORKSPACE_STATE_DIR:-$ROOT_DIR/.workspace}"
CONFIG_FILE="${WORKSPACE_CONFIG_FILE:-$ROOT_DIR/.env}"
assert_absolute_safe_path "$STATE_DIR" 'WORKSPACE_STATE_DIR'
assert_absolute_safe_path "$CONFIG_FILE" 'WORKSPACE_CONFIG_FILE'


require_command() {
  command -v "$1" >/dev/null 2>&1 || die "Required command is missing: $1"
}

ensure_runtime_edge_network() {
  local network="${WORKSPACE_EDGE_NETWORK:-c2s_workspace_edge}"
  require_command docker || return $?
  [[ "$network" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] || {
    die "WORKSPACE_EDGE_NETWORK is invalid: $network"
    return 1
  }

  if docker network inspect "$network" >/dev/null 2>&1; then
    return 0
  fi
  if docker network create --driver bridge "$network" >/dev/null; then
    return 0
  fi
  if docker network inspect "$network" >/dev/null 2>&1; then
    return 0
  fi
  die "Could not create runtime edge network: $network"
}

read_env_file() {
  local file="$1" line key value
  [ -f "$file" ] || return 0

  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    case "$line" in
      ''|'#'*) continue ;;
    esac
    case "$line" in
      [A-Za-z_][A-Za-z0-9_]*=*) ;;
      *) die "Invalid configuration line in $file" ;;
    esac
    key="${line%%=*}"
    value="${line#*=}"
    if [[ "$value" == \"*\" ]]; then
      value="${value:1:${#value}-2}"
    fi
    case "$key" in
      CRM_REPO_URL) FILE_CRM_REPO_URL="$value" ;;
      AIO_REPO_URL) FILE_AIO_REPO_URL="$value" ;;
      CRM_REPO_PATH) FILE_CRM_REPO_PATH="$value" ;;
      AIO_REPO_PATH) FILE_AIO_REPO_PATH="$value" ;;
      CRM_BASE_REF) FILE_CRM_BASE_REF="$value" ;;
      AIO_BASE_REF) FILE_AIO_BASE_REF="$value" ;;
      WORKSPACE_BASE_REF) FILE_WORKSPACE_BASE_REF="$value" ;;
      WORKSPACE_SOURCE_ROOT) FILE_WORKSPACE_SOURCE_ROOT="$value" ;;
      WORKTREE_ROOT) FILE_WORKTREE_ROOT="$value" ;;
      AIO_PORT_BASE) FILE_AIO_PORT_BASE="$value" ;;
      WORKSPACE_EDGE_NETWORK) FILE_WORKSPACE_EDGE_NETWORK="$value" ;;
      WORKSPACE_PROXY_ROOT) FILE_WORKSPACE_PROXY_ROOT="$value" ;;
      WORKSPACE_PROXY_PROJECT) FILE_WORKSPACE_PROXY_PROJECT="$value" ;;
      ORCA_BIN) FILE_ORCA_BIN="$value" ;;
      MAKE_BIN) FILE_MAKE_BIN="$value" ;;
      *) die "Unsupported configuration key in $file: $key" ;;
    esac
  done < "$file"
}

load_config() {
  FILE_CRM_REPO_URL=''
  FILE_AIO_REPO_URL=''
  FILE_CRM_REPO_PATH=''
  FILE_AIO_REPO_PATH=''
  FILE_CRM_BASE_REF=''
  FILE_AIO_BASE_REF=''
  FILE_WORKSPACE_BASE_REF=''
  FILE_WORKSPACE_SOURCE_ROOT=''
  FILE_WORKTREE_ROOT=''
  FILE_AIO_PORT_BASE=''
  FILE_WORKSPACE_EDGE_NETWORK=''
  FILE_WORKSPACE_PROXY_ROOT=''
  FILE_WORKSPACE_PROXY_PROJECT=''
  FILE_ORCA_BIN=''
  FILE_MAKE_BIN=''
  read_env_file "$CONFIG_FILE"

  CRM_REPO_URL="${CRM_REPO_URL:-${FILE_CRM_REPO_URL:-git@github.com:contact2sale/c2s-crm.git}}"
  AIO_REPO_URL="${AIO_REPO_URL:-${FILE_AIO_REPO_URL:-git@github.com:contact2sale/c2s-all-in-one.git}}"
  CRM_REPO_PATH="${CRM_REPO_PATH:-${FILE_CRM_REPO_PATH:-}}"
  AIO_REPO_PATH="${AIO_REPO_PATH:-${FILE_AIO_REPO_PATH:-}}"
  CRM_BASE_REF="${CRM_BASE_REF:-${FILE_CRM_BASE_REF:-main}}"
  AIO_BASE_REF="${AIO_BASE_REF:-${FILE_AIO_BASE_REF:-main}}"
  WORKSPACE_BASE_REF="${WORKSPACE_BASE_REF:-${FILE_WORKSPACE_BASE_REF:-main}}"
  WORKSPACE_SOURCE_ROOT="${WORKSPACE_SOURCE_ROOT:-${FILE_WORKSPACE_SOURCE_ROOT:-$STATE_DIR/sources}}"
  WORKTREE_ROOT="${WORKTREE_ROOT:-${FILE_WORKTREE_ROOT:-$STATE_DIR/worktrees}}"
  AIO_PORT_BASE="${AIO_PORT_BASE:-${FILE_AIO_PORT_BASE:-}}"
  WORKSPACE_EDGE_NETWORK="${WORKSPACE_EDGE_NETWORK:-${FILE_WORKSPACE_EDGE_NETWORK:-}}"
  WORKSPACE_PROXY_ROOT="${WORKSPACE_PROXY_ROOT:-${FILE_WORKSPACE_PROXY_ROOT:-}}"
  WORKSPACE_PROXY_PROJECT="${WORKSPACE_PROXY_PROJECT:-${FILE_WORKSPACE_PROXY_PROJECT:-}}"
  ORCA_BIN="${ORCA_BIN:-${FILE_ORCA_BIN:-orca-ide}}"
  MAKE_BIN="${MAKE_BIN:-${FILE_MAKE_BIN:-make}}"
  assert_absolute_safe_path "$WORKSPACE_SOURCE_ROOT" 'WORKSPACE_SOURCE_ROOT'
  assert_absolute_safe_path "$WORKTREE_ROOT" 'WORKTREE_ROOT'
}

ensure_absolute_dir() {
  local configured="$1" label="$2"
  [ -n "$configured" ] || die "$label is not configured"
  [ -d "$configured" ] || die "$label does not exist: $configured"
  (cd "$configured" && pwd)
}

assert_clean_git_repo() {
  local repo="$1" label="$2" status
  require_command git
  git -C "$repo" rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "$label is not a Git worktree: $repo"
  status="$(git -C "$repo" status --porcelain --untracked-files=all)"
  [ -z "$status" ] || die "$label is dirty; refusing to use uncommitted source state: $repo"
}

prepare_repo() {
  local configured="$1" url="$2" destination="$3" label="$4"
  if [ -n "$configured" ]; then
    ensure_absolute_dir "$configured" "$label" >/dev/null
    assert_clean_git_repo "$configured" "$label"
    (cd "$configured" && pwd)
    return 0
  fi

  mkdir -p "$(dirname "$destination")"
  if [ ! -e "$destination" ]; then
    case "$url" in
      ''|-*) die "$label URL is empty or starts with an option" ;;
    esac
    git clone "$url" "$destination" >/dev/null
  fi
  [ -d "$destination" ] || die "$label destination is not a directory: $destination"
  assert_clean_git_repo "$destination" "$label"
  git -C "$destination" fetch --all --prune >/dev/null
  (cd "$destination" && pwd)
}

prepare_source_repo() {
  local source_name="${1:-}" repo_url="${2:-}" destination="${3:-}"
  local configured source_label source_root="${WORKSPACE_SOURCE_ROOT:-$STATE_DIR/sources}"
  local worktree_root="${WORKTREE_ROOT:-$STATE_DIR/worktrees}"

  [ -n "$source_name" ] || die 'Source repository name is required'
  assert_absolute_safe_path "$source_root" 'WORKSPACE_SOURCE_ROOT'
  assert_absolute_safe_path "$worktree_root" 'WORKTREE_ROOT'

  # Also accept the URL, destination form for callers that do not use the
  # CRM/AIO names: prepare_source_repo URL /absolute/cache/path.
  if [[ "$source_name" == *:* || "$source_name" == */* ]] && [ -n "$repo_url" ]; then
    destination="$repo_url"
    repo_url="$source_name"
    source_name="$(basename "$destination")"
  fi

  case "$source_name" in
    crm|CRM|c2s-crm)
      configured="${CRM_REPO_PATH:-}"
      repo_url="${repo_url:-${CRM_REPO_URL:-}}"
      source_label='CRM source repository'
      source_name='c2s-crm'
      ;;
    aio|AIO|c2s-all-in-one)
      configured="${AIO_REPO_PATH:-}"
      repo_url="${repo_url:-${AIO_REPO_URL:-}}"
      source_label='All In One source repository'
      source_name='c2s-all-in-one'
      ;;
    *)
      configured=''
      source_label="Source repository $source_name"
      ;;
  esac

  destination="${destination:-${configured:-$source_root/$source_name}}"
  if [ -n "$configured" ] && [ -z "${3:-}" ]; then
    destination="$configured"
  fi
  case "$destination" in
    "$worktree_root"|"$worktree_root"/*) die "$source_label must not live inside WORKTREE_ROOT: $destination" ;;
  esac
  assert_absolute_safe_path "$destination" "$source_label destination"

  if [ -e "$destination" ]; then
    [ ! -L "$destination" ] || die "$source_label destination must not be a symlink: $destination"
    [ -d "$destination" ] || die "$source_label path is not a directory: $destination"
    git -C "$destination" rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "$source_label is not a Git worktree: $destination"
    assert_clean_git_repo "$destination" "$source_label"
    # Fetch updates refs only; never reset, clean, or otherwise overwrite
    # files in a persistent clone that may contain local work.
    if declare -F run_logged >/dev/null 2>&1; then
      run_logged "fetching $source_label" git -C "$destination" fetch --all --prune || die "Could not fetch $source_label: $destination"
    else
      git -C "$destination" fetch --all --prune >/dev/null 2>&1 || die "Could not fetch $source_label: $destination"
    fi
  else
    case "$repo_url" in
      ''|-*) die "$source_label URL is empty or starts with an option" ;;
    esac
    mkdir -p "$(dirname "$destination")"
    if declare -F run_logged >/dev/null 2>&1; then
      run_logged "cloning $source_label" git clone -- "$repo_url" "$destination" || die "Could not clone $source_label"
    else
      git clone -- "$repo_url" "$destination" >/dev/null 2>&1 || die "Could not clone $source_label"
    fi
  fi
  (cd "$destination" && pwd)
}

prepare_repositories() {
  CRM_SOURCE_PATH="$(prepare_source_repo c2s-crm "$CRM_REPO_URL")"
  AIO_SOURCE_PATH="$(prepare_source_repo c2s-all-in-one "$AIO_REPO_URL")"
  CRM_REPO_DIR="$CRM_SOURCE_PATH"
  AIO_REPO_DIR="$AIO_SOURCE_PATH"
}

ensure_state_dirs() {
  mkdir -p "$STATE_DIR/issues"
}

write_state_value() {
  local file="$1" key="$2" value="$3"
  printf '%s=%s\n' "$key" "$value" >> "$file"
}

load_issue_state() {
  local issue_file="$1" require_worktrees="${2:-true}" validate_filename="${3:-true}"
  local allow_missing_workspace_selector="${4:-${WORKSPACE_ALLOW_MISSING_WORKSPACE_SELECTOR:-false}}" line key value
  local seen_keys='' key_count=0 expected_key path branch
  ISSUE_STATE_LEGACY=false
  [ -f "$issue_file" ] || die "Issue state does not exist: $issue_file"
  ISSUE_ID=''
  ISSUE_NUMBER=''
  ISSUE_TYPE=''
  ISSUE_BRANCH=''
  WORKSPACE_REPO_ID=''
  WORKSPACE_WORKTREE_PATH=''
  WORKSPACE_ORCA_ID=''
  WORKSPACE_BRANCH=''
  CRM_SOURCE_PATH=''
  CRM_WORKTREE_PATH=''
  CRM_BRANCH=''
  AIO_SOURCE_PATH=''
  AIO_WORKTREE_PATH=''
  AIO_BRANCH=''
  # Keep old consumers loadable until their next migration lot. These are
  # intentionally empty and are never read from the new manifest.
  CRM_REPO_ID=''
  CRM_ORCA_ID=''
  AIO_REPO_ID=''
  AIO_ORCA_ID=''
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      ''|'#'*) continue ;;
    esac
    [[ "$line" == *=* ]] || die "Invalid issue state line: $line"
    key="${line%%=*}"
    value="${line#*=}"
    case "$key" in
      ISSUE_ID) ISSUE_ID="$value" ;;
      ISSUE_NUMBER) ISSUE_NUMBER="$value" ;;
      ISSUE_TYPE) ISSUE_TYPE="$value" ;;
      ISSUE_BRANCH) ISSUE_BRANCH="$value" ;;
      WORKSPACE_REPO_ID) WORKSPACE_REPO_ID="$value" ;;
      WORKSPACE_WORKTREE_PATH) WORKSPACE_WORKTREE_PATH="$value" ;;
      WORKSPACE_ORCA_ID) WORKSPACE_ORCA_ID="$value" ;;
      WORKSPACE_BRANCH) WORKSPACE_BRANCH="$value" ;;
      CRM_SOURCE_PATH) CRM_SOURCE_PATH="$value" ;;
      CRM_WORKTREE_PATH) CRM_WORKTREE_PATH="$value" ;;
      CRM_BRANCH) CRM_BRANCH="$value" ;;
      AIO_SOURCE_PATH) AIO_SOURCE_PATH="$value" ;;
      AIO_WORKTREE_PATH) AIO_WORKTREE_PATH="$value" ;;
      AIO_BRANCH) AIO_BRANCH="$value" ;;
      *) die "Unsupported key in issue state: $key" ;;
    esac
    case " $seen_keys " in
      *" $key "*) die "Duplicate key in issue state: $key" ;;
    esac
    seen_keys="$seen_keys $key"
    key_count=$((key_count + 1))
  done < "$issue_file"
  [ "$key_count" -eq 14 ] || die "Issue state must contain exactly 14 fields; found $key_count"
  for expected_key in \
    ISSUE_ID ISSUE_NUMBER ISSUE_TYPE ISSUE_BRANCH \
    WORKSPACE_REPO_ID WORKSPACE_WORKTREE_PATH WORKSPACE_ORCA_ID WORKSPACE_BRANCH \
    CRM_SOURCE_PATH CRM_WORKTREE_PATH CRM_BRANCH \
    AIO_SOURCE_PATH AIO_WORKTREE_PATH AIO_BRANCH; do
    case " $seen_keys " in
      *" $expected_key "*) ;;
      *) die "Issue state is missing required field: $expected_key" ;;
    esac
  done
  if [ "$validate_filename" = true ]; then
    [ "$ISSUE_ID" = "$(basename "$issue_file" .env)" ] || die "Issue state identifier does not match its filename"
  fi
  [[ "$ISSUE_NUMBER" =~ ^[1-9][0-9]*$ ]] || die "Issue state has an invalid numeric issue"
  ISSUE_SLUG="cc-$ISSUE_NUMBER"
  issue_branch_for_type "$ISSUE_TYPE" "$ISSUE_NUMBER" >/dev/null || die "Issue state has an invalid issue type: $ISSUE_TYPE"
  expected_key="$(issue_branch_for_type "$ISSUE_TYPE" "$ISSUE_NUMBER")"
  branch="$(normalize_branch_ref "$ISSUE_BRANCH")"
  [ "$branch" = "$expected_key" ] || die "Issue state branch does not match issue type"
  [ -n "$WORKSPACE_REPO_ID" ] || die "Issue state is missing Workspace repository ID"
  if [ "$require_worktrees" = true ] || [ "$allow_missing_workspace_selector" != true ]; then
    [ -n "$WORKSPACE_ORCA_ID" ] || die "Issue state is missing Workspace Orca selector"
  fi
  [ -n "$WORKSPACE_BRANCH" ] && [ -n "$CRM_BRANCH" ] && [ -n "$AIO_BRANCH" ] || die "Issue state is missing branches"
  [ -n "$WORKSPACE_WORKTREE_PATH" ] && [ -n "$CRM_SOURCE_PATH" ] && [ -n "$CRM_WORKTREE_PATH" ] && [ -n "$AIO_SOURCE_PATH" ] && [ -n "$AIO_WORKTREE_PATH" ] || die "Issue state is missing essential paths"
  for path in "$WORKSPACE_WORKTREE_PATH" "$CRM_SOURCE_PATH" "$CRM_WORKTREE_PATH" "$AIO_SOURCE_PATH" "$AIO_WORKTREE_PATH"; do
    [[ "$path" = /* ]] || die "Issue state paths must be absolute"
  done
  [ "$(normalize_branch_ref "$CRM_BRANCH")" = "$branch" ] && [ "$(normalize_branch_ref "$AIO_BRANCH")" = "$branch" ] || die "Issue state product branches must share ISSUE_BRANCH"
  [ "$(normalize_branch_ref "$WORKSPACE_BRANCH")" = "$branch" ] || die "Issue state Workspace branch must share ISSUE_BRANCH"
  if [ -n "$WORKSPACE_ORCA_ID" ]; then
    validate_worktree_selector "$WORKSPACE_ORCA_ID" "$WORKSPACE_REPO_ID" || die "Issue state has an invalid Workspace Orca selector"
    [ "${WORKSPACE_ORCA_ID#*::}" = "$WORKSPACE_WORKTREE_PATH" ] || die "Issue state Workspace selector does not match its path"
  fi
  if [ "$require_worktrees" = true ]; then
    [ -d "$WORKSPACE_WORKTREE_PATH" ] || die "Workspace coordinator worktree recorded for $ISSUE_ID no longer exists: $WORKSPACE_WORKTREE_PATH"
    [ -d "$CRM_SOURCE_PATH" ] || die "CRM source repository recorded for $ISSUE_ID no longer exists: $CRM_SOURCE_PATH"
    [ -d "$CRM_WORKTREE_PATH" ] || die "CRM worktree recorded for $ISSUE_ID no longer exists: $CRM_WORKTREE_PATH"
    [ -d "$AIO_SOURCE_PATH" ] || die "All In One source repository recorded for $ISSUE_ID no longer exists: $AIO_SOURCE_PATH"
    [ -d "$AIO_WORKTREE_PATH" ] || die "All In One worktree recorded for $ISSUE_ID no longer exists: $AIO_WORKTREE_PATH"
  fi
}

issue_state_is_legacy() {
  local issue_file="$1" line key
  [ -f "$issue_file" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      ''|'#'*) continue ;;
    esac
    key="${line%%=*}"
    case "$key" in
      CRM_REPO_ID|CRM_ORCA_ID|AIO_REPO_ID|AIO_ORCA_ID) return 0 ;;
    esac
  done < "$issue_file"
  return 1
}

load_legacy_issue_state_for_destroy() {
  local issue_file="$1" line key value seen_keys=''
  [ -f "$issue_file" ] || die "Issue state does not exist: $issue_file"

  ISSUE_ID=''
  ISSUE_NUMBER=''
  ISSUE_TYPE='improvement'
  ISSUE_BRANCH=''
  WORKSPACE_REPO_ID=''
  LEGACY_WORKSPACE_REPO_ID=''
  WORKSPACE_WORKTREE_PATH=''
  WORKSPACE_ORCA_ID=''
  WORKSPACE_BRANCH=''
  CRM_SOURCE_PATH="${CRM_REPO_PATH:-}"
  CRM_WORKTREE_PATH=''
  CRM_BRANCH=''
  AIO_SOURCE_PATH="${AIO_REPO_PATH:-}"
  AIO_WORKTREE_PATH=''
  AIO_BRANCH=''

  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      ''|'#'*) continue ;;
    esac
    [[ "$line" == *=* ]] || die "Invalid legacy issue state line: $line"
    key="${line%%=*}"
    value="${line#*=}"
    case "$key" in
      ISSUE_ID|ISSUE_NUMBER|CRM_WORKTREE_PATH|AIO_WORKTREE_PATH|CRM_BRANCH|AIO_BRANCH|WORKSPACE_ORCA_ID)
        ;;
      CRM_REPO_ID|CRM_ORCA_ID|AIO_REPO_ID|AIO_ORCA_ID)
        ;;
      *) die "Unsupported key in legacy issue state: $key" ;;
    esac
    case " $seen_keys " in
      *" $key "*) die "Duplicate key in legacy issue state: $key" ;;
    esac
    seen_keys="$seen_keys $key"
    case "$key" in
      ISSUE_ID) ISSUE_ID="$value" ;;
      ISSUE_NUMBER) ISSUE_NUMBER="$value" ;;
      CRM_WORKTREE_PATH) CRM_WORKTREE_PATH="$value" ;;
      AIO_WORKTREE_PATH) AIO_WORKTREE_PATH="$value" ;;
      CRM_BRANCH) CRM_BRANCH="$value" ;;
      AIO_BRANCH) AIO_BRANCH="$value" ;;
      WORKSPACE_ORCA_ID)
        case "$value" in
          repo:[A-Za-z0-9_-]*) LEGACY_WORKSPACE_REPO_ID="${value#repo:}" ;;
        esac
        ;;
    esac
  done < "$issue_file"

  [[ "$ISSUE_ID" =~ ^CC-[1-9][0-9]*$ ]] || die "Legacy issue state has an invalid issue identifier"
  [[ "$ISSUE_NUMBER" =~ ^[1-9][0-9]*$ ]] || die "Legacy issue state has an invalid issue number"
  [ "$ISSUE_ID" = "CC-$ISSUE_NUMBER" ] || die "Legacy issue state identifier does not match its issue number"
  [ -n "$CRM_WORKTREE_PATH" ] || die "Legacy issue state is missing the CRM worktree path"
  [ -n "$AIO_WORKTREE_PATH" ] || die "Legacy issue state is missing the All In One worktree path"
  assert_absolute_safe_path "$CRM_WORKTREE_PATH" 'Legacy CRM worktree path'
  assert_absolute_safe_path "$AIO_WORKTREE_PATH" 'Legacy All In One worktree path'

  ISSUE_SLUG="cc-$ISSUE_NUMBER"
  ISSUE_BRANCH="feat/cc${ISSUE_NUMBER}-improvement"
  WORKSPACE_BRANCH="$ISSUE_BRANCH"
  WORKSPACE_REPO_ID="$LEGACY_WORKSPACE_REPO_ID"
  ISSUE_STATE_LEGACY=true
}

normalize_branch_ref() {
  local branch="$1"
  case "$branch" in
    refs/heads/*) printf '%s\n' "${branch#refs/heads/}" ;;
    *) printf '%s\n' "$branch" ;;
  esac
}

validate_worktree_selector() {
  local selector="$1" repo_id="$2" path
  [[ "$selector" == "$repo_id::"* ]] || return 1
  path="${selector#*::}"
  [[ "$path" = /* ]] || return 1
  [ -n "$path" ]
}

current_issue_state() {
  local current issue
  [ -f "$STATE_DIR/current_issue" ] || die "No issue selected; run: make issue 123"
  IFS= read -r current < "$STATE_DIR/current_issue" || true
  [[ "$current" =~ ^CC-[1-9][0-9]*$ ]] || die "Selected issue state is invalid"
  issue_file="$STATE_DIR/issues/$current.env"
  load_issue_state "$issue_file"
}

selected_issue_state() {
  local selected="${WORKSPACE_ISSUE_ID:-}" explicit_issue="${ISSUE:-}" require_worktrees=true
  if [ "${WORKSPACE_ALLOW_MISSING_WORKTREES:-false}" = true ]; then
    require_worktrees=false
  fi
  if [ -n "$selected" ]; then
    [[ "$selected" =~ ^CC-[1-9][0-9]*$ ]] || die "Selected issue state is invalid"
    if [ "${WORKSPACE_ALLOW_LEGACY_STATE:-false}" = true ]; then
      load_legacy_issue_state_for_destroy "$STATE_DIR/issues/$selected.env"
    else
      load_issue_state "$STATE_DIR/issues/$selected.env" "$require_worktrees"
    fi
  elif [ "$WORKSPACE_CONTEXT_LOADED" != true ] && [ -n "$explicit_issue" ]; then
    [[ "$explicit_issue" =~ ^([Cc][Cc]-)?0*([1-9][0-9]*)$ ]] || die "Explicit issue is invalid"
    selected="CC-${BASH_REMATCH[2]}"
    if [ "${WORKSPACE_ALLOW_LEGACY_STATE:-false}" = true ]; then
      load_legacy_issue_state_for_destroy "$STATE_DIR/issues/$selected.env"
    else
      load_issue_state "$STATE_DIR/issues/$selected.env" "$require_worktrees"
    fi
  else
    if [ "$require_worktrees" = true ]; then
      current_issue_state
    else
      local current
      [ -f "$STATE_DIR/current_issue" ] || die "No issue selected; run: make issue 123"
      IFS= read -r current < "$STATE_DIR/current_issue" || true
      [[ "$current" =~ ^CC-[1-9][0-9]*$ ]] || die "Selected issue state is invalid"
      if [ "${WORKSPACE_ALLOW_LEGACY_STATE:-false}" = true ]; then
        load_legacy_issue_state_for_destroy "$STATE_DIR/issues/$current.env"
      else
        load_issue_state "$STATE_DIR/issues/$current.env" false
      fi
    fi
  fi
}

validate_runtime_worktree() {
  local path="$1" label="$2" branch expected_branch
  [[ "$path" = /* ]] || die "$label worktree path must be absolute"
  [ -d "$path" ] || die "$label worktree does not exist: $path"
  git -C "$path" rev-parse --is-inside-work-tree >/dev/null 2>&1 || \
    die "$label worktree is not a Git worktree: $path"
  branch="$(git -C "$path" symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
  expected_branch="$(normalize_branch_ref "$ISSUE_BRANCH")"
  [ "$branch" = "$expected_branch" ] || \
    die "$label worktree branch must match issue branch $expected_branch: ${branch:-detached}"
}

validate_runtime_worktrees() {
  validate_runtime_worktree "$CRM_WORKTREE_PATH" 'CRM'
  validate_runtime_worktree "$AIO_WORKTREE_PATH" 'All In One'
}

json_repo_id() {
  local json="$1" path="$2"
  jq -er --arg path "$path" '.result.repos[]? | select(.path == $path) | .id' <<< "$json" 2>/dev/null | head -n 1
}

ensure_orca_repo() {
  local path="$1" list_json repo_json repo_id
  list_json="$("$ORCA_BIN" repo list --json)" || die "Could not list Orca repositories"
  repo_id="$(json_repo_id "$list_json" "$path" || true)"
  if [ -z "$repo_id" ]; then
    repo_json="$("$ORCA_BIN" repo add --path "$path" --json)" || die "Could not register repository with Orca: $path"
    repo_id="$(jq -er '(.result.repo // .repo // .result) | (.id // .repoId)' <<< "$repo_json" 2>/dev/null)" || die "Orca did not return a repository ID: $path"
  fi
  printf '%s\n' "$repo_id"
}

assert_no_existing_orca_issue() {
  local repo_id="$1" issue_id="$2" issue_number="$3" list_json existing
  list_json="$("$ORCA_BIN" worktree list --repo "id:$repo_id" --json)" || die "Could not list Orca worktrees for repository $repo_id"
  existing="$(jq -r --arg issue "$issue_id" --arg number "$issue_number" '(.result.worktrees // .worktrees // []) | any(.[]?; (.linkedLinearIssue == $issue) or ((.linkedIssue // "") | tostring == $number))' <<< "$list_json" 2>/dev/null)" || die "Orca returned invalid worktree metadata for repository $repo_id"
  if [ "$existing" = true ]; then
    die "Orca already has a worktree linked to $issue_id in repository $repo_id; refusing to create a partial issue unit"
  fi
}

create_orca_worktree() {
  local repo_id="$1" name="$2" base_ref="$3" issue_id="$4" issue_number="$5" parent_selector="$6" role="$7" output record
  output="$("$ORCA_BIN" worktree create \
    --repo "id:$repo_id" \
    --name "$name" \
    --base-branch "$base_ref" \
    --issue "$issue_number" \
    --linear-issue "$issue_id" \
    --parent-worktree "$parent_selector" \
    --setup skip \
    --comment "C2S CRM Workspace issue $issue_id ($role)" \
    --json)" || die "Orca could not create worktree $name"
  record="$(jq -er '(.result.worktree // .worktree // .result // .) as $w | select(($w.id // $w.worktreeId) and $w.path and ($w.repoId // $w.repo_id) and $w.branch) | [($w.id // $w.worktreeId), $w.path, ($w.repoId // $w.repo_id), $w.branch] | @tsv' <<< "$output" 2>/dev/null)" || die "Orca returned incomplete worktree metadata for $name"
  printf '%s\n' "$record"
}

issue_branch_for_type() {
  local issue_type="${1:-}" issue_number="${2:-}"
  case "${issue_type,,}" in
    bug|b) printf 'fix/cc%s-bug\n' "$issue_number" ;;
    feature|f) printf 'feat/cc%s-feature\n' "$issue_number" ;;
    improvement|i) printf 'feat/cc%s-improvement\n' "$issue_number" ;;
    *) die "Invalid issue type; use bug, feature, or improvement" ;;
  esac
}

normalize_issue_type() {
  local raw="${1:-improvement}"
  case "${raw,,}" in
    bug|b) ISSUE_TYPE='bug' ;;
    feature|f) ISSUE_TYPE='feature' ;;
    improvement|i) ISSUE_TYPE='improvement' ;;
    *) die "Invalid issue type; use bug, feature, or improvement" ;;
  esac
}

normalize_issue() {
  local raw="$1" requested_type="${2:-${TYPE:-improvement}}" digits
  [[ "$raw" =~ ^([Cc][Cc]-)?0*([1-9][0-9]*)$ ]] || die "Invalid issue; use a positive issue such as CC-123"
  digits="${BASH_REMATCH[2]}"
  ISSUE_NUMBER="$digits"
  ISSUE_ID="CC-$digits"
  ISSUE_SLUG="cc-$digits"
  normalize_issue_type "$requested_type"
  ISSUE_BRANCH="$(issue_branch_for_type "$ISSUE_TYPE" "$ISSUE_NUMBER")"
}

normalize_destroy_issue() {
  local raw="$1"
  [[ "$raw" =~ ^([Cc][Cc]-)?0*([1-9][0-9]*)$ ]] || die "Invalid issue number; use a positive number such as 1987"
  ISSUE_NUMBER="${BASH_REMATCH[2]}"
  ISSUE_ID="CC-$ISSUE_NUMBER"
  ISSUE_SLUG="cc-$ISSUE_NUMBER"
}

frontend_port_base() {
  runtime_public_port shell
}

require_positive_issue_number() {
  [[ "${ISSUE_NUMBER:-}" =~ ^[1-9][0-9]*$ ]] || die "Issue number must be a positive integer"
}

validate_runtime_port() {
  local port="$1" label="$2"
  [[ "$port" =~ ^[0-9]+$ ]] || die "$label must be numeric"
  [ "$port" -ge 1024 ] && [ "$port" -le 65535 ] || die "$label must be a valid host port (1024-65535)"
}

workspace_compose_project() {
  require_positive_issue_number
  printf 'c2s-workspace-%s\n' "$ISSUE_SLUG"
}

crm_web_port() {
  runtime_public_port backend
}

runtime_public_port() {
  local service="${1:-}"
  case "$service" in
    shell) printf '3000\n' ;;
    imob) printf '3001\n' ;;
    backend) printf '3002\n' ;;
    styleguide) printf '3003\n' ;;
    *) die "Unknown runtime service: $service"; return 1 ;;
  esac
}

crm_postgres_port() {
  require_positive_issue_number
  local port=$((5432 + ISSUE_NUMBER))
  validate_runtime_port "$port" CRM_POSTGRES_PORT
  printf '%s\n' "$port"
}

crm_redis_port() {
  require_positive_issue_number
  local port=$((6379 + ISSUE_NUMBER))
  validate_runtime_port "$port" CRM_REDIS_PORT
  printf '%s\n' "$port"
}

workspace_primary_host() {
  require_positive_issue_number
  printf 'cc%s.localhost\n' "$ISSUE_NUMBER"
}

workspace_secondary_host() {
  require_positive_issue_number
  printf '%s.localhost\n' "$ISSUE_NUMBER"
}

derive_runtime_routes() {
  require_positive_issue_number
  [[ "${CRM_WORKTREE_PATH:-}" = /* ]] || die "CRM worktree path must be absolute"
  [[ "${AIO_WORKTREE_PATH:-}" = /* ]] || die "All In One worktree path must be absolute"

  WORKSPACE_COMPOSE_PROJECT="$(workspace_compose_project)"
  CRM_WEB_PORT="$(runtime_public_port backend)"
  CRM_POSTGRES_PORT="$(crm_postgres_port)"
  CRM_REDIS_PORT="$(crm_redis_port)"
  AIO_PORT_BASE="$(runtime_public_port shell)"
  AIO_ALL_IN_ONE_PORT="$AIO_PORT_BASE"
  AIO_IMOB_PORT="$(runtime_public_port imob)"
  AIO_STYLEGUIDE_PORT="$(runtime_public_port styleguide)"
  WORKSPACE_EDGE_NETWORK="${WORKSPACE_EDGE_NETWORK:-c2s_workspace_edge}"
  WORKSPACE_BACKEND_ALIAS="cc${ISSUE_NUMBER}-backend"
  WORKSPACE_AIO_ALIAS="cc${ISSUE_NUMBER}-aio"
  WORKTREE_PRIMARY_HOST="$(workspace_primary_host)"
  WORKTREE_SECONDARY_HOST="$(workspace_secondary_host)"

  [[ "$WORKSPACE_EDGE_NETWORK" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] || \
    die "WORKSPACE_EDGE_NETWORK is invalid: $WORKSPACE_EDGE_NETWORK"
  validate_runtime_port "$AIO_PORT_BASE" AIO_PORT_BASE
  validate_runtime_port "$CRM_WEB_PORT" CRM_WEB_PORT
  validate_runtime_port "$AIO_ALL_IN_ONE_PORT" AIO_ALL_IN_ONE_PORT
  validate_runtime_port "$AIO_IMOB_PORT" AIO_IMOB_PORT
  validate_runtime_port "$AIO_STYLEGUIDE_PORT" AIO_STYLEGUIDE_PORT
}
