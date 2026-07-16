#include <stdbool.h>
#include <stdio.h>
#include <stdint.h>
#include <string.h>

#include "audio_stream.h"
#include "ble_transport.h"
#include "control_protocol.h"
#include "device_model.h"
#include "device_ui.h"
#include "driver/gpio.h"
#include "esp_log.h"
#include "esp_system.h"
#include "esp_timer.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "freertos/queue.h"
#include "nvs_flash.h"
#include "prompt_payload.h"
#include "usb_audio_mode.h"
#include "usb_control.h"
#include "usb_hid_ptt.h"
#include "wifi_manager.h"
#include "wifi_transport.h"

#define BOOT_BUTTON_GPIO GPIO_NUM_0
#define HEARTBEAT_TIMEOUT_MS 6000
// Pixel animation has twelve frames per second; redrawing at 30fps only
// repeatedly invalidates the same LCD regions and can starve the SPI DMA heap.
// Listening is intentionally faster so the local waveform still feels live.
#define UI_RENDER_IDLE_PERIOD_MS 83
#define UI_RENDER_LISTENING_PERIOD_MS 40

static cc_device_model_t model;
static cc_sequence_guard_t inbound_sequences;
static uint32_t outbound_sequence;
static uint64_t last_heartbeat_ms;
static QueueHandle_t control_queue;
static QueueHandle_t wifi_setup_result_queue;
static const char *TAG = "cc_app";
static bool usb_uac_mode;

typedef struct {
    cc_message_type_t type;
    size_t payload_length;
    uint8_t payload[448];
} control_event_t;

static uint64_t now_ms(void) { return (uint64_t)(esp_timer_get_time() / 1000); }

static bool read_cbor_uint(const uint8_t **cursor, const uint8_t *end,
                           uint64_t *value) {
    if (*cursor >= end) return false;
    const uint8_t initial = *(*cursor)++;
    if ((initial >> 5) != 0) return false;
    const uint8_t additional = initial & 0x1F;
    if (additional <= 23) {
        *value = additional;
        return true;
    }
    size_t count = additional == 24 ? 1 : additional == 25 ? 2 : 0;
    if (count == 0 || (size_t)(end - *cursor) < count) return false;
    *value = 0;
    for (size_t i = 0; i < count; ++i) *value = (*value << 8) | *(*cursor)++;
    return true;
}

static void send_control_payload(cc_message_type_t type, const uint8_t *payload,
                                 size_t payload_length) {
    uint8_t key[32];
    if (!cc_ble_copy_hmac_key(key)) return;
    cc_envelope_t envelope = {
        .version = CC_PROTOCOL_VERSION,
        .sequence = ++outbound_sequence,
        .message_type = type,
        .timestamp_ms = now_ms(),
        .payload = payload,
        .payload_len = payload_length,
    };
    uint8_t encoded[96];
    size_t encoded_length = 0;
    if (cc_encode_envelope(&envelope, key, sizeof(key), encoded,
                           sizeof(encoded), &encoded_length) == CC_OK) {
        // The v1 envelope keeps one device-wide sequence. Mirroring the exact
        // bytes to BLE and Wi-Fi lets either transport recover without creating
        // a second authority or a duplicate approval action.
        (void)cc_ble_notify_control(encoded, encoded_length);
        (void)cc_wifi_transport_send_control(encoded, encoded_length);
    }
}

static void send_control_event(cc_message_type_t type) {
    const uint8_t empty_map[] = {0xA0};
    send_control_payload(type, empty_map, sizeof(empty_map));
}

static bool parse_state_payload(const uint8_t *payload, size_t length,
                                cc_device_state_t *state) {
    if (length < 3 || payload[0] != 0xA1 || payload[1] != 0x00) return false;
    const uint8_t *cursor = payload + 2;
    uint64_t value;
    if (!read_cbor_uint(&cursor, payload + length, &value) ||
        cursor != payload + length || value > CC_STATE_RUNNING ||
        value == CC_STATE_LISTENING) return false;
    *state = (cc_device_state_t)value;
    return true;
}

static bool parse_quota_payload(const uint8_t *payload, size_t length,
                                uint8_t *five_hour, uint8_t *week) {
    if (length < 7 || payload[0] != 0xA2) return false;
    const uint8_t *cursor = payload + 1;
    const uint8_t *end = payload + length;
    uint64_t key0, value0, key1, value1;
    if (!read_cbor_uint(&cursor, end, &key0) || key0 != 0 ||
        !read_cbor_uint(&cursor, end, &value0) ||
        !read_cbor_uint(&cursor, end, &key1) || key1 != 1 ||
        !read_cbor_uint(&cursor, end, &value1) || cursor != end ||
        value0 > 255 || value1 > 255) return false;
    *five_hour = (uint8_t)value0;
    *week = (uint8_t)value1;
    return true;
}

static bool parse_heartbeat_payload(const uint8_t *payload, size_t length,
                                    bool *quota_fresh) {
    if (length != 3 || payload[0] != 0xA1 || payload[1] != 0x00 ||
        (payload[2] != 0xF4 && payload[2] != 0xF5)) return false;
    *quota_fresh = payload[2] == 0xF5;
    return true;
}

static void handle_control(const uint8_t *data, size_t length) {
    uint8_t key[32];
    if (!cc_ble_copy_hmac_key(key)) return;
    uint8_t payload[448];
    cc_envelope_t envelope = {0};
    if (cc_decode_envelope(data, length, key, sizeof(key), &envelope,
                           payload, sizeof(payload)) != CC_OK ||
        cc_sequence_guard_accept(&inbound_sequences, envelope.sequence) != CC_OK) {
        return;
    }
    control_event_t event = {
        .type = envelope.message_type,
        .payload_length = envelope.payload_len,
    };
    if (event.payload_length > sizeof(event.payload)) return;
    memcpy(event.payload, envelope.payload, event.payload_length);
    xQueueSend(control_queue, &event, 0);
}

static void process_control_event(const control_event_t *event) {
    last_heartbeat_ms = now_ms();
    if (!model.connected) cc_device_set_connected(&model, true, last_heartbeat_ms);
    if (event->type == CC_MSG_HEARTBEAT) {
        bool quota_fresh = false;
        if (parse_heartbeat_payload(event->payload, event->payload_length,
                                    &quota_fresh) && quota_fresh) {
            cc_device_mark_quota_fresh(&model, last_heartbeat_ms);
        }
        send_control_event(CC_MSG_ACK);
    } else if (event->type == CC_MSG_STATE_UPDATE) {
        cc_device_state_t state;
        if (parse_state_payload(event->payload, event->payload_length, &state)) {
            // A duplicate state update used to replay the tone every time.
            // Speaker playback reconfigures the ES7210 shared-I2S path, so a
            // rapid duplicate stream starved microphone capture and tore down
            // the BLE session during push-to-talk.
            if (cc_device_set_remote_state(&model, state)) {
                ESP_LOGI(TAG, "remote state changed: %d", state);
                cc_audio_play_state_tone(state);
            }
        }
    } else if (event->type == CC_MSG_QUOTA_UPDATE) {
        uint8_t five_hour, week;
        if (parse_quota_payload(event->payload, event->payload_length,
                                &five_hour, &week)) {
            cc_device_update_quota(&model, five_hour <= 100, five_hour,
                                   week <= 100, week, now_ms());
        }
    } else if (event->type == CC_MSG_PROMPT_CLOSE) {
        cc_device_ui_close_prompt();
    }
}

static void prompt_selected(uint32_t prompt_id, uint8_t option_index,
                            bool long_press) {
    uint8_t payload[16];
    const size_t length = cc_prompt_encode_selection(
        prompt_id, option_index, payload, sizeof(payload));
    if (length != 0) {
        send_control_payload(long_press ? CC_MSG_LONG_PRESS_CONFIRM :
                                         CC_MSG_OPTION_SELECT,
                             payload, length);
    }
}

static void initialize_button(void) {
    const gpio_config_t config = {
        .pin_bit_mask = 1ULL << BOOT_BUTTON_GPIO,
        .mode = GPIO_MODE_INPUT,
        .pull_up_en = GPIO_PULLUP_ENABLE,
        .pull_down_en = GPIO_PULLDOWN_DISABLE,
        .intr_type = GPIO_INTR_DISABLE,
    };
    ESP_ERROR_CHECK(gpio_config(&config));
}

static void select_usb_uac_mode(bool enable_uac_mode) {
    if (!cc_usb_mode_store(enable_uac_mode ? CC_USB_MODE_UAC_MIC :
                                             CC_USB_MODE_NORMAL)) {
        ESP_LOGE(TAG, "failed to persist USB mode request");
        return;
    }
    ESP_LOGI(TAG, "USB mode changed; restarting into %s",
             enable_uac_mode ? "UAC microphone" : "normal mode");
    // USB descriptors are selected at boot. Restarting rather than attempting
    // a live controller swap avoids corrupting USB Serial/JTAG or TinyUSB.
    esp_restart();
}

static volatile bool wifi_setup_pending;

static void wifi_setup_task(void *context) {
    (void)context;
    const bool started = cc_wifi_begin_provisioning();
    if (!started) {
        ESP_LOGE(TAG, "failed to start Wi-Fi setup portal");
    }
    // LVGL objects are owned by the display task. Report the outcome through
    // a queue so the app loop, not this Wi-Fi worker, updates the screen.
    (void)xQueueOverwrite(wifi_setup_result_queue, &started);
    wifi_setup_pending = false;
    vTaskDelete(NULL);
}

static void begin_wifi_setup(void) {
    if (wifi_setup_pending) return;
    wifi_setup_pending = true;
    cc_device_ui_set_wifi_status("网络：正在启动热点");
    if (xTaskCreate(wifi_setup_task, "cc_wifi_setup", 6144, NULL, 5, NULL) != pdPASS) {
        wifi_setup_pending = false;
        ESP_LOGE(TAG, "failed to schedule Wi-Fi setup portal");
        cc_device_ui_set_wifi_status("网络：启动失败");
    }
}

static void reset_ble_pairing(void) {
    if (!cc_ble_clear_pairing()) {
        ESP_LOGE(TAG, "BLE pairing reset did not fully clear persistent state");
    }
}

static void handle_usb_control_line(const char *line) {
    // USB is a physical, locally-attached transport. Its tiny sideband avoids
    // the radio pairing stack. It intentionally accepts only heartbeat and
    // state lines from the Mac; BOOT edges travel in the other direction.
    const uint64_t time = now_ms();
    if (strcmp(line, "H:1") == 0) {
        cc_device_set_connected(&model, true, time);
        last_heartbeat_ms = time;
        return;
    }
    if (strncmp(line, "S:", 2) != 0 || line[3] != '\0') return;
    uint8_t value;
    if (line[2] >= '0' && line[2] <= '9') {
        value = (uint8_t)(line[2] - '0');
    } else if (line[2] >= 'A' && line[2] <= 'C') {
        value = (uint8_t)(10 + line[2] - 'A');
    } else {
        return;
    }
    if (value > CC_STATE_RUNNING) return;
    const cc_device_state_t state = (cc_device_state_t)value;
    cc_device_set_connected(&model, true, time);
    last_heartbeat_ms = time;
    if (cc_device_set_remote_state(&model, state) && state != CC_STATE_LISTENING) {
        cc_audio_play_state_tone(state);
    }
}

void app_main(void) {
    esp_err_t result = nvs_flash_init();
    if (result == ESP_ERR_NVS_NO_FREE_PAGES ||
        result == ESP_ERR_NVS_NEW_VERSION_FOUND) {
        ESP_ERROR_CHECK(nvs_flash_erase());
        result = nvs_flash_init();
    }
    ESP_ERROR_CHECK(result);

    cc_device_model_init(&model);
    usb_uac_mode = cc_usb_mode_load() == CC_USB_MODE_UAC_MIC;
    control_queue = xQueueCreate(8, sizeof(control_event_t));
    configASSERT(control_queue != NULL);
    wifi_setup_result_queue = xQueueCreate(1, sizeof(bool));
    configASSERT(wifi_setup_result_queue != NULL);
    initialize_button();
    cc_device_ui_start();
    cc_device_ui_set_usb_uac_mode(usb_uac_mode, select_usb_uac_mode);
    cc_device_ui_set_wifi_setup(begin_wifi_setup);
    cc_device_ui_set_pairing_reset(reset_ble_pairing);
    (void)cc_wifi_start();
    cc_device_ui_set_wifi_status(cc_wifi_portal_hint());
    cc_ble_start(handle_control);
    cc_wifi_transport_start(handle_control);
    cc_audio_stream_init(cc_ble_notify_audio);
    if (usb_uac_mode && !cc_usb_uac_start()) {
        // Continue BLE control/UI so the user can tap Link → USB Mic and
        // switch back to normal mode even if USB enumeration failed.
        ESP_LOGE(TAG, "USB UAC unavailable; use Connection Center to exit mode");
    }
    if (usb_uac_mode) cc_usb_control_start(handle_usb_control_line);

    bool previous_link_connected = false;
    char last_wifi_hint[96] = {0};
    uint64_t last_render_ms = 0;
    while (true) {
        const uint64_t time = now_ms();
        if (usb_uac_mode) {
            cc_usb_control_poll();
            cc_usb_hid_ptt_poll();
        }
        bool wifi_setup_started;
        if (xQueueReceive(wifi_setup_result_queue, &wifi_setup_started, 0) == pdTRUE) {
            cc_device_ui_set_wifi_status(wifi_setup_started ? cc_wifi_portal_hint()
                                                            : "网络：启动失败");
        }
        const char *wifi_hint = cc_wifi_portal_hint();
        if (strncmp(last_wifi_hint, wifi_hint, sizeof(last_wifi_hint) - 1) != 0) {
            snprintf(last_wifi_hint, sizeof(last_wifi_hint), "%s", wifi_hint);
            cc_device_ui_set_wifi_status(last_wifi_hint);
        }
        const bool link_connected = (usb_uac_mode && cc_usb_control_is_connected()) ||
                                    cc_ble_is_connected() ||
                                    cc_wifi_transport_is_connected();
        if (link_connected != previous_link_connected) {
            cc_device_set_connected(&model, link_connected, time);
            previous_link_connected = link_connected;
            cc_sequence_guard_reset(&inbound_sequences);
            if (link_connected) {
                last_heartbeat_ms = time;
            } else {
                cc_audio_stream_cancel();
            }
        }
        if (link_connected && last_heartbeat_ms != 0 &&
            time - last_heartbeat_ms > HEARTBEAT_TIMEOUT_MS) {
            cc_device_set_connected(&model, false, time);
            cc_audio_stream_cancel();
        }

        const bool button_down = gpio_get_level(BOOT_BUTTON_GPIO) == 0;
        control_event_t control_event;
        while (xQueueReceive(control_queue, &control_event, 0) == pdTRUE) {
            process_control_event(&control_event);
            if (control_event.type == CC_MSG_PROMPT_OPEN) {
                cc_prompt_payload_t prompt;
                if (cc_prompt_decode(control_event.payload,
                                     control_event.payload_length, &prompt)) {
                    cc_device_set_remote_state(&model, CC_STATE_APPROVAL_REQUIRED);
                    cc_device_ui_show_prompt(&prompt, prompt_selected);
                }
            }
        }
        switch (cc_device_button_sample(&model, button_down, time)) {
            case CC_BUTTON_PTT_DOWN:
                if (usb_uac_mode) {
                    // UAC is host-pulled. The standard HID F13 boundary is
                    // translated by macOS Companion into the configured voice
                    // shortcut; CDC stays Mac -> device only for UI status.
                    cc_usb_hid_ptt_set(true);
                    cc_device_ui_render(&model, 0);
                    last_render_ms = time;
                } else if (model.connected) {
                    ESP_LOGI(TAG, "PTT down; starting microphone stream");
                    cc_device_ui_render(&model, 0);
                    last_render_ms = time;
                    // Do not play a listening tone here: speaker playback
                    // reconfigures the same I2S path as ES7210 capture and
                    // can make reads return immediately. The listening UI is
                    // the non-audible acknowledgement while the mic is live.
                    // Announce the authenticated PTT boundary before audio.
                    // macOS uses it to reset its per-session frame sequencer;
                    // starting capture first lets sequence 0 race ahead and be
                    // rejected as a replay from the prior PTT session.
                    send_control_event(CC_MSG_PTT_DOWN);
                    if (!usb_uac_mode) cc_audio_stream_start();
                } else {
                    model.visible_state = CC_STATE_VOICE_ERROR;
                }
                break;
            case CC_BUTTON_PTT_UP:
                ESP_LOGI(TAG, "PTT up; keeping %d ms microphone tail",
                         CC_PTT_POST_ROLL_MS);
                // Release the Mac-side Fn modifier immediately; capture keeps
                // a short local tail so the final phoneme is not clipped.
                if (usb_uac_mode) {
                    cc_usb_hid_ptt_set(false);
                } else {
                    cc_audio_stream_stop(CC_PTT_POST_ROLL_MS);
                    send_control_event(CC_MSG_PTT_UP);
                }
                break;
            case CC_BUTTON_NONE:
                break;
        }
        const uint32_t render_period_ms =
            model.visible_state == CC_STATE_LISTENING
                ? UI_RENDER_LISTENING_PERIOD_MS
                : UI_RENDER_IDLE_PERIOD_MS;
        if (time - last_render_ms >= render_period_ms) {
            cc_device_ui_render(&model, cc_audio_stream_level());
            last_render_ms = time;
        }
        vTaskDelay(pdMS_TO_TICKS(10));
    }
}
