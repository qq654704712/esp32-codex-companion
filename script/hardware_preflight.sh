#!/usr/bin/env bash
set -euo pipefail

# Read-only readiness check for the physical ESP32-S3 validation stage.
# It never flashes, resets, pairs, or changes the selected macOS microphone.

REQUIRE_BOARD=false
if [[ "${1:-}" == "--require-board" ]]; then
  REQUIRE_BOARD=true
elif [[ -n "${1:-}" ]]; then
  echo "usage: $0 [--require-board]" >&2
  exit 2
fi

echo "== Codex Companion hardware preflight =="

SERIAL_PORT=$(find /dev -maxdepth 1 -type c \( \
  -name 'cu.usbmodem*' -o -name 'cu.SLAB_USBtoUART*' -o \
  -name 'cu.wchusbserial*' -o -name 'cu.usbserial*' \
\) -print -quit 2>/dev/null || true)

if [[ -n "$SERIAL_PORT" ]]; then
  echo "ESP32 serial candidate: $SERIAL_PORT"
else
  echo "ESP32 serial candidate: not detected"
fi

if system_profiler SPAudioDataType 2>/dev/null | grep -q 'Codex Companion USB Mic'; then
  echo "USB UAC microphone: detected"
else
  echo "USB UAC microphone: not detected"
fi

if launchctl print "gui/$(id -u)/com.codexcompanion.daemon" 2>/dev/null |
  grep -q 'state = running'; then
  echo "macOS Companion agent: running"
else
  echo "macOS Companion agent: not running"
fi

if /usr/sbin/lsof -nP -iTCP:49152 -sTCP:LISTEN 2>/dev/null |
  grep -q '49152 (LISTEN)'; then
  echo "Wi-Fi control server: listening on 49152"
else
  echo "Wi-Fi control server: not listening"
fi

if command -v dns-sd >/dev/null 2>&1; then
  BROWSE_OUTPUT=$(mktemp)
  trap 'rm -f "$BROWSE_OUTPUT"' EXIT
  dns-sd -B _codex-companion._tcp local. >"$BROWSE_OUTPUT" 2>&1 &
  BROWSER_PID=$!
  sleep 3
  kill "$BROWSER_PID" >/dev/null 2>&1 || true
  wait "$BROWSER_PID" 2>/dev/null || true
  if grep -q '_codex-companion._tcp' "$BROWSE_OUTPUT" &&
    grep -q 'Add' "$BROWSE_OUTPUT"; then
    echo "Bonjour service: discoverable"
  else
    echo "Bonjour service: not discovered"
  fi
fi

if [[ "$REQUIRE_BOARD" == true && -z "$SERIAL_PORT" ]]; then
  echo "Physical board is not connected. For a flash session: power off -> hold BOOT -> plug USB -> release BOOT immediately." >&2
  exit 1
fi
