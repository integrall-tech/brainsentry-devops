#!/usr/bin/env bash
# =============================================================================
# migrate.sh — aplica as migrações do brainsentry no Postgres compartilhado.
#
# O binário NÃO auto-migra (por decisão do projeto). Os .up.sql viajam DENTRO
# da imagem do backend em /app/migrations — por isso a ordem no upgrade é:
#   1) atualizar a imagem do backend   2) migrate.sh   3) atualizar o frontend
# (ver docs/RELEASE.md).
#
# Uso:
#   scripts/migrate.sh                 # migrações de dentro da imagem (padrão)
#   scripts/migrate.sh /path/to/dir    # migrações de um diretório do host
#
# Idempotente: as migrações usam IF NOT EXISTS / ON CONFLICT DO NOTHING.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
ENV_FILE="${ENV_FILE:-$PROJECT_DIR/.env}"

[[ -f "$ENV_FILE" ]] || { echo "FATAL: $ENV_FILE ausente." >&2; exit 1; }
# shellcheck disable=SC1090
set -a; source "$ENV_FILE"; set +a

PG_CONTAINER="${POSTGRES_ADMIN_CONTAINER:-bluevix-postgres}"
DB_NAME="${BRAINSENTRY_DB_NAME:-brainsentry}"
DB_USER="${BRAINSENTRY_DB_USER:-brainsentry}"
BACKEND_CONTAINER="${BACKEND_CONTAINER:-brainsentry-backend}"
MIGRATIONS_SRC="${1:-}"

docker ps --format '{{.Names}}' | grep -qx "$PG_CONTAINER" \
  || { echo "FATAL: container $PG_CONTAINER não está rodando." >&2; exit 1; }

# psql pelo socket unix do container: pg_hba local = trust na imagem oficial,
# então não precisamos passar senha (e ela não vaza para o histórico/ps).
psql_app() { docker exec -i "$PG_CONTAINER" psql -v ON_ERROR_STOP=1 -U "$DB_USER" -d "$DB_NAME" "$@"; }

echo "[migrate] alvo: ${PG_CONTAINER}/${DB_NAME} (role ${DB_USER})"

# A extensão é criada por ensure-db.sh (exige superusuário). Só conferimos.
if [[ "$(psql_app -tAc "SELECT 1 FROM pg_extension WHERE extname='vector'")" != "1" ]]; then
  echo "FATAL: extensão pgvector ausente em ${DB_NAME}. Rode scripts/ensure-db.sh." >&2
  exit 1
fi

apply_from_host() {
  local f="$1"
  echo "[migrate] aplicando $(basename "$f")"
  psql_app < "$f" >/dev/null
}

apply_from_image() {
  local f="$1"
  echo "[migrate] aplicando $(basename "$f")"
  docker exec "$BACKEND_CONTAINER" cat "$f" | psql_app >/dev/null
}

if [[ -n "$MIGRATIONS_SRC" ]]; then
  [[ -d "$MIGRATIONS_SRC" ]] || { echo "FATAL: $MIGRATIONS_SRC não é um diretório" >&2; exit 1; }
  files="$(find "$MIGRATIONS_SRC" -maxdepth 1 -name '0*.up.sql' | sort)"
  [[ -n "$files" ]] || { echo "FATAL: nenhum .up.sql em $MIGRATIONS_SRC" >&2; exit 1; }
  while IFS= read -r f; do apply_from_host "$f"; done <<< "$files"
else
  docker ps --format '{{.Names}}' | grep -qx "$BACKEND_CONTAINER" \
    || { echo "FATAL: $BACKEND_CONTAINER não está rodando (é dele que vêm os .sql)." >&2
         echo "       alternativa: scripts/migrate.sh /caminho/para/migrations" >&2; exit 1; }
  files="$(docker exec "$BACKEND_CONTAINER" sh -c 'ls /app/migrations/0*.up.sql' | sort)"
  [[ -n "$files" ]] || { echo "FATAL: nenhuma migração em /app/migrations da imagem" >&2; exit 1; }
  while IFS= read -r f; do apply_from_image "$f"; done <<< "$files"
fi

echo
echo "[migrate] ok — $(psql_app -tAc "SELECT count(*) FROM information_schema.tables WHERE table_schema='public'" | xargs) tabelas em public"
