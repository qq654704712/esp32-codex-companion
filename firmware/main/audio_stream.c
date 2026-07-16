#include "audio_stream.h"

#include <stdlib.h>

#include "audio_codec.h"
#include "bsp/esp-bsp.h"
#include "esp_codec_dev.h"
#include "esp_log.h"
#include "esp_timer.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"

#define ES7210_RAW_CHANNELS 4

static const char *TAG = "cc_audio";
static esp_codec_dev_handle_t microphone;
static esp_codec_dev_handle_t speaker;
static cc_audio_send_fn audio_send;
static volatile bool active;
static volatile int64_t stop_at_us;
static volatile uint16_t audio_level;
static uint16_t sequence;

static void capture_task(void *argument) {
    (void)argument;
    int16_t raw[CC_AUDIO_SAMPLES_PER_FRAME * ES7210_RAW_CHANNELS];
    int16_t mono[CC_AUDIO_SAMPLES_PER_FRAME];
    uint8_t encoded[CC_AUDIO_ENCODED_FRAME_SIZE];
    while (true) {
        if (!active) {
            vTaskDelay(pdMS_TO_TICKS(10));
            continue;
        }
        if (stop_at_us != 0 && esp_timer_get_time() >= stop_at_us) {
            active = false;
            stop_at_us = 0;
            audio_level = 0;
            continue;
        }
        // A BLE audio block is exactly 20 ms. Usually the codec read blocks
        // for that period, but it can return immediately after another audio
        // client reconfigures the shared I2S peripheral. Keep the transport
        // rate correct even in that failure mode, otherwise the notification
        // queue is flooded and the BLE link times out.
        const int64_t frame_started_us = esp_timer_get_time();
        const int result = esp_codec_dev_read(microphone, raw, sizeof(raw));
        if (result != ESP_OK) {
            ESP_LOGW(TAG, "microphone read failed: %d", result);
            vTaskDelay(pdMS_TO_TICKS(5));
            continue;
        }
        uint64_t energy = 0;
        for (size_t i = 0; i < CC_AUDIO_SAMPLES_PER_FRAME; ++i) {
            // Official Waveshare wake-word example identifies raw slots 1 and 3
            // as the two microphone channels in the ES7210 RMNM layout.
            const int32_t sum = (int32_t)raw[i * 4 + 1] + raw[i * 4 + 3];
            mono[i] = (int16_t)(sum / 2);
            energy += (uint32_t)abs(mono[i]);
        }
        const uint32_t mean = (uint32_t)(energy / CC_AUDIO_SAMPLES_PER_FRAME);
        // Raw microphone amplitude is far below the signed 16-bit ceiling in
        // normal speech. A noise gate plus a short-range visual scale keeps
        // silence calm while making ordinary speech legible on a 360 px display.
        const uint16_t target_level = mean <= 24 ? 0 :
            (uint16_t)((mean - 24) >= 900 ? 1000 : (mean - 24) * 1000 / 900);
        audio_level = (uint16_t)((audio_level * 2 + target_level) / 3);
        if (cc_adpcm_encode_frame(sequence++, mono, encoded, sizeof(encoded)) != 0 &&
            audio_send) {
            audio_send(encoded, sizeof(encoded));
        }
        const int64_t frame_elapsed_us = esp_timer_get_time() - frame_started_us;
        const int64_t frame_budget_us = (int64_t)CC_AUDIO_FRAME_MS * 1000;
        if (frame_elapsed_us < frame_budget_us) {
            const uint32_t sleep_ms = (uint32_t)((frame_budget_us - frame_elapsed_us + 999) / 1000);
            vTaskDelay(pdMS_TO_TICKS(sleep_ms));
        }
    }
}

void cc_audio_stream_init(cc_audio_send_fn send_fn) {
    audio_send = send_fn;
    microphone = bsp_audio_codec_microphone_init();
    configASSERT(microphone != NULL);
    esp_codec_dev_sample_info_t input_format = {
        .sample_rate = CC_AUDIO_SAMPLE_RATE,
        .channel = 2,
        .bits_per_sample = 32,
    };
    ESP_ERROR_CHECK(esp_codec_dev_set_in_gain(microphone, 30.0));
    ESP_ERROR_CHECK(esp_codec_dev_open(microphone, &input_format));
    // A capture cycle owns 3,366 bytes of fixed audio buffers before the
    // codec/I2S call frames are counted. 4 KiB leaves too little headroom and
    // can reboot exactly when PTT first activates capture.
    xTaskCreatePinnedToCore(capture_task, "cc_audio_capture", 8192, NULL, 8,
                            NULL, 1);
}

void cc_audio_stream_start(void) {
    sequence = 0;
    stop_at_us = 0;
    active = true;
}

void cc_audio_stream_stop(uint32_t post_roll_ms) {
    if (active) stop_at_us = esp_timer_get_time() + (int64_t)post_roll_ms * 1000;
}

void cc_audio_stream_cancel(void) {
    active = false;
    stop_at_us = 0;
    audio_level = 0;
}

bool cc_audio_stream_is_active(void) { return active; }
uint16_t cc_audio_stream_level(void) { return audio_level; }

bool cc_audio_stream_read_usb_pcm16(uint8_t *output, size_t length) {
    // The UAC configuration deliberately requests 20 ms of 16 kHz PCM16:
    // 320 mono samples (640 bytes). Rejecting every other size prevents a
    // descriptor/config mismatch from overrunning a fixed I2S frame buffer.
    if (!output || length != CC_AUDIO_SAMPLES_PER_FRAME * sizeof(int16_t) ||
        !microphone || active) {
        return false;
    }
    int16_t raw[CC_AUDIO_SAMPLES_PER_FRAME * ES7210_RAW_CHANNELS];
    int16_t *mono = (int16_t *)output;
    if (esp_codec_dev_read(microphone, raw, sizeof(raw)) != ESP_OK) {
        return false;
    }
    uint64_t energy = 0;
    for (size_t i = 0; i < CC_AUDIO_SAMPLES_PER_FRAME; ++i) {
        // Match the documented ES7210 RMNM slots used by BLE capture.
        const int32_t sum = (int32_t)raw[i * 4 + 1] + raw[i * 4 + 3];
        mono[i] = (int16_t)(sum / 2);
        energy += (uint32_t)abs(mono[i]);
    }
    const uint32_t mean = (uint32_t)(energy / CC_AUDIO_SAMPLES_PER_FRAME);
    const uint16_t target_level = mean <= 24 ? 0 :
        (uint16_t)((mean - 24) >= 900 ? 1000 : (mean - 24) * 1000 / 900);
    audio_level = (uint16_t)((audio_level * 2 + target_level) / 3);
    return true;
}

void cc_audio_play_state_tone(cc_device_state_t state) {
    if (active) return;
    if (!speaker) {
        speaker = bsp_audio_codec_speaker_init();
        if (!speaker) return;
    }
    esp_codec_dev_sample_info_t format = {
        .sample_rate = 16000,
        .channel = 2,
        .bits_per_sample = 32,
    };
    if (esp_codec_dev_open(speaker, &format) != ESP_OK) return;
    esp_codec_dev_set_out_vol(speaker, 45);
    const uint32_t frequency = 360 + (uint32_t)state * 73;
    const size_t frames = 960;
    int32_t *samples = calloc(frames * 2, sizeof(int32_t));
    if (samples) {
        uint32_t phase = 0;
        for (size_t i = 0; i < frames; ++i) {
            phase += frequency;
            const int32_t value = ((phase / 8000) & 1) ? 0x09000000 : -0x09000000;
            samples[i * 2] = value;
            samples[i * 2 + 1] = value;
        }
        esp_codec_dev_write(speaker, samples, frames * 2 * sizeof(int32_t));
        free(samples);
    }
    esp_codec_dev_close(speaker);
}
