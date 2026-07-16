#include "wifi_manager.h"

#include <assert.h>

int main(void) {
    cc_wifi_model_t model = cc_wifi_model_initial();
    assert(cc_wifi_event(&model, CC_WIFI_BEGIN_PROVISIONING, 10) == CC_WIFI_SOFTAP_ACTIVE);
    assert(model.setup_password_is_ephemeral);
    assert(cc_wifi_event(&model, CC_WIFI_PROVISION_TIMEOUT, 20) == CC_WIFI_UNCONFIGURED);
    assert(!model.setup_password_is_ephemeral);
    assert(cc_wifi_event(&model, CC_WIFI_BEGIN_PROVISIONING, 30) == CC_WIFI_SOFTAP_ACTIVE);
    assert(cc_wifi_event(&model, CC_WIFI_CREDENTIALS_ACCEPTED, 31) == CC_WIFI_STA_CONNECTING);
    assert(cc_wifi_event(&model, CC_WIFI_STA_GOT_IP, 32) == CC_WIFI_CONNECTED);
    assert(cc_wifi_is_valid_ipv4("192.168.10.50"));
    assert(cc_wifi_is_valid_ipv4("0.0.0.0"));
    assert(!cc_wifi_is_valid_ipv4("192.168.10.50."));
    assert(!cc_wifi_is_valid_ipv4("192.168.10"));
    assert(!cc_wifi_is_valid_ipv4("192.168.10.256"));
    assert(!cc_wifi_is_valid_ipv4("192.168.10.a"));
    return 0;
}
