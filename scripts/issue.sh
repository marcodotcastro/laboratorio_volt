#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$SCRIPT_DIR/lib/logging.sh"

ISSUE_INPUT="${1:-${ISSUE:-1000}}"
ISSUE_NUM="$(printf '%s' "$ISSUE_INPUT" | sed -E 's/[^0-9]//g')"
[ -n "$ISSUE_NUM" ] || ISSUE_NUM="1000"
ISSUE_ID="CC-$ISSUE_NUM"
ISSUE_SLUG="cc-$ISSUE_NUM"
ISSUE_BRANCH="feat/cc${ISSUE_NUM}-improvement"

STATE_DIR="$ROOT_DIR/.workspace"
LOG_DIR="$STATE_DIR/logs/$ISSUE_ID"
mkdir -p "$LOG_DIR" "$STATE_DIR/issues" "$STATE_DIR/sources" "$STATE_DIR/worktrees/$ISSUE_ID"

LOG_FILE="$LOG_DIR/$(date +%Y%m%d-%H%M%S)-issue-create.log"
export WORKSPACE_LOG_FILE="$LOG_FILE"

printf '[%s] Creating issue %s in Laboratório Volt\n' "$(date -Iseconds)" "$ISSUE_ID" | tee -a "$LOG_FILE"

ORCA_BIN="$(command -v orca-ide || command -v orca || echo "orca")"

# 1. Obter ou registrar o repo do Workspace no Orca
workspace_repo_id="$("$ORCA_BIN" repo list --json 2>/dev/null | jq -r --arg path "$ROOT_DIR" '.result.repos[]? | select(.path == $path) | .id' | head -n 1 || true)"
if [ -z "$workspace_repo_id" ]; then
  "$ORCA_BIN" repo add --path "$ROOT_DIR" --json >/dev/null 2>&1 || true
  workspace_repo_id="$("$ORCA_BIN" repo list --json 2>/dev/null | jq -r --arg path "$ROOT_DIR" '.result.repos[]? | select(.path == $path) | .id' | head -n 1 || true)"
fi

# 2. Criar ou reusar Coordenador no Orca
orca_worktree_dir="/home/marcodotcastro/Work/orca-workspaces/laboratorio_volt/laboratorio_volt-$ISSUE_SLUG"
mkdir -p "$(dirname "$orca_worktree_dir")"

existing_orca_wt="$("$ORCA_BIN" worktree list --repo "id:$workspace_repo_id" --json 2>/dev/null | jq -r --arg issue "$ISSUE_ID" '(.result.worktrees // .worktrees // [])[]? | select((.linkedLinearIssue // "") == $issue) | .path' | head -n 1 || true)"
if [ -z "$existing_orca_wt" ]; then
  printf '→ Workspace · coordinator · creating\n'
  "$ORCA_BIN" worktree create \
    --repo "id:$workspace_repo_id" --name "laboratorio_volt-$ISSUE_SLUG" \
    --base-branch main --issue "$ISSUE_NUM" --linear-issue "$ISSUE_ID" \
    --parent-worktree "path:$ROOT_DIR" --setup skip \
    --comment "Laboratório Volt issue $ISSUE_ID (coordinator)" --json >/dev/null 2>&1 || true
fi

# Ajustar branch do coordenador
if [ -d "$orca_worktree_dir" ]; then
  git -C "$orca_worktree_dir" checkout -B "$ISSUE_BRANCH" >/dev/null 2>&1 || true
  printf '✓ Workspace · coordinator · ready (%s)\n' "$ISSUE_BRANCH"
fi

# 3. Provisionar os 3 repositórios
PROJS=("portal-agro" "pmoc-pro" "marketing-hub")

for proj in "${PROJS[@]}"; do
  source_path="$STATE_DIR/sources/$proj"
  wt_path="$STATE_DIR/worktrees/$ISSUE_ID/$proj"

  [ -d "$source_path" ] || {
    printf 'Erro: Fonte %s nao existe em %s\n' "$proj" "$source_path" >&2
    exit 1
  }

  printf '→ %s · issue worktree · preparing\n' "$proj"
  base_branch="$(git -C "$source_path" branch --show-current 2>/dev/null || echo "main")"
  [ -n "$base_branch" ] || base_branch="main"
  if [ ! -d "$wt_path" ]; then
    git -C "$source_path" worktree add -B "$ISSUE_BRANCH" "$wt_path" "$base_branch" >/dev/null 2>&1 || \
    git -C "$source_path" worktree add "$wt_path" "$ISSUE_BRANCH" >/dev/null 2>&1
  else
    git -C "$wt_path" checkout "$ISSUE_BRANCH" >/dev/null 2>&1 || true
  fi
  printf '✓ %s · issue worktree · ready (%s)\n' "$proj" "$ISSUE_BRANCH"
done

# 4. Salvar estado da issue
cat <<ENV > "$STATE_DIR/issues/$ISSUE_ID.env"
ISSUE_ID=$ISSUE_ID
ISSUE_NUMBER=$ISSUE_NUM
ISSUE_TYPE=improvement
ISSUE_BRANCH=$ISSUE_BRANCH
WORKSPACE_REPO_ID=$workspace_repo_id
WORKSPACE_WORKTREE_PATH=$orca_worktree_dir
WORKSPACE_BRANCH=$ISSUE_BRANCH
PORTAL_AGRO_WORKTREE_PATH=$STATE_DIR/worktrees/$ISSUE_ID/portal-agro
PORTAL_AGRO_BRANCH=$ISSUE_BRANCH
PMOC_PRO_WORKTREE_PATH=$STATE_DIR/worktrees/$ISSUE_ID/pmoc-pro
PMOC_PRO_BRANCH=$ISSUE_BRANCH
MARKETING_HUB_WORKTREE_PATH=$STATE_DIR/worktrees/$ISSUE_ID/marketing-hub
MARKETING_HUB_BRANCH=$ISSUE_BRANCH
ENV

printf '%s\n' "$ISSUE_ID" > "$STATE_DIR/current_issue"

printf '✓ Issue %s provisionada com sucesso no Laboratório Volt!\n' "$ISSUE_ID"
