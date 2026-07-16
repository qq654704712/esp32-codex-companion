#include "control_protocol.h"

#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

static const uint8_t expected[] = {
    0xa6, 0x00, 0x01, 0x01, 0x18, 0x2a, 0x02, 0x07, 0x03, 0x1a,
    0x00, 0x12, 0xd6, 0x87, 0x04, 0x43, 0xa1, 0x00, 0xf5, 0x05,
    0x50, 0x7f, 0xf7, 0xdf, 0x98, 0x9d, 0x9b, 0xd1, 0xee, 0xe0,
    0xe4, 0x6f, 0x35, 0x5d, 0x6b, 0x16, 0x10,
};

int main(void) {
    uint8_t key[32];
    for (size_t i = 0; i < sizeof(key); ++i) key[i] = (uint8_t)i;
    const uint8_t payload[] = {0xa1, 0x00, 0xf5};
    cc_envelope_t envelope = {
        .version = 1,
        .sequence = 42,
        .message_type = CC_MSG_PTT_DOWN,
        .timestamp_ms = 1234567,
        .payload = payload,
        .payload_len = sizeof(payload),
    };
    uint8_t encoded[128];
    size_t encoded_len = 0;

    assert(cc_encode_envelope(&envelope, key, sizeof(key), encoded,
                              sizeof(encoded), &encoded_len) == CC_OK);
    assert(encoded_len == sizeof(expected));
    assert(memcmp(encoded, expected, sizeof(expected)) == 0);

    cc_envelope_t decoded = {0};
    uint8_t decoded_payload[32];
    assert(cc_decode_envelope(encoded, encoded_len, key, sizeof(key), &decoded,
                              decoded_payload, sizeof(decoded_payload)) == CC_OK);
    assert(decoded.sequence == envelope.sequence);
    assert(decoded.message_type == envelope.message_type);
    assert(decoded.payload_len == sizeof(payload));
    assert(memcmp(decoded.payload, payload, sizeof(payload)) == 0);

    encoded[encoded_len - 1] ^= 1;
    assert(cc_decode_envelope(encoded, encoded_len, key, sizeof(key), &decoded,
                              decoded_payload, sizeof(decoded_payload)) ==
           CC_ERR_AUTHENTICATION);

    cc_sequence_guard_t guard = {0};
    assert(cc_sequence_guard_accept(&guard, 10) == CC_OK);
    assert(cc_sequence_guard_accept(&guard, 10) == CC_ERR_REPLAY);
    assert(cc_sequence_guard_accept(&guard, 11) == CC_OK);
    cc_sequence_guard_reset(&guard);
    assert(cc_sequence_guard_accept(&guard, 1) == CC_OK);

    puts("control protocol tests passed");
    return 0;
}
