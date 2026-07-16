#include "control_protocol.h"

#include <string.h>

#ifdef ESP_PLATFORM
#include "mbedtls/md.h"
#else
#include <CommonCrypto/CommonHMAC.h>
#endif

typedef struct {
    uint8_t *data;
    size_t capacity;
    size_t length;
} writer_t;

typedef struct {
    const uint8_t *data;
    size_t length;
    size_t offset;
} reader_t;

static cc_result_t append_byte(writer_t *writer, uint8_t value) {
    if (writer->length >= writer->capacity) return CC_ERR_BUFFER_TOO_SMALL;
    writer->data[writer->length++] = value;
    return CC_OK;
}

static cc_result_t append_raw(writer_t *writer, const uint8_t *value,
                              size_t length) {
    if (length > writer->capacity - writer->length) {
        return CC_ERR_BUFFER_TOO_SMALL;
    }
    memcpy(writer->data + writer->length, value, length);
    writer->length += length;
    return CC_OK;
}

static cc_result_t append_major(writer_t *writer, uint8_t major,
                                uint64_t value) {
    const uint8_t prefix = (uint8_t)(major << 5);
    if (value <= 23) return append_byte(writer, prefix | (uint8_t)value);
    uint8_t bytes[9];
    size_t count;
    if (value <= UINT8_MAX) {
        bytes[0] = prefix | 24;
        bytes[1] = (uint8_t)value;
        count = 2;
    } else if (value <= UINT16_MAX) {
        bytes[0] = prefix | 25;
        bytes[1] = (uint8_t)(value >> 8);
        bytes[2] = (uint8_t)value;
        count = 3;
    } else if (value <= UINT32_MAX) {
        bytes[0] = prefix | 26;
        for (size_t i = 0; i < 4; ++i) {
            bytes[1 + i] = (uint8_t)(value >> (24 - i * 8));
        }
        count = 5;
    } else {
        bytes[0] = prefix | 27;
        for (size_t i = 0; i < 8; ++i) {
            bytes[1 + i] = (uint8_t)(value >> (56 - i * 8));
        }
        count = 9;
    }
    return append_raw(writer, bytes, count);
}

static cc_result_t append_unsigned(writer_t *writer, uint64_t value) {
    return append_major(writer, 0, value);
}

static cc_result_t append_bytes(writer_t *writer, const uint8_t *value,
                                size_t length) {
    cc_result_t result = append_major(writer, 2, length);
    if (result != CC_OK) return result;
    return append_raw(writer, value, length);
}

static cc_result_t hmac_sha256(const uint8_t *key, size_t key_len,
                               const uint8_t *data, size_t data_len,
                               uint8_t output[32]) {
#ifdef ESP_PLATFORM
    const mbedtls_md_info_t *info =
        mbedtls_md_info_from_type(MBEDTLS_MD_SHA256);
    if (info == NULL ||
        mbedtls_md_hmac(info, key, key_len, data, data_len, output) != 0) {
        return CC_ERR_CRYPTO;
    }
#else
    CCHmac(kCCHmacAlgSHA256, key, key_len, data, data_len, output);
#endif
    return CC_OK;
}

static bool constant_time_equal(const uint8_t *left, const uint8_t *right,
                                size_t length) {
    uint8_t difference = 0;
    for (size_t i = 0; i < length; ++i) difference |= left[i] ^ right[i];
    return difference == 0;
}

static bool valid_message_type(uint64_t raw) {
    return raw >= CC_MSG_HELLO && raw <= CC_MSG_ERROR;
}

static cc_result_t read_byte(reader_t *reader, uint8_t *value) {
    if (reader->offset >= reader->length) return CC_ERR_INVALID_ENCODING;
    *value = reader->data[reader->offset++];
    return CC_OK;
}

static cc_result_t read_length(reader_t *reader, uint8_t additional,
                               uint64_t *value) {
    if (additional <= 23) {
        *value = additional;
        return CC_OK;
    }
    size_t count;
    if (additional == 24)
        count = 1;
    else if (additional == 25)
        count = 2;
    else if (additional == 26)
        count = 4;
    else if (additional == 27)
        count = 8;
    else
        return CC_ERR_INVALID_ENCODING;
    if (count > reader->length - reader->offset) return CC_ERR_INVALID_ENCODING;
    uint64_t decoded = 0;
    for (size_t i = 0; i < count; ++i) {
        decoded = (decoded << 8) | reader->data[reader->offset++];
    }
    *value = decoded;
    return CC_OK;
}

static cc_result_t read_unsigned(reader_t *reader, uint64_t *value) {
    uint8_t initial;
    cc_result_t result = read_byte(reader, &initial);
    if (result != CC_OK || (initial >> 5) != 0) {
        return CC_ERR_INVALID_ENCODING;
    }
    return read_length(reader, initial & 0x1f, value);
}

static cc_result_t expect_key(reader_t *reader, uint64_t expected) {
    uint64_t actual;
    cc_result_t result = read_unsigned(reader, &actual);
    if (result != CC_OK || actual != expected) return CC_ERR_INVALID_ENCODING;
    return CC_OK;
}

static cc_result_t read_bytes(reader_t *reader, const uint8_t **value,
                              size_t *length) {
    uint8_t initial;
    cc_result_t result = read_byte(reader, &initial);
    if (result != CC_OK || (initial >> 5) != 2) {
        return CC_ERR_INVALID_ENCODING;
    }
    uint64_t decoded_length;
    result = read_length(reader, initial & 0x1f, &decoded_length);
    if (result != CC_OK || decoded_length > SIZE_MAX ||
        decoded_length > reader->length - reader->offset) {
        return CC_ERR_INVALID_ENCODING;
    }
    *value = reader->data + reader->offset;
    *length = (size_t)decoded_length;
    reader->offset += *length;
    return CC_OK;
}

cc_result_t cc_encode_envelope(const cc_envelope_t *envelope,
                               const uint8_t *key, size_t key_len,
                               uint8_t *output, size_t output_capacity,
                               size_t *output_len) {
    if (envelope == NULL || key == NULL || key_len == 0 || output == NULL ||
        output_len == NULL ||
        (envelope->payload_len > 0 && envelope->payload == NULL)) {
        return CC_ERR_INVALID_ARGUMENT;
    }
    if (envelope->version != CC_PROTOCOL_VERSION) {
        return CC_ERR_UNSUPPORTED_VERSION;
    }
    if (!valid_message_type(envelope->message_type)) {
        return CC_ERR_UNKNOWN_MESSAGE_TYPE;
    }
    writer_t writer = {.data = output,
                       .capacity = output_capacity,
                       .length = 0};
#define APPEND(call)             \
    do {                         \
        cc_result_t r = (call);  \
        if (r != CC_OK) return r; \
    } while (0)
    APPEND(append_byte(&writer, 0xa5));
    APPEND(append_unsigned(&writer, 0));
    APPEND(append_unsigned(&writer, envelope->version));
    APPEND(append_unsigned(&writer, 1));
    APPEND(append_unsigned(&writer, envelope->sequence));
    APPEND(append_unsigned(&writer, 2));
    APPEND(append_unsigned(&writer, envelope->message_type));
    APPEND(append_unsigned(&writer, 3));
    APPEND(append_unsigned(&writer, envelope->timestamp_ms));
    APPEND(append_unsigned(&writer, 4));
    APPEND(append_bytes(&writer, envelope->payload, envelope->payload_len));

    uint8_t tag[32];
    cc_result_t crypto =
        hmac_sha256(key, key_len, writer.data, writer.length, tag);
    if (crypto != CC_OK) return crypto;
    writer.data[0] = 0xa6;
    APPEND(append_unsigned(&writer, 5));
    APPEND(append_bytes(&writer, tag, CC_HMAC_TAG_SIZE));
#undef APPEND
    *output_len = writer.length;
    return CC_OK;
}

cc_result_t cc_decode_envelope(const uint8_t *data, size_t data_len,
                               const uint8_t *key, size_t key_len,
                               cc_envelope_t *envelope,
                               uint8_t *payload_buffer,
                               size_t payload_capacity) {
    if (data == NULL || key == NULL || key_len == 0 || envelope == NULL ||
        payload_buffer == NULL || data_len > CC_MAX_CONTROL_PACKET) {
        return CC_ERR_INVALID_ARGUMENT;
    }
    reader_t reader = {.data = data, .length = data_len, .offset = 0};
    uint8_t map;
    if (read_byte(&reader, &map) != CC_OK || map != 0xa6) {
        return CC_ERR_INVALID_ENCODING;
    }
    uint64_t version, sequence, message_type, timestamp;
#define READ_UINT(key_number, target)                                      \
    do {                                                                   \
        if (expect_key(&reader, (key_number)) != CC_OK ||                  \
            read_unsigned(&reader, &(target)) != CC_OK)                    \
            return CC_ERR_INVALID_ENCODING;                               \
    } while (0)
    READ_UINT(0, version);
    READ_UINT(1, sequence);
    READ_UINT(2, message_type);
    READ_UINT(3, timestamp);
#undef READ_UINT
    if (expect_key(&reader, 4) != CC_OK) return CC_ERR_INVALID_ENCODING;
    const uint8_t *payload;
    size_t payload_len;
    if (read_bytes(&reader, &payload, &payload_len) != CC_OK ||
        payload_len > payload_capacity) {
        return CC_ERR_BUFFER_TOO_SMALL;
    }
    const size_t unsigned_length = reader.offset;
    if (expect_key(&reader, 5) != CC_OK) return CC_ERR_INVALID_ENCODING;
    const uint8_t *supplied_tag;
    size_t tag_len;
    if (read_bytes(&reader, &supplied_tag, &tag_len) != CC_OK ||
        tag_len != CC_HMAC_TAG_SIZE || reader.offset != data_len) {
        return CC_ERR_INVALID_ENCODING;
    }
    uint8_t unsigned_data[CC_MAX_CONTROL_PACKET];
    memcpy(unsigned_data, data, unsigned_length);
    unsigned_data[0] = 0xa5;
    uint8_t expected_tag[32];
    cc_result_t crypto = hmac_sha256(key, key_len, unsigned_data,
                                     unsigned_length, expected_tag);
    if (crypto != CC_OK) return crypto;
    if (!constant_time_equal(supplied_tag, expected_tag, CC_HMAC_TAG_SIZE)) {
        return CC_ERR_AUTHENTICATION;
    }
    if (version != CC_PROTOCOL_VERSION) return CC_ERR_UNSUPPORTED_VERSION;
    if (sequence > UINT32_MAX || !valid_message_type(message_type)) {
        return CC_ERR_UNKNOWN_MESSAGE_TYPE;
    }
    memcpy(payload_buffer, payload, payload_len);
    envelope->version = (uint8_t)version;
    envelope->sequence = (uint32_t)sequence;
    envelope->message_type = (cc_message_type_t)message_type;
    envelope->timestamp_ms = timestamp;
    envelope->payload = payload_buffer;
    envelope->payload_len = payload_len;
    return CC_OK;
}

cc_result_t cc_sequence_guard_accept(cc_sequence_guard_t *guard,
                                     uint32_t sequence) {
    if (guard == NULL) return CC_ERR_INVALID_ARGUMENT;
    if (guard->initialized && sequence <= guard->last_accepted) {
        return CC_ERR_REPLAY;
    }
    guard->initialized = true;
    guard->last_accepted = sequence;
    return CC_OK;
}

void cc_sequence_guard_reset(cc_sequence_guard_t *guard) {
    if (guard == NULL) return;
    guard->initialized = false;
    guard->last_accepted = 0;
}
