#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

typedef enum {
    CC_WIRELESS_AUDIO_NONE = 0,
    CC_WIRELESS_AUDIO_WIFI,
    CC_WIRELESS_AUDIO_BLE,
} cc_wireless_audio_route_t;

/** Selects and locks the best route for one PTT session. */
cc_wireless_audio_route_t cc_wireless_audio_route_begin(void);
/** PCM callback passed directly to the microphone capture task. */
bool cc_wireless_audio_route_send(const int16_t *samples, size_t sample_count);
/** Marks physical release while keeping the locked route for the 200 ms tail. */
void cc_wireless_audio_route_finish(void);
/**
 * True only after the selected route stayed unavailable for the grace period.
 * A short radio-state bounce must not synthesize a release while BOOT is held.
 */
bool cc_wireless_audio_route_lost_at(uint32_t now_ms);
cc_wireless_audio_route_t cc_wireless_audio_route_current(void);
void cc_wireless_audio_route_cancel(void);
