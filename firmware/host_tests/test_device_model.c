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

    assert(cc_device_button_sample(&model, true, 1010) == CC_BUTTON_NONE);
    assert(cc_device_button_sample(&model, false, 1020) == CC_BUTTON_NONE);
    assert(cc_device_button_sample(&model, true, 1030) == CC_BUTTON_NONE);
    assert(cc_device_button_sample(&model, true, 1060) == CC_BUTTON_PTT_DOWN);
    assert(model.visible_state == CC_STATE_LISTENING);
    assert(cc_device_button_sample(&model, false, 1070) == CC_BUTTON_NONE);
    assert(cc_device_button_sample(&model, false, 1100) == CC_BUTTON_PTT_UP);
    assert(model.visible_state == CC_STATE_WORKING);
    assert(cc_device_button_sample(&model, false, 1300) == CC_BUTTON_NONE);

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
