#include <stdbool.h>
#include <stdio.h>
#include <stdint.h>
#include <string.h>
#include <sys/time.h>

#include "audio_stream.h"
#include "battery_monitor.h"
#include "ble_transport.h"
#include "control_protocol.h"
#include "device_model.h"
#include "device_ui.h"
#include "driver/gpio.h"
#include "esp_intr_alloc.h"
#include "esp_log.h"
#include "esp_system.h"
#include "esp_task_wdt.h"
#include "esp_timer.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "freertos/queue.h"
#include "mbedtls/base64.h"
#include "nvs_flash.h"
#include "prompt_payload.h"
#include "usb_audio_mode.h"
#include "usb_control.h"
#include "usb_hid_ptt.h"
#include "wifi_manager.h"
#include "wifi_transport.h"
#include "wireless_audio_router.h"

#define BOOT_BUTTON_GPIO GPIO_NUM_0
#define HEARTBEAT_TIMEOUT_MS 6000
// Pixel animation has twelve frames per second; redrawing at 30fps only
// repeatedly invalidates the same LCD regions and can starve the SPI DMA heap.
// Listening is intentionally faster so the local waveform still feels live.
#define UI_RENDER_IDLE_PERIOD_MS 83
#define UI_RENDER_LISTENING_PERIOD_MS 40
#define UI_POWER_TICK_PERIOD_MS 250
#define BATTERY_POLL_PERIOD_MS 15000
#define BATTERY_LOG_PERIOD_MS 60000

static cc_device_model_t model;
static cc_sequence_guard_t inbound_sequences;
static uint32_t outbound_sequence;
static uint64_t last_heartbeat_ms;
static QueueHandle_t control_queue;
static QueueHandle_t wifi_setup_result_queue;
static QueueHandle_t button_edge_queue;
static const char *TAG = "cc_app";
static bool usb_uac_mode;
static uint64_t wifi_realtime_release_ms;

typedef struct {
    cc_message_type_t type;
    size_t payload_length;
    uint8_t payload[448];
} control_event_t;

typedef struct {
    bool down;
    uint64_t timestamp_ms;
} button_edge_event_t;

static uint64_t now_ms(void) { return (uint64_t)(esp_timer_get_time() / 1000); }

static cc_wireless_audio_route_t begin_wireless_audio_route(void) {
    const cc_wireless_audio_route_t route = cc_wireless_audio_route_begin();
    if (route == CC_WIRELESS_AUDIO_WIFI) {
        // Disable modem sleep before capture can enqueue its first 20 ms frame.
        cc_wifi_set_realtime(true);
        wifi_realtime_release_ms = 0;
    }
    return route;
}

static void cancel_wireless_audio_route(void) {
    cc_wireless_audio_route_cancel();
    cc_wifi_set_realtime(false);
    wifi_realtime_release_ms = 0;
}

static void finish_wireless_audio_route(uint64_t time_ms) {
    const bool was_wifi =
        cc_wireless_audio_route_current() == CC_WIRELESS_AUDIO_WIFI;
    cc_wireless_audio_route_finish();
    // The capture task owns a 200 ms release tail. Keep Wi-Fi awake until that
    // tail has left the UDP socket, then return to standby modem sleep.
    wifi_realtime_release_ms = was_wifi
        ? time_ms + CC_PTT_POST_ROLL_MS + 50U : 0;
}

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
                                cc_device_state_t *state,
                                uint8_t *active_tasks,
                                uint8_t *attention_tasks,
                                uint8_t *recent_completed_tasks) {
    if (length < 3 || (payload[0] != 0xA1 && payload[0] != 0xA4) ||
        payload[1] != 0x00) return false;
    const uint8_t *cursor = payload + 2;
    uint64_t value;
    if (!read_cbor_uint(&cursor, payload + length, &value) ||
        value > CC_STATE_RUNNING ||
        value == CC_STATE_LISTENING) return false;
    *state = (cc_device_state_t)value;
    *active_tasks = 0;
    *attention_tasks = 0;
    *recent_completed_tasks = 0;
    if (payload[0] == 0xA1) return cursor == payload + length;
    uint64_t key, active, attention, completed;
    if (!read_cbor_uint(&cursor, payload + length, &key) || key != 1 ||
        !read_cbor_uint(&cursor, payload + length, &active) || active > 255 ||
        !read_cbor_uint(&cursor, payload + length, &key) || key != 2 ||
        !read_cbor_uint(&cursor, payload + length, &attention) || attention > 255 ||
        !read_cbor_uint(&cursor, payload + length, &key) || key != 3 ||
        !read_cbor_uint(&cursor, payload + length, &completed) || completed > 255 ||
        cursor != payload + length) return false;
    *active_tasks = (uint8_t)active;
    *attention_tasks = (uint8_t)attention;
    *recent_completed_tasks = (uint8_t)completed;
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

static bool parse_task_event_payload(const uint8_t *payload, size_t length,
                                     cc_task_event_t *task_event) {
    if (!task_event || length != 3 || payload[0] != 0xA1 || payload[1] != 0x00 ||
        payload[2] > CC_TASK_EVENT_COMPLETED) return false;
    *task_event = (cc_task_event_t)payload[2];
    return true;
}

static bool parse_weather_payload(const uint8_t *payload, size_t length,
                                  char *city, size_t city_capacity,
                                  int16_t *temperature_tenths_celsius,
                                  uint8_t *weather_code) {
    if (!payload || !city || city_capacity == 0 || !temperature_tenths_celsius ||
        !weather_code || length < 6 || payload[0] != 1) return false;
    const size_t city_length = payload[4];
    if (city_length == 0 || city_length >= city_capacity ||
        length != city_length + 5) return false;
    memcpy(city, payload + 5, city_length);
    city[city_length] = '\0';
    const uint16_t raw = ((uint16_t)payload[1] << 8) | payload[2];
    *temperature_tenths_celsius = (int16_t)raw;
    *weather_code = payload[3];
    return true;
}

static bool parse_weather_config_payload(const uint8_t *payload, size_t length,
                                         bool *enabled, bool *uses_celsius,
                                         uint8_t *refresh_minutes) {
    if (!payload || !enabled || !uses_celsius || !refresh_minutes ||
        length != 4 || payload[0] != 1 || payload[1] > 1 || payload[2] > 1 ||
        (payload[3] != 15 && payload[3] != 30 && payload[3] != 60)) return false;
    *enabled = payload[1] != 0;
    *uses_celsius = payload[2] != 0;
    *refresh_minutes = payload[3];
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
    // Authenticated Mac time keeps the on-device Codex clock correct without
    // adding a second time-sync protocol. Ignore implausible pre-2020 values.
    if (envelope.timestamp_ms >= 1577836800000ULL) {
        struct timeval tv = {
            .tv_sec = (time_t)(envelope.timestamp_ms / 1000ULL),
            .tv_usec = (suseconds_t)((envelope.timestamp_ms % 1000ULL) * 1000ULL),
        };
        settimeofday(&tv, NULL);
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
        uint8_t active_tasks, attention_tasks, recent_completed_tasks;
        if (parse_state_payload(event->payload, event->payload_length, &state,
                                &active_tasks, &attention_tasks,
                                &recent_completed_tasks)) {
            cc_device_set_activity(&model, active_tasks, attention_tasks,
                                   recent_completed_tasks);
            if (cc_device_set_remote_state(&model, state)) {
                ESP_LOGI(TAG, "remote state changed: %d", state);
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
    } else if (event->type == CC_MSG_TASK_EVENT) {
        cc_task_event_t task_event;
        if (parse_task_event_payload(event->payload, event->payload_length,
                                     &task_event)) {
            if (cc_device_ui_codex_app_active()) {
                // Lifecycle effects belong to the foreground Codex app. A
                // watch face or another app must never behave like Codex is a
                // system-wide notification service.
                cc_device_ui_enqueue_task_event(task_event);
                cc_audio_play_task_event_tone(task_event);
            } else {
                ESP_LOGI(TAG, "Codex task effect suppressed outside app");
            }
        }
    } else if (event->type == CC_MSG_WEATHER_UPDATE) {
        char city[49];
        int16_t temperature;
        uint8_t code;
        if (parse_weather_payload(event->payload, event->payload_length, city,
                                  sizeof(city), &temperature, &code)) {
            cc_device_ui_update_weather(city, temperature, code);
        }
    } else if (event->type == CC_MSG_WEATHER_CONFIG) {
        bool enabled, uses_celsius;
        uint8_t refresh_minutes;
        if (parse_weather_config_payload(event->payload, event->payload_length,
                                         &enabled, &uses_celsius,
                                         &refresh_minutes)) {
            cc_device_ui_apply_weather_settings(enabled, uses_celsius,
                                                refresh_minutes);
        }
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
        if (usb_uac_mode) {
            char line[48];
            snprintf(line, sizeof(line), "O:%lu:%u:%u\n",
                     (unsigned long)prompt_id, option_index,
                     long_press ? 1U : 0U);
            (void)cc_usb_control_send(line);
        }
    }
}

static void weather_settings_changed(bool enabled, bool uses_celsius,
                                     uint8_t refresh_minutes) {
    const uint8_t payload[] = {
        1, enabled ? 1 : 0, uses_celsius ? 1 : 0, refresh_minutes,
    };
    send_control_payload(CC_MSG_WEATHER_CONFIG, payload, sizeof(payload));
    if (usb_uac_mode) {
        char line[24];
        snprintf(line, sizeof(line), "G:%u:%u:%u\n", enabled ? 1U : 0U,
                 uses_celsius ? 1U : 0U, refresh_minutes);
        (void)cc_usb_control_send(line);
    }
}

static void codex_visibility_changed(bool visible) {
    cc_audio_set_task_tones_enabled(visible);
}

static void IRAM_ATTR button_edge_isr(void *context) {
    (void)context;
    const button_edge_event_t event = {
        .down = gpio_get_level(BOOT_BUTTON_GPIO) == 0,
        .timestamp_ms = (uint64_t)(esp_timer_get_time() / 1000),
    };
    BaseType_t task_woken = pdFALSE;
    (void)xQueueSendFromISR(button_edge_queue, &event, &task_woken);
    if (task_woken == pdTRUE) portYIELD_FROM_ISR();
}

static void initialize_button(void) {
    const gpio_config_t config = {
        .pin_bit_mask = 1ULL << BOOT_BUTTON_GPIO,
        .mode = GPIO_MODE_INPUT,
        .pull_up_en = GPIO_PULLUP_ENABLE,
        .pull_down_en = GPIO_PULLDOWN_DISABLE,
        .intr_type = GPIO_INTR_ANYEDGE,
    };
    ESP_ERROR_CHECK(gpio_config(&config));
    const esp_err_t isr_result = gpio_install_isr_service(ESP_INTR_FLAG_IRAM);
    if (isr_result != ESP_OK && isr_result != ESP_ERR_INVALID_STATE) {
        ESP_ERROR_CHECK(isr_result);
    }
    ESP_ERROR_CHECK(gpio_isr_handler_add(BOOT_BUTTON_GPIO, button_edge_isr, NULL));
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

static bool reset_ble_pairing(void) {
    const bool reset = cc_ble_clear_pairing();
    if (!reset) {
        ESP_LOGE(TAG, "BLE pairing reset did not fully clear persistent state");
    }
    return reset;
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
    if (strcmp(line, "E:S") == 0 || strcmp(line, "E:D") == 0) {
        const cc_task_event_t event = line[2] == 'S'
            ? CC_TASK_EVENT_STARTED : CC_TASK_EVENT_COMPLETED;
        if (cc_device_ui_codex_app_active()) {
            cc_device_ui_enqueue_task_event(event);
            cc_audio_play_task_event_tone(event);
        } else {
            ESP_LOGI(TAG, "USB Codex task effect suppressed outside app");
        }
        return;
    }
    if (strcmp(line, "C:P") == 0) {
        cc_device_ui_close_prompt();
        return;
    }
    if (strncmp(line, "P:", 2) == 0 || strncmp(line, "W:", 2) == 0) {
        uint8_t payload[448];
        size_t payload_length = 0;
        const size_t encoded_length = strlen(line + 2);
        if (mbedtls_base64_decode(payload, sizeof(payload), &payload_length,
                                  (const unsigned char *)line + 2,
                                  encoded_length) != 0) return;
        if (line[0] == 'P') {
            cc_prompt_payload_t prompt;
            if (cc_prompt_decode(payload, payload_length, &prompt)) {
                cc_device_set_remote_state(&model, CC_STATE_APPROVAL_REQUIRED);
                cc_device_ui_show_prompt(&prompt, prompt_selected);
            }
        } else {
            char city[49];
            int16_t temperature;
            uint8_t code;
            if (parse_weather_payload(payload, payload_length, city, sizeof(city),
                                      &temperature, &code)) {
                cc_device_ui_update_weather(city, temperature, code);
            }
        }
        return;
    }
    unsigned enabled, uses_celsius, refresh_minutes;
    if (sscanf(line, "G:%u:%u:%u", &enabled, &uses_celsius,
               &refresh_minutes) == 3 && enabled <= 1 && uses_celsius <= 1 &&
        (refresh_minutes == 15 || refresh_minutes == 30 || refresh_minutes == 60)) {
        cc_device_ui_apply_weather_settings(enabled != 0, uses_celsius != 0,
                                            (uint8_t)refresh_minutes);
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
    (void)cc_device_set_remote_state(&model, state);
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
    button_edge_queue = xQueueCreate(16, sizeof(button_edge_event_t));
    configASSERT(button_edge_queue != NULL);
    initialize_button();
    cc_device_ui_start();
    bool battery_monitor_ready = cc_battery_monitor_init();
    cc_battery_sample_t battery_sample;
    const bool initial_battery_valid = battery_monitor_ready &&
        cc_battery_monitor_read(&battery_sample) && battery_sample.valid;
    cc_device_ui_update_battery(
        initial_battery_valid,
        initial_battery_valid ? battery_sample.percent : 0,
        initial_battery_valid && battery_sample.charging);
    cc_device_ui_set_usb_uac_mode(usb_uac_mode, select_usb_uac_mode);
    cc_device_ui_set_wifi_setup(begin_wifi_setup);
    cc_device_ui_set_pairing_reset(reset_ble_pairing);
    cc_device_ui_set_weather_settings_callback(weather_settings_changed);
    (void)cc_wifi_start();
    cc_device_ui_set_wifi_status(cc_wifi_portal_hint());
    cc_ble_start(handle_control);
    cc_host_profile_t paired_host;
    if (cc_ble_copy_host_profile(&paired_host)) {
        cc_device_ui_set_paired_host(paired_host.display_name);
    }
    cc_wifi_transport_start(handle_control);
    cc_audio_stream_init(cc_wireless_audio_route_send);
    cc_device_ui_set_codex_visibility_callback(codex_visibility_changed);
    if (usb_uac_mode && !cc_usb_uac_start()) {
        // Continue BLE control/UI so the user can tap Link → USB Mic and
        // switch back to normal mode even if USB enumeration failed.
        ESP_LOGE(TAG, "USB UAC unavailable; use Connection Center to exit mode");
    }
    if (usb_uac_mode) cc_usb_control_start(handle_usb_control_line);

    bool previous_link_connected = false;
    bool previous_button_down = false;
    bool boot_interaction_armed = false;
    char last_wifi_hint[96] = {0};
    char last_host_name[CC_HOST_NAME_MAX + 1U] = {0};
    uint64_t last_render_ms = 0;
    uint64_t last_power_tick_ms = 0;
    uint64_t last_battery_poll_ms = 0;
    uint64_t last_battery_log_ms = 0;
    const esp_err_t watchdog_result = esp_task_wdt_add(NULL);
    if (watchdog_result != ESP_OK) {
        ESP_LOGE(TAG, "failed to watch main UI loop: %s",
                 esp_err_to_name(watchdog_result));
    }
    while (true) {
        const uint64_t time = now_ms();
        if (wifi_realtime_release_ms != 0 &&
            time >= wifi_realtime_release_ms) {
            cc_wifi_set_realtime(false);
            wifi_realtime_release_ms = 0;
        }
        if (cc_ble_copy_host_profile(&paired_host) &&
            strcmp(last_host_name, paired_host.display_name) != 0) {
            snprintf(last_host_name, sizeof(last_host_name), "%s",
                     paired_host.display_name);
            cc_device_ui_set_paired_host(last_host_name);
        } else if (!cc_ble_copy_host_profile(&paired_host) &&
                   last_host_name[0] != '\0') {
            last_host_name[0] = '\0';
            cc_device_ui_set_paired_host("");
        }
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
                cancel_wireless_audio_route();
            }
        }
        if (link_connected && last_heartbeat_ms != 0 &&
            time - last_heartbeat_ms > HEARTBEAT_TIMEOUT_MS) {
            cc_device_set_connected(&model, false, time);
            cc_audio_stream_cancel();
            cancel_wireless_audio_route();
        }
        if (cc_audio_stream_is_active() &&
            cc_wireless_audio_route_lost_at((uint32_t)time)) {
            ESP_LOGW(TAG, "selected wireless microphone route was lost");
            send_control_event(CC_MSG_PTT_UP);
            cc_audio_stream_cancel();
            cancel_wireless_audio_route();
            model.visible_state = CC_STATE_VOICE_ERROR;
        }

        const bool button_down = gpio_get_level(BOOT_BUTTON_GPIO) == 0;
        if (button_down && !previous_button_down) {
            boot_interaction_armed = cc_device_ui_codex_voice_available();
            if (!boot_interaction_armed) {
                ESP_LOGI(TAG, "BOOT ignored outside Codex app");
            }
        }
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
        button_edge_event_t button_edge;
        bool submit_from_edge = false;
        while (xQueueReceive(button_edge_queue, &button_edge, 0) == pdTRUE) {
            if (cc_device_button_edge(&model, button_edge.down,
                                      button_edge.timestamp_ms) ==
                    CC_BUTTON_SUBMIT &&
                cc_device_ui_codex_voice_available()) {
                submit_from_edge = true;
            }
        }
        if (submit_from_edge) {
            if (!usb_uac_mode) {
                cc_audio_stream_cancel();
                cancel_wireless_audio_route();
                send_control_event(CC_MSG_SUBMIT);
            } else {
                (void)cc_usb_control_send("K:R\n");
            }
            ESP_LOGI(TAG, "BOOT latched double-click requested Return");
            cc_device_ui_render(&model, 0);
            last_render_ms = time;
        }
        cc_button_action_t button_action =
            cc_device_button_sample(&model, button_down, time);
        if (!boot_interaction_armed && button_action != CC_BUTTON_NONE) {
            button_action = CC_BUTTON_NONE;
        }
        switch (button_action) {
            case CC_BUTTON_PREPARE_PTT:
                if (!usb_uac_mode && model.connected &&
                    cc_wireless_audio_route_current() == CC_WIRELESS_AUDIO_NONE &&
                    begin_wireless_audio_route() != CC_WIRELESS_AUDIO_NONE) {
                    // Capture begins before the hold threshold. Wi-Fi retains
                    // the last 100 ms until authenticated PTT_DOWN, so the
                    // long-press discriminator does not clip the first word.
                    cc_audio_stream_start();
                }
                break;
            case CC_BUTTON_CANCEL_PTT:
                if (!usb_uac_mode) {
                    cc_audio_stream_cancel();
                    cancel_wireless_audio_route();
                }
                break;
            case CC_BUTTON_PTT_DOWN:
                if (usb_uac_mode) {
                    // UAC is host-pulled. Mirror the physical boundary over
                    // both transports: recent macOS releases can leave a new
                    // USB keyboard in HID approval while the already-open CDC
                    // sideband is fully usable. Companion deduplicates the two
                    // edges if HID approval is granted later.
                    cc_usb_hid_ptt_set(true);
                    (void)cc_usb_control_send("B:1\n");
                    cc_device_ui_render(&model, 0);
                    last_render_ms = time;
                } else if (model.connected) {
                    if (cc_wireless_audio_route_current() == CC_WIRELESS_AUDIO_NONE &&
                        begin_wireless_audio_route() == CC_WIRELESS_AUDIO_NONE) {
                        ESP_LOGW(TAG, "PTT down without an audio-capable wireless route");
                        model.visible_state = CC_STATE_VOICE_ERROR;
                        break;
                    }
                    ESP_LOGI(TAG, "PTT down; starting microphone stream");
                    cc_device_ui_render(&model, 0);
                    last_render_ms = time;
                    // Do not play a listening tone here: speaker playback
                    // reconfigures the same I2S path as ES7210 capture and
                    // can make reads return immediately. The listening UI is
                    // the non-audible acknowledgement while the mic is live.
                    // Announce the authenticated PTT boundary after the short
                    // pre-roll. Wi-Fi keeps that bounded slice and releases it
                    // only after this message resets the session sequencer.
                    send_control_event(CC_MSG_PTT_DOWN);
                    if (!cc_audio_stream_is_active()) cc_audio_stream_start();
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
                    (void)cc_usb_control_send("B:0\n");
                } else {
                    cc_audio_stream_stop(CC_PTT_POST_ROLL_MS);
                    finish_wireless_audio_route(time);
                    send_control_event(CC_MSG_PTT_UP);
                }
                break;
            case CC_BUTTON_SUBMIT:
                if (!usb_uac_mode) {
                    // Confirmation taps never start pre-roll. Cancellation is
                    // still idempotent here and closes a route left behind by
                    // an interrupted earlier session before sending Return.
                    cc_audio_stream_cancel();
                    cancel_wireless_audio_route();
                    send_control_event(CC_MSG_SUBMIT);
                } else {
                    (void)cc_usb_control_send("K:R\n");
                }
                ESP_LOGI(TAG, "BOOT confirmation requested Return");
                cc_device_ui_render(&model, 0);
                last_render_ms = time;
                break;
            case CC_BUTTON_NONE:
                break;
        }
        if (!button_down && previous_button_down) boot_interaction_armed = false;
        previous_button_down = button_down;
        const uint32_t render_period_ms =
            model.visible_state == CC_STATE_LISTENING
                ? UI_RENDER_LISTENING_PERIOD_MS
                : UI_RENDER_IDLE_PERIOD_MS;
        if (time - last_render_ms >= render_period_ms) {
            cc_device_ui_render(&model, cc_audio_stream_level());
            last_render_ms = time;
        }
        if (time - last_power_tick_ms >= UI_POWER_TICK_PERIOD_MS) {
            const bool active_work = button_down ||
                model.visible_state == CC_STATE_LISTENING ||
                model.visible_state == CC_STATE_SESSION_STARTING ||
                model.visible_state == CC_STATE_WORKING ||
                model.visible_state == CC_STATE_RUNNING ||
                model.visible_state == CC_STATE_APPROVAL_REQUIRED ||
                model.visible_state == CC_STATE_INPUT_REQUIRED ||
                model.visible_state == CC_STATE_CONFIRMATION_REQUIRED;
            cc_device_ui_power_tick(time, active_work);
            last_power_tick_ms = time;
        }
        if (last_battery_poll_ms == 0 ||
            time - last_battery_poll_ms >= BATTERY_POLL_PERIOD_MS) {
            if (!battery_monitor_ready) {
                battery_monitor_ready = cc_battery_monitor_init();
            }
            const bool battery_valid = battery_monitor_ready &&
                cc_battery_monitor_read(&battery_sample) && battery_sample.valid;
            cc_device_ui_update_battery(
                battery_valid,
                battery_valid ? battery_sample.percent : 0,
                battery_valid && battery_sample.charging);
            if (battery_valid &&
                (last_battery_log_ms == 0 ||
                 time - last_battery_log_ms >= BATTERY_LOG_PERIOD_MS)) {
                ESP_LOGI(TAG, "battery %u%% %umV current=%dmA%s",
                         battery_sample.percent, battery_sample.millivolts,
                         battery_sample.current_ma,
                         battery_sample.charging ? " charging" : "");
                last_battery_log_ms = time;
            }
            last_battery_poll_ms = time;
        }
        if (watchdog_result == ESP_OK) (void)esp_task_wdt_reset();
        vTaskDelay(pdMS_TO_TICKS(10));
    }
}
