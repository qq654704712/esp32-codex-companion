#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
DRIVER_DIR=${SCRIPT_DIR:h}
BUILD_DIR=${DRIVER_DIR}/build

export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
COMPAT_USB_TRANSPORT=${CODEX_MIC_COMPAT_USB_TRANSPORT:-1}
cmake -S "$DRIVER_DIR" -B "$BUILD_DIR" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCODEX_MIC_COMPAT_USB_TRANSPORT="$COMPAT_USB_TRANSPORT"
cmake --build "$BUILD_DIR" --config Release
ctest --test-dir "$BUILD_DIR" --output-on-failure
codesign --force --sign - "$BUILD_DIR/CodexMic.driver"
codesign --verify --deep --strict "$BUILD_DIR/CodexMic.driver"
print "$BUILD_DIR/CodexMic.driver"
