#ifndef CODEX_COMPANION_WIFI_WIRE_H
#define CODEX_COMPANION_WIFI_WIRE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define CC_WIFI_WIRE_VERSION 2
#define CC_WIFI_PAIRING_SECRET_SIZE 32
#define CC_WIFI_SESSION_NONCE_SIZE 32
#define CC_WIFI_KEY_SIZE 32
#define CC_WIFI_NONCE_SIZE 12
#define CC_WIFI_TAG_SIZE 16
#define CC_WIFI_FRAME_HEADER_SIZE 42
#define CC_WIFI_HANDSHAKE_SIZE 54
#define CC_WIFI_MAX_PAYLOAD_SIZE 768
#define CC_WIFI_AUDIO_PAYLOAD_SIZE 640
#define CC_WIFI_MAX_PACKET_SIZE (CC_WIFI_FRAME_HEADER_SIZE + CC_WIFI_MAX_PAYLOAD_SIZE + CC_WIFI_TAG_SIZE)

typedef enum {
    CC_WIFI_WIRE_OK = 0,
    CC_WIFI_WIRE_INVALID_ARGUMENT = -1,
    CC_WIFI_WIRE_INVALID_FRAME = -2,
    CC_WIFI_WIRE_UNSUPPORTED_VERSION = -3,
    CC_WIFI_WIRE_INVALID_KIND = -4,
    CC_WIFI_WIRE_INVALID_LENGTH = -5,
    CC_WIFI_WIRE_AUTHENTICATION = -6,
    CC_WIFI_WIRE_REPLAY = -7,
    CC_WIFI_WIRE_CRYPTO = -8,
} cc_wifi_wire_result_t;

typedef enum {
    CC_WIFI_FRAME_CONTROL = 1,
    CC_WIFI_FRAME_AUDIO = 2,
} cc_wifi_frame_kind_t;

typedef enum {
    CC_WIFI_HANDSHAKE_DEVICE = 1,
    CC_WIFI_HANDSHAKE_HOST = 2,
} cc_wifi_handshake_role_t;

typedef struct {
    uint8_t control_key[CC_WIFI_KEY_SIZE];
    uint8_t audio_key[CC_WIFI_KEY_SIZE];
} cc_wifi_session_keys_t;

typedef struct {
    cc_wifi_frame_kind_t kind;
    uint64_t session_id;
    uint32_t sequence;
    uint64_t timestamp_ms;
    const uint8_t *payload;
    size_t payload_len;
} cc_wifi_frame_t;

typedef struct {
    uint8_t initialized;
    uint64_t session_id;
    uint32_t highest_sequence;
    uint64_t seen_mask;
} cc_wifi_replay_window_t;

cc_wifi_wire_result_t cc_wifi_derive_session_keys(
    const uint8_t *pairing_secret, size_t pairing_secret_len,
    const uint8_t session_nonce[CC_WIFI_SESSION_NONCE_SIZE],
    cc_wifi_session_keys_t *keys);

cc_wifi_wire_result_t cc_wifi_encode_handshake(
    cc_wifi_handshake_role_t role,
    const uint8_t nonce[CC_WIFI_SESSION_NONCE_SIZE],
    const uint8_t pairing_secret[CC_WIFI_PAIRING_SECRET_SIZE],
    uint8_t output[CC_WIFI_HANDSHAKE_SIZE]);

cc_wifi_wire_result_t cc_wifi_decode_handshake(
    const uint8_t input[CC_WIFI_HANDSHAKE_SIZE],
    cc_wifi_handshake_role_t expected_role,
    const uint8_t pairing_secret[CC_WIFI_PAIRING_SECRET_SIZE],
    uint8_t nonce[CC_WIFI_SESSION_NONCE_SIZE]);

cc_wifi_wire_result_t cc_wifi_make_session_nonce(
    const uint8_t device_nonce[CC_WIFI_SESSION_NONCE_SIZE],
    const uint8_t host_nonce[CC_WIFI_SESSION_NONCE_SIZE],
    uint8_t session_nonce[CC_WIFI_SESSION_NONCE_SIZE]);

uint64_t cc_wifi_session_id_from_nonce(
    const uint8_t session_nonce[CC_WIFI_SESSION_NONCE_SIZE]);

void cc_wifi_make_nonce(uint64_t session_id, uint32_t sequence,
                        uint8_t nonce[CC_WIFI_NONCE_SIZE]);

cc_wifi_wire_result_t cc_wifi_encode_frame(
    const cc_wifi_frame_t *frame, const uint8_t key[CC_WIFI_KEY_SIZE],
    const uint8_t nonce[CC_WIFI_NONCE_SIZE], uint8_t *output,
    size_t output_capacity, size_t *output_len);

cc_wifi_wire_result_t cc_wifi_decode_frame(
    const uint8_t *packet, size_t packet_len,
    const uint8_t key[CC_WIFI_KEY_SIZE], cc_wifi_frame_t *frame,
    uint8_t *payload_buffer, size_t payload_capacity);

cc_wifi_wire_result_t cc_wifi_replay_accept(cc_wifi_replay_window_t *window,
                                             uint64_t session_id,
                                             uint32_t sequence);
void cc_wifi_replay_reset(cc_wifi_replay_window_t *window);

#ifdef __cplusplus
}
#endif

#endif
