#!/usr/bin/env bash
# =============================================================================
# seed-admin.sh — cria (ou reseta a senha do) usuário admin inicial.
#
# Por que SQL: a API não tem rota pública de registro (POST /v1/users exige
# um token com role ADMIN) e POST /v1/auth/demo só existe fora de produção.
# Então o PRIMEIRO admin nasce direto no banco; os demais saem da UI/API.
#
# O hash é bcrypt cost 12 (security.bcrypt_cost), gerado pelo htpasswd do
# httpd:2.4-alpine. Ele emite o prefixo $2y$ — aceito pelo
# golang.org/x/crypto/bcrypt, que trata o "minor version" como opaco.
#
# Uso:  scripts/seed-admin.sh            # usa BRAINSENTRY_ADMIN_* do .env
#       scripts/seed-admin.sh --reset    # sobrescreve a senha se já existir
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
ENV_FILE="${ENV_FILE:-$PROJECT_DIR/.env}"

[[ -f "$ENV_FILE" ]] || { echo "FATAL: $ENV_FILE ausente." >&2; exit 1; }
# shellcheck disable=SC1090
set -a; source "$ENV_FILE"; set +a

RESET=0
[[ "${1:-}" == "--reset" ]] && RESET=1

PG_CONTAINER="${POSTGRES_ADMIN_CONTAINER:-bluevix-postgres}"
DB_NAME="${BRAINSENTRY_DB_NAME:-brainsentry}"
DB_USER="${BRAINSENTRY_DB_USER:-brainsentry}"
EMAIL="${BRAINSENTRY_ADMIN_EMAIL:?BRAINSENTRY_ADMIN_EMAIL obrigatório}"
NAME="${BRAINSENTRY_ADMIN_NAME:-Admin}"
PASSWORD="${BRAINSENTRY_ADMIN_PASSWORD:?BRAINSENTRY_ADMIN_PASSWORD obrigatório}"
# Tenant padrão criado pela migração 1.
TENANT_ID="${BRAINSENTRY_TENANT_ID:-a9f814d2-4dae-41f3-851b-8aa3d4706561}"

psql_app() { docker exec -i "$PG_CONTAINER" psql -v ON_ERROR_STOP=1 -U "$DB_USER" -d "$DB_NAME" "$@"; }

existing="$(psql_app -tAc "SELECT id FROM users WHERE email='${EMAIL}'" | xargs || true)"
if [[ -n "$existing" && "$RESET" == "0" ]]; then
  echo "[seed-admin] usuário ${EMAIL} já existe (id=${existing}) — nada a fazer."
  echo "             use --reset para redefinir a senha para BRAINSENTRY_ADMIN_PASSWORD."
  exit 0
fi

echo "[seed-admin] gerando hash bcrypt (cost 12)…"
# htpasswd emite "user:hash"; o usuário aqui é descartável — só o hash importa.
HASH="$(docker run --rm httpd:2.4-alpine htpasswd -bnBC 12 seed "$PASSWORD" | tr -d '\n' | cut -d: -f2-)"
[[ "$HASH" == \$2* ]] || { echo "FATAL: hash bcrypt inesperado: ${HASH:0:8}…" >&2; exit 1; }

USER_ID="${existing:-$(cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen | tr 'A-Z' 'a-z')}"

# A senha nunca entra na linha de comando: vai por stdin como variável psql.
psql_app -v uid="$USER_ID" -v email="$EMAIL" -v name="$NAME" \
         -v hash="$HASH" -v tenant="$TENANT_ID" >/dev/null <<'SQL'
INSERT INTO users (id, email, name, password_hash, tenant_id, active, email_verified)
VALUES (:'uid', :'email', :'name', :'hash', :'tenant', true, true)
ON CONFLICT (email) DO UPDATE
  SET password_hash = EXCLUDED.password_hash,
      name          = EXCLUDED.name,
      active        = true;

INSERT INTO user_roles (user_id, role)
SELECT id, 'ADMIN' FROM users WHERE email = :'email'
ON CONFLICT DO NOTHING;
SQL

echo "[seed-admin] ok"
echo "  email: $EMAIL"
echo "  senha: (BRAINSENTRY_ADMIN_PASSWORD do .env)"
echo "  role : ADMIN   tenant: $TENANT_ID"
