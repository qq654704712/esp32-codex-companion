#include "wifi_wire.h"

#include <assert.h>
#include <stdint.h>
#include <string.h>

int main(void) {
    uint8_t pairing_secret[CC_WIFI_PAIRING_SECRET_SIZE];
    memset(pairing_secret, 0x11, sizeof(pairing_secret));
    uint8_t session_nonce[CC_WIFI_SESSION_NONCE_SIZE];
    for (size_t i = 0; i < sizeof(session_nonce); ++i) session_nonce[i] = (uint8_t)i;

    cc_wifi_session_keys_t keys;
    assert(cc_wifi_derive_session_keys(pairing_secret, sizeof(pairing_secret),
                                       session_nonce, &keys) == CC_WIFI_WIRE_OK);
    const uint8_t expected_control[CC_WIFI_KEY_SIZE] = {
        0x6c, 0xf2, 0xbb, 0xa7, 0x3d, 0x62, 0x9c, 0x85,
        0x4f, 0xc2, 0xaa, 0x6b, 0x8f, 0x01, 0xa5, 0x58,
        0x2d, 0xa3, 0xd1, 0xa2, 0x95, 0x14, 0xaa, 0xd3,
        0x14, 0xb0, 0x86, 0xc6, 0xec, 0xa2, 0x23, 0x85,
    };
    const uint8_t expected_audio[CC_WIFI_KEY_SIZE] = {
        0xf9, 0xf1, 0xd8, 0xc3, 0x79, 0xc5, 0x4a, 0xfd,
        0x29, 0xa1, 0x6a, 0xd2, 0xaf, 0x70, 0xf8, 0x21,
        0x61, 0xee, 0xf7, 0x4b, 0x56, 0x06, 0xcc, 0x4d,
        0x75, 0x70, 0x7e, 0x99, 0x32, 0xa6, 0x9c, 0x28,
    };
    assert(memcmp(keys.control_key, expected_control, CC_WIFI_KEY_SIZE) == 0);
    assert(memcmp(keys.audio_key, expected_audio, CC_WIFI_KEY_SIZE) == 0);
    assert(memcmp(keys.control_key, keys.audio_key, CC_WIFI_KEY_SIZE) != 0);

    uint8_t device_nonce[CC_WIFI_SESSION_NONCE_SIZE];
    uint8_t host_nonce[CC_WIFI_SESSION_NONCE_SIZE];
    memset(device_nonce, 0x11, sizeof(device_nonce));
    memset(host_nonce, 0x22, sizeof(host_nonce));
    uint8_t device_handshake[CC_WIFI_HANDSHAKE_SIZE];
    uint8_t host_handshake[CC_WIFI_HANDSHAKE_SIZE];
    uint8_t decoded_nonce[CC_WIFI_SESSION_NONCE_SIZE];
    assert(cc_wifi_encode_handshake(CC_WIFI_HANDSHAKE_DEVICE, device_nonce,
                                    pairing_secret, device_handshake) == CC_WIFI_WIRE_OK);
    assert(cc_wifi_encode_handshake(CC_WIFI_HANDSHAKE_HOST, host_nonce,
                                    pairing_secret, host_handshake) == CC_WIFI_WIRE_OK);
    assert(cc_wifi_decode_handshake(device_handshake, CC_WIFI_HANDSHAKE_DEVICE,
                                    pairing_secret, decoded_nonce) == CC_WIFI_WIRE_OK);
    assert(memcmp(decoded_nonce, device_nonce, sizeof(decoded_nonce)) == 0);
    uint8_t handshake_nonce[CC_WIFI_SESSION_NONCE_SIZE];
    assert(cc_wifi_make_session_nonce(device_nonce, host_nonce, handshake_nonce) == CC_WIFI_WIRE_OK);
    const uint8_t expected_handshake_nonce[CC_WIFI_SESSION_NONCE_SIZE] = {
        0x93, 0x7e, 0xec, 0x12, 0xd3, 0xc7, 0xe4, 0xe5,
        0x31, 0x12, 0x9b, 0xa5, 0xfa, 0xe2, 0xa0, 0x3f,
        0x49, 0xe6, 0xc8, 0x44, 0xe6, 0x24, 0x7e, 0x6f,
        0x34, 0x9f, 0xc1, 0xa5, 0x18, 0xa2, 0xfa, 0x19,
    };
    assert(memcmp(handshake_nonce, expected_handshake_nonce, sizeof(handshake_nonce)) == 0);
    assert(cc_wifi_session_id_from_nonce(handshake_nonce) == UINT64_C(0x937eec12d3c7e4e5));

    uint8_t pcm[CC_WIFI_AUDIO_PAYLOAD_SIZE] = {0};
    cc_wifi_frame_t input = {
        .kind = CC_WIFI_FRAME_AUDIO,
        .session_id = 42,
        .sequence = 7,
        .timestamp_ms = 1234,
        .payload = pcm,
        .payload_len = sizeof(pcm),
    };
    const uint8_t nonce[CC_WIFI_NONCE_SIZE] = {0xA5};
    uint8_t packet[CC_WIFI_MAX_PACKET_SIZE];
    size_t packet_len = 0;
    assert(cc_wifi_encode_frame(&input, keys.audio_key, nonce, packet,
                                sizeof(packet), &packet_len) == CC_WIFI_WIRE_OK);

    uint8_t decoded_payload[CC_WIFI_MAX_PAYLOAD_SIZE];
    cc_wifi_frame_t output;
    assert(cc_wifi_decode_frame(packet, packet_len, keys.audio_key, &output,
                                decoded_payload, sizeof(decoded_payload)) == CC_WIFI_WIRE_OK);
    assert(output.kind == CC_WIFI_FRAME_AUDIO);
    assert(output.session_id == 42);
    assert(output.sequence == 7);
    assert(output.payload_len == sizeof(pcm));

    cc_wifi_replay_window_t window = {0};
    assert(cc_wifi_replay_accept(&window, 42, 7) == CC_WIFI_WIRE_OK);
    assert(cc_wifi_replay_accept(&window, 42, 7) == CC_WIFI_WIRE_REPLAY);
    assert(cc_wifi_replay_accept(&window, 42, 8) == CC_WIFI_WIRE_OK);
    assert(cc_wifi_replay_accept(&window, 43, 7) == CC_WIFI_WIRE_OK);

    packet[CC_WIFI_FRAME_HEADER_SIZE] ^= 0x01;
    assert(cc_wifi_decode_frame(packet, packet_len, keys.audio_key, &output,
                                decoded_payload, sizeof(decoded_payload)) == CC_WIFI_WIRE_AUTHENTICATION);
    return 0;
}
