#!/usr/bin/env bash
# =============================================================================
# health-check.sh — verifica a stack de dentro (containers) e de fora (HTTPS).
# Sai != 0 se algum check obrigatório falhar.
# =============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
ENV_FILE="${ENV_FILE:-$PROJECT_DIR/.env}"
# shellcheck disable=SC1090
[[ -f "$ENV_FILE" ]] && { set -a; source "$ENV_FILE"; set +a; }
ROOT_DOMAIN="${ROOT_DOMAIN:-brainsentry.com.br}"

fail=0
ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$*"; fail=1; }
warn() { printf '  \033[33m!\033[0m %s\n' "$*"; }

echo "── containers ──"
for c in brainsentry-falkordb brainsentry-backend brainsentry-frontend; do
  st="$(docker inspect --format '{{.State.Status}}/{{if .State.Health}}{{.State.Health.Status}}{{else}}-{{end}}' "$c" 2>/dev/null)"
  case "$st" in
    running/healthy) ok  "$c ($st)" ;;
    running/-)       ok  "$c (running, sem healthcheck)" ;;
    "")              bad "$c não existe" ;;
    *)               bad "$c ($st)" ;;
  esac
done

echo "── API (rede interna) ──"
if docker exec brainsentry-backend curl -fsS http://127.0.0.1:8081/api/health >/dev/null 2>&1; then
  ok "/api/health"
else
  bad "/api/health não respondeu"
fi
ver="$(docker exec brainsentry-backend curl -fsS http://127.0.0.1:8081/api/version 2>/dev/null)"
[[ -n "$ver" ]] && ok "/api/version → $ver" || warn "/api/version não respondeu"

echo "── dependências ──"
# O /api/health do backend reporta postgres/redis/falkordb; imprime o detalhe.
detail="$(docker exec brainsentry-backend curl -fsS http://127.0.0.1:8081/api/health 2>/dev/null)"
[[ -n "$detail" ]] && printf '  %s\n' "$detail"

echo "── proxy interno do SPA ──"
if docker exec brainsentry-frontend wget -q -O- http://127.0.0.1/api/version >/dev/null 2>&1; then
  ok "nginx → /api/version"
else
  bad "nginx não alcança o backend em /api/*"
fi

echo "── HTTPS (público) ──"
for host in "app.${ROOT_DOMAIN}" "api.${ROOT_DOMAIN}"; do
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "https://${host}/" 2>/dev/null)"
  case "$code" in
    200|301|302|401|404) ok "https://${host}/ → HTTP $code" ;;
    000) warn "https://${host}/ inacessível (DNS ainda não propagou ou TLS não emitido)" ;;
    *)   warn "https://${host}/ → HTTP $code" ;;
  esac
done

echo
[[ "$fail" == "0" ]] && echo "health-check: OK" || echo "health-check: FALHOU"
exit "$fail"
