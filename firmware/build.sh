#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export IDF_PATH="${IDF_PATH:-$ROOT/work/esp-idf}"
export IDF_TOOLS_PATH="${IDF_TOOLS_PATH:-$ROOT/work/idf-tools}"

if [[ ! -f "$IDF_PATH/export.sh" ]]; then
  echo "ESP-IDF 5.5.3 not found. Set IDF_PATH or install it under work/esp-idf." >&2
  exit 1
fi

source "$IDF_PATH/export.sh"
idf.py -C "$ROOT/firmware" set-target esp32s3 build
