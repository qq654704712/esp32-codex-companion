#ifndef CODEX_COMPANION_WIFI_MANAGER_H
#define CODEX_COMPANION_WIFI_MANAGER_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#define CC_WIFI_MANUAL_HOST_MAX_LEN 16

typedef enum {
    CC_WIFI_UNCONFIGURED = 0,
    CC_WIFI_SOFTAP_ACTIVE,
    CC_WIFI_STA_CONNECTING,
    CC_WIFI_CONNECTED,
    CC_WIFI_FAILED,
} cc_wifi_state_t;

typedef enum {
    CC_WIFI_BEGIN_PROVISIONING,
    CC_WIFI_CREDENTIALS_ACCEPTED,
    CC_WIFI_STA_GOT_IP,
    CC_WIFI_PROVISION_TIMEOUT,
    CC_WIFI_CLEAR_CREDENTIALS,
    CC_WIFI_CONNECTION_FAILED,
} cc_wifi_event_t;

typedef struct {
    cc_wifi_state_t state;
    bool setup_password_is_ephemeral;
    uint32_t setup_started_at_ms;
} cc_wifi_model_t;

cc_wifi_model_t cc_wifi_model_initial(void);
cc_wifi_state_t cc_wifi_event(cc_wifi_model_t *model, cc_wifi_event_t event,
                               uint32_t now_ms);
/** Strict dotted-quad validation for the unicast Wi-Fi fallback endpoint. */
bool cc_wifi_is_valid_ipv4(const char *value);

/** Starts the persistent Wi-Fi subsystem without opening a provisioning AP. */
bool cc_wifi_start(void);
/** Disable modem sleep only for latency-sensitive Wi-Fi microphone frames. */
void cc_wifi_set_realtime(bool enabled);
/** Opens the locally-confirmed, time-limited setup portal. */
bool cc_wifi_begin_provisioning(void);
cc_wifi_state_t cc_wifi_status(void);
/** Human-readable portal address/SSID for the device Connection Center. */
const char *cc_wifi_portal_hint(void);
/** Copies the optional IPv4 fallback selected in the setup portal. */
bool cc_wifi_copy_manual_host(char *output, size_t output_size);
/** Returns the station subnet broadcast address in network byte order. */
bool cc_wifi_get_subnet_broadcast(uint32_t *address);
void cc_wifi_clear_credentials(void);

#endif
