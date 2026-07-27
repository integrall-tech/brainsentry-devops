#!/usr/bin/env bash
# =============================================================================
# undeploy.sh — derruba a stack brainsentry.
#   scripts/undeploy.sh                 # para os containers (dados preservados)
#   scripts/undeploy.sh --purge-graph   # apaga também o volume do FalkorDB
#   scripts/undeploy.sh --purge-db      # DROPa o database no pg compartilhado
#
# O bloco do Caddy é removido em qualquer caso (senão sobra rota 502).
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_DIR"

ENV_FILE="${ENV_FILE:-$PROJECT_DIR/.env}"
# shellcheck disable=SC1090
[[ -f "$ENV_FILE" ]] && { set -a; source "$ENV_FILE"; set +a; }

PURGE_GRAPH=0
PURGE_DB=0
for arg in "$@"; do
  case "$arg" in
    --purge-graph) PURGE_GRAPH=1 ;;
    --purge-db)    PURGE_DB=1 ;;
    *) echo "opção desconhecida: $arg" >&2; exit 2 ;;
  esac
done

dc() { docker compose --env-file "$ENV_FILE" "$@"; }

echo "[undeploy] parando a stack…"
if [[ "$PURGE_GRAPH" == "1" ]]; then
  dc -f docker-compose.yml down -v   # -v apaga falkordb_data junto
else
  dc -f docker-compose.yml down
fi
dc -f docker-compose.webhook.yml down 2>/dev/null || true

echo "[undeploy] removendo o bloco do Caddy…"
CADDYFILE_HOST="${CADDYFILE_HOST:-/opt/bluevix/caddy/Caddyfile}"
CADDY_CONTAINER="${CADDY_CONTAINER:-bluevix-caddy}"
if [[ -f "$CADDYFILE_HOST" ]]; then
  cp -a "$CADDYFILE_HOST" "${CADDYFILE_HOST}.brainsentry.bak.$(date -u +%Y%m%dT%H%M%SZ)"
  TMP="$(mktemp)"
  awk -v b="# >>> brainsentry >>>" -v e="# <<< brainsentry <<<" '
    index($0,b)==1          {inblk=1; next}
    inblk && index($0,e)==1 {inblk=0; next}
    !inblk {print}
  ' "$CADDYFILE_HOST" > "$TMP"
  if docker exec -i "$CADDY_CONTAINER" caddy validate --adapter caddyfile --config - < "$TMP" >/dev/null 2>&1; then
    cp "$TMP" "$CADDYFILE_HOST"
    docker exec "$CADDY_CONTAINER" caddy reload --config /etc/caddy/Caddyfile
    echo "  bloco removido e Caddy recarregado"
  else
    echo "  AVISO: Caddyfile resultante inválido — bloco NÃO removido ($TMP)" >&2
  fi
fi

if [[ "$PURGE_DB" == "1" ]]; then
  PG_CONTAINER="${POSTGRES_ADMIN_CONTAINER:-bluevix-postgres}"
  PG_ADMIN="${POSTGRES_ADMIN_USER:-bluevix}"
  DB_NAME="${BRAINSENTRY_DB_NAME:-brainsentry}"
  echo "ATENÇÃO: isto APAGA o database '${DB_NAME}' e todos os dados."
  read -r -p "Digite 'apagar' para confirmar: " answer
  if [[ "$answer" == "apagar" ]]; then
    docker exec -i "$PG_CONTAINER" psql -U "$PG_ADMIN" -d postgres \
      -c "DROP DATABASE IF EXISTS \"${DB_NAME}\" WITH (FORCE);" >/dev/null
    echo "  database removido"
  else
    echo "  abortado (database preservado)"
  fi
fi

echo "[undeploy] ok"
