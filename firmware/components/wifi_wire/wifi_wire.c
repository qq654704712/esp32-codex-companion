#include "wifi_wire.h"

#include <stdbool.h>
#include <string.h>

#ifdef ESP_PLATFORM
#include "mbedtls/chachapoly.h"
#include "mbedtls/md.h"
#else
#include <CommonCrypto/CommonHMAC.h>
#include <CommonCrypto/CommonDigest.h>
#include <openssl/evp.h>
#endif

static const uint8_t k_magic[4] = {'C', 'C', 'W', '2'};
static const uint8_t k_control_label[] = "codex-control-v2";
static const uint8_t k_audio_label[] = "codex-audio-v2";
static const uint8_t k_handshake_magic[4] = {'C', 'C', 'H', '2'};
static const uint8_t k_session_label[] = "codex-wifi-session-v2";

static void write_u16(uint8_t *output, uint16_t value) {
    output[0] = (uint8_t)(value >> 8);
    output[1] = (uint8_t)value;
}

static void write_u32(uint8_t *output, uint32_t value) {
    for (size_t i = 0; i < 4; ++i) output[i] = (uint8_t)(value >> (24 - i * 8));
}

static void write_u64(uint8_t *output, uint64_t value) {
    for (size_t i = 0; i < 8; ++i) output[i] = (uint8_t)(value >> (56 - i * 8));
}

static uint16_t read_u16(const uint8_t *input) {
    return (uint16_t)((uint16_t)input[0] << 8 | input[1]);
}

static uint32_t read_u32(const uint8_t *input) {
    uint32_t value = 0;
    for (size_t i = 0; i < 4; ++i) value = (value << 8) | input[i];
    return value;
}

static uint64_t read_u64(const uint8_t *input) {
    uint64_t value = 0;
    for (size_t i = 0; i < 8; ++i) value = (value << 8) | input[i];
    return value;
}

static cc_wifi_wire_result_t hmac_sha256(const uint8_t *key, size_t key_len,
                                         const uint8_t *input, size_t input_len,
                                         uint8_t output[CC_WIFI_KEY_SIZE]) {
#ifdef ESP_PLATFORM
    const mbedtls_md_info_t *info =
        mbedtls_md_info_from_type(MBEDTLS_MD_SHA256);
    if (info == NULL || mbedtls_md_hmac(info, key, key_len, input, input_len,
                                        output) != 0) {
        return CC_WIFI_WIRE_CRYPTO;
    }
#else
    CCHmac(kCCHmacAlgSHA256, key, key_len, input, input_len, output);
#endif
    return CC_WIFI_WIRE_OK;
}

static cc_wifi_wire_result_t sha256(const uint8_t *input, size_t input_len,
                                    uint8_t output[CC_WIFI_KEY_SIZE]) {
#ifdef ESP_PLATFORM
    const mbedtls_md_info_t *info = mbedtls_md_info_from_type(MBEDTLS_MD_SHA256);
    if (info == NULL || mbedtls_md(info, input, input_len, output) != 0) {
        return CC_WIFI_WIRE_CRYPTO;
    }
#else
    CC_SHA256(input, (CC_LONG)input_len, output);
#endif
    return CC_WIFI_WIRE_OK;
}

static bool constant_time_equal(const uint8_t *left, const uint8_t *right,
                                size_t length) {
    uint8_t difference = 0;
    for (size_t i = 0; i < length; ++i) difference |= left[i] ^ right[i];
    return difference == 0;
}

static cc_wifi_wire_result_t hkdf_expand_one_block(
    const uint8_t pairing_secret[CC_WIFI_PAIRING_SECRET_SIZE],
    const uint8_t session_nonce[CC_WIFI_SESSION_NONCE_SIZE],
    const uint8_t *label, size_t label_len, uint8_t output[CC_WIFI_KEY_SIZE]) {
    uint8_t prk[CC_WIFI_KEY_SIZE];
    cc_wifi_wire_result_t result = hmac_sha256(
        session_nonce, CC_WIFI_SESSION_NONCE_SIZE, pairing_secret,
        CC_WIFI_PAIRING_SECRET_SIZE, prk);
    if (result != CC_WIFI_WIRE_OK) return result;
    uint8_t info[64];
    if (label_len + 1 > sizeof(info)) return CC_WIFI_WIRE_INVALID_ARGUMENT;
    memcpy(info, label, label_len);
    info[label_len] = 1;
    result = hmac_sha256(prk, sizeof(prk), info, label_len + 1, output);
    memset(prk, 0, sizeof(prk));
    return result;
}

static cc_wifi_wire_result_t encrypt(const uint8_t key[CC_WIFI_KEY_SIZE],
                                     const uint8_t nonce[CC_WIFI_NONCE_SIZE],
                                     const uint8_t *aad, size_t aad_len,
                                     const uint8_t *plain, size_t plain_len,
                                     uint8_t *cipher, uint8_t tag[CC_WIFI_TAG_SIZE]) {
#ifdef ESP_PLATFORM
    mbedtls_chachapoly_context context;
    mbedtls_chachapoly_init(&context);
    int result = mbedtls_chachapoly_setkey(&context, key);
    if (result == 0) {
        result = mbedtls_chachapoly_encrypt_and_tag(
            &context, plain_len, nonce, aad, aad_len, plain, cipher, tag);
    }
    mbedtls_chachapoly_free(&context);
    return result == 0 ? CC_WIFI_WIRE_OK : CC_WIFI_WIRE_CRYPTO;
#else
    EVP_CIPHER_CTX *context = EVP_CIPHER_CTX_new();
    int result = 0;
    int output_len = 0;
    if (context != NULL &&
        EVP_EncryptInit_ex(context, EVP_chacha20_poly1305(), NULL, NULL, NULL) == 1 &&
        EVP_CIPHER_CTX_ctrl(context, EVP_CTRL_AEAD_SET_IVLEN, CC_WIFI_NONCE_SIZE, NULL) == 1 &&
        EVP_EncryptInit_ex(context, NULL, NULL, key, nonce) == 1 &&
        EVP_EncryptUpdate(context, NULL, &output_len, aad, (int)aad_len) == 1 &&
        EVP_EncryptUpdate(context, cipher, &output_len, plain, (int)plain_len) == 1 &&
        EVP_EncryptFinal_ex(context, cipher + output_len, &output_len) == 1 &&
        EVP_CIPHER_CTX_ctrl(context, EVP_CTRL_AEAD_GET_TAG, CC_WIFI_TAG_SIZE, tag) == 1) {
        result = 1;
    }
    EVP_CIPHER_CTX_free(context);
    return result ? CC_WIFI_WIRE_OK : CC_WIFI_WIRE_CRYPTO;
#endif
}

static cc_wifi_wire_result_t decrypt(const uint8_t key[CC_WIFI_KEY_SIZE],
                                     const uint8_t nonce[CC_WIFI_NONCE_SIZE],
                                     const uint8_t *aad, size_t aad_len,
                                     const uint8_t *cipher, size_t cipher_len,
                                     const uint8_t tag[CC_WIFI_TAG_SIZE],
                                     uint8_t *plain) {
#ifdef ESP_PLATFORM
    mbedtls_chachapoly_context context;
    mbedtls_chachapoly_init(&context);
    int result = mbedtls_chachapoly_setkey(&context, key);
    if (result == 0) {
        result = mbedtls_chachapoly_auth_decrypt(
            &context, cipher_len, nonce, aad, aad_len, tag, cipher, plain);
    }
    mbedtls_chachapoly_free(&context);
    return result == 0 ? CC_WIFI_WIRE_OK : CC_WIFI_WIRE_AUTHENTICATION;
#else
    EVP_CIPHER_CTX *context = EVP_CIPHER_CTX_new();
    int result = 0;
    int output_len = 0;
    if (context != NULL &&
        EVP_DecryptInit_ex(context, EVP_chacha20_poly1305(), NULL, NULL, NULL) == 1 &&
        EVP_CIPHER_CTX_ctrl(context, EVP_CTRL_AEAD_SET_IVLEN, CC_WIFI_NONCE_SIZE, NULL) == 1 &&
        EVP_DecryptInit_ex(context, NULL, NULL, key, nonce) == 1 &&
        EVP_DecryptUpdate(context, NULL, &output_len, aad, (int)aad_len) == 1 &&
        EVP_DecryptUpdate(context, plain, &output_len, cipher, (int)cipher_len) == 1 &&
        EVP_CIPHER_CTX_ctrl(context, EVP_CTRL_AEAD_SET_TAG, CC_WIFI_TAG_SIZE,
                            (void *)tag) == 1 &&
        EVP_DecryptFinal_ex(context, plain + output_len, &output_len) == 1) {
        result = 1;
    }
    EVP_CIPHER_CTX_free(context);
    return result ? CC_WIFI_WIRE_OK : CC_WIFI_WIRE_AUTHENTICATION;
#endif
}

cc_wifi_wire_result_t cc_wifi_derive_session_keys(
    const uint8_t *pairing_secret, size_t pairing_secret_len,
    const uint8_t session_nonce[CC_WIFI_SESSION_NONCE_SIZE],
    cc_wifi_session_keys_t *keys) {
    if (pairing_secret == NULL || session_nonce == NULL || keys == NULL ||
        pairing_secret_len != CC_WIFI_PAIRING_SECRET_SIZE) {
        return CC_WIFI_WIRE_INVALID_ARGUMENT;
    }
    cc_wifi_wire_result_t result = hkdf_expand_one_block(
        pairing_secret, session_nonce, k_control_label, sizeof(k_control_label) - 1,
        keys->control_key);
    if (result != CC_WIFI_WIRE_OK) return result;
    return hkdf_expand_one_block(pairing_secret, session_nonce, k_audio_label,
                                 sizeof(k_audio_label) - 1, keys->audio_key);
}

cc_wifi_wire_result_t cc_wifi_encode_handshake(
    cc_wifi_handshake_role_t role,
    const uint8_t nonce[CC_WIFI_SESSION_NONCE_SIZE],
    const uint8_t pairing_secret[CC_WIFI_PAIRING_SECRET_SIZE],
    uint8_t output[CC_WIFI_HANDSHAKE_SIZE]) {
    if (nonce == NULL || pairing_secret == NULL || output == NULL ||
        (role != CC_WIFI_HANDSHAKE_DEVICE && role != CC_WIFI_HANDSHAKE_HOST)) {
        return CC_WIFI_WIRE_INVALID_ARGUMENT;
    }
    memcpy(output, k_handshake_magic, sizeof(k_handshake_magic));
    output[4] = CC_WIFI_WIRE_VERSION;
    output[5] = (uint8_t)role;
    memcpy(output + 6, nonce, CC_WIFI_SESSION_NONCE_SIZE);
    uint8_t tag[CC_WIFI_KEY_SIZE];
    cc_wifi_wire_result_t result = hmac_sha256(
        pairing_secret, CC_WIFI_PAIRING_SECRET_SIZE, output,
        CC_WIFI_HANDSHAKE_SIZE - 16, tag);
    if (result == CC_WIFI_WIRE_OK) memcpy(output + CC_WIFI_HANDSHAKE_SIZE - 16, tag, 16);
    memset(tag, 0, sizeof(tag));
    return result;
}

cc_wifi_wire_result_t cc_wifi_decode_handshake(
    const uint8_t input[CC_WIFI_HANDSHAKE_SIZE],
    cc_wifi_handshake_role_t expected_role,
    const uint8_t pairing_secret[CC_WIFI_PAIRING_SECRET_SIZE],
    uint8_t nonce[CC_WIFI_SESSION_NONCE_SIZE]) {
    if (input == NULL || pairing_secret == NULL || nonce == NULL ||
        (expected_role != CC_WIFI_HANDSHAKE_DEVICE &&
         expected_role != CC_WIFI_HANDSHAKE_HOST)) {
        return CC_WIFI_WIRE_INVALID_ARGUMENT;
    }
    if (memcmp(input, k_handshake_magic, sizeof(k_handshake_magic)) != 0 ||
        input[4] != CC_WIFI_WIRE_VERSION || input[5] != (uint8_t)expected_role) {
        return CC_WIFI_WIRE_INVALID_FRAME;
    }
    uint8_t tag[CC_WIFI_KEY_SIZE];
    cc_wifi_wire_result_t result = hmac_sha256(
        pairing_secret, CC_WIFI_PAIRING_SECRET_SIZE, input,
        CC_WIFI_HANDSHAKE_SIZE - 16, tag);
    if (result == CC_WIFI_WIRE_OK && !constant_time_equal(
            tag, input + CC_WIFI_HANDSHAKE_SIZE - 16, 16)) {
        result = CC_WIFI_WIRE_AUTHENTICATION;
    }
    if (result == CC_WIFI_WIRE_OK) {
        memcpy(nonce, input + 6, CC_WIFI_SESSION_NONCE_SIZE);
    }
    memset(tag, 0, sizeof(tag));
    return result;
}

cc_wifi_wire_result_t cc_wifi_make_session_nonce(
    const uint8_t device_nonce[CC_WIFI_SESSION_NONCE_SIZE],
    const uint8_t host_nonce[CC_WIFI_SESSION_NONCE_SIZE],
    uint8_t session_nonce[CC_WIFI_SESSION_NONCE_SIZE]) {
    if (device_nonce == NULL || host_nonce == NULL || session_nonce == NULL) {
        return CC_WIFI_WIRE_INVALID_ARGUMENT;
    }
    uint8_t material[sizeof(k_session_label) - 1 + CC_WIFI_SESSION_NONCE_SIZE * 2];
    memcpy(material, k_session_label, sizeof(k_session_label) - 1);
    memcpy(material + sizeof(k_session_label) - 1, device_nonce,
           CC_WIFI_SESSION_NONCE_SIZE);
    memcpy(material + sizeof(k_session_label) - 1 + CC_WIFI_SESSION_NONCE_SIZE,
           host_nonce, CC_WIFI_SESSION_NONCE_SIZE);
    return sha256(material, sizeof(material), session_nonce);
}

uint64_t cc_wifi_session_id_from_nonce(
    const uint8_t session_nonce[CC_WIFI_SESSION_NONCE_SIZE]) {
    return session_nonce == NULL ? 0 : read_u64(session_nonce);
}

void cc_wifi_make_nonce(uint64_t session_id, uint32_t sequence,
                        uint8_t nonce[CC_WIFI_NONCE_SIZE]) {
    write_u64(nonce, session_id);
    write_u32(nonce + 8, sequence);
}

cc_wifi_wire_result_t cc_wifi_encode_frame(
    const cc_wifi_frame_t *frame, const uint8_t key[CC_WIFI_KEY_SIZE],
    const uint8_t nonce[CC_WIFI_NONCE_SIZE], uint8_t *output,
    size_t output_capacity, size_t *output_len) {
    if (frame == NULL || key == NULL || nonce == NULL || output == NULL ||
        output_len == NULL || frame->payload == NULL ||
        frame->payload_len > CC_WIFI_MAX_PAYLOAD_SIZE ||
        (frame->kind != CC_WIFI_FRAME_CONTROL && frame->kind != CC_WIFI_FRAME_AUDIO) ||
        (frame->kind == CC_WIFI_FRAME_AUDIO &&
         frame->payload_len != CC_WIFI_AUDIO_PAYLOAD_SIZE)) {
        return CC_WIFI_WIRE_INVALID_ARGUMENT;
    }
    const size_t total_len = CC_WIFI_FRAME_HEADER_SIZE + frame->payload_len +
                             CC_WIFI_TAG_SIZE;
    if (output_capacity < total_len) return CC_WIFI_WIRE_INVALID_LENGTH;
    memcpy(output, k_magic, sizeof(k_magic));
    output[4] = CC_WIFI_WIRE_VERSION;
    output[5] = (uint8_t)frame->kind;
    output[6] = 0;
    output[7] = CC_WIFI_FRAME_HEADER_SIZE;
    write_u64(output + 8, frame->session_id);
    write_u32(output + 16, frame->sequence);
    write_u64(output + 20, frame->timestamp_ms);
    write_u16(output + 28, (uint16_t)frame->payload_len);
    memcpy(output + 30, nonce, CC_WIFI_NONCE_SIZE);
    cc_wifi_wire_result_t result = encrypt(
        key, nonce, output, CC_WIFI_FRAME_HEADER_SIZE, frame->payload,
        frame->payload_len, output + CC_WIFI_FRAME_HEADER_SIZE,
        output + CC_WIFI_FRAME_HEADER_SIZE + frame->payload_len);
    if (result != CC_WIFI_WIRE_OK) return result;
    *output_len = total_len;
    return CC_WIFI_WIRE_OK;
}

cc_wifi_wire_result_t cc_wifi_decode_frame(
    const uint8_t *packet, size_t packet_len,
    const uint8_t key[CC_WIFI_KEY_SIZE], cc_wifi_frame_t *frame,
    uint8_t *payload_buffer, size_t payload_capacity) {
    if (packet == NULL || key == NULL || frame == NULL || payload_buffer == NULL ||
        packet_len < CC_WIFI_FRAME_HEADER_SIZE + CC_WIFI_TAG_SIZE) {
        return CC_WIFI_WIRE_INVALID_ARGUMENT;
    }
    if (memcmp(packet, k_magic, sizeof(k_magic)) != 0) return CC_WIFI_WIRE_INVALID_FRAME;
    if (packet[4] != CC_WIFI_WIRE_VERSION) return CC_WIFI_WIRE_UNSUPPORTED_VERSION;
    if ((packet[5] != CC_WIFI_FRAME_CONTROL && packet[5] != CC_WIFI_FRAME_AUDIO) ||
        packet[6] != 0 || packet[7] != CC_WIFI_FRAME_HEADER_SIZE) {
        return CC_WIFI_WIRE_INVALID_KIND;
    }
    const size_t payload_len = read_u16(packet + 28);
    if (payload_len > CC_WIFI_MAX_PAYLOAD_SIZE || payload_len > payload_capacity ||
        packet_len != CC_WIFI_FRAME_HEADER_SIZE + payload_len + CC_WIFI_TAG_SIZE ||
        (packet[5] == CC_WIFI_FRAME_AUDIO &&
         payload_len != CC_WIFI_AUDIO_PAYLOAD_SIZE)) {
        return CC_WIFI_WIRE_INVALID_LENGTH;
    }
    cc_wifi_wire_result_t result = decrypt(
        key, packet + 30, packet, CC_WIFI_FRAME_HEADER_SIZE,
        packet + CC_WIFI_FRAME_HEADER_SIZE, payload_len,
        packet + CC_WIFI_FRAME_HEADER_SIZE + payload_len, payload_buffer);
    if (result != CC_WIFI_WIRE_OK) return result;
    frame->kind = (cc_wifi_frame_kind_t)packet[5];
    frame->session_id = read_u64(packet + 8);
    frame->sequence = read_u32(packet + 16);
    frame->timestamp_ms = read_u64(packet + 20);
    frame->payload = payload_buffer;
    frame->payload_len = payload_len;
    return CC_WIFI_WIRE_OK;
}

cc_wifi_wire_result_t cc_wifi_replay_accept(cc_wifi_replay_window_t *window,
                                             uint64_t session_id,
                                             uint32_t sequence) {
    if (window == NULL) return CC_WIFI_WIRE_INVALID_ARGUMENT;
    if (!window->initialized || window->session_id != session_id) {
        window->initialized = 1;
        window->session_id = session_id;
        window->highest_sequence = sequence;
        window->seen_mask = 1;
        return CC_WIFI_WIRE_OK;
    }
    if (sequence > window->highest_sequence) {
        const uint32_t shift = sequence - window->highest_sequence;
        window->seen_mask = shift >= 64 ? 1 : (window->seen_mask << shift) | 1;
        window->highest_sequence = sequence;
        return CC_WIFI_WIRE_OK;
    }
    const uint32_t distance = window->highest_sequence - sequence;
    if (distance >= 64 || (window->seen_mask & (UINT64_C(1) << distance)) != 0) {
        return CC_WIFI_WIRE_REPLAY;
    }
    window->seen_mask |= UINT64_C(1) << distance;
    return CC_WIFI_WIRE_OK;
}

void cc_wifi_replay_reset(cc_wifi_replay_window_t *window) {
    if (window != NULL) memset(window, 0, sizeof(*window));
}
