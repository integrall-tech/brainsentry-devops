#!/usr/bin/env bash
# Generate the 3 brainsentry-owned swarm secrets (postgres password,
# JWT signing key, LLM API key). Run once per environment. The reused
# secrets (redis_password, falkordb_password) come from dev-env-devops
# and are NOT generated here.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
SECRETS_DIR="${PROJECT_DIR}/secrets"

mkdir -p "$SECRETS_DIR"

write_if_absent() {
    local name="$1"
    local generator="$2"
    local file="${SECRETS_DIR}/${name}.txt"
    if [ -s "$file" ]; then
        echo "  [skip] ${name} already exists (${file})"
        return
    fi
    eval "$generator" > "$file"
    chmod 600 "$file"
    echo "  [ok]   ${name} -> ${file}"
}

echo "Generating brainsentry secrets in ${SECRETS_DIR}/"
write_if_absent brainsentry_postgres_password "openssl rand -base64 32 | tr -d '/+=' | head -c 24"
write_if_absent brainsentry_jwt_secret "openssl rand -base64 48"

LLM_FILE="${SECRETS_DIR}/brainsentry_llm_api_key.txt"
if [ ! -s "$LLM_FILE" ]; then
    echo
    echo "  brainsentry_llm_api_key needs an OpenRouter PAT (or LiteLLM master"
    echo "  key if you route via the internal litellm service). Paste it now"
    echo "  and press Enter (input echoed for verification):"
    read -r LLM_KEY
    if [ -z "$LLM_KEY" ]; then
        echo "  [fail] empty LLM key — re-run when ready"
        exit 1
    fi
    printf '%s' "$LLM_KEY" > "$LLM_FILE"
    chmod 600 "$LLM_FILE"
    echo "  [ok]   brainsentry_llm_api_key -> ${LLM_FILE}"
else
    echo "  [skip] brainsentry_llm_api_key already exists"
fi

echo
echo "Done. The secrets are gitignored and will be mounted into the swarm by"
echo "docker-compose.swarm.yml via the 'secrets:' section."
