#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DEFAULTS="$ROOT/firmware/sdkconfig.defaults"
SOURCE="$ROOT/firmware/main/ble_transport.c"

grep -Fq 'CONFIG_BT_NIMBLE_HOST_TASK_STACK_SIZE=8192' "$DEFAULTS"
grep -Fq 'static uint8_t provisioning_candidate' "$SOURCE"
grep -Fq 'static cc_host_profile_t provisioning_profile' "$SOURCE"
grep -Fq 'uxTaskGetStackHighWaterMark(NULL)' "$SOURCE"

AUDIO_SOURCE="$ROOT/firmware/main/audio_stream.c"
grep -Fq 'xTaskCreate(tone_task, "cc_audio_tones", 8192' "$AUDIO_SOURCE"
grep -Fq 'codec_io_mutex = xSemaphoreCreateMutex();' "$AUDIO_SOURCE"
grep -Fq 'tone task stack high-water=%u' "$AUDIO_SOURCE"

echo "BLE runtime configuration tests passed"
