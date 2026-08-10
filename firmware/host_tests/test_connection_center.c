#include "connection_center.h"

#include <assert.h>
#include <string.h>

int main(void) {
    cc_connection_center_t center;
    cc_connection_center_init(&center);
    assert(!center.open);
    assert(center.page == CC_CENTER_PAGE_NETWORK);
    assert(center.audio_mode == CC_AUDIO_MODE_WIFI);

    cc_connection_center_open(&center);
    cc_connection_center_next_page(&center);
    assert(center.page == CC_CENTER_PAGE_HOST);
    cc_connection_center_next_page(&center);
    assert(center.page == CC_CENTER_PAGE_AUDIO);
    cc_connection_center_next_page(&center);
    assert(center.page == CC_CENTER_PAGE_NETWORK);
    cc_connection_center_previous_page(&center);
    assert(center.page == CC_CENTER_PAGE_AUDIO);

    cc_center_host_t hosts[2] = {0};
    strcpy(hosts[0].id, "office");
    strcpy(hosts[0].display_name, "Office Mac");
    hosts[0].paired = true;
    strcpy(hosts[1].id, "studio");
    strcpy(hosts[1].display_name, "Studio Mac");
    hosts[1].reachable = true;
    assert(cc_connection_center_set_hosts(&center, hosts, 2));
    assert(cc_connection_center_select_host(&center, 1));

    cc_connection_center_begin_hold(&center, CC_CENTER_ACTION_SWITCH_HOST, 100);
    assert(!cc_connection_center_complete_hold(&center, 1599));
    assert(center.pending_action == CC_CENTER_ACTION_SWITCH_HOST);
    assert(cc_connection_center_complete_hold(&center, 1600));
    assert(center.pending_action == CC_CENTER_ACTION_NONE);

    cc_connection_center_begin_hold(&center, CC_CENTER_ACTION_UNPAIR_HOST, 2000);
    cc_connection_center_close(&center);
    assert(center.pending_action == CC_CENTER_ACTION_NONE);

    cc_connection_center_set_audio_mode(&center, CC_AUDIO_MODE_USB_COMPATIBILITY);
    assert(center.audio_mode == CC_AUDIO_MODE_USB_COMPATIBILITY);
    return 0;
}
