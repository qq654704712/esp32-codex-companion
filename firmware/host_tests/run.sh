#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUT="${TMPDIR:-/tmp}/codex-companion-host-tests"
mkdir -p "$OUT"

clang -std=c17 -Wall -Wextra -Werror \
  -I"$ROOT/firmware/components/control_protocol/include" \
  "$ROOT/firmware/host_tests/test_control_protocol.c" \
  "$ROOT/firmware/components/control_protocol/control_protocol.c" \
  -o "$OUT/control_protocol"
clang -std=c17 -Wall -Wextra -Werror \
  -I"$ROOT/firmware/components/device_model/include" \
  "$ROOT/firmware/host_tests/test_device_model.c" \
  "$ROOT/firmware/components/device_model/device_model.c" \
  -o "$OUT/device_model"
clang -std=c17 -Wall -Wextra -Werror \
  -I"$ROOT/firmware/components/audio_codec/include" \
  "$ROOT/firmware/host_tests/test_audio_codec.c" \
  "$ROOT/firmware/components/audio_codec/audio_codec.c" \
  -o "$OUT/audio_codec"
clang -std=c17 -Wall -Wextra -Werror \
  -I"$ROOT/firmware/components/ble_framing/include" \
  "$ROOT/firmware/host_tests/test_ble_framing.c" \
  "$ROOT/firmware/components/ble_framing/ble_framing.c" \
  -o "$OUT/ble_framing"
clang -std=c17 -Wall -Wextra -Werror \
  -I"$ROOT/firmware/components/prompt_payload/include" \
  "$ROOT/firmware/host_tests/test_prompt_payload.c" \
  "$ROOT/firmware/components/prompt_payload/prompt_payload.c" \
  -o "$OUT/prompt_payload"
OPENSSL_CFLAGS="$(pkg-config --cflags openssl)"
OPENSSL_LIBS="$(pkg-config --libs openssl)"
# shellcheck disable=SC2086
clang -std=c17 -Wall -Wextra -Werror $OPENSSL_CFLAGS \
  -I"$ROOT/firmware/components/wifi_wire/include" \
  "$ROOT/firmware/host_tests/test_wifi_wire.c" \
  "$ROOT/firmware/components/wifi_wire/wifi_wire.c" \
  $OPENSSL_LIBS \
  -o "$OUT/wifi_wire"
clang -std=c17 -Wall -Wextra -Werror \
  -I"$ROOT/firmware/main" \
  "$ROOT/firmware/host_tests/test_wifi_manager.c" \
  "$ROOT/firmware/main/wifi_state.c" \
  -o "$OUT/wifi_manager"

"$OUT/control_protocol"
"$OUT/device_model"
"$OUT/audio_codec"
"$OUT/ble_framing"
"$OUT/prompt_payload"
"$OUT/wifi_wire"
"$OUT/wifi_manager"
"$ROOT/firmware/host_tests/test_device_ui_layout.sh"
