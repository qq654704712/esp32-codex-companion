#include "device_model.h"

#include <string.h>

static uint8_t clamp_percent(uint8_t value) {
    return value > 100 ? 100 : value;
}

static void clear_submit_state(cc_device_model_t *model) {
    model->submit_pending = false;
    model->submit_confirm_armed = false;
    model->last_submit_press_ms = 0;
    model->submit_pending_until_ms = 0;
    model->submit_confirm_deadline_ms = 0;
}

static bool local_interaction_visible(const cc_device_model_t *model) {
    return model->visible_state == CC_STATE_LISTENING ||
           model->visible_state == CC_STATE_SUBMIT_PENDING ||
           model->visible_state == CC_STATE_SUBMIT_CONFIRM;
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
    // Physical PTT owns the visible state until the debounced release. Radio
    // control may reconnect (or its heartbeat may expire) while native USB UAC
    // audio is still being pulled successfully by the Mac. Updating the link
    // flag here is still important, but replacing LISTENING would make the
    // device lie about a voice session that remains active on the computer.
    if (!connected && model->visible_state != CC_STATE_LISTENING) {
        clear_submit_state(model);
    }
    if (!local_interaction_visible(model)) {
        model->visible_state = connected ? model->remote_state
                                         : CC_STATE_DISCONNECTED;
    }
}

bool cc_device_set_remote_state(cc_device_model_t *model,
                                cc_device_state_t state) {
    if (model->remote_state == state) return false;
    model->remote_state = state;
    if (model->connected && !local_interaction_visible(model)) {
        model->visible_state = state;
    }
    return true;
}

void cc_device_set_activity(cc_device_model_t *model,
                            uint8_t active_tasks,
                            uint8_t attention_tasks,
                            uint8_t recent_completed_tasks) {
    model->active_tasks = active_tasks;
    model->attention_tasks = attention_tasks;
    model->recent_completed_tasks = recent_completed_tasks;
}

cc_button_action_t cc_device_button_edge(cc_device_model_t *model,
                                         bool button_down,
                                         uint64_t now_ms) {
    if (!button_down || !model->submit_pending ||
        now_ms >= model->submit_pending_until_ms) {
        return CC_BUTTON_NONE;
    }

    // Only falling edges participate in submit confirmation. A short lockout
    // removes contact bounce while preserving even an unusually fast human
    // double-click (whose two press edges are much farther apart).
    if (model->last_submit_press_ms != 0 &&
        now_ms - model->last_submit_press_ms < CC_SUBMIT_EDGE_LOCKOUT_MS) {
        return CC_BUTTON_NONE;
    }
    model->last_submit_press_ms = now_ms;

    if (!model->submit_confirm_armed) {
        model->submit_confirm_armed = true;
        model->submit_confirm_deadline_ms = model->submit_pending_until_ms;
        model->visible_state = CC_STATE_SUBMIT_CONFIRM;
        return CC_BUTTON_NONE;
    }

    clear_submit_state(model);
    model->visible_state = model->connected ? model->remote_state
                                            : CC_STATE_DISCONNECTED;
    return CC_BUTTON_SUBMIT;
}

cc_button_action_t cc_device_button_sample(cc_device_model_t *model,
                                            bool button_down,
                                            uint64_t now_ms) {
    if (model->submit_pending && now_ms >= model->submit_pending_until_ms) {
        clear_submit_state(model);
        if (!model->ptt_active) {
            model->visible_state = model->connected ? model->remote_state
                                                    : CC_STATE_DISCONNECTED;
        }
    } else if (model->submit_confirm_armed &&
               now_ms >= model->submit_confirm_deadline_ms) {
        model->submit_confirm_armed = false;
        model->submit_confirm_deadline_ms = 0;
        model->visible_state = CC_STATE_SUBMIT_PENDING;
    }

    if (button_down != model->candidate_button_down) {
        model->candidate_button_down = button_down;
        model->candidate_since_ms = now_ms;
        return CC_BUTTON_NONE;
    }
    if (button_down != model->stable_button_down &&
        now_ms - model->candidate_since_ms >= CC_BUTTON_DEBOUNCE_MS) {
        model->stable_button_down = button_down;
        if (button_down) {
            model->button_press_since_ms = now_ms;

            // During the bounded post-voice submit window, a press may be a
            // confirmation tap or a deliberate hold to record again. Do not
            // open an audio route for the short-tap case; a real hold starts
            // the route below when it reaches CC_PTT_HOLD_MS.
            if (model->submit_pending) return CC_BUTTON_NONE;
            return CC_BUTTON_PREPARE_PTT;
        }

        if (model->ptt_active) {
            model->ptt_active = false;
            model->submit_pending = true;
            model->submit_confirm_armed = false;
            model->last_submit_press_ms = 0;
            model->submit_pending_until_ms = now_ms + CC_SUBMIT_WINDOW_MS;
            model->submit_confirm_deadline_ms = 0;
            model->visible_state = CC_STATE_SUBMIT_PENDING;
            return CC_BUTTON_PTT_UP;
        }

        if (model->submit_pending) return CC_BUTTON_NONE;
        return CC_BUTTON_CANCEL_PTT;
    }

    if (button_down && model->stable_button_down && !model->ptt_active &&
        now_ms - model->button_press_since_ms >= CC_PTT_HOLD_MS) {
        model->ptt_active = true;
        clear_submit_state(model);
        model->visible_state = CC_STATE_LISTENING;
        return CC_BUTTON_PTT_DOWN;
    }
    return CC_BUTTON_NONE;
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
