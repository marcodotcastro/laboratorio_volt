#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/control-plane.sh
source "$SCRIPT_DIR/lib/control-plane.sh"

load_config
require_command git
prepare_repositories >/dev/null
printf 'Repositories are ready for Orca worktree creation.\n'
