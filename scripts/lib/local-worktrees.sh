#!/usr/bin/env bash

set -euo pipefail

die() {
  printf 'ERROR: %s\n' "$*" >&2
  return 1
}

require_git_repo() {
  local path="$1" label="$2"
  [ -d "$path" ] || die "$label does not exist: $path"
  git -C "$path" rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "$label is not a Git worktree: $path"
}

local_worktree_record() {
  local source_path="$1" worktree_path="$2" record path branch
  while IFS= read -r line; do
    case "$line" in
      worktree\ *) path="${line#worktree }" ;;
      branch\ *) branch="${line#branch }" ;;
      '')
        if [ "${path:-}" = "$worktree_path" ]; then
          printf '%s\t%s\n' "$path" "${branch#refs/heads/}"
          return 0
        fi
        path=''
        branch=''
        ;;
    esac
  done < <(git -C "$source_path" worktree list --porcelain)
  if [ "${path:-}" = "$worktree_path" ]; then
    printf '%s\t%s\n' "$path" "${branch#refs/heads/}"
    return 0
  fi
  return 1
}

local_worktree_branch_record() {
  local source_path="$1" wanted_branch="$2" path branch
  while IFS= read -r line; do
    case "$line" in
      worktree\ *) path="${line#worktree }" ;;
      branch\ *) branch="${line#branch }" ;;
      '')
        if [ "${branch#refs/heads/}" = "$wanted_branch" ]; then
          printf '%s\n' "$path"
          return 0
        fi
        path=''
        branch=''
        ;;
    esac
  done < <(git -C "$source_path" worktree list --porcelain)
  if [ "${branch#refs/heads/}" = "$wanted_branch" ]; then
    printf '%s\n' "$path"
    return 0
  fi
  return 1
}

resolve_worktree_base_ref() {
  local source_path="$1" requested_ref="$2"

  [ -n "$requested_ref" ] || die 'Local worktree base ref is required'
  case "$requested_ref" in
    origin/*|refs/*)
      printf '%s\n' "$requested_ref"
      return 0
      ;;
  esac

  if git -C "$source_path" show-ref --verify --quiet "refs/remotes/origin/$requested_ref"; then
    printf 'origin/%s\n' "$requested_ref"
  else
    printf '%s\n' "$requested_ref"
  fi
}

worktree_requires_privileged_cleanup() {
  local worktree_path="$1" current_uid candidate
  [ -e "$worktree_path" ] || return 1
  current_uid="$(id -u)"
  candidate="$(find "$worktree_path" -xdev \
    \( ! -user "$current_uid" -o ! -perm -u+w \) \
    -print -quit 2>/dev/null || true)"
  [ -n "$candidate" ]
}

remove_local_worktree_directory() {
  local worktree_path="$1" cleanup_image="${2:-${WORKSPACE_CLEANUP_IMAGE:-}}"
  local parent_path worktree_name
  [[ "$worktree_path" = /* ]] || die 'Local worktree path must be absolute'
  [ ! -L "$worktree_path" ] || die 'Local worktree path must not be a symlink'
  [ -e "$worktree_path" ] || return 0

  if [ "$(id -u)" -eq 0 ] || ! worktree_requires_privileged_cleanup "$worktree_path"; then
    rm -rf -- "$worktree_path" || die "Could not remove local worktree directory: $worktree_path"
  else
    parent_path="$(dirname -- "$worktree_path")"
    worktree_name="$(basename -- "$worktree_path")"
    if [ -n "$cleanup_image" ] && command -v docker >/dev/null 2>&1 &&
       docker image inspect "$cleanup_image" >/dev/null 2>&1 &&
       docker run --rm --user 0:0 \
         --mount "type=bind,src=$parent_path,dst=/cleanup" \
         "$cleanup_image" rm -rf -- "/cleanup/$worktree_name" >/dev/null 2>&1; then
      :
    elif command -v sudo >/dev/null 2>&1 && sudo -n true >/dev/null 2>&1 &&
         sudo -n rm -rf -- "$worktree_path" >/dev/null 2>&1; then
      :
    else
      die "Could not remove local worktree directory with current permissions: $worktree_path"
    fi
  fi
  [ ! -e "$worktree_path" ] && [ ! -L "$worktree_path" ] ||
    die "Local worktree directory remained after cleanup: $worktree_path"
}

assert_local_worktree_clean() {
  local worktree_path="$1" status
  status="$(git -C "$worktree_path" status --porcelain --untracked-files=no 2>/dev/null)" ||
    die "Could not inspect local Git worktree: $worktree_path"
  [ -z "$status" ] || die "Local Git worktree has uncommitted changes: $worktree_path"
}

create_local_worktree() {
  local source_path="$1" worktree_path="$2" branch="$3" base_ref="${4:-HEAD}" label="${5:-local Git worktree}"
  local existing existing_branch branch_path
  require_git_repo "$source_path" 'Source repository'
  [ -n "$branch" ] || die 'Local worktree branch is required'
  [[ "$worktree_path" = /* ]] || die 'Local worktree path must be absolute'
  [[ "$worktree_path" != *$'\n'* && "$worktree_path" != *$'\r'* ]] || die 'Local worktree path contains unsafe characters'
  [ ! -L "$worktree_path" ] || die 'Local worktree path must not be a symlink'
  [[ "$branch" != -* ]] || die 'Local worktree branch must not start with an option'
  git -C "$source_path" check-ref-format --branch "$branch" >/dev/null 2>&1 || die "Invalid local worktree branch: $branch"

  if existing="$(local_worktree_record "$source_path" "$worktree_path" 2>/dev/null)"; then
    existing_branch="${existing#*$'\t'}"
    [ "$existing_branch" = "$branch" ] || die "Worktree path already uses branch $existing_branch: $worktree_path"
    printf '%s\n' "$worktree_path"
    return 0
  fi

  if branch_path="$(local_worktree_branch_record "$source_path" "$branch" 2>/dev/null)"; then
    die "Local worktree branch already used by $branch_path: $branch"
  fi

  if [ -e "$worktree_path" ]; then
    [ -d "$worktree_path" ] || die "Local worktree path is not a directory: $worktree_path"
    [ -z "$(find "$worktree_path" -mindepth 1 -maxdepth 1 -print -quit)" ] || die "Local worktree path is not empty: $worktree_path"
  else
    mkdir -p "$(dirname "$worktree_path")"
  fi
  if git -C "$source_path" show-ref --verify --quiet "refs/heads/$branch"; then
    if declare -F run_logged >/dev/null 2>&1; then
      run_logged "reusing $label" git -C "$source_path" worktree add "$worktree_path" "$branch" || die "Could not reuse local Git worktree branch: $branch"
    else
      git -C "$source_path" worktree add "$worktree_path" "$branch" >/dev/null 2>&1 || die "Could not reuse local Git worktree branch: $branch"
    fi
  else
    if declare -F run_logged >/dev/null 2>&1; then
      run_logged "creating $label" git -C "$source_path" worktree add -b "$branch" "$worktree_path" "$base_ref" || die "Could not create local Git worktree: $worktree_path"
    else
      git -C "$source_path" worktree add -b "$branch" "$worktree_path" "$base_ref" >/dev/null 2>&1 || die "Could not create local Git worktree: $worktree_path"
    fi
  fi
  printf '%s\n' "$worktree_path"
}

remove_local_worktree() {
  local source_path="$1" worktree_path="$2" privileged_cleanup="${3:-false}"
  local cleanup_image="${4:-${WORKSPACE_CLEANUP_IMAGE:-}}"
  require_git_repo "$source_path" 'Source repository'
  [[ "$worktree_path" = /* ]] || die 'Local worktree path must be absolute'

  if ! local_worktree_record "$source_path" "$worktree_path" >/dev/null 2>&1; then
    [ ! -e "$worktree_path" ] || die "Path is not a registered Git worktree: $worktree_path"
    git -C "$source_path" worktree prune >/dev/null
    return 0
  fi

  if worktree_requires_privileged_cleanup "$worktree_path"; then
    [ "$privileged_cleanup" = true ] ||
      die "Local Git worktree contains files that require privileged cleanup: $worktree_path"
    assert_local_worktree_clean "$worktree_path"
    remove_local_worktree_directory "$worktree_path" "$cleanup_image"
    git -C "$source_path" worktree prune >/dev/null || die "Could not prune local Git worktree: $worktree_path"
    return 0
  fi

  # No --force: uncommitted files remain protected and the caller gets the
  # real Git refusal instead of silently losing local work.
  if declare -F run_logged >/dev/null 2>&1; then
    run_logged "removing local Git worktree" git -C "$source_path" worktree remove "$worktree_path" || die "Could not remove local Git worktree: $worktree_path"
  else
    git -C "$source_path" worktree remove "$worktree_path" >/dev/null || die "Could not remove local Git worktree: $worktree_path"
  fi
  git -C "$source_path" worktree prune >/dev/null
}
