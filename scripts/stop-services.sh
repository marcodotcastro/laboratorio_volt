#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

ISSUE_NUM="${1:-1000}"
ISSUE_ID="CC-$ISSUE_NUM"
RUN_DIR="$ROOT_DIR/.workspace/run/$ISSUE_ID"

if [ -f "$RUN_DIR/portal-agro.pid" ]; then
  pid=$(cat "$RUN_DIR/portal-agro.pid")
  printf "Finalizando Portal Agro (PID %s)...\n" "$pid"
  kill "$pid" 2>/dev/null || true
  rm -f "$RUN_DIR/portal-agro.pid"
fi

if [ -f "$RUN_DIR/pmoc-pro.pid" ]; then
  pid=$(cat "$RUN_DIR/pmoc-pro.pid")
  printf "Finalizando PMOC Pro (PID %s)...\n" "$pid"
  kill "$pid" 2>/dev/null || true
  rm -f "$RUN_DIR/pmoc-pro.pid"
fi

printf "✓ Serviços da issue %s finalizados.\n" "$ISSUE_ID"
