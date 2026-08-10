#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export IDF_PATH="${IDF_PATH:-$ROOT/work/esp-idf-v6.0.2}"
export IDF_TOOLS_PATH="${IDF_TOOLS_PATH:-$ROOT/work/idf-tools-v6}"
export IDF_SKIP_CHECK_SUBMODULES="${IDF_SKIP_CHECK_SUBMODULES:-1}"
BUILD_DIR="${BUILD_DIR:-$ROOT/build-v6.0.2}"

if [[ ! -f "$IDF_PATH/export.sh" ]]; then
  echo "ESP-IDF 6.0.2 not found. Set IDF_PATH or install it under work/esp-idf-v6.0.2." >&2
  exit 1
fi

source "$IDF_PATH/export.sh"
NINJA_DIR="$IDF_TOOLS_PATH/tools/ninja/1.12.1"
if [[ ! -x "$NINJA_DIR/ninja" ]]; then
  NINJA_DIR="$ROOT/work/idf-tools/tools/ninja/1.12.1"
fi
if [[ -x "$NINJA_DIR/ninja" ]]; then
  export PATH="$NINJA_DIR:$PATH"
fi
idf.py -G Ninja -C "$ROOT/firmware" -B "$BUILD_DIR" build
