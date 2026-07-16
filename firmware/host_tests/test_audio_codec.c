#include "audio_codec.h"

#include <assert.h>
#include <stdio.h>

int main(void) {
    int16_t samples[CC_AUDIO_SAMPLES_PER_FRAME] = {0};
    uint8_t frame[CC_AUDIO_ENCODED_FRAME_SIZE];
    assert(cc_adpcm_encode_frame(0x1234, samples, frame, sizeof(frame)) ==
           CC_AUDIO_ENCODED_FRAME_SIZE);
    assert(frame[0] == 0x12 && frame[1] == 0x34);
    assert(frame[2] == 0 && frame[3] == 0 && frame[4] == 0 && frame[5] == 0);
    for (size_t i = 6; i < sizeof(frame); ++i) assert(frame[i] == 0);

    int16_t interleaved[] = {1000, -1000, 2000, 0, -3000, 1000};
    int16_t mono[3];
    cc_downmix_stereo(interleaved, mono, 3);
    assert(mono[0] == 0);
    assert(mono[1] == 1000);
    assert(mono[2] == -1000);
    puts("audio codec tests passed");
    return 0;
}
