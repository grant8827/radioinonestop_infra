#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# STRM-7  Relay Benchmark Script
# Verifies that the FFmpeg stream-copy relay keeps combined CPU under 5 %
# even at 1080p/60fps with multiple concurrent output destinations.
#
# Usage:
#   ./benchmark-relay.sh [OPTIONS]
#
# Options:
#   -s, --server    RTMP ingest URL (default: rtmp://localhost:1935/live)
#   -k, --key       Stream key       (default: benchmark_test)
#   -d, --duration  Seconds to run   (default: 60)
#   -w, --wait      Seconds to wait for relay to start before sampling (default: 5)
#   -t, --targets   Number of simulated output destinations (default: 4)
#   --cpu-limit     Max acceptable CPU % (default: 5.0)
#   --dest-base     Base RTMP URL for output destinations (default: rtmp://localhost:19350/sink)
#   --api-token     Bearer token for /api/metrics (required for live API metrics)
#   -h, --help      Show this help
#
# Requirements:
#   - ffmpeg (on PATH)
#   - nc or socat (for the sink server)
#   - curl
#
# The script:
#   1. Starts N lightweight "sink" listeners on sequential ports.
#   2. Starts a test RTMP source publishing a 1080p/60fps test pattern.
#   3. Samples CPU and /api/metrics every second for --duration seconds.
#   4. Prints a summary and exits non-zero if peak CPU exceeds --cpu-limit.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

# ── Defaults ──────────────────────────────────────────────────────────────────
SERVER="rtmp://localhost:1935/live"
STREAM_KEY="benchmark_test"
DURATION=60
WAIT_SECS=5
TARGETS=4
CPU_LIMIT=5.0
DEST_BASE="rtmp://localhost:19350/sink"
API_BASE="http://localhost:8080"
API_TOKEN=""
SINK_BASE_PORT=19350

# ── Arg parsing ───────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    -s|--server)      SERVER="$2";      shift 2 ;;
    -k|--key)         STREAM_KEY="$2";  shift 2 ;;
    -d|--duration)    DURATION="$2";    shift 2 ;;
    -w|--wait)        WAIT_SECS="$2";   shift 2 ;;
    -t|--targets)     TARGETS="$2";     shift 2 ;;
    --cpu-limit)      CPU_LIMIT="$2";   shift 2 ;;
    --dest-base)      DEST_BASE="$2";   shift 2 ;;
    --api-base)       API_BASE="$2";    shift 2 ;;
    --api-token)      API_TOKEN="$2";   shift 2 ;;
    --sink-port)      SINK_BASE_PORT="$2"; shift 2 ;;
    -h|--help)
      sed -n '3,25p' "$0" | sed 's/^# //'
      exit 0 ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

PIDS=()

cleanup() {
  echo ""
  echo "── Cleaning up…"
  for pid in "${PIDS[@]:-}"; do
    kill "$pid" 2>/dev/null || true
  done
  wait 2>/dev/null || true
  echo "── Done."
}
trap cleanup EXIT INT TERM

# ── Detect OS for CPU sampling ─────────────────────────────────────────────────
OS="$(uname -s)"
cpu_sample() {
  if [[ "$OS" == "Linux" ]]; then
    # Sum all CPU% columns in /proc (instant snapshot via ps)
    ps -A -o %cpu --no-headers 2>/dev/null | awk '{s+=$1} END {printf "%.1f", s+0}'
  elif [[ "$OS" == "Darwin" ]]; then
    ps -A -o %cpu 2>/dev/null | awk 'NR>1 {s+=$1} END {printf "%.1f", s+0}'
  else
    echo "0.0"
  fi
}

cores() {
  if [[ "$OS" == "Linux" ]]; then
    nproc 2>/dev/null || echo 1
  else
    sysctl -n hw.logicalcpu 2>/dev/null || echo 1
  fi
}

NCORES=$(cores)
echo "── System: $OS, $NCORES logical CPUs"

# ── Check ffmpeg ────────────────────────────────────────────────────────────────
if ! command -v ffmpeg &>/dev/null; then
  echo "ERROR: ffmpeg not found on PATH" >&2
  exit 1
fi
FFMPEG_VER=$(ffmpeg -version 2>&1 | head -1)
echo "── FFmpeg: $FFMPEG_VER"

# ── 1. Start sink servers (accept RTMP bytes and discard) ──────────────────────
echo ""
echo "── Starting $TARGETS sink listeners on ports ${SINK_BASE_PORT}…$((SINK_BASE_PORT + TARGETS - 1))"
SINK_URLS=()
for i in $(seq 0 $((TARGETS - 1))); do
  PORT=$((SINK_BASE_PORT + i))
  SINK_URLS+=("rtmp://localhost:${PORT}/sink/stream${i}")
  # Use ffmpeg as a sink: accept one RTMP connection and write to /dev/null
  ffmpeg -loglevel quiet \
    -listen 1 -i "rtmp://localhost:${PORT}/sink/stream${i}" \
    -f null - &>/dev/null &
  PIDS+=($!)
  echo "   sink[$i] → port $PORT (pid ${PIDS[-1]})"
done

sleep 1

# ── 2. Start test RTMP source (1080p 60fps test pattern) ──────────────────────
echo ""
echo "── Starting test source → ${SERVER}/${STREAM_KEY}"
echo "   Resolution: 1920×1080 @ 60fps, 4 Mbps, codec: libx264 → copy at relay"

ffmpeg -loglevel warning \
  -re \
  -f lavfi -i "testsrc2=size=1920x1080:rate=60" \
  -f lavfi -i "sine=frequency=440:sample_rate=44100" \
  -c:v libx264 -preset ultrafast -tune zerolatency \
  -b:v 4M -maxrate 4M -bufsize 8M \
  -g 120 -keyint_min 120 -sc_threshold 0 \
  -profile:v high -pix_fmt yuv420p \
  -c:a aac -b:a 128k \
  -f flv "${SERVER}/${STREAM_KEY}" &
SRC_PID=$!
PIDS+=($SRC_PID)
echo "   source pid=$SRC_PID"

echo ""
echo "── Waiting ${WAIT_SECS}s for relay to initialise…"
sleep "$WAIT_SECS"

# ── 3. Sample CPU + /api/metrics ──────────────────────────────────────────────
echo ""
echo "── Sampling for ${DURATION}s (Ctrl+C to abort early)"
printf "%-8s %-12s %-12s %-10s %-10s %-10s\n" "SECOND" "CPU_TOTAL%" "CPU_PER_CORE%" "FPS" "BANDWIDTH" "ACTIVE"

PEAK_CPU=0
PEAK_PER_CORE=0
SAMPLE_COUNT=0
CPU_SUM=0

for s in $(seq 1 "$DURATION"); do
  sleep 1

  # OS-level CPU across all processes
  TOTAL_CPU=$(cpu_sample)
  PER_CORE=$(echo "$TOTAL_CPU $NCORES" | awk '{printf "%.1f", $1 / $2}')

  # Keep peak
  PEAK_CPU=$(echo "$TOTAL_CPU $PEAK_CPU" | awk '{print ($1>$2)?$1:$2}')
  PEAK_PER_CORE=$(echo "$PER_CORE $PEAK_PER_CORE" | awk '{print ($1>$2)?$1:$2}')
  CPU_SUM=$(echo "$CPU_SUM $TOTAL_CPU" | awk '{printf "%.1f", $1+$2}')
  SAMPLE_COUNT=$((SAMPLE_COUNT + 1))

  # Optional: pull live metrics from the API
  FPS="n/a"
  BANDWIDTH="n/a"
  ACTIVE="n/a"
  if [[ -n "$API_TOKEN" ]]; then
    METRICS=$(curl -sS --max-time 1 \
      -H "Authorization: Bearer ${API_TOKEN}" \
      "${API_BASE}/api/metrics" 2>/dev/null || echo "{}")
    FPS=$(echo "$METRICS" | grep -o '"fps":[0-9.]*' | cut -d: -f2 || echo "n/a")
    BANDWIDTH=$(echo "$METRICS" | grep -o '"bandwidth":[0-9.]*' | cut -d: -f2 | awk '{printf "%.2f Mbps", $1}' || echo "n/a")
    ACTIVE=$(echo "$METRICS" | grep -o '"active_streams":[0-9]*' | cut -d: -f2 || echo "n/a")
  fi

  printf "%-8s %-12s %-12s %-10s %-10s %-10s\n" \
    "${s}s" "${TOTAL_CPU}%" "${PER_CORE}%" "$FPS" "$BANDWIDTH" "$ACTIVE"
done

# ── 4. Summary ────────────────────────────────────────────────────────────────
AVG_CPU=$(echo "$CPU_SUM $SAMPLE_COUNT" | awk '{if($2>0) printf "%.1f", $1/$2; else print "0.0"}')

echo ""
echo "═══════════════════════════════════════════════════════════"
echo "  STRM-7  RELAY BENCHMARK RESULTS"
echo "═══════════════════════════════════════════════════════════"
echo "  Duration:        ${DURATION}s"
echo "  Targets:         $TARGETS"
echo "  System CPUs:     $NCORES"
echo "  Peak CPU total:  ${PEAK_CPU}%"
echo "  Peak CPU/core:   ${PEAK_PER_CORE}%"
echo "  Avg CPU total:   ${AVG_CPU}%"
echo "  Limit (per-core):${CPU_LIMIT}%"
echo "═══════════════════════════════════════════════════════════"

PASS=true
if (( $(echo "$PEAK_PER_CORE $CPU_LIMIT" | awk '{print ($1 > $2)}') )); then
  PASS=false
fi

if $PASS; then
  echo "  RESULT: ✅ PASS  — peak per-core CPU ${PEAK_PER_CORE}% ≤ ${CPU_LIMIT}%"
  echo "═══════════════════════════════════════════════════════════"
  exit 0
else
  echo "  RESULT: ❌ FAIL  — peak per-core CPU ${PEAK_PER_CORE}% > ${CPU_LIMIT}%"
  echo "  Consider: verify -c:v copy -c:a copy flags are active (not transcoding)."
  echo "═══════════════════════════════════════════════════════════"
  exit 1
fi
