#include "audio_codec.h"

#include <limits.h>

static const int8_t index_table[8] = {-1, -1, -1, -1, 2, 4, 6, 8};
static const int16_t step_table[89] = {
    7, 8, 9, 10, 11, 12, 13, 14, 16, 17, 19, 21, 23, 25, 28, 31,
    34, 37, 41, 45, 50, 55, 60, 66, 73, 80, 88, 97, 107, 118, 130,
    143, 157, 173, 190, 209, 230, 253, 279, 307, 337, 371, 408, 449,
    494, 544, 598, 658, 724, 796, 876, 963, 1060, 1166, 1282, 1411,
    1552, 1707, 1878, 2066, 2272, 2499, 2749, 3024, 3327, 3660, 4026,
    4428, 4871, 5358, 5894, 6484, 7132, 7845, 8630, 9493, 10442,
    11487, 12635, 13899, 15289, 16818, 18500, 20350, 22385, 24623,
    27086, 29794, 32767,
};

static uint8_t encode_nibble(int sample, int *predictor, int *step_index) {
    const int step = step_table[*step_index];
    int difference = sample - *predictor;
    uint8_t nibble = 0;
    if (difference < 0) {
        nibble = 8;
        difference = -difference;
    }
    int reconstructed = step >> 3;
    if (difference >= step) {
        nibble |= 4;
        difference -= step;
        reconstructed += step;
    }
    if (difference >= (step >> 1)) {
        nibble |= 2;
        difference -= step >> 1;
        reconstructed += step >> 1;
    }
    if (difference >= (step >> 2)) {
        nibble |= 1;
        reconstructed += step >> 2;
    }
    *predictor += (nibble & 8) ? -reconstructed : reconstructed;
    if (*predictor > INT16_MAX) *predictor = INT16_MAX;
    if (*predictor < INT16_MIN) *predictor = INT16_MIN;
    *step_index += index_table[nibble & 7];
    if (*step_index < 0) *step_index = 0;
    if (*step_index > 88) *step_index = 88;
    return nibble;
}

size_t cc_adpcm_encode_frame(uint16_t sequence,
                             const int16_t samples[CC_AUDIO_SAMPLES_PER_FRAME],
                             uint8_t *output, size_t output_capacity) {
    if (!samples || !output || output_capacity < CC_AUDIO_ENCODED_FRAME_SIZE) {
        return 0;
    }
    int predictor = samples[0];
    int step_index = 0;
    output[0] = (uint8_t)(sequence >> 8);
    output[1] = (uint8_t)sequence;
    output[2] = (uint8_t)((uint16_t)predictor >> 8);
    output[3] = (uint8_t)predictor;
    output[4] = (uint8_t)step_index;
    output[5] = 0;
    for (size_t i = 0; i < CC_AUDIO_SAMPLES_PER_FRAME; i += 2) {
        uint8_t low = encode_nibble(samples[i], &predictor, &step_index);
        uint8_t high = encode_nibble(samples[i + 1], &predictor, &step_index);
        output[6 + i / 2] = (uint8_t)(low | (uint8_t)(high << 4));
    }
    return CC_AUDIO_ENCODED_FRAME_SIZE;
}

void cc_downmix_stereo(const int16_t *interleaved, int16_t *mono,
                       size_t frame_count) {
    for (size_t i = 0; i < frame_count; ++i) {
        const int32_t sum = (int32_t)interleaved[i * 2] + interleaved[i * 2 + 1];
        mono[i] = (int16_t)(sum / 2);
    }
}
