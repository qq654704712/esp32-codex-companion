#include "device_model.h"

#include <string.h>

static uint8_t clamp_percent(uint8_t value) {
    return value > 100 ? 100 : value;
}

void cc_device_model_init(cc_device_model_t *model) {
    memset(model, 0, sizeof(*model));
    model->remote_state = CC_STATE_IDLE;
    model->visible_state = CC_STATE_DISCONNECTED;
}

void cc_device_set_connected(cc_device_model_t *model, bool connected,
                             uint64_t now_ms) {
    (void)now_ms;
    model->connected = connected;
    model->visible_state = connected ? model->remote_state : CC_STATE_DISCONNECTED;
}

bool cc_device_set_remote_state(cc_device_model_t *model,
                                cc_device_state_t state) {
    if (model->remote_state == state) return false;
    model->remote_state = state;
    if (model->connected && model->visible_state != CC_STATE_LISTENING) {
        model->visible_state = state;
    }
    return true;
}

cc_button_action_t cc_device_button_sample(cc_device_model_t *model,
                                            bool button_down,
                                            uint64_t now_ms) {
    if (button_down != model->candidate_button_down) {
        model->candidate_button_down = button_down;
        model->candidate_since_ms = now_ms;
        return CC_BUTTON_NONE;
    }
    if (button_down == model->stable_button_down ||
        now_ms - model->candidate_since_ms < CC_BUTTON_DEBOUNCE_MS) {
        return CC_BUTTON_NONE;
    }
    model->stable_button_down = button_down;
    if (button_down) {
        model->visible_state = CC_STATE_LISTENING;
        return CC_BUTTON_PTT_DOWN;
    }
    model->visible_state = model->connected ? model->remote_state
                                            : CC_STATE_DISCONNECTED;
    // The keyboard modifier must track BOOT exactly. app_main retains the
    // local microphone tail without delaying the PTT_UP control event.
    return CC_BUTTON_PTT_UP;
}

void cc_device_update_quota(cc_device_model_t *model,
                            bool five_hour_available,
                            uint8_t five_hour_percent,
                            bool week_available,
                            uint8_t week_percent,
                            uint64_t now_ms) {
    model->five_hour.available = five_hour_available;
    model->five_hour.percent = clamp_percent(five_hour_percent);
    model->week.available = week_available;
    model->week.percent = clamp_percent(week_percent);
    model->quota_updated_at_ms = now_ms;
}

void cc_device_mark_quota_fresh(cc_device_model_t *model, uint64_t now_ms) {
    model->quota_updated_at_ms = now_ms;
}

bool cc_device_quota_is_stale(const cc_device_model_t *model,
                              uint64_t now_ms) {
    if (!model->five_hour.available && !model->week.available) return false;
    return now_ms - model->quota_updated_at_ms > CC_QUOTA_STALE_MS;
}
