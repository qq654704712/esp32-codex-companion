#ifndef CODEX_COMPANION_WIFI_TRANSPORT_H
#define CODEX_COMPANION_WIFI_TRANSPORT_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

typedef void (*cc_wifi_control_fn)(const uint8_t *data, size_t length);

#define CC_WIFI_AUDIO_PORT 49154
#define CC_WIFI_AUDIO_SAMPLE_COUNT 320

/** Starts mDNS discovery and the authenticated daily-use TCP control link. */
void cc_wifi_transport_start(cc_wifi_control_fn control_callback);
bool cc_wifi_transport_is_connected(void);
/** True only when the authenticated session owns a non-blocking UDP audio socket. */
bool cc_wifi_transport_is_audio_available(void);
/** Sends an already-signed v1 ControlEnvelope through the CCW2 session. */
bool cc_wifi_transport_send_control(const uint8_t *data, size_t length);
/** Sends one 20 ms, 16 kHz, mono PCM16 frame through the session audio key. */
bool cc_wifi_transport_send_audio_pcm16(const int16_t *samples, size_t sample_count);

#endif
