#ifndef CODEX_COMPANION_CONTROL_PROTOCOL_H
#define CODEX_COMPANION_CONTROL_PROTOCOL_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define CC_PROTOCOL_VERSION 1
#define CC_HMAC_TAG_SIZE 16
#define CC_MAX_CONTROL_PACKET 512

typedef enum {
    CC_MSG_HELLO = 1,
    CC_MSG_HEARTBEAT = 2,
    CC_MSG_STATE_UPDATE = 3,
    CC_MSG_QUOTA_UPDATE = 4,
    CC_MSG_PROMPT_OPEN = 5,
    CC_MSG_PROMPT_CLOSE = 6,
    CC_MSG_PTT_DOWN = 7,
    CC_MSG_PTT_UP = 8,
    CC_MSG_OPTION_SELECT = 9,
    CC_MSG_LONG_PRESS_CONFIRM = 10,
    CC_MSG_AUDIO_LEVEL = 11,
    CC_MSG_ACK = 12,
    CC_MSG_ERROR = 13,
} cc_message_type_t;

typedef enum {
    CC_OK = 0,
    CC_ERR_INVALID_ARGUMENT = -1,
    CC_ERR_BUFFER_TOO_SMALL = -2,
    CC_ERR_INVALID_ENCODING = -3,
    CC_ERR_UNSUPPORTED_VERSION = -4,
    CC_ERR_UNKNOWN_MESSAGE_TYPE = -5,
    CC_ERR_AUTHENTICATION = -6,
    CC_ERR_REPLAY = -7,
    CC_ERR_CRYPTO = -8,
} cc_result_t;

typedef struct {
    uint8_t version;
    uint32_t sequence;
    cc_message_type_t message_type;
    uint64_t timestamp_ms;
    const uint8_t *payload;
    size_t payload_len;
} cc_envelope_t;

typedef struct {
    bool initialized;
    uint32_t last_accepted;
} cc_sequence_guard_t;

cc_result_t cc_encode_envelope(const cc_envelope_t *envelope,
                               const uint8_t *key, size_t key_len,
                               uint8_t *output, size_t output_capacity,
                               size_t *output_len);

cc_result_t cc_decode_envelope(const uint8_t *data, size_t data_len,
                               const uint8_t *key, size_t key_len,
                               cc_envelope_t *envelope,
                               uint8_t *payload_buffer,
                               size_t payload_capacity);

cc_result_t cc_sequence_guard_accept(cc_sequence_guard_t *guard,
                                     uint32_t sequence);
void cc_sequence_guard_reset(cc_sequence_guard_t *guard);

#ifdef __cplusplus
}
#endif

#endif
