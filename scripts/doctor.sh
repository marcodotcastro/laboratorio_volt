#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/control-plane.sh
source "$SCRIPT_DIR/lib/control-plane.sh"

load_config
for command_name in git jq "$ORCA_BIN" "$MAKE_BIN"; do
  require_command "$command_name"
done
[ -d "$ROOT_DIR/repos" ] || mkdir -p "$ROOT_DIR/repos"
printf 'Control plane dependencies are available.\n'
