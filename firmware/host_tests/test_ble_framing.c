#include "ble_framing.h"

#include <assert.h>
#include <stdio.h>
#include <string.h>

int main(void) {
    uint8_t packet[512];
    for (size_t i = 0; i < sizeof(packet); ++i) packet[i] = (uint8_t)i;
    assert(cc_ble_fragment_count(sizeof(packet)) == 3);
    cc_ble_reassembler_t reassembler = {0};
    uint8_t fragment[CC_BLE_GATT_PAYLOAD_LIMIT];
    size_t output_length = 0;
    for (uint8_t i = 0; i < 3; ++i) {
        size_t fragment_length = cc_ble_make_fragment(
            0x1234, i, 3, packet, sizeof(packet), fragment, sizeof(fragment));
        assert(fragment_length <= CC_BLE_GATT_PAYLOAD_LIMIT);
        cc_ble_frame_result_t result = cc_ble_reassembler_accept(
            &reassembler, fragment, fragment_length, &output_length);
        assert(result == (i == 2 ? CC_BLE_FRAME_COMPLETE : CC_BLE_FRAME_INCOMPLETE));
    }
    assert(output_length == sizeof(packet));
    assert(memcmp(reassembler.buffer, packet, sizeof(packet)) == 0);
    puts("BLE framing tests passed");
    return 0;
}
