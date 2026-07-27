#!/usr/bin/env bash
# =============================================================================
# setup.sh — cria o .env a partir do .env.example e gera os segredos que
# faltam. Idempotente: valores JÁ PREENCHIDOS no .env nunca são sobrescritos
# (rodar de novo depois de um deploy não invalida sessões nem quebra o banco).
#
# Uso:  scripts/setup.sh
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_DIR"

ENV_FILE="${ENV_FILE:-$PROJECT_DIR/.env}"

if [[ ! -f "$ENV_FILE" ]]; then
  cp .env.example "$ENV_FILE"
  chmod 600 "$ENV_FILE"
  echo "[setup] .env criado a partir de .env.example"
else
  echo "[setup] .env já existe — preenchendo só o que estiver vazio"
fi

# Preenche KEY= (vazio) com um valor gerado. Não toca em chaves já preenchidas.
fill() {
  local key="$1" value="$2" label="$3"
  local current
  current="$(grep -E "^${key}=" "$ENV_FILE" | head -1 | cut -d= -f2- | sed 's/[[:space:]]*#.*$//' | xargs || true)"
  if [[ -n "$current" ]]; then
    echo "  $key — já definido (mantido)"
    return
  fi
  # O separador | evita colisão com / e + do base64.
  if grep -qE "^${key}=" "$ENV_FILE"; then
    sed -i.bak "s|^${key}=.*|${key}=${value}|" "$ENV_FILE" && rm -f "${ENV_FILE}.bak"
  else
    printf '%s=%s\n' "$key" "$value" >> "$ENV_FILE"
  fi
  echo "  $key — gerado ($label)"
}

# openssl rand -hex nunca produz caracteres que precisem de escape em .env,
# em URL de conexão do Postgres ou em linha de comando do redis.
fill JWT_SECRET                          "$(openssl rand -hex 32)" "64 hex chars"
fill BRAINSENTRY_DB_PASSWORD             "$(openssl rand -hex 16)" "32 hex chars"
fill FALKORDB_PASSWORD                   "$(openssl rand -hex 16)" "32 hex chars"
fill BRAINSENTRY_ADMIN_PASSWORD          "$(openssl rand -base64 18 | tr -d '/+=' | cut -c1-20)" "senha do admin"

chmod 600 "$ENV_FILE"

echo
echo "[setup] ok. Falta preencher à mão (se ainda não estiver):"
grep -nE '^(BRAINSENTRY_AI_AGENTIC_MODEL_API_KEY|CLOUDFLARE_API_TOKEN)=$' "$ENV_FILE" || echo "  (nada — tudo preenchido)"
echo
echo "Senha do admin inicial (anote, ela não é recuperável do hash):"
grep -E '^BRAINSENTRY_ADMIN_(EMAIL|PASSWORD)=' "$ENV_FILE" | sed 's/^/  /'
