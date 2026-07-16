#include "ble_framing.h"

#include <string.h>

uint8_t cc_ble_fragment_count(size_t packet_length) {
    if (packet_length > CC_BLE_MAX_CONTROL_PACKET) return 0;
    const size_t count = packet_length == 0 ? 1 :
        (packet_length + CC_BLE_FRAME_CHUNK_SIZE - 1) / CC_BLE_FRAME_CHUNK_SIZE;
    return count > UINT8_MAX ? 0 : (uint8_t)count;
}

size_t cc_ble_make_fragment(uint16_t frame_id, uint8_t fragment_index,
                            uint8_t fragment_count, const uint8_t *packet,
                            size_t packet_length, uint8_t *output,
                            size_t output_capacity) {
    if (!output || !packet || fragment_count == 0 ||
        fragment_count != cc_ble_fragment_count(packet_length) ||
        fragment_index >= fragment_count) return 0;
    const size_t start = (size_t)fragment_index * CC_BLE_FRAME_CHUNK_SIZE;
    const size_t remaining = packet_length - start;
    const size_t chunk = remaining > CC_BLE_FRAME_CHUNK_SIZE ?
                         CC_BLE_FRAME_CHUNK_SIZE : remaining;
    if (output_capacity < CC_BLE_FRAME_HEADER_SIZE + chunk) return 0;
    output[0] = CC_BLE_FRAME_MAGIC;
    output[1] = (uint8_t)(frame_id >> 8);
    output[2] = (uint8_t)frame_id;
    output[3] = fragment_index;
    output[4] = fragment_count;
    memcpy(output + CC_BLE_FRAME_HEADER_SIZE, packet + start, chunk);
    return CC_BLE_FRAME_HEADER_SIZE + chunk;
}

cc_ble_frame_result_t cc_ble_reassembler_accept(
    cc_ble_reassembler_t *state, const uint8_t *fragment,
    size_t fragment_length, size_t *output_length) {
    if (!state || !fragment || fragment_length < CC_BLE_FRAME_HEADER_SIZE ||
        fragment[0] != CC_BLE_FRAME_MAGIC || fragment[4] == 0 ||
        fragment[3] >= fragment[4]) return CC_BLE_FRAME_ERROR;
    const uint16_t frame_id = (uint16_t)((uint16_t)fragment[1] << 8) | fragment[2];
    const uint8_t index = fragment[3];
    const uint8_t count = fragment[4];
    if (index == 0) {
        state->frame_id = frame_id;
        state->expected_index = 0;
        state->fragment_count = count;
        state->length = 0;
    }
    if (state->frame_id != frame_id || state->fragment_count != count ||
        state->expected_index != index) {
        state->length = 0;
        return CC_BLE_FRAME_ERROR;
    }
    const size_t chunk = fragment_length - CC_BLE_FRAME_HEADER_SIZE;
    if (chunk > sizeof(state->buffer) - state->length) {
        state->length = 0;
        return CC_BLE_FRAME_ERROR;
    }
    memcpy(state->buffer + state->length,
           fragment + CC_BLE_FRAME_HEADER_SIZE, chunk);
    state->length += chunk;
    state->expected_index++;
    if (state->expected_index == state->fragment_count) {
        if (output_length) *output_length = state->length;
        return CC_BLE_FRAME_COMPLETE;
    }
    return CC_BLE_FRAME_INCOMPLETE;
}
