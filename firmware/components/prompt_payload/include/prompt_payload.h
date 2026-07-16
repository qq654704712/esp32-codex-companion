#ifndef CODEX_COMPANION_PROMPT_PAYLOAD_H
#define CODEX_COMPANION_PROMPT_PAYLOAD_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define CC_PROMPT_MAX_OPTIONS 8
#define CC_PROMPT_IDENTIFIER_CAPACITY 65
#define CC_PROMPT_TITLE_CAPACITY 81

typedef struct {
    char identifier[CC_PROMPT_IDENTIFIER_CAPACITY];
    char title[CC_PROMPT_TITLE_CAPACITY];
    bool requires_long_press;
} cc_prompt_option_t;

typedef struct {
    uint32_t id;
    uint8_t option_count;
    cc_prompt_option_t options[CC_PROMPT_MAX_OPTIONS];
} cc_prompt_payload_t;

bool cc_prompt_decode(const uint8_t *data, size_t length,
                      cc_prompt_payload_t *prompt);
size_t cc_prompt_encode_selection(uint32_t prompt_id, uint8_t option_index,
                                  uint8_t *output, size_t capacity);

#ifdef __cplusplus
}
#endif

#endif
