#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/control-plane.sh
source "$SCRIPT_DIR/lib/control-plane.sh"

action="${1:-}"
[ "$#" -eq 1 ] && [ "$action" = ensure ] || die "Usage: runtime-dev-account.sh ensure"

load_config
require_command docker
selected_issue_state
validate_runtime_worktrees
derive_runtime_routes

runtime_env_file="$STATE_DIR/runtime/$ISSUE_ID/compose.env"
[ -f "$runtime_env_file" ] || die "Runtime environment was not generated: $runtime_env_file"

compose_command=(docker compose --project-name "$WORKSPACE_COMPOSE_PROJECT" \
  --env-file "$runtime_env_file" -f "$ROOT_DIR/docker-compose.yml")

"${compose_command[@]}" exec -T crm-web bundle exec rails runner - \
  < "$SCRIPT_DIR/development-account.rb"
