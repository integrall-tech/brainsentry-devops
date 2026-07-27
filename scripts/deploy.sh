#!/usr/bin/env bash
# =============================================================================
# deploy.sh — sobe/atualiza a stack brainsentry na VPS.
#   1) role+db+pgvector no Postgres compartilhado
#   2) sobe falkordb + backend + frontend
#   3) migrações (os .sql vêm de dentro da imagem do backend)
#   4) admin inicial (idempotente)
#   5) roteamento no Caddy compartilhado
#   6) (opcional) receiver de CD
# Uso:
#   scripts/deploy.sh              # tudo, menos o webhook
#   scripts/deploy.sh --webhook    # também sobe o receiver de CD
#   scripts/deploy.sh --no-migrate # pula as migrações
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_DIR"

ENV_FILE="${ENV_FILE:-$PROJECT_DIR/.env}"
WITH_WEBHOOK=0
DO_MIGRATE=1
for arg in "$@"; do
  case "$arg" in
    --webhook)    WITH_WEBHOOK=1 ;;
    --no-migrate) DO_MIGRATE=0 ;;
    *) echo "opção desconhecida: $arg" >&2; exit 2 ;;
  esac
done

dc() { docker compose --env-file "$ENV_FILE" "$@"; }

echo "==================================================================="
echo " brainsentry — deploy (docker compose, VPS)"
echo "==================================================================="

[[ -f "$ENV_FILE" ]] || { echo "FATAL: $ENV_FILE ausente. Rode scripts/setup.sh antes." >&2; exit 1; }
# shellcheck disable=SC1090
set -a; source "$ENV_FILE"; set +a

# Pré-requisitos da VPS: as redes e o Caddy do bluevix.
for net in bluevix_web bluevix_internal; do
  docker network inspect "$net" >/dev/null 2>&1 \
    || { echo "FATAL: rede $net não existe (a stack bluevix está no ar?)." >&2; exit 1; }
done

echo "[1/6] Garantindo role/database/pgvector no Postgres compartilhado…"
"$SCRIPT_DIR/ensure-db.sh"

echo "[2/6] Baixando imagens e subindo a stack…"
dc -f docker-compose.yml pull
dc -f docker-compose.yml up -d --remove-orphans

echo "[3/6] Aguardando health do backend…"
status=""
for _ in $(seq 1 45); do
  status="$(docker inspect --format '{{.State.Health.Status}}' brainsentry-backend 2>/dev/null || echo starting)"
  [[ "$status" == "healthy" ]] && break
  printf "."; sleep 2
done
echo " ${status:-?}"
if [[ "$status" != "healthy" ]]; then
  echo "AVISO: backend não ficou healthy. Últimas linhas do log:" >&2
  docker logs --tail 40 brainsentry-backend 2>&1 | sed 's/^/  /' >&2
fi

if [[ "$DO_MIGRATE" == "1" ]]; then
  echo "[4/6] Aplicando migrações…"
  "$SCRIPT_DIR/migrate.sh"
  echo "      admin inicial…"
  "$SCRIPT_DIR/seed-admin.sh"
  # O backend abre o pool antes das migrações existirem no primeiro deploy;
  # reiniciar garante que ele enxergue o schema já pronto.
  dc -f docker-compose.yml restart brainsentry-backend >/dev/null
  # O FalkorDB é cache derivado e o backend NUNCA escreve nele em operação
  # normal — sem este passo, /v1/graph/* responde com um grafo vazio depois
  # de um deploy novo. Ver scripts/rebuild-graph.sh (precisa de cron também).
  echo "      reconstruindo o grafo…"
  sleep 5   # o backend precisa estar de pé para o docker exec
  "$SCRIPT_DIR/rebuild-graph.sh" || echo "AVISO: rebuild do grafo falhou (não bloqueia o deploy)" >&2
else
  echo "[4/6] (migrações puladas por --no-migrate)"
fi

echo "[5/6] Sincronizando roteamento no Caddy compartilhado…"
"$SCRIPT_DIR/caddy-sync.sh"

if [[ "$WITH_WEBHOOK" == "1" ]]; then
  echo "[6/6] Subindo receiver de CD…"
  dc -f docker-compose.webhook.yml up -d --build
else
  echo "[6/6] (webhook não solicitado — use --webhook para subir o receiver de CD)"
fi

docker image prune -f >/dev/null 2>&1 || true

echo
echo "Deploy concluído:"
docker ps --format "table {{.Names}}\t{{.Status}}" | grep -E "brainsentry|NAMES" || true
echo
"$SCRIPT_DIR/health-check.sh" || true
