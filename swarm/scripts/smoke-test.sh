#!/usr/bin/env bash
# Run the brain-sentry-explorer validation suite against the deployed
# backend. Requires the brainsentry.io repo to be cloned somewhere — by
# default looks at ../brainsentry.io, override with BRAINSENTRY_REPO=<path>.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_DIR"

# shellcheck disable=SC1091
[ -f .env ] && source .env
HOST="${HEALTH_CHECK_HOST:-localhost}"
BACKEND_PORT="${BRAINSENTRY_BACKEND_PORT:-8081}"
BS_BASE_URL="http://${HOST}:${BACKEND_PORT}/api"
BS_REPO="${BRAINSENTRY_REPO:-${PROJECT_DIR}/../brainsentry.io}"
EXPLORER_DIR="${BS_REPO}/brain-sentry-explorer"

if [ ! -d "$EXPLORER_DIR" ]; then
    echo "[fail] brain-sentry-explorer not found at ${EXPLORER_DIR}" >&2
    echo "       Clone brainsentry.io next to brainsentry-devops, or set" >&2
    echo "       BRAINSENTRY_REPO=/path/to/brainsentry.io" >&2
    exit 1
fi

echo "[1/3] verifying backend reachable at ${BS_BASE_URL}/health..."
curl -fsS --max-time 5 "${BS_BASE_URL}/health" >/dev/null

echo "[2/3] installing explorer deps (cached)..."
cd "$EXPLORER_DIR"
npm install --silent

echo "[3/3] running validation suite (this takes ~5-10min with LLM enabled)..."
BS_BASE_URL="$BS_BASE_URL" npm run validate
