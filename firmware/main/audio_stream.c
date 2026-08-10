#include "audio_stream.h"

#include <stdlib.h>

#include "audio_codec.h"
#include "bsp/esp-bsp.h"
#include "esp_codec_dev.h"
#include "esp_log.h"
#include "esp_timer.h"
#include "freertos/FreeRTOS.h"
#include "freertos/queue.h"
#include "freertos/semphr.h"
#include "freertos/task.h"

#define ES7210_RAW_CHANNELS 4

static const char *TAG = "cc_audio";
static esp_codec_dev_handle_t microphone;
static esp_codec_dev_handle_t speaker;
static cc_audio_send_fn audio_send;
static volatile bool active;
static volatile bool task_tones_enabled;
static volatile int64_t stop_at_us;
static volatile uint16_t audio_level;
static QueueHandle_t tone_queue;
// The microphone and speaker share one I2S data interface. esp_codec_dev
// serializes individual reads and writes, but speaker open/close also
// reconfigures that interface. Keep the whole codec operation atomic so a
// task-start tone cannot race the final microphone frame after PTT release.
static SemaphoreHandle_t codec_io_mutex;
static void tone_task(void *argument);

static void capture_task(void *argument) {
    (void)argument;
    int16_t raw[CC_AUDIO_SAMPLES_PER_FRAME * ES7210_RAW_CHANNELS];
    int16_t mono[CC_AUDIO_SAMPLES_PER_FRAME];
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
        // A wireless audio block is exactly 20 ms. Usually the codec read blocks
        // for that period, but it can return immediately after another audio
        // client reconfigures the shared I2S peripheral. Keep the transport
        // rate correct even in that failure mode, otherwise the notification
        // queue is flooded and the BLE link times out.
        const int64_t frame_started_us = esp_timer_get_time();
        if (xSemaphoreTake(codec_io_mutex, portMAX_DELAY) != pdTRUE) continue;
        // PTT may have been cancelled while this task waited for a tone or a
        // USB transfer to release the shared codec.
        if (!active) {
            xSemaphoreGive(codec_io_mutex);
            continue;
        }
        const int result = esp_codec_dev_read(microphone, raw, sizeof(raw));
        xSemaphoreGive(codec_io_mutex);
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
        if (audio_send) (void)audio_send(mono, CC_AUDIO_SAMPLES_PER_FRAME);
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
    tone_queue = xQueueCreate(8, sizeof(cc_task_event_t));
    configASSERT(tone_queue != NULL);
    codec_io_mutex = xSemaphoreCreateMutex();
    configASSERT(codec_io_mutex != NULL);
    // A capture cycle owns 3,366 bytes of fixed audio buffers before the
    // codec/I2S call frames are counted. 4 KiB leaves too little headroom and
    // can reboot exactly when PTT first activates capture.
    configASSERT(xTaskCreatePinnedToCore(capture_task, "cc_audio_capture", 8192,
                                        NULL, 8, NULL, 1) == pdPASS);
    // Speaker initialization descends through the codec, I2C and I2S layers.
    // Four KiB is marginal and can overflow only on the first task-event tone,
    // which presents as an intermittent reboot a few seconds after Submit.
    configASSERT(xTaskCreate(tone_task, "cc_audio_tones", 8192, NULL, 5,
                             NULL) == pdPASS);
}

void cc_audio_stream_start(void) {
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
    if (xSemaphoreTake(codec_io_mutex, portMAX_DELAY) != pdTRUE) return false;
    if (active) {
        xSemaphoreGive(codec_io_mutex);
        return false;
    }
    const int read_result = esp_codec_dev_read(microphone, raw, sizeof(raw));
    xSemaphoreGive(codec_io_mutex);
    if (read_result != ESP_OK) {
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

typedef struct {
    uint16_t frequency;
    uint16_t duration_ms;
} cc_tone_note_t;

// Keep some headroom for the small on-board speaker while making notification
// tones clearly audible at normal desk distance. The previous 0x07000000 / 42
// combination was intentionally cautious but proved too quiet on real hardware.
#define CC_TASK_TONE_AMPLITUDE 0x20000000
#define CC_TASK_TONE_VOLUME 82
#define CC_TASK_TONE_GAP_MS 25
#define CC_COMPLETION_AUDIO_SAMPLE_RATE 16000
#define CC_COMPLETION_AUDIO_CHUNK_FRAMES 320

extern const uint8_t task_complete_dog_pack_start[]
    asm("_binary_task_complete_dog_pack_pcm_start");
extern const uint8_t task_complete_dog_pack_end[]
    asm("_binary_task_complete_dog_pack_pcm_end");

static void write_square_note(uint16_t frequency, uint16_t duration_ms) {
    const size_t frames = (size_t)duration_ms * 16;
    int32_t *samples = calloc(frames * 2, sizeof(int32_t));
    if (!samples) return;
    uint32_t phase = 0;
    if (frequency != 0) {
        for (size_t i = 0; i < frames; ++i) {
            phase += frequency;
            // Deliberately quantized square wave: the short arpeggio should read
            // as an 8-bit UI sound, not as speech or a generic system beep.
            const int32_t value = ((phase / 8000) & 1)
                ? CC_TASK_TONE_AMPLITUDE
                : -CC_TASK_TONE_AMPLITUDE;
            samples[i * 2] = value;
            samples[i * 2 + 1] = value;
        }
    }
    (void)esp_codec_dev_write(speaker, samples, frames * 2 * sizeof(int32_t));
    free(samples);
}

static void write_completion_dog_bark(void) {
    const size_t byte_count = (size_t)(task_complete_dog_pack_end -
                                       task_complete_dog_pack_start);
    const size_t total_frames = byte_count / sizeof(int16_t);
    int32_t samples[CC_COMPLETION_AUDIO_CHUNK_FRAMES * 2];
    for (size_t offset = 0;
         offset < total_frames && !active && task_tones_enabled;
         offset += CC_COMPLETION_AUDIO_CHUNK_FRAMES) {
        const size_t frames = total_frames - offset < CC_COMPLETION_AUDIO_CHUNK_FRAMES
            ? total_frames - offset : CC_COMPLETION_AUDIO_CHUNK_FRAMES;
        for (size_t i = 0; i < frames; ++i) {
            const size_t byte_offset = (offset + i) * sizeof(int16_t);
            const uint16_t raw = (uint16_t)task_complete_dog_pack_start[byte_offset] |
                ((uint16_t)task_complete_dog_pack_start[byte_offset + 1] << 8);
            const int32_t value = (int32_t)(int16_t)raw << 14;
            samples[i * 2] = value;
            samples[i * 2 + 1] = value;
        }
        if (esp_codec_dev_write(speaker, samples,
                                frames * 2 * sizeof(int32_t)) != ESP_OK) {
            ESP_LOGW(TAG, "completion bark playback failed at frame %u",
                     (unsigned)offset);
            break;
        }
    }
}

static void play_task_event_tone_now(cc_task_event_t event) {
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
    esp_codec_dev_set_out_vol(speaker, CC_TASK_TONE_VOLUME);
    static const cc_tone_note_t started[] = {
        {523, 100}, {659, 120}, {784, 240},
    };
    if (event == CC_TASK_EVENT_COMPLETED) {
        write_completion_dog_bark();
    } else {
        const size_t note_count = sizeof(started) / sizeof(started[0]);
        for (size_t i = 0; i < note_count; ++i) {
            // PTT always wins over a lifecycle sound. The coarse codec mutex
            // keeps I2S reconfiguration safe; these checks bound any newly-
            // started voice session's wait to at most the current note.
            if (active || !task_tones_enabled) break;
            write_square_note(started[i].frequency, started[i].duration_ms);
            if (active || !task_tones_enabled) break;
            if (i + 1 < note_count) write_square_note(0, CC_TASK_TONE_GAP_MS);
        }
    }
    esp_codec_dev_close(speaker);
}

static void tone_task(void *argument) {
    (void)argument;
    cc_task_event_t event;
    while (true) {
        if (xQueueReceive(tone_queue, &event, portMAX_DELAY) != pdTRUE) continue;
        // Task-start commonly arrives during the microphone's 200 ms tail.
        // Wait for ownership to clear instead of silently losing the sound.
        for (int wait = 0; active && wait < 100; ++wait) {
            vTaskDelay(pdMS_TO_TICKS(20));
        }
        if (xSemaphoreTake(codec_io_mutex, portMAX_DELAY) != pdTRUE) continue;
        if (!active && task_tones_enabled) play_task_event_tone_now(event);
        xSemaphoreGive(codec_io_mutex);
        ESP_LOGI(TAG, "tone task stack high-water=%u",
                 (unsigned)uxTaskGetStackHighWaterMark(NULL));
    }
}

void cc_audio_play_task_event_tone(cc_task_event_t event) {
    if (!tone_queue || !task_tones_enabled) return;
    if (xQueueSend(tone_queue, &event, 0) == pdTRUE) return;
    cc_task_event_t discarded;
    (void)xQueueReceive(tone_queue, &discarded, 0);
    (void)xQueueSend(tone_queue, &event, 0);
}

void cc_audio_set_task_tones_enabled(bool enabled) {
    task_tones_enabled = enabled;
    if (enabled || !tone_queue) return;
    cc_task_event_t discarded;
    while (xQueueReceive(tone_queue, &discarded, 0) == pdTRUE) {
    }
}
