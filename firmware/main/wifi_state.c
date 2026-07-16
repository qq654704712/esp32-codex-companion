#include "wifi_manager.h"

#include <stddef.h>

bool cc_wifi_is_valid_ipv4(const char *value) {
    if (!value || !*value) return false;
    unsigned int octet_count = 0;
    const char *cursor = value;
    while (*cursor) {
        if (octet_count == 4 || *cursor < '0' || *cursor > '9') return false;
        unsigned int value_part = 0;
        size_t digits = 0;
        while (*cursor >= '0' && *cursor <= '9') {
            value_part = value_part * 10U + (unsigned int)(*cursor - '0');
            if (++digits > 3 || value_part > 255) return false;
            cursor++;
        }
        octet_count++;
        if (*cursor == '\0') break;
        if (*cursor != '.') return false;
        cursor++;
        if (*cursor == '\0') return false;
    }
    return octet_count == 4;
}

cc_wifi_model_t cc_wifi_model_initial(void) {
    return (cc_wifi_model_t){.state = CC_WIFI_UNCONFIGURED};
}

cc_wifi_state_t cc_wifi_event(cc_wifi_model_t *model, cc_wifi_event_t event,
                               uint32_t now_ms) {
    if (model == NULL) return CC_WIFI_FAILED;
    switch (event) {
        case CC_WIFI_BEGIN_PROVISIONING:
            model->state = CC_WIFI_SOFTAP_ACTIVE;
            model->setup_password_is_ephemeral = true;
            model->setup_started_at_ms = now_ms;
            break;
        case CC_WIFI_CREDENTIALS_ACCEPTED:
            // Credentials can arrive from the setup portal or from NVS on
            // boot. Both paths must enter STA_CONNECTING so the transport
            // task can start discovery after the station gets an IP.
            if (model->state == CC_WIFI_SOFTAP_ACTIVE ||
                model->state == CC_WIFI_UNCONFIGURED ||
                model->state == CC_WIFI_FAILED) {
                model->state = CC_WIFI_STA_CONNECTING;
                model->setup_password_is_ephemeral = false;
            }
            break;
        case CC_WIFI_STA_GOT_IP:
            if (model->state == CC_WIFI_STA_CONNECTING) model->state = CC_WIFI_CONNECTED;
            break;
        case CC_WIFI_PROVISION_TIMEOUT:
        case CC_WIFI_CLEAR_CREDENTIALS:
            model->state = CC_WIFI_UNCONFIGURED;
            model->setup_password_is_ephemeral = false;
            model->setup_started_at_ms = 0;
            break;
        case CC_WIFI_CONNECTION_FAILED:
            if (model->state == CC_WIFI_STA_CONNECTING) model->state = CC_WIFI_FAILED;
            break;
    }
    return model->state;
}
