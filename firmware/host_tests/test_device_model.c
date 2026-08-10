#include "device_model.h"

#include <assert.h>
#include <stdio.h>

int main(void) {
    cc_device_model_t model;
    cc_device_model_init(&model);
    assert(model.visible_state == CC_STATE_DISCONNECTED);

    cc_device_set_connected(&model, true, 1000);
    assert(cc_device_set_remote_state(&model, CC_STATE_WORKING));
    assert(model.visible_state == CC_STATE_WORKING);
    assert(!cc_device_set_remote_state(&model, CC_STATE_WORKING));
    cc_device_set_activity(&model, 3, 1, 2);
    assert(model.active_tasks == 3);
    assert(model.attention_tasks == 1);
    assert(model.recent_completed_tasks == 2);

    // A stable press prepares bounded pre-roll, but only a hold starts PTT.
    assert(cc_device_button_sample(&model, true, 1030) == CC_BUTTON_NONE);
    assert(cc_device_button_sample(&model, true, 1060) == CC_BUTTON_PREPARE_PTT);
    assert(cc_device_button_sample(&model, true, 1659) == CC_BUTTON_NONE);
    assert(cc_device_button_sample(&model, true, 1660) == CC_BUTTON_PTT_DOWN);
    assert(model.visible_state == CC_STATE_LISTENING);
    assert(cc_device_button_sample(&model, false, 1670) == CC_BUTTON_NONE);
    assert(cc_device_button_sample(&model, false, 1700) == CC_BUTTON_PTT_UP);
    assert(model.visible_state == CC_STATE_SUBMIT_PENDING);

    // Submit taps arrive as ISR-latched edges rather than polling samples.
    // The first press arms and a contact bounce inside the lockout is ignored.
    assert(cc_device_button_edge(&model, true, 1720) == CC_BUTTON_NONE);
    assert(model.visible_state == CC_STATE_SUBMIT_CONFIRM);
    assert(cc_device_button_edge(&model, false, 1725) == CC_BUTTON_NONE);
    assert(cc_device_button_edge(&model, true, 1730) == CC_BUTTON_NONE);
    assert(cc_device_button_edge(&model, false, 1735) == CC_BUTTON_NONE);
    assert(cc_device_button_edge(&model, true, 1780) == CC_BUTTON_SUBMIT);
    assert(model.visible_state == CC_STATE_WORKING);
    assert(!model.submit_pending);

    // A lone short tap can never submit. Its confirmation remains visible for
    // the rest of the original bounded window, then expires without action.
    model.submit_pending = true;
    model.last_submit_press_ms = 0;
    model.submit_pending_until_ms = 20000;
    model.visible_state = CC_STATE_SUBMIT_PENDING;
    assert(cc_device_button_edge(&model, true, 4000) == CC_BUTTON_NONE);
    assert(cc_device_button_edge(&model, false, 4010) == CC_BUTTON_NONE);
    assert(model.visible_state == CC_STATE_SUBMIT_CONFIRM);
    assert(cc_device_button_sample(&model, false, 5610) == CC_BUTTON_NONE);
    assert(model.visible_state == CC_STATE_SUBMIT_CONFIRM);
    assert(cc_device_button_sample(&model, false, 20000) == CC_BUTTON_NONE);
    assert(model.visible_state == CC_STATE_WORKING);

    // A rapid pair remains available even if the main loop receives all of
    // the ISR-latched edges after both physical clicks have already ended.
    cc_device_model_t rapid_submit_model;
    cc_device_model_init(&rapid_submit_model);
    cc_device_set_connected(&rapid_submit_model, true, 100);
    assert(cc_device_set_remote_state(&rapid_submit_model, CC_STATE_WORKING));
    rapid_submit_model.submit_pending = true;
    rapid_submit_model.submit_pending_until_ms = 5000;
    rapid_submit_model.visible_state = CC_STATE_SUBMIT_PENDING;
    assert(cc_device_button_edge(&rapid_submit_model, true, 200) == CC_BUTTON_NONE);
    assert(cc_device_button_edge(&rapid_submit_model, false, 205) == CC_BUTTON_NONE);
    assert(rapid_submit_model.visible_state == CC_STATE_SUBMIT_CONFIRM);
    assert(cc_device_button_edge(&rapid_submit_model, true, 230) == CC_BUTTON_SUBMIT);
    assert(cc_device_button_edge(&rapid_submit_model, false, 235) == CC_BUTTON_NONE);
    assert(!rapid_submit_model.submit_pending);

    cc_device_model_t listening_model;
    cc_device_model_init(&listening_model);
    cc_device_set_connected(&listening_model, true, 2000);
    assert(cc_device_set_remote_state(&listening_model, CC_STATE_WORKING));
    assert(cc_device_button_sample(&listening_model, true, 2010) == CC_BUTTON_NONE);
    assert(cc_device_button_sample(&listening_model, true, 2040) == CC_BUTTON_PREPARE_PTT);
    assert(cc_device_button_sample(&listening_model, true, 2640) == CC_BUTTON_PTT_DOWN);
    cc_device_set_connected(&listening_model, false, 2650);
    assert(!listening_model.connected);
    assert(listening_model.visible_state == CC_STATE_LISTENING);
    assert(cc_device_set_remote_state(&listening_model, CC_STATE_COMPLETED));
    assert(listening_model.visible_state == CC_STATE_LISTENING);
    cc_device_set_connected(&listening_model, true, 2660);
    assert(listening_model.connected);
    assert(listening_model.visible_state == CC_STATE_LISTENING);
    assert(cc_device_button_sample(&listening_model, false, 2670) == CC_BUTTON_NONE);
    assert(cc_device_button_sample(&listening_model, false, 2700) == CC_BUTTON_PTT_UP);
    assert(listening_model.visible_state == CC_STATE_SUBMIT_PENDING);

    cc_device_update_quota(&model, true, 75, true, 40, 2000);
    assert(model.five_hour.percent == 75);
    assert(!cc_device_quota_is_stale(&model, 121999));
    assert(cc_device_quota_is_stale(&model, 122001));
    cc_device_mark_quota_fresh(&model, 122001);
    assert(!cc_device_quota_is_stale(&model, 242000));
    assert(cc_device_quota_is_stale(&model, 242002));

    cc_device_set_connected(&model, false, 123000);
    assert(model.visible_state == CC_STATE_DISCONNECTED);
    puts("device model tests passed");
    return 0;
}
