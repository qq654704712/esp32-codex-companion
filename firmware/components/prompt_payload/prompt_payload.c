#include "prompt_payload.h"

#include <string.h>

typedef struct {
    const uint8_t *data;
    size_t length;
    size_t offset;
} reader_t;

static bool read_byte(reader_t *reader, uint8_t *value) {
    if (reader->offset >= reader->length) return false;
    *value = reader->data[reader->offset++];
    return true;
}

static bool read_major(reader_t *reader, uint8_t expected_major,
                       uint64_t *value) {
    uint8_t initial;
    if (!read_byte(reader, &initial) || initial >> 5 != expected_major) return false;
    const uint8_t additional = initial & 0x1F;
    if (additional <= 23) {
        *value = additional;
        return true;
    }
    size_t count = additional == 24 ? 1 : additional == 25 ? 2 :
                   additional == 26 ? 4 : 0;
    if (count == 0 || count > reader->length - reader->offset) return false;
    *value = 0;
    for (size_t i = 0; i < count; ++i) {
        *value = (*value << 8) | reader->data[reader->offset++];
    }
    return true;
}

static bool read_uint(reader_t *reader, uint64_t *value) {
    return read_major(reader, 0, value);
}

static bool read_text(reader_t *reader, char *output, size_t capacity) {
    uint64_t count;
    if (!read_major(reader, 3, &count) || count >= capacity ||
        count > reader->length - reader->offset) return false;
    memcpy(output, reader->data + reader->offset, (size_t)count);
    output[count] = '\0';
    reader->offset += (size_t)count;
    return true;
}

bool cc_prompt_decode(const uint8_t *data, size_t length,
                      cc_prompt_payload_t *prompt) {
    if (!data || !prompt) return false;
    memset(prompt, 0, sizeof(*prompt));
    reader_t reader = {.data = data, .length = length};
    uint64_t value;
    if (!read_major(&reader, 5, &value) || value != 2 ||
        !read_uint(&reader, &value) || value != 0 ||
        !read_uint(&reader, &value) || value > UINT32_MAX) return false;
    prompt->id = (uint32_t)value;
    if (!read_uint(&reader, &value) || value != 1 ||
        !read_major(&reader, 4, &value) || value == 0 ||
        value > CC_PROMPT_MAX_OPTIONS) return false;
    prompt->option_count = (uint8_t)value;
    for (uint8_t i = 0; i < prompt->option_count; ++i) {
        if (!read_major(&reader, 5, &value) || value != 3 ||
            !read_uint(&reader, &value) || value != 0 ||
            !read_text(&reader, prompt->options[i].identifier,
                       sizeof(prompt->options[i].identifier)) ||
            !read_uint(&reader, &value) || value != 1 ||
            !read_text(&reader, prompt->options[i].title,
                       sizeof(prompt->options[i].title)) ||
            !read_uint(&reader, &value) || value != 2) return false;
        uint8_t boolean;
        if (!read_byte(&reader, &boolean) || (boolean != 0xF4 && boolean != 0xF5)) {
            return false;
        }
        prompt->options[i].requires_long_press = boolean == 0xF5;
    }
    return reader.offset == reader.length;
}

static size_t append_uint(uint32_t value, uint8_t *output, size_t capacity) {
    if (value <= 23 && capacity >= 1) {
        output[0] = (uint8_t)value;
        return 1;
    }
    if (value <= UINT8_MAX && capacity >= 2) {
        output[0] = 0x18;
        output[1] = (uint8_t)value;
        return 2;
    }
    if (value <= UINT16_MAX && capacity >= 3) {
        output[0] = 0x19;
        output[1] = (uint8_t)(value >> 8);
        output[2] = (uint8_t)value;
        return 3;
    }
    if (capacity >= 5) {
        output[0] = 0x1A;
        for (size_t i = 0; i < 4; ++i) output[1 + i] = (uint8_t)(value >> (24 - i * 8));
        return 5;
    }
    return 0;
}

size_t cc_prompt_encode_selection(uint32_t prompt_id, uint8_t option_index,
                                  uint8_t *output, size_t capacity) {
    if (!output || capacity < 6) return 0;
    size_t offset = 0;
    output[offset++] = 0xA2;
    output[offset++] = 0x00;
    const size_t id_length = append_uint(prompt_id, output + offset, capacity - offset);
    if (id_length == 0) return 0;
    offset += id_length;
    if (capacity - offset < 2) return 0;
    output[offset++] = 0x01;
    const size_t option_length = append_uint(option_index, output + offset, capacity - offset);
    if (option_length == 0) return 0;
    return offset + option_length;
}
