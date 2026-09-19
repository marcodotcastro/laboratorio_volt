#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

ISSUE_NUM="${1:-1000}"
ISSUE_ID="CC-$ISSUE_NUM"
WORKTREE_DIR="$ROOT_DIR/.workspace/worktrees/$ISSUE_ID"
LOG_DIR="$ROOT_DIR/.workspace/logs/$ISSUE_ID"
RUN_DIR="$ROOT_DIR/.workspace/run/$ISSUE_ID"

mkdir -p "$LOG_DIR" "$RUN_DIR"

printf "→ Iniciando serviços para a issue %s...\n" "$ISSUE_ID"

# 1. Iniciar dependências do PMOC (Postgres e Redis)
printf "→ Garantindo dependências do PMOC (Postgres + Redis)...\n"
cd "$WORKTREE_DIR/pmoc-pro/pmoc-rails"
docker compose up -d postgres redis

# 2. Portal Agro (Porta 43001 -> Caddy :3001)
printf "→ Iniciando Portal Agro na porta 43001...\n"
cd "$WORKTREE_DIR/portal-agro"
rm -f tmp/pids/server.pid
nohup bundle exec rails server -b 0.0.0.0 -p 43001 > "$LOG_DIR/portal-agro.log" 2>&1 &
echo $! > "$RUN_DIR/portal-agro.pid"

# 3. PMOC Pro (Porta 43002 -> Caddy :3002)
printf "→ Iniciando PMOC Pro na porta 43002...\n"
cd "$WORKTREE_DIR/pmoc-pro/pmoc-rails"
rm -f tmp/pids/server.pid
nohup bundle exec rails server -b 0.0.0.0 -p 43002 > "$LOG_DIR/pmoc-pro.log" 2>&1 &
echo $! > "$RUN_DIR/pmoc-pro.pid"

printf "→ Aguardando inicialização dos servidores...\n"
for i in {1..30}; do
  portal_ok=0
  pmoc_ok=0

  if curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:43001 | grep -qE '^[23]'; then
    portal_ok=1
  fi

  if curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:43002 | grep -qE '^[23]'; then
    pmoc_ok=1
  fi

  if [ "$portal_ok" -eq 1 ] && [ "$pmoc_ok" -eq 1 ]; then
    printf "✓ Ambos os servidores Rails responderam com sucesso!\n"
    break
  fi

  sleep 1
done

printf "\n=== STATUS DOS SERVIÇOS DA ISSUE %s ===\n" "$ISSUE_ID"
printf "Hub Central: http://cc%s.localhost (Porta 80 e 3000)\n" "$ISSUE_NUM"
printf "Portal Agro: http://cc%s.localhost:3001 (Proxy -> :43001)\n" "$ISSUE_NUM"
printf "PMOC Pro:    http://cc%s.localhost:3002 (Proxy -> :43002)\n" "$ISSUE_NUM"
