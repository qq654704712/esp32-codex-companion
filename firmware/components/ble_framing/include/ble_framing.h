#ifndef CODEX_COMPANION_BLE_FRAMING_H
#define CODEX_COMPANION_BLE_FRAMING_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define CC_BLE_FRAME_MAGIC 0xCC
#define CC_BLE_GATT_PAYLOAD_LIMIT 244
#define CC_BLE_FRAME_HEADER_SIZE 5
#define CC_BLE_FRAME_CHUNK_SIZE 239
#define CC_BLE_MAX_CONTROL_PACKET 512

typedef enum {
    CC_BLE_FRAME_ERROR = -1,
    CC_BLE_FRAME_INCOMPLETE = 0,
    CC_BLE_FRAME_COMPLETE = 1,
} cc_ble_frame_result_t;

typedef struct {
    uint16_t frame_id;
    uint8_t expected_index;
    uint8_t fragment_count;
    size_t length;
    uint8_t buffer[CC_BLE_MAX_CONTROL_PACKET];
} cc_ble_reassembler_t;

uint8_t cc_ble_fragment_count(size_t packet_length);
size_t cc_ble_make_fragment(uint16_t frame_id, uint8_t fragment_index,
                            uint8_t fragment_count, const uint8_t *packet,
                            size_t packet_length, uint8_t *output,
                            size_t output_capacity);
cc_ble_frame_result_t cc_ble_reassembler_accept(
    cc_ble_reassembler_t *reassembler, const uint8_t *fragment,
    size_t fragment_length, size_t *output_length);

#ifdef __cplusplus
}
#endif

#endif
