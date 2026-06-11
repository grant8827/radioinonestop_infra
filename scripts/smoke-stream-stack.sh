#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# smoke-stream-stack.sh
# Quick smoke checks for stream auth, lifecycle webhook, and metrics API.
#
# Usage:
#   ./smoke-stream-stack.sh [options]
#
# Options:
#   --base-url URL             Backend base URL (default: http://localhost:8080)
#   --stream-key KEY           Valid user stream key for positive checks
#   --invalid-key KEY          Invalid key for negative auth check (default: invalid_key)
#   --auth-token TOKEN         STREAM_AUTH_TOKEN header value (optional)
#   --status-token TOKEN       STREAM_STATUS_TOKEN header value (optional)
#   --jwt TOKEN                Bearer token for /api/metrics (optional)
#   --path PATH                Media path for publish/done webhook (default: live/<stream-key>)
#   -h, --help                 Show help
#
# Exit codes:
#   0 = all required checks passed
#   1 = one or more required checks failed
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

BASE_URL="http://localhost:8080"
STREAM_KEY=""
INVALID_KEY="invalid_key"
AUTH_TOKEN=""
STATUS_TOKEN=""
JWT_TOKEN=""
PATH_OVERRIDE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --base-url)      BASE_URL="$2"; shift 2 ;;
    --stream-key)    STREAM_KEY="$2"; shift 2 ;;
    --invalid-key)   INVALID_KEY="$2"; shift 2 ;;
    --auth-token)    AUTH_TOKEN="$2"; shift 2 ;;
    --status-token)  STATUS_TOKEN="$2"; shift 2 ;;
    --jwt)           JWT_TOKEN="$2"; shift 2 ;;
    --path)          PATH_OVERRIDE="$2"; shift 2 ;;
    -h|--help)
      sed -n '3,27p' "$0" | sed 's/^# //'
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 1
      ;;
  esac
done

PASS=0
FAIL=0
SKIP=0

log_ok()   { echo "[PASS] $*"; PASS=$((PASS + 1)); }
log_fail() { echo "[FAIL] $*"; FAIL=$((FAIL + 1)); }
log_skip() { echo "[SKIP] $*"; SKIP=$((SKIP + 1)); }

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

http_code() {
  # shellcheck disable=SC2086
  curl -sS -o /tmp/stream_smoke_body.$$ -w "%{http_code}" "$@"
}

show_body() {
  sed -n '1,8p' /tmp/stream_smoke_body.$$ || true
}

cleanup() {
  rm -f /tmp/stream_smoke_body.$$ 2>/dev/null || true
}
trap cleanup EXIT

require_cmd curl

echo "Smoke checks against: ${BASE_URL}"

# 1) Health
code=$(http_code "${BASE_URL}/api/health")
if [[ "$code" == "200" ]]; then
  log_ok "/api/health is reachable"
else
  log_fail "/api/health expected 200, got ${code}"
  show_body
fi

# 2) Auth negative test (invalid key should be forbidden)
auth_headers=()
if [[ -n "$AUTH_TOKEN" ]]; then
  auth_headers+=( -H "X-Stream-Auth-Token: ${AUTH_TOKEN}" )
fi

code=$(http_code -X POST "${BASE_URL}/api/stream/auth" \
  -H "Content-Type: application/json" \
  "${auth_headers[@]}" \
  -d "{\"action\":\"publish\",\"user\":\"${INVALID_KEY}\",\"path\":\"live/${INVALID_KEY}\",\"protocol\":\"rtmp\"}")
if [[ "$code" == "403" ]]; then
  log_ok "/api/stream/auth rejects invalid stream key"
else
  log_fail "/api/stream/auth invalid-key check expected 403, got ${code}"
  show_body
fi

# 3) Auth positive test (requires valid stream key)
if [[ -n "$STREAM_KEY" ]]; then
  code=$(http_code -X POST "${BASE_URL}/api/stream/auth" \
    -H "Content-Type: application/json" \
    "${auth_headers[@]}" \
    -d "{\"action\":\"publish\",\"user\":\"${STREAM_KEY}\",\"path\":\"live/${STREAM_KEY}\",\"protocol\":\"rtmp\"}")
  if [[ "$code" == "200" ]]; then
    log_ok "/api/stream/auth allows valid stream key"
  else
    log_fail "/api/stream/auth valid-key check expected 200, got ${code}"
    show_body
  fi
else
  log_skip "No --stream-key provided; skipping auth positive check"
fi

# 4) Lifecycle webhook publish/done (requires valid stream key for meaningful check)
status_headers=()
if [[ -n "$STATUS_TOKEN" ]]; then
  status_headers+=( -H "X-Stream-Status-Token: ${STATUS_TOKEN}" )
fi

if [[ -n "$STREAM_KEY" ]]; then
  stream_path="${PATH_OVERRIDE:-live/${STREAM_KEY}}"

  code=$(http_code -X POST "${BASE_URL}/api/stream/status" \
    -H "Content-Type: application/json" \
    "${status_headers[@]}" \
    -d "{\"action\":\"publish\",\"user\":\"${STREAM_KEY}\",\"path\":\"${stream_path}\"}")
  if [[ "$code" == "200" ]]; then
    log_ok "/api/stream/status publish callback accepted"
  else
    log_fail "/api/stream/status publish expected 200, got ${code}"
    show_body
  fi

  code=$(http_code -X POST "${BASE_URL}/api/stream/status" \
    -H "Content-Type: application/json" \
    "${status_headers[@]}" \
    -d "{\"action\":\"done\",\"user\":\"${STREAM_KEY}\",\"path\":\"${stream_path}\"}")
  if [[ "$code" == "200" ]]; then
    log_ok "/api/stream/status done callback accepted"
  else
    log_fail "/api/stream/status done expected 200, got ${code}"
    show_body
  fi
else
  log_skip "No --stream-key provided; skipping lifecycle publish/done checks"
fi

# 5) Metrics endpoint
if [[ -n "$JWT_TOKEN" ]]; then
  code=$(http_code "${BASE_URL}/api/metrics" -H "Authorization: Bearer ${JWT_TOKEN}")
  if [[ "$code" == "200" ]]; then
    if grep -q '"active_streams"' /tmp/stream_smoke_body.$$ && grep -q '"cpu"' /tmp/stream_smoke_body.$$; then
      log_ok "/api/metrics returned telemetry payload"
    else
      log_fail "/api/metrics returned 200 but missing expected fields"
      show_body
    fi
  else
    log_fail "/api/metrics expected 200, got ${code}"
    show_body
  fi
else
  log_skip "No --jwt provided; skipping /api/metrics auth check"
fi

echo ""
echo "Summary: PASS=${PASS} FAIL=${FAIL} SKIP=${SKIP}"
if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
exit 0
