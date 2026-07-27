#!/usr/bin/env bash
# =============================================================================
# rebuild-graph.sh — reconstrói o FalkorDB (grafo, embeddings, comunidades) a
# partir do Postgres, que é o sistema de registro.
#
# POR QUE ISTO PRECISA DE CRON, e não é só um passo de deploy:
# o backend NUNCA escreve no grafo durante a operação normal — `SaveToGraph`
# só é chamado por este rebuild (internal/rebuild/targets.go). Criar memória
# grava no Postgres; o grafo só enxerga isso no próximo rebuild. Sem agendar,
# /v1/graph/ego, GraphRAG e comunidades respondem com um retrato congelado no
# último rebuild — e, num deploy novo, com um grafo VAZIO.
#
# Uso:
#   scripts/rebuild-graph.sh                 # graph,embeddings,communities
#   scripts/rebuild-graph.sh graph           # só um alvo
#   scripts/rebuild-graph.sh --dry-run       # mostra o que faria
#
# Cron diário (na VPS), depois do backup:
#   30 3 * * * cd /opt/brainsentry-devops && ./scripts/rebuild-graph.sh >> /var/log/bs-rebuild.log 2>&1
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
ENV_FILE="${ENV_FILE:-$PROJECT_DIR/.env}"
# shellcheck disable=SC1090
[[ -f "$ENV_FILE" ]] && { set -a; source "$ENV_FILE"; set +a; }

BACKEND_CONTAINER="${BACKEND_CONTAINER:-brainsentry-backend}"
DRY=0
TARGETS="graph,embeddings,communities"
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY=1 ;;
    -*) echo "opção desconhecida: $arg" >&2; exit 2 ;;
    *)  TARGETS="$arg" ;;
  esac
done

docker ps --format '{{.Names}}' | grep -qx "$BACKEND_CONTAINER" \
  || { echo "FATAL: $BACKEND_CONTAINER não está rodando." >&2; exit 1; }

echo "[rebuild] alvos: $TARGETS"

# Sem --confirm-destructive o binário só faz dry-run e sai com 0 — fácil de
# achar que rodou quando não rodou. Por isso o flag é explícito aqui.
if [[ "$DRY" == "1" ]]; then
  docker exec "$BACKEND_CONTAINER" /app/brainsentry --rebuild "$TARGETS"
  exit 0
fi

out="$(docker exec "$BACKEND_CONTAINER" /app/brainsentry --rebuild "$TARGETS" --confirm-destructive 2>&1)"
echo "$out" | grep -E "rebuild —|\[PASS\]|\[FAIL\]" || echo "$out" | tail -5

# Falha explícita: em cron, silêncio não pode passar por sucesso.
if echo "$out" | grep -q "\[FAIL\]"; then
  echo "[rebuild] ALGUM ALVO FALHOU" >&2
  exit 1
fi
echo "[rebuild] ok"
