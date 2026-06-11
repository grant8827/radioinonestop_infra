#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# watch-stream-logs.sh
# Tail and filter only stream-related logs from Docker Compose services.
#
# Usage:
#   ./watch-stream-logs.sh [options]
#
# Options:
#   --infra-dir DIR         Infra directory (default: current directory)
#   --services LIST         Comma-separated services (default: backend,mediamtx)
#   --since VALUE           docker compose logs --since value (default: 5m)
#   --no-follow             Print once and exit (no tail)
#   --raw                   Do not filter; show raw selected service logs
#   --pattern REGEX         Custom regex filter (overrides default)
#   -h, --help              Show help
#
# Notes:
#   - Requires docker + docker compose available on PATH.
#   - Default filter highlights auth/lifecycle/relay/metrics activity.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

INFRA_DIR="$(pwd)"
SERVICES="backend,mediamtx"
SINCE="5m"
FOLLOW=1
RAW=0
CUSTOM_PATTERN=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --infra-dir) INFRA_DIR="$2"; shift 2 ;;
    --services) SERVICES="$2"; shift 2 ;;
    --since) SINCE="$2"; shift 2 ;;
    --no-follow) FOLLOW=0; shift ;;
    --raw) RAW=1; shift ;;
    --pattern) CUSTOM_PATTERN="$2"; shift 2 ;;
    -h|--help)
      sed -n '3,26p' "$0" | sed 's/^# //'
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 1
      ;;
  esac
done

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

require_cmd docker
require_cmd grep

if [[ ! -d "$INFRA_DIR" ]]; then
  echo "Infra dir not found: $INFRA_DIR" >&2
  exit 1
fi

IFS=',' read -r -a svc_array <<< "$SERVICES"

# Default signal patterns for this project's stream pipeline.
DEFAULT_PATTERN='\[stream/auth\]|/api/stream/status|\[relay\]|\[relay/|publish|unpublish|\[rtmp\]|/api/metrics|active_streams|streaming disabled|forbidden|FFmpeg exited'
PATTERN="$DEFAULT_PATTERN"
if [[ -n "$CUSTOM_PATTERN" ]]; then
  PATTERN="$CUSTOM_PATTERN"
fi

cd "$INFRA_DIR"

args=(compose logs --since "$SINCE")
if [[ "$FOLLOW" -eq 1 ]]; then
  args+=( -f )
fi
args+=("${svc_array[@]}")

echo "Watching services: ${SERVICES}"
echo "Since: ${SINCE}"
if [[ "$RAW" -eq 1 ]]; then
  echo "Mode: raw"
  docker "${args[@]}"
else
  echo "Mode: filtered"
  echo "Pattern: ${PATTERN}"
  docker "${args[@]}" 2>&1 | grep -Ei --line-buffered "$PATTERN"
fi
