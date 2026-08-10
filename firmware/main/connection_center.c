#include "connection_center.h"

#include <string.h>

void cc_connection_center_init(cc_connection_center_t *center) {
    if (center == NULL) return;
    memset(center, 0, sizeof(*center));
    center->audio_mode = CC_AUDIO_MODE_WIFI;
}

void cc_connection_center_open(cc_connection_center_t *center) {
    if (center != NULL) center->open = true;
}

void cc_connection_center_close(cc_connection_center_t *center) {
    if (center == NULL) return;
    center->open = false;
    cc_connection_center_cancel_hold(center);
}

void cc_connection_center_next_page(cc_connection_center_t *center) {
    if (center == NULL || !center->open) return;
    center->page = (cc_center_page_t)((center->page + 1) % CC_CENTER_PAGE_COUNT);
    cc_connection_center_cancel_hold(center);
}

void cc_connection_center_previous_page(cc_connection_center_t *center) {
    if (center == NULL || !center->open) return;
    center->page = center->page == CC_CENTER_PAGE_NETWORK
                       ? (cc_center_page_t)(CC_CENTER_PAGE_COUNT - 1)
                       : (cc_center_page_t)(center->page - 1);
    cc_connection_center_cancel_hold(center);
}

bool cc_connection_center_set_hosts(cc_connection_center_t *center,
                                    const cc_center_host_t *hosts,
                                    size_t count) {
    if (center == NULL || count > CC_CONNECTION_CENTER_MAX_HOSTS ||
        (count > 0 && hosts == NULL)) {
        return false;
    }
    memset(center->hosts, 0, sizeof(center->hosts));
    if (count > 0) memcpy(center->hosts, hosts, count * sizeof(*hosts));
    center->host_count = count;
    if (count == 0 || center->selected_host >= count) center->selected_host = 0;
    cc_connection_center_cancel_hold(center);
    return true;
}

bool cc_connection_center_select_host(cc_connection_center_t *center,
                                      size_t index) {
    if (center == NULL || index >= center->host_count) return false;
    center->selected_host = index;
    cc_connection_center_cancel_hold(center);
    return true;
}

void cc_connection_center_begin_hold(cc_connection_center_t *center,
                                     cc_center_action_t action,
                                     uint32_t now_ms) {
    if (center == NULL || !center->open || action == CC_CENTER_ACTION_NONE) return;
    center->pending_action = action;
    center->hold_started_at_ms = now_ms;
}

bool cc_connection_center_complete_hold(cc_connection_center_t *center,
                                        uint32_t now_ms) {
    if (center == NULL || center->pending_action == CC_CENTER_ACTION_NONE) {
        return false;
    }
    if ((uint32_t)(now_ms - center->hold_started_at_ms) <
        CC_CONNECTION_CENTER_CONFIRM_HOLD_MS) {
        return false;
    }
    center->pending_action = CC_CENTER_ACTION_NONE;
    center->hold_started_at_ms = 0;
    return true;
}

void cc_connection_center_cancel_hold(cc_connection_center_t *center) {
    if (center == NULL) return;
    center->pending_action = CC_CENTER_ACTION_NONE;
    center->hold_started_at_ms = 0;
}

void cc_connection_center_set_audio_mode(cc_connection_center_t *center,
                                         cc_audio_mode_t mode) {
    if (center == NULL || mode > CC_AUDIO_MODE_BLE_RECOVERY) return;
    center->audio_mode = mode;
}
