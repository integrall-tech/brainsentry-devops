#!/usr/bin/env bash
# =============================================================================
# dns-sync.sh — cria/atualiza na Cloudflare os registros A do brainsentry
# apontando para a VPS. Idempotente (PUT quando o registro já existe).
#
#   scripts/dns-sync.sh            # aplica
#   scripts/dns-sync.sh --dry-run  # só mostra o que faria
#
# IMPORTANTE — proxied=false: o Caddy emite o certificado por HTTP-01, que
# exige que o :80 do domínio chegue ATÉ a VPS. Com o proxy laranja ligado a
# Cloudflare termina o TLS antes e o desafio nunca chega — o Caddy fica em
# retry e o host responde 525/526.
#
# Token: CLOUDFLARE_API_TOKEN no .env, ou ~/.env-projetos/api_token_cloudflare.
# Escopos necessários: Zone:Read + DNS:Edit na zona do ROOT_DOMAIN.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
ENV_FILE="${ENV_FILE:-$PROJECT_DIR/.env}"

# shellcheck disable=SC1090
[[ -f "$ENV_FILE" ]] && { set -a; source "$ENV_FILE"; set +a; }

DRY=0
[[ "${1:-}" == "--dry-run" ]] && DRY=1

ROOT_DOMAIN="${ROOT_DOMAIN:?ROOT_DOMAIN obrigatório}"
VPS_IP="${VPS_IP:?VPS_IP obrigatório}"
TOKEN="${CLOUDFLARE_API_TOKEN:-}"
if [[ -z "$TOKEN" && -f "$HOME/.env-projetos/api_token_cloudflare" ]]; then
  TOKEN="$(tr -d '[:space:]' < "$HOME/.env-projetos/api_token_cloudflare")"
fi
[[ -n "$TOKEN" ]] || { echo "FATAL: CLOUDFLARE_API_TOKEN não definido." >&2; exit 1; }

command -v jq >/dev/null || { echo "FATAL: jq é necessário." >&2; exit 1; }

API="https://api.cloudflare.com/client/v4"
cf() { curl -fsS -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" "$@"; }

ZONE_ID="$(cf "$API/zones?name=${ROOT_DOMAIN}" | jq -r '.result[0].id // empty')"
[[ -n "$ZONE_ID" ]] || { echo "FATAL: zona ${ROOT_DOMAIN} não encontrada (token tem Zone:Read?)." >&2; exit 1; }
echo "[dns] zona ${ROOT_DOMAIN} → ${ZONE_ID}"

# Subdomínios servidos pelo Caddy da VPS. O apex entra como "@".
RECORDS=("@" "www" "app" "api" "deploy")

for sub in "${RECORDS[@]}"; do
  if [[ "$sub" == "@" ]]; then name="$ROOT_DOMAIN"; else name="${sub}.${ROOT_DOMAIN}"; fi
  rec_id="$(cf "$API/zones/$ZONE_ID/dns_records?type=A&name=${name}" | jq -r '.result[0].id // empty')"
  body="$(jq -nc --arg n "$name" --arg ip "$VPS_IP" \
          '{type:"A",name:$n,content:$ip,ttl:300,proxied:false}')"

  if [[ "$DRY" == "1" ]]; then
    echo "  [dry-run] ${name} → ${VPS_IP} ($([[ -n "$rec_id" ]] && echo update || echo create))"
    continue
  fi

  if [[ -n "$rec_id" ]]; then
    cf -X PUT "$API/zones/$ZONE_ID/dns_records/$rec_id" --data "$body" >/dev/null
    echo "  atualizado: ${name} → ${VPS_IP}"
  else
    cf -X POST "$API/zones/$ZONE_ID/dns_records" --data "$body" >/dev/null
    echo "  criado:     ${name} → ${VPS_IP}"
  fi
done

echo "[dns] ok — verifique com: dig +short app.${ROOT_DOMAIN}"
