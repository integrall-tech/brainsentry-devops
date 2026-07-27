#!/usr/bin/env bash
# =============================================================================
# ensure-db.sh — cria (idempotente) role + database "brainsentry" no Postgres
# compartilhado da VPS (bluevix-postgres) e instala a extensão pgvector nele.
#
# CREATE EXTENSION exige superusuário: por isso roda com o admin do container
# (POSTGRES_ADMIN_USER), não com o role da aplicação. A migração 8 cria
# colunas vector(1536) e falha se a extensão não existir.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
ENV_FILE="${ENV_FILE:-$PROJECT_DIR/.env}"

[[ -f "$ENV_FILE" ]] || { echo "FATAL: $ENV_FILE ausente. Rode scripts/setup.sh antes." >&2; exit 1; }
# shellcheck disable=SC1090
set -a; source "$ENV_FILE"; set +a

PG_CONTAINER="${POSTGRES_ADMIN_CONTAINER:-bluevix-postgres}"
PG_ADMIN="${POSTGRES_ADMIN_USER:-bluevix}"
DB_USER="${BRAINSENTRY_DB_USER:-brainsentry}"
DB_NAME="${BRAINSENTRY_DB_NAME:-brainsentry}"
DB_PASS="${BRAINSENTRY_DB_PASSWORD:?BRAINSENTRY_DB_PASSWORD obrigatório}"

echo "[ensure-db] Postgres=$PG_CONTAINER admin=$PG_ADMIN → role/db=$DB_NAME"

docker ps --format '{{.Names}}' | grep -qx "$PG_CONTAINER" \
  || { echo "FATAL: container $PG_CONTAINER não está rodando." >&2; exit 1; }

psql_admin()    { docker exec -i "$PG_CONTAINER" psql -v ON_ERROR_STOP=1 -U "$PG_ADMIN" -d postgres "$@"; }
psql_admin_app(){ docker exec -i "$PG_CONTAINER" psql -v ON_ERROR_STOP=1 -U "$PG_ADMIN" -d "$DB_NAME" "$@"; }

# Role (cria se não existe; sempre sincroniza a senha com o .env).
if [[ "$(psql_admin -tAc "SELECT 1 FROM pg_roles WHERE rolname='${DB_USER}'")" == "1" ]]; then
  echo "  role ${DB_USER} já existe — atualizando senha"
  psql_admin -c "ALTER ROLE \"${DB_USER}\" WITH LOGIN PASSWORD '${DB_PASS}';" >/dev/null
else
  echo "  criando role ${DB_USER}"
  psql_admin -c "CREATE ROLE \"${DB_USER}\" WITH LOGIN PASSWORD '${DB_PASS}';" >/dev/null
fi

# Database (owner = role da aplicação).
if [[ "$(psql_admin -tAc "SELECT 1 FROM pg_database WHERE datname='${DB_NAME}'")" == "1" ]]; then
  echo "  database ${DB_NAME} já existe"
else
  echo "  criando database ${DB_NAME}"
  psql_admin -c "CREATE DATABASE \"${DB_NAME}\" OWNER \"${DB_USER}\";" >/dev/null
fi

# pgvector — no database da aplicação, como superusuário.
echo "  garantindo extensão vector em ${DB_NAME}"
psql_admin_app -c "CREATE EXTENSION IF NOT EXISTS vector;" >/dev/null

# O owner do schema public no PG15+ é o role pg_database_owner; garantir o
# privilégio explícito evita "permission denied for schema public" nas migrações.
psql_admin_app -c "GRANT ALL ON SCHEMA public TO \"${DB_USER}\";" >/dev/null

echo "[ensure-db] ok"
