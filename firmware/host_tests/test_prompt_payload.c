#include "prompt_payload.h"

#include <assert.h>
#include <stdio.h>
#include <string.h>

int main(void) {
    const uint8_t encoded[] = {
        0xA2, 0x00, 0x18, 0x4D, 0x01, 0x81, 0xA3, 0x00,
        0x61, 'x', 0x01, 0x62, 'O', 'K', 0x02, 0xF4,
    };
    cc_prompt_payload_t prompt;
    assert(cc_prompt_decode(encoded, sizeof(encoded), &prompt));
    assert(prompt.id == 77 && prompt.option_count == 1);
    assert(strcmp(prompt.options[0].identifier, "x") == 0);
    assert(strcmp(prompt.options[0].title, "OK") == 0);
    assert(!prompt.options[0].requires_long_press);

    uint8_t selection[16];
    size_t length = cc_prompt_encode_selection(77, 1, selection, sizeof(selection));
    const uint8_t expected[] = {0xA2, 0x00, 0x18, 0x4D, 0x01, 0x01};
    assert(length == sizeof(expected));
    assert(memcmp(selection, expected, sizeof(expected)) == 0);
    puts("prompt payload tests passed");
    return 0;
}
