#ifndef CODEX_COMPANION_CONNECTION_CENTER_H
#define CODEX_COMPANION_CONNECTION_CENTER_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "pairing_manager.h"

#define CC_CONNECTION_CENTER_MAX_HOSTS 8
#define CC_CONNECTION_CENTER_HOST_NAME_MAX 32
#define CC_CONNECTION_CENTER_CONFIRM_HOLD_MS 1500U

typedef enum {
    CC_CENTER_PAGE_NETWORK = 0,
    CC_CENTER_PAGE_HOST,
    CC_CENTER_PAGE_AUDIO,
    CC_CENTER_PAGE_COUNT,
} cc_center_page_t;

typedef enum {
    CC_AUDIO_MODE_WIFI = 0,
    CC_AUDIO_MODE_USB_COMPATIBILITY,
    CC_AUDIO_MODE_BLE_RECOVERY,
} cc_audio_mode_t;

typedef enum {
    CC_CENTER_ACTION_NONE = 0,
    CC_CENTER_ACTION_CLEAR_NETWORK,
    CC_CENTER_ACTION_SWITCH_HOST,
    CC_CENTER_ACTION_UNPAIR_HOST,
} cc_center_action_t;

typedef struct {
    char id[CC_PAIRING_HOST_ID_MAX + 1];
    char display_name[CC_CONNECTION_CENTER_HOST_NAME_MAX + 1];
    bool paired;
    bool reachable;
} cc_center_host_t;

typedef struct {
    bool open;
    cc_center_page_t page;
    cc_audio_mode_t audio_mode;
    cc_center_host_t hosts[CC_CONNECTION_CENTER_MAX_HOSTS];
    size_t host_count;
    size_t selected_host;
    cc_center_action_t pending_action;
    uint32_t hold_started_at_ms;
    uint8_t microphone_level;
    uint16_t network_latency_ms;
} cc_connection_center_t;

void cc_connection_center_init(cc_connection_center_t *center);
void cc_connection_center_open(cc_connection_center_t *center);
void cc_connection_center_close(cc_connection_center_t *center);
void cc_connection_center_next_page(cc_connection_center_t *center);
void cc_connection_center_previous_page(cc_connection_center_t *center);
bool cc_connection_center_set_hosts(cc_connection_center_t *center,
                                    const cc_center_host_t *hosts,
                                    size_t count);
bool cc_connection_center_select_host(cc_connection_center_t *center,
                                      size_t index);
void cc_connection_center_begin_hold(cc_connection_center_t *center,
                                     cc_center_action_t action,
                                     uint32_t now_ms);
bool cc_connection_center_complete_hold(cc_connection_center_t *center,
                                        uint32_t now_ms);
void cc_connection_center_cancel_hold(cc_connection_center_t *center);
void cc_connection_center_set_audio_mode(cc_connection_center_t *center,
                                         cc_audio_mode_t mode);

#endif
