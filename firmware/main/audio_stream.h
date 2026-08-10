#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "device_model.h"

typedef bool (*cc_audio_send_fn)(const int16_t *samples, size_t sample_count);

void cc_audio_stream_init(cc_audio_send_fn send_fn);
void cc_audio_stream_start(void);
void cc_audio_stream_stop(uint32_t post_roll_ms);
void cc_audio_stream_cancel(void);
bool cc_audio_stream_is_active(void);
uint16_t cc_audio_stream_level(void);
/**
 * Fill a native USB Audio Class microphone frame with mono PCM16 samples.
 * This is intentionally unavailable while wireless capture owns the codec, so the
 * two transports cannot race the ES7210/I2S path.
 */
bool cc_audio_stream_read_usb_pcm16(uint8_t *output, size_t length);
/** Play the distinct 8-bit lifecycle melody for one queued task event. */
void cc_audio_play_task_event_tone(cc_task_event_t event);
/**
 * Scope lifecycle sounds to the foreground Codex app. Disabling also stops a
 * bark already in progress and drops queued Codex sounds.
 */
void cc_audio_set_task_tones_enabled(bool enabled);
