#ifndef CODEX_COMPANION_WIFI_TRANSPORT_H
#define CODEX_COMPANION_WIFI_TRANSPORT_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

typedef void (*cc_wifi_control_fn)(const uint8_t *data, size_t length);

/** Starts mDNS discovery and the authenticated daily-use TCP control link. */
void cc_wifi_transport_start(cc_wifi_control_fn control_callback);
bool cc_wifi_transport_is_connected(void);
/** Sends an already-signed v1 ControlEnvelope through the CCW2 session. */
bool cc_wifi_transport_send_control(const uint8_t *data, size_t length);

#endif
