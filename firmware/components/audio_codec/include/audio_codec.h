#ifndef CODEX_COMPANION_AUDIO_CODEC_H
#define CODEX_COMPANION_AUDIO_CODEC_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define CC_AUDIO_SAMPLE_RATE 16000
#define CC_AUDIO_FRAME_MS 20
#define CC_AUDIO_SAMPLES_PER_FRAME 320
#define CC_AUDIO_ENCODED_FRAME_SIZE 166

size_t cc_adpcm_encode_frame(uint16_t sequence,
                             const int16_t samples[CC_AUDIO_SAMPLES_PER_FRAME],
                             uint8_t *output, size_t output_capacity);
void cc_downmix_stereo(const int16_t *interleaved, int16_t *mono,
                       size_t frame_count);

#ifdef __cplusplus
}
#endif

#endif
