#!/usr/bin/env bash
# Hit /api/health + /api/version on the running stack and report. Exits
# non-zero on any failure so it's usable in alerting/healthcheck loops.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_DIR"

# shellcheck disable=SC1091
[ -f .env ] && source .env
HOST="${HEALTH_CHECK_HOST:-localhost}"
BACKEND_PORT="${BRAINSENTRY_BACKEND_PORT:-8081}"
FRONTEND_PORT="${BRAINSENTRY_FRONTEND_PORT:-8086}"

check() {
    local label="$1"; local url="$2"
    local code
    code=$(curl -fsS -o /dev/null -w "%{http_code}" --max-time 5 "$url" || echo "000")
    if [ "$code" = "200" ]; then
        echo "  [ok] ${label}  (${url})"
        return 0
    else
        echo "  [fail] ${label}  (${url})  HTTP ${code}"
        return 1
    fi
}

echo "Health check against http://${HOST}:..."
failed=0

check "backend /api/health" "http://${HOST}:${BACKEND_PORT}/api/health" || failed=1
check "frontend /"          "http://${HOST}:${FRONTEND_PORT}/"          || failed=1
check "frontend /api/health (proxied)" \
      "http://${HOST}:${FRONTEND_PORT}/api/health" || failed=1

echo
echo "Build identity:"
curl -fsS --max-time 5 "http://${HOST}:${BACKEND_PORT}/api/version" 2>/dev/null \
  | python3 -m json.tool 2>/dev/null \
  || echo "  (could not fetch /api/version)"

if [ "$failed" -ne 0 ]; then
    echo
    echo "FAIL — see logs:"
    echo "  docker service logs ${STACK_NAME:-brainsentry}_brainsentry-backend"
    echo "  docker service logs ${STACK_NAME:-brainsentry}_brainsentry-frontend"
    exit 1
fi

echo
echo "All checks passed."
