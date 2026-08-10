#include "device_ui.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "bsp/esp-bsp.h"
#include "generated/cc_font_zh_14.h"
#include "generated/cc_pixel_poop.h"
#include "esp_log.h"
#include "esp_timer.h"
#include "lvgl.h"
#include "nvs.h"

static const char *TAG = "cc_device_ui";

static lv_obj_t *outer_arc;
static lv_obj_t *inner_arc;
static lv_obj_t *quota_dashes[2][24];
static lv_obj_t *face;
static lv_obj_t *status_label;
static lv_obj_t *wave_bars[13];
static lv_obj_t *hud_marks[8];
static lv_obj_t *prompt_buttons[CC_PROMPT_MAX_OPTIONS];
static lv_obj_t *prompt_list;
static lv_obj_t *connection_center;
static lv_obj_t *connection_mac_label;
static lv_obj_t *connection_auth_label;
static lv_obj_t *connection_mic_label;
static lv_obj_t *connection_wifi_label;
static lv_obj_t *connection_usb_button;
static lv_obj_t *connection_usb_button_label;
static lv_obj_t *connection_wifi_button;
static lv_obj_t *connection_reset_button;
static lv_obj_t *connection_reset_label;
static lv_obj_t *os_status_bar;
static lv_obj_t *os_home_title;
static lv_obj_t *os_settings_title;
static lv_obj_t *os_link_label;
static lv_obj_t *companion_summary_label;
static lv_obj_t *clock_label;
static lv_obj_t *quota_five_label;
static lv_obj_t *quota_week_label;
static lv_obj_t *os_dock;
static lv_obj_t *os_app_buttons[4];
static lv_obj_t *os_settings_launcher;
static lv_obj_t *os_settings_panel;
static lv_obj_t *os_settings_buttons[4];
static lv_obj_t *watch_face;
static lv_obj_t *watch_battery_label;
static lv_obj_t *watch_time_label;
static lv_obj_t *watch_date_label;
static lv_obj_t *watch_weather_label;
static lv_obj_t *watch_sync_label;
static lv_obj_t *pet_image;
static time_t watch_rendered_minute = (time_t)-1;
static lv_obj_t *app_sheet;
static lv_obj_t *app_sheet_title;
static lv_obj_t *app_sheet_detail;
static lv_obj_t *settings_menu_buttons[3];
static lv_obj_t *weather_config_button;
static lv_obj_t *weather_config_label;
static lv_obj_t *weather_option_buttons[3];
static lv_obj_t *weather_option_labels[3];
static bool prompt_requires_hold[CC_PROMPT_MAX_OPTIONS];
static int64_t prompt_press_started[CC_PROMPT_MAX_OPTIONS];
static uint32_t prompt_id;
static bool prompt_visible;
static bool prompt_pending;
static cc_prompt_payload_t pending_prompt;
static bool connection_center_visible;
static cc_prompt_selection_fn on_prompt_selection;
static cc_usb_mode_selection_fn on_usb_mode_selection;
static cc_wifi_setup_fn on_wifi_setup;
static cc_pairing_reset_fn on_pairing_reset;
static cc_weather_settings_fn on_weather_settings;
static cc_codex_visibility_fn on_codex_visibility;
static bool usb_uac_enabled;
static int64_t usb_mode_pressed_at;
static int64_t pairing_reset_pressed_at;
static bool pairing_reset_fired;
static char paired_host_name[65];
static bool connection_render_initialized;
static bool connection_rendered_connected;
static char connection_rendered_host[65];
static bool weather_settings_visible;
static bool weather_sync_enabled = true;
static bool weather_celsius = true;
static uint8_t weather_refresh_index = 1;
static bool weather_data_valid;
static char weather_city[49];
static int16_t weather_temperature_tenths_celsius;
static uint8_t weather_code;
static lv_indev_t *ui_input;
static bool ui_started;
static bool display_dimmed;
static uint64_t last_ui_activity_ms;
static bool battery_rendered_valid;
static bool battery_rendered_charging;
static uint8_t battery_rendered_percent = UINT8_MAX;

#define CC_WEATHER_NVS_NAMESPACE "cc_weather"
#define CC_WEATHER_SYNC_KEY "sync"
#define CC_WEATHER_UNIT_KEY "unit_c"
#define CC_WEATHER_REFRESH_KEY "refresh"

#define TASK_EVENT_QUEUE_CAPACITY 8
#define TASK_EVENT_ANIMATION_US 4000000
#define UI_INPUT_STARTUP_GUARD_MS 4000
#define UI_IDLE_DIM_MS 60000
#define UI_ACTIVE_BRIGHTNESS 100
#define UI_IDLE_BRIGHTNESS 25
static cc_task_event_t task_event_queue[TASK_EVENT_QUEUE_CAPACITY];
static uint8_t task_event_head;
static uint8_t task_event_count;
static bool task_event_active;
static cc_task_event_t active_task_event;
static int64_t task_event_started_at;

typedef enum {
    OS_APP_HOME = 0,
    OS_APP_CODEX,
    OS_APP_SYSTEM,
    OS_APP_MUSIC,
    OS_APP_TOOLS,
    OS_APP_WEATHER,
    OS_APP_WATCH,
    OS_APP_SETTINGS,
    OS_APP_SETTINGS_MENU,
    OS_APP_SOUND,
    OS_APP_DISPLAY,
    OS_APP_ABOUT,
} os_app_t;

typedef enum {
    CODEX_PAGE_HOME = 0,
    CODEX_PAGE_SETTINGS,
    CODEX_PAGE_TASKS,
    CODEX_PAGE_USAGE,
    CODEX_PAGE_VOICE,
} codex_page_t;

static volatile os_app_t active_os_app = OS_APP_WATCH;
static codex_page_t active_codex_page = CODEX_PAGE_HOME;

static void enable_input_after_startup(lv_timer_t *timer) {
    lv_indev_t *indev = (lv_indev_t *)lv_timer_get_user_data(timer);
    if (!indev) return;
    // Drop any coordinate/gesture state accumulated while the CST816S and the
    // shared I2C bus settled. Waiting for a physical release prevents a stale
    // boot interrupt from becoming a click on the app drawer.
    lv_indev_reset(indev, NULL);
    lv_indev_enable(indev, true);
    lv_indev_wait_release(indev);
    ESP_LOGI(TAG, "touch input enabled after startup guard");
}

typedef struct {
    bool initialized;
    codex_page_t page;
    bool prompt_visible;
    bool lifecycle_visible;
    cc_task_event_t lifecycle_event;
    cc_device_state_t visual_state;
    bool connected;
    cc_quota_value_t five_hour;
    cc_quota_value_t week;
    bool quota_stale;
    uint8_t active_tasks;
    uint8_t attention_tasks;
    uint8_t recent_completed_tasks;
    bool listening;
    time_t clock_minute;
    uint8_t sprite_frame;
} codex_render_cache_t;

static codex_render_cache_t codex_render_cache;

enum {
    GLYPH_EFFECT_0,
    GLYPH_EFFECT_1,
    GLYPH_EFFECT_2,
    GLYPH_EFFECT_3,
    GLYPH_EFFECT_4,
    GLYPH_EFFECT_5,
    GLYPH_COUNT,
};

static lv_obj_t *sprite[GLYPH_COUNT];

// Round-watch visual system: true black canvas, quiet graphite surfaces and
// only two normal-state accents. Orange/red are reserved for attention and
// faults, so users can read state without decoding a rainbow HUD.
#define UI_INK 0x000000
#define UI_NAVY 0x11151C
#define UI_FOREST 0x10231C
#define UI_TEAL 0x18CFC1
#define UI_BLUE 0x3478F6
#define UI_MINT 0x31E981
#define UI_AMBER 0xFFB020
#define UI_ALARM 0xFF4D5E
#define UI_MAGENTA 0x3478F6
#define UI_VIOLET 0x8A6CFF
#define UI_DIM 0x343941
#define UI_RING_TRACK 0x24282E
#define UI_GRAPHITE 0x484D55
#define UI_SECONDARY 0x8B919A
#define UI_SHELL 0x17191D
#define UI_SCREEN 0x050607
#define UI_SIGNAL 0x31E981

static void prompt_button_event(lv_event_t *event) {
    const uint8_t index = (uint8_t)(uintptr_t)lv_event_get_user_data(event);
    const lv_event_code_t code = lv_event_get_code(event);
    if (code == LV_EVENT_PRESSED) {
        prompt_press_started[index] = esp_timer_get_time();
    } else if (code == LV_EVENT_RELEASED && on_prompt_selection) {
        const int64_t held_ms = (esp_timer_get_time() - prompt_press_started[index]) / 1000;
        if (!prompt_requires_hold[index] || held_ms >= 1500) {
            on_prompt_selection(prompt_id, index, prompt_requires_hold[index]);
        }
    }
}

static void set_home_visible(bool visible) {
    if (!face || !status_label) return;
    if (visible) {
        lv_obj_remove_flag(face, LV_OBJ_FLAG_HIDDEN);
        lv_obj_remove_flag(status_label, LV_OBJ_FLAG_HIDDEN);
    } else {
        lv_obj_add_flag(face, LV_OBJ_FLAG_HIDDEN);
        lv_obj_add_flag(status_label, LV_OBJ_FLAG_HIDDEN);
    }
}

static void set_codex_rings_visible(bool visible) {
    if (!outer_arc || !inner_arc) return;
    if (visible) {
        lv_obj_remove_flag(outer_arc, LV_OBJ_FLAG_HIDDEN);
        lv_obj_remove_flag(inner_arc, LV_OBJ_FLAG_HIDDEN);
    } else {
        lv_obj_add_flag(outer_arc, LV_OBJ_FLAG_HIDDEN);
        lv_obj_add_flag(inner_arc, LV_OBJ_FLAG_HIDDEN);
    }
    for (int ring = 0; ring < 2; ring++) {
        for (int index = 0; index < 24; index++) {
            lv_obj_add_flag(quota_dashes[ring][index], LV_OBJ_FLAG_HIDDEN);
        }
    }
}

static void set_settings_menu_visible(bool visible) {
    for (int i = 0; i < 3; ++i) {
        if (!settings_menu_buttons[i]) continue;
        if (visible) lv_obj_remove_flag(settings_menu_buttons[i], LV_OBJ_FLAG_HIDDEN);
        else lv_obj_add_flag(settings_menu_buttons[i], LV_OBJ_FLAG_HIDDEN);
    }
}

static uint8_t weather_refresh_minutes(void) {
    static const uint8_t values[] = {15, 30, 60};
    if (weather_refresh_index >= sizeof(values)) weather_refresh_index = 1;
    return values[weather_refresh_index];
}

static uint8_t weather_refresh_index_for_minutes(uint8_t minutes) {
    if (minutes == 15) return 0;
    if (minutes == 60) return 2;
    return 1;
}

static const char *weather_condition_text(uint8_t code) {
    if (code == 0) return "晴";
    if (code <= 3) return "多云";
    if (code == 45 || code == 48) return "有雾";
    if (code <= 57) return "毛毛雨";
    if (code <= 67) return "雨";
    if (code <= 77) return "雪";
    if (code <= 82) return "阵雨";
    if (code <= 86) return "阵雪";
    if (code >= 95) return "雷雨";
    return "未知";
}

static int16_t weather_display_temperature_tenths(void) {
    if (weather_celsius) return weather_temperature_tenths_celsius;
    return (int16_t)((weather_temperature_tenths_celsius * 9) / 5 + 320);
}

static void update_watch_weather_label(void) {
    if (!watch_weather_label) return;
    if (!weather_sync_enabled) {
        lv_label_set_text(watch_weather_label, "天气  已关闭");
        return;
    }
    if (!weather_data_valid) {
        lv_label_set_text(watch_weather_label, "天气  等待同步");
        return;
    }
    const int16_t tenths = weather_display_temperature_tenths();
    char text[72];
    snprintf(text, sizeof(text), "%s  %s  %d.%d°%c", weather_city,
             weather_condition_text(weather_code), tenths / 10,
             abs(tenths % 10), weather_celsius ? 'C' : 'F');
    lv_label_set_text(watch_weather_label, text);
}

static void weather_load_settings(void) {
    nvs_handle_t handle;
    if (nvs_open(CC_WEATHER_NVS_NAMESPACE, NVS_READONLY, &handle) != ESP_OK) return;
    uint8_t value = 0;
    if (nvs_get_u8(handle, CC_WEATHER_SYNC_KEY, &value) == ESP_OK) {
        weather_sync_enabled = value != 0;
    }
    if (nvs_get_u8(handle, CC_WEATHER_UNIT_KEY, &value) == ESP_OK) {
        weather_celsius = value != 0;
    }
    if (nvs_get_u8(handle, CC_WEATHER_REFRESH_KEY, &value) == ESP_OK && value < 3) {
        weather_refresh_index = value;
    }
    nvs_close(handle);
}

static void weather_save_settings(void) {
    nvs_handle_t handle;
    esp_err_t result = nvs_open(CC_WEATHER_NVS_NAMESPACE, NVS_READWRITE, &handle);
    if (result != ESP_OK) return;
    if (nvs_set_u8(handle, CC_WEATHER_SYNC_KEY, weather_sync_enabled ? 1 : 0) != ESP_OK ||
        nvs_set_u8(handle, CC_WEATHER_UNIT_KEY, weather_celsius ? 1 : 0) != ESP_OK ||
        nvs_set_u8(handle, CC_WEATHER_REFRESH_KEY, weather_refresh_index) != ESP_OK ||
        nvs_commit(handle) != ESP_OK) {
        ESP_LOGW(TAG, "failed to persist weather settings");
    }
    nvs_close(handle);
}

static void set_weather_controls_visible(bool settings_visible) {
    if (weather_config_button) {
        if (active_os_app == OS_APP_WEATHER && !settings_visible) {
            lv_obj_remove_flag(weather_config_button, LV_OBJ_FLAG_HIDDEN);
        } else {
            lv_obj_add_flag(weather_config_button, LV_OBJ_FLAG_HIDDEN);
        }
    }
    for (int i = 0; i < 3; ++i) {
        if (!weather_option_buttons[i]) continue;
        if (active_os_app == OS_APP_WEATHER && settings_visible) {
            lv_obj_remove_flag(weather_option_buttons[i], LV_OBJ_FLAG_HIDDEN);
        } else {
            lv_obj_add_flag(weather_option_buttons[i], LV_OBJ_FLAG_HIDDEN);
        }
    }
}

static void update_weather_option_labels(void) {
    if (!weather_option_labels[0]) return;
    lv_label_set_text(weather_option_labels[0],
                      weather_sync_enabled ? "城市来源      主机同步" :
                                             "城市来源      已关闭");
    lv_label_set_text(weather_option_labels[1],
                      weather_celsius ? "温度单位      摄氏 °C" :
                                        "温度单位      华氏 °F");
    char refresh[40];
    snprintf(refresh, sizeof(refresh), "更新频率      %u 分钟",
             weather_refresh_minutes());
    lv_label_set_text(weather_option_labels[2], refresh);
}

static void show_weather_home(void) {
    weather_settings_visible = false;
    set_settings_menu_visible(false);
    set_weather_controls_visible(false);
    lv_obj_set_style_text_opa(app_sheet_detail, LV_OPA_COVER, 0);
    lv_label_set_text(app_sheet_title, "天气");
    char detail[220];
    if (weather_sync_enabled && weather_data_valid) {
        const int16_t tenths = weather_display_temperature_tenths();
        snprintf(detail, sizeof(detail),
                 "城市          %s\n天气          %s\n温度          %d.%d°%c\n状态          已同步\n\n每 %u 分钟自动更新",
                 weather_city, weather_condition_text(weather_code), tenths / 10,
                 abs(tenths % 10), weather_celsius ? 'C' : 'F',
                 weather_refresh_minutes());
    } else {
        snprintf(detail, sizeof(detail),
                 "城市          %s\n天气          --°%c\n状态          %s\n\n每 %u 分钟自动更新",
                 weather_sync_enabled ? "等待主机同步" : "未启用",
                 weather_celsius ? 'C' : 'F',
                 weather_sync_enabled ? "等待天气数据" : "同步已关闭",
                 weather_refresh_minutes());
    }
    lv_label_set_text(app_sheet_detail, detail);
    set_weather_controls_visible(false);
    lv_obj_move_foreground(weather_config_button);
}

static void show_weather_settings(void) {
    weather_settings_visible = true;
    set_settings_menu_visible(false);
    lv_obj_set_style_text_opa(app_sheet_detail, LV_OPA_TRANSP, 0);
    lv_label_set_text(app_sheet_title, "天气设置");
    update_weather_option_labels();
    set_weather_controls_visible(true);
    for (int i = 0; i < 3; ++i) lv_obj_move_foreground(weather_option_buttons[i]);
}

static void weather_config_event(lv_event_t *event) {
    if (lv_event_get_code(event) == LV_EVENT_CLICKED &&
        active_os_app == OS_APP_WEATHER) {
        show_weather_settings();
    }
}

static void weather_option_event(lv_event_t *event) {
    if (lv_event_get_code(event) != LV_EVENT_CLICKED ||
        active_os_app != OS_APP_WEATHER || !weather_settings_visible) return;
    const int option = (int)(uintptr_t)lv_event_get_user_data(event);
    if (option == 0) weather_sync_enabled = !weather_sync_enabled;
    else if (option == 1) weather_celsius = !weather_celsius;
    else if (option == 2) weather_refresh_index = (weather_refresh_index + 1) % 3;
    else return;
    update_weather_option_labels();
    weather_save_settings();
    update_watch_weather_label();
    if (on_weather_settings) {
        on_weather_settings(weather_sync_enabled, weather_celsius,
                            weather_refresh_minutes());
    }
}

static void show_codex_page(codex_page_t page) {
    codex_render_cache.initialized = false;
    active_codex_page = page;
    const bool home = page == CODEX_PAGE_HOME;
    const bool settings = page == CODEX_PAGE_SETTINGS;
    connection_center_visible = false;
    weather_settings_visible = false;
    set_weather_controls_visible(false);
    set_codex_rings_visible(home);
    set_home_visible(home);
    if (clock_label) {
        if (home) lv_obj_remove_flag(clock_label, LV_OBJ_FLAG_HIDDEN);
        else lv_obj_add_flag(clock_label, LV_OBJ_FLAG_HIDDEN);
    }
    if (quota_five_label && quota_week_label) {
        if (home) {
            lv_obj_remove_flag(quota_five_label, LV_OBJ_FLAG_HIDDEN);
            lv_obj_remove_flag(quota_week_label, LV_OBJ_FLAG_HIDDEN);
        } else {
            lv_obj_add_flag(quota_five_label, LV_OBJ_FLAG_HIDDEN);
            lv_obj_add_flag(quota_week_label, LV_OBJ_FLAG_HIDDEN);
        }
    }
    set_settings_menu_visible(settings);
    lv_obj_add_flag(connection_center, LV_OBJ_FLAG_HIDDEN);
    if (!home) {
        lv_obj_add_flag(connection_center, LV_OBJ_FLAG_HIDDEN);
        lv_obj_remove_flag(app_sheet, LV_OBJ_FLAG_HIDDEN);
        lv_obj_scroll_to_y(app_sheet, 0, LV_ANIM_OFF);
        lv_obj_set_style_text_opa(app_sheet_detail,
                                  settings ? LV_OPA_TRANSP : LV_OPA_COVER, 0);
        if (settings) {
            lv_label_set_text(app_sheet_title, "Codex 设置");
            lv_label_set_text(app_sheet_detail, "");
        } else if (page == CODEX_PAGE_TASKS) {
            lv_label_set_text(app_sheet_title, "多任务状态");
            lv_label_set_text(app_sheet_detail, "正在读取对话状态…");
        } else if (page == CODEX_PAGE_USAGE) {
            lv_label_set_text(app_sheet_title, "Codex 用量");
            lv_label_set_text(app_sheet_detail, "正在读取官方用量…");
        } else if (page == CODEX_PAGE_VOICE) {
            lv_label_set_text(app_sheet_title, "Codex 语音");
            lv_label_set_text(app_sheet_detail,
                              "按住 BOOT 开始说话\n松开完成语音输入\n无线输入使用 Codex Mic");
        }
        lv_obj_move_foreground(app_sheet);
    } else {
        lv_obj_add_flag(connection_center, LV_OBJ_FLAG_HIDDEN);
        lv_obj_add_flag(app_sheet, LV_OBJ_FLAG_HIDDEN);
    }
    if (os_status_bar) lv_obj_move_foreground(os_status_bar);
}

static void show_pending_prompt_locked(void) {
    if (!prompt_pending || active_os_app != OS_APP_CODEX) return;
    const cc_prompt_payload_t *prompt = &pending_prompt;
    prompt_id = prompt->id;
    prompt_visible = true;
    connection_center_visible = false;
    lv_obj_add_flag(connection_center, LV_OBJ_FLAG_HIDDEN);
    lv_obj_add_flag(app_sheet, LV_OBJ_FLAG_HIDDEN);
    lv_obj_add_flag(os_dock, LV_OBJ_FLAG_HIDDEN);
    lv_obj_add_flag(os_settings_panel, LV_OBJ_FLAG_HIDDEN);
    lv_obj_add_flag(watch_face, LV_OBJ_FLAG_HIDDEN);
    if (os_home_title) lv_obj_add_flag(os_home_title, LV_OBJ_FLAG_HIDDEN);
    if (os_settings_title) lv_obj_add_flag(os_settings_title, LV_OBJ_FLAG_HIDDEN);
    if (os_status_bar) lv_obj_add_flag(os_status_bar, LV_OBJ_FLAG_HIDDEN);
    if (clock_label) lv_obj_add_flag(clock_label, LV_OBJ_FLAG_HIDDEN);
    if (quota_five_label) lv_obj_add_flag(quota_five_label, LV_OBJ_FLAG_HIDDEN);
    if (quota_week_label) lv_obj_add_flag(quota_week_label, LV_OBJ_FLAG_HIDDEN);
    lv_obj_add_flag(face, LV_OBJ_FLAG_HIDDEN);
    lv_obj_remove_flag(prompt_list, LV_OBJ_FLAG_HIDDEN);
    lv_label_set_text(status_label, "请选择 / 长按 1.5 秒");
    lv_obj_align(status_label, LV_ALIGN_CENTER, 0, 126);
    for (uint8_t i = 0; i < CC_PROMPT_MAX_OPTIONS; ++i) {
        if (i < prompt->option_count) {
            prompt_requires_hold[i] = prompt->options[i].requires_long_press;
            lv_obj_t *label = lv_obj_get_child(prompt_buttons[i], 0);
            if (!label) label = lv_label_create(prompt_buttons[i]);
            lv_label_set_text(label, prompt->options[i].title);
            lv_obj_set_style_text_font(label, &cc_font_zh_14, 0);
            lv_obj_set_style_text_color(label, lv_color_hex(UI_MINT), 0);
            lv_label_set_long_mode(label, LV_LABEL_LONG_SCROLL_CIRCULAR);
            lv_obj_set_width(label, 170);
            lv_obj_center(label);
            lv_obj_remove_flag(prompt_buttons[i], LV_OBJ_FLAG_HIDDEN);
        } else {
            lv_obj_add_flag(prompt_buttons[i], LV_OBJ_FLAG_HIDDEN);
        }
    }
}

static void show_os_app(os_app_t app) {
    const bool codex_was_foreground = active_os_app == OS_APP_CODEX;
    if (active_os_app != app) {
        ESP_LOGI(TAG, "OS view %d -> %d", (int)active_os_app, (int)app);
    }
    active_os_app = app;
    if (app != OS_APP_WEATHER) weather_settings_visible = false;
    set_weather_controls_visible(false);
    if (app != OS_APP_CODEX) set_settings_menu_visible(false);
    const bool on_home = app == OS_APP_HOME;
    const bool on_watch = app == OS_APP_WATCH;
    const bool on_settings = app == OS_APP_SETTINGS;
    const bool in_settings_menu = app == OS_APP_SETTINGS_MENU;
    const bool in_codex = app == OS_APP_CODEX;
    const bool in_connection = app == OS_APP_SYSTEM;
    if (os_dock) {
        if (on_home) lv_obj_remove_flag(os_dock, LV_OBJ_FLAG_HIDDEN);
        else lv_obj_add_flag(os_dock, LV_OBJ_FLAG_HIDDEN);
    }
    if (os_settings_panel) {
        if (in_settings_menu) lv_obj_remove_flag(os_settings_panel, LV_OBJ_FLAG_HIDDEN);
        else lv_obj_add_flag(os_settings_panel, LV_OBJ_FLAG_HIDDEN);
    }
    if (os_settings_launcher) {
        if (on_settings) lv_obj_remove_flag(os_settings_launcher, LV_OBJ_FLAG_HIDDEN);
        else lv_obj_add_flag(os_settings_launcher, LV_OBJ_FLAG_HIDDEN);
    }
    if (watch_face) {
        if (on_watch) lv_obj_remove_flag(watch_face, LV_OBJ_FLAG_HIDDEN);
        else lv_obj_add_flag(watch_face, LV_OBJ_FLAG_HIDDEN);
    }
    if (os_status_bar) {
        if (in_codex) lv_obj_remove_flag(os_status_bar, LV_OBJ_FLAG_HIDDEN);
        else lv_obj_add_flag(os_status_bar, LV_OBJ_FLAG_HIDDEN);
    }
    if (os_home_title) {
        if (on_home) lv_obj_remove_flag(os_home_title, LV_OBJ_FLAG_HIDDEN);
        else lv_obj_add_flag(os_home_title, LV_OBJ_FLAG_HIDDEN);
    }
    if (os_settings_title) {
        if (on_settings || in_settings_menu) {
            lv_obj_remove_flag(os_settings_title, LV_OBJ_FLAG_HIDDEN);
        }
        else lv_obj_add_flag(os_settings_title, LV_OBJ_FLAG_HIDDEN);
    }
    if (clock_label && !in_codex) lv_obj_add_flag(clock_label, LV_OBJ_FLAG_HIDDEN);
    if (!in_codex) {
        if (quota_five_label) lv_obj_add_flag(quota_five_label, LV_OBJ_FLAG_HIDDEN);
        if (quota_week_label) lv_obj_add_flag(quota_week_label, LV_OBJ_FLAG_HIDDEN);
    }
    if (in_codex) {
        show_codex_page(active_codex_page);
        show_pending_prompt_locked();
    } else if (on_home || on_watch || on_settings || in_settings_menu) {
        connection_center_visible = false;
        set_codex_rings_visible(false);
        lv_obj_add_flag(connection_center, LV_OBJ_FLAG_HIDDEN);
        lv_obj_add_flag(app_sheet, LV_OBJ_FLAG_HIDDEN);
        set_home_visible(false);
    } else if (in_connection) {
        connection_center_visible = true;
        connection_render_initialized = false;
        set_codex_rings_visible(false);
        set_home_visible(false);
        lv_obj_add_flag(app_sheet, LV_OBJ_FLAG_HIDDEN);
        lv_obj_remove_flag(connection_center, LV_OBJ_FLAG_HIDDEN);
        lv_obj_scroll_to_y(connection_center, 0, LV_ANIM_OFF);
        lv_obj_move_foreground(connection_center);
    } else {
        connection_center_visible = false;
        set_codex_rings_visible(false);
        lv_obj_add_flag(connection_center, LV_OBJ_FLAG_HIDDEN);
        lv_obj_remove_flag(app_sheet, LV_OBJ_FLAG_HIDDEN);
        lv_obj_scroll_to_y(app_sheet, 0, LV_ANIM_OFF);
        set_home_visible(false);
        if (app == OS_APP_WEATHER) {
            show_weather_home();
        } else if (app == OS_APP_MUSIC) {
            lv_label_set_text(app_sheet_title, "音乐");
            lv_label_set_text(app_sheet_detail,
                              "TF 卡播放器\n扬声器与音量控制\n功能接入中");
        } else if (app == OS_APP_TOOLS) {
            lv_label_set_text(app_sheet_title, "工具");
            lv_label_set_text(app_sheet_detail,
                              "触摸测试 · 传感器\nRTC · 屏幕诊断\n功能接入中");
        } else if (app == OS_APP_SOUND) {
            lv_label_set_text(app_sheet_title, "声音与提示");
            lv_label_set_text(app_sheet_detail,
                              "任务提示音      开启\n语音提示        开启\n系统音量        82%");
        } else if (app == OS_APP_DISPLAY) {
            lv_label_set_text(app_sheet_title, "显示与表盘");
            lv_label_set_text(app_sheet_detail,
                              "默认表盘      极简圆环\n主屏循环      已开启\n屏幕尺寸      360x360");
        } else {
            lv_label_set_text(app_sheet_title, "关于设备");
            lv_label_set_text(app_sheet_detail,
                              "ESP32-S3 · 16MB Flash\n8MB PSRAM · 360x360\nCodex Companion OS");
        }
        lv_obj_move_foreground(app_sheet);
    }
    if (os_dock && on_home) lv_obj_move_foreground(os_dock);
    if (os_settings_launcher && on_settings) lv_obj_move_foreground(os_settings_launcher);
    if (os_settings_panel && in_settings_menu) lv_obj_move_foreground(os_settings_panel);
    if (watch_face && on_watch) lv_obj_move_foreground(watch_face);
    if (on_codex_visibility && codex_was_foreground != in_codex) {
        on_codex_visibility(in_codex);
    }
}

static void os_app_button_event(lv_event_t *event) {
    if (lv_event_get_code(event) != LV_EVENT_CLICKED) return;
    show_os_app((os_app_t)(uintptr_t)lv_event_get_user_data(event));
}

static void os_settings_button_event(lv_event_t *event) {
    if (lv_event_get_code(event) != LV_EVENT_CLICKED) return;
    show_os_app((os_app_t)(uintptr_t)lv_event_get_user_data(event));
}

static void companion_button_event(lv_event_t *event) {
    if (lv_event_get_code(event) == LV_EVENT_CLICKED &&
        active_os_app == OS_APP_CODEX && !prompt_visible) {
        show_codex_page(CODEX_PAGE_SETTINGS);
    }
}

static void settings_menu_button_event(lv_event_t *event) {
    if (lv_event_get_code(event) != LV_EVENT_CLICKED) return;
    const int index = (int)(uintptr_t)lv_event_get_user_data(event);
    const codex_page_t pages[] = {
        CODEX_PAGE_TASKS, CODEX_PAGE_USAGE, CODEX_PAGE_VOICE,
    };
    if (index >= 0 && index < 3) show_codex_page(pages[index]);
}

static void navigation_gesture_event(lv_event_t *event) {
    if (lv_event_get_code(event) != LV_EVENT_GESTURE || prompt_visible) return;
    lv_indev_t *indev = lv_indev_active();
    if (!indev) return;
    const lv_dir_t direction = lv_indev_get_gesture_dir(indev);
    const bool top_level = active_os_app == OS_APP_SETTINGS ||
                           active_os_app == OS_APP_HOME ||
                           active_os_app == OS_APP_WATCH;
    if (top_level && direction == LV_DIR_LEFT) {
        show_os_app(active_os_app == OS_APP_SETTINGS ? OS_APP_HOME :
                    (active_os_app == OS_APP_HOME ? OS_APP_WATCH : OS_APP_SETTINGS));
    } else if (top_level && direction == LV_DIR_RIGHT) {
        show_os_app(active_os_app == OS_APP_SETTINGS ? OS_APP_WATCH :
                    (active_os_app == OS_APP_WATCH ? OS_APP_HOME : OS_APP_SETTINGS));
    } else if (direction == LV_DIR_RIGHT && active_os_app == OS_APP_CODEX) {
        if (active_codex_page == CODEX_PAGE_HOME) show_os_app(OS_APP_HOME);
        else if (active_codex_page == CODEX_PAGE_SETTINGS) show_codex_page(CODEX_PAGE_HOME);
        else show_codex_page(CODEX_PAGE_SETTINGS);
    } else if (direction == LV_DIR_RIGHT && active_os_app == OS_APP_WEATHER &&
               weather_settings_visible) {
        show_weather_home();
    } else if (direction == LV_DIR_RIGHT && active_os_app == OS_APP_SETTINGS_MENU) {
        show_os_app(OS_APP_SETTINGS);
    } else if (direction == LV_DIR_RIGHT) {
        show_os_app(OS_APP_HOME);
    } else {
        return;
    }
    lv_indev_wait_release(indev);
}

static void usb_mode_button_event(lv_event_t *event) {
    const lv_event_code_t code = lv_event_get_code(event);
    if (code == LV_EVENT_PRESSED) {
        usb_mode_pressed_at = esp_timer_get_time();
    } else if (code == LV_EVENT_RELEASED && on_usb_mode_selection &&
               (esp_timer_get_time() - usb_mode_pressed_at) >= 1000000) {
        // USB enumeration must restart after changing personality. A hold
        // makes this deliberate, rather than turning a broad touch target
        // into an accidental white-screen/reboot action.
        on_usb_mode_selection(!usb_uac_enabled);
    }
}

static void wifi_setup_button_event(lv_event_t *event) {
    if (lv_event_get_code(event) == LV_EVENT_CLICKED && on_wifi_setup) {
        on_wifi_setup();
    }
}

static void pairing_reset_button_event(lv_event_t *event) {
    const lv_event_code_t code = lv_event_get_code(event);
    if (code == LV_EVENT_PRESSED) {
        pairing_reset_pressed_at = esp_timer_get_time();
        pairing_reset_fired = false;
    } else if (code == LV_EVENT_PRESSING && !pairing_reset_fired &&
               on_pairing_reset &&
               (esp_timer_get_time() - pairing_reset_pressed_at) >= 2000000) {
        // Trigger while the finger is still held. A RELEASED-only gesture is
        // unreliable inside this vertically scrollable panel because LVGL can
        // transfer the gesture to the parent and cancel the button release.
        pairing_reset_fired = true;
        lv_label_set_text(connection_auth_label, "安全：正在重置配对");
        lv_label_set_text(connection_reset_label, "正在重置配对…");
        const bool reset = on_pairing_reset();
        const char *result = reset ? "配对已清除，正在重新连接" : "重置失败，请重试";
        lv_label_set_text(connection_auth_label,
                          reset ? "安全：等待重新配对" : "安全：重置失败");
        lv_label_set_text(connection_reset_label, result);
    }
}

static lv_obj_t *connection_text(lv_obj_t *parent, const char *text,
                                 int x, int y, lv_color_t color) {
    lv_obj_t *label = lv_label_create(parent);
    lv_label_set_text(label, text);
    lv_obj_set_pos(label, x, y);
    lv_obj_set_style_text_font(label, &cc_font_zh_14, 0);
    lv_obj_set_style_text_color(label, color, 0);
    return label;
}

static lv_obj_t *os_button(lv_obj_t *parent, const char *glyph,
                           const char *title, const char *detail, int y,
                           uint32_t accent, lv_event_cb_t callback,
                           void *user_data) {
    lv_obj_t *button = lv_button_create(parent);
    lv_obj_set_size(button, 232, 60);
    lv_obj_set_pos(button, 10, y);
    lv_obj_set_style_radius(button, 18, 0);
    lv_obj_set_style_bg_color(button, lv_color_hex(UI_SHELL), 0);
    lv_obj_set_style_bg_color(button, lv_color_hex(UI_DIM), LV_STATE_PRESSED);
    lv_obj_set_style_border_width(button, 0, 0);
    lv_obj_set_style_pad_all(button, 0, 0);
    lv_obj_add_event_cb(button, callback, LV_EVENT_ALL, user_data);

    lv_obj_t *icon = lv_obj_create(button);
    lv_obj_set_size(icon, 42, 42);
    lv_obj_set_pos(icon, 10, 9);
    lv_obj_set_style_radius(icon, LV_RADIUS_CIRCLE, 0);
    lv_obj_set_style_bg_color(icon, lv_color_hex(accent), 0);
    lv_obj_set_style_border_width(icon, 0, 0);
    lv_obj_set_style_pad_all(icon, 0, 0);
    lv_obj_remove_flag(icon, LV_OBJ_FLAG_SCROLLABLE);
    lv_obj_remove_flag(icon, LV_OBJ_FLAG_CLICKABLE);
    lv_obj_t *glyph_label = lv_label_create(icon);
    lv_label_set_text(glyph_label, glyph);
    lv_obj_set_style_text_font(glyph_label, &cc_font_zh_14, 0);
    lv_obj_set_style_text_color(glyph_label, lv_color_hex(UI_INK), 0);
    lv_obj_center(glyph_label);

    lv_obj_t *title_label = lv_label_create(button);
    lv_label_set_text(title_label, title);
    lv_obj_set_pos(title_label, 64, 10);
    lv_obj_set_style_text_font(title_label, &cc_font_zh_14, 0);
    lv_obj_set_style_text_color(title_label, lv_color_white(), 0);
    lv_obj_t *detail_label = lv_label_create(button);
    lv_label_set_text(detail_label, detail);
    lv_obj_set_pos(detail_label, 64, 34);
    lv_obj_set_style_text_font(detail_label, &cc_font_zh_14, 0);
    lv_obj_set_style_text_color(detail_label, lv_color_hex(UI_SECONDARY), 0);
    lv_obj_t *chevron = lv_label_create(button);
    lv_label_set_text(chevron, ">");
    lv_obj_align(chevron, LV_ALIGN_RIGHT_MID, -14, 0);
    lv_obj_set_style_text_font(chevron, &cc_font_zh_14, 0);
    lv_obj_set_style_text_color(chevron, lv_color_hex(UI_SECONDARY), 0);
    return button;
}

static lv_obj_t *os_grid_button(lv_obj_t *parent, const char *glyph,
                                const char *title, int column, int row,
                                uint32_t accent, lv_event_cb_t callback,
                                void *user_data) {
    lv_obj_t *button = lv_button_create(parent);
    lv_obj_set_size(button, 112, 110);
    lv_obj_set_pos(button, 8 + column * 124, 6 + row * 120);
    lv_obj_set_style_radius(button, 24, 0);
    lv_obj_set_style_bg_color(button, lv_color_hex(UI_SHELL), 0);
    lv_obj_set_style_bg_color(button, lv_color_hex(UI_DIM), LV_STATE_PRESSED);
    lv_obj_set_style_border_width(button, 0, 0);
    lv_obj_set_style_pad_all(button, 0, 0);
    lv_obj_add_event_cb(button, callback, LV_EVENT_CLICKED, user_data);

    lv_obj_t *icon = lv_obj_create(button);
    lv_obj_set_size(icon, 54, 54);
    lv_obj_align(icon, LV_ALIGN_TOP_MID, 0, 10);
    lv_obj_set_style_radius(icon, LV_RADIUS_CIRCLE, 0);
    lv_obj_set_style_bg_color(icon, lv_color_hex(accent), 0);
    lv_obj_set_style_border_width(icon, 0, 0);
    lv_obj_set_style_pad_all(icon, 0, 0);
    lv_obj_remove_flag(icon, LV_OBJ_FLAG_SCROLLABLE);
    lv_obj_remove_flag(icon, LV_OBJ_FLAG_CLICKABLE);
    lv_obj_t *glyph_label = lv_label_create(icon);
    lv_label_set_text(glyph_label, glyph);
    lv_obj_set_style_text_font(glyph_label, &lv_font_montserrat_48, 0);
    lv_obj_set_style_text_color(glyph_label, lv_color_hex(UI_INK), 0);
    lv_obj_center(glyph_label);

    lv_obj_t *title_label = lv_label_create(button);
    lv_label_set_text(title_label, title);
    lv_obj_set_width(title_label, 100);
    lv_obj_align(title_label, LV_ALIGN_BOTTOM_MID, 0, -12);
    lv_obj_set_style_text_align(title_label, LV_TEXT_ALIGN_CENTER, 0);
    lv_obj_set_style_text_font(title_label, &cc_font_zh_14, 0);
    lv_obj_set_style_text_color(title_label, lv_color_white(), 0);
    return button;
}

static lv_color_t state_color(cc_device_state_t state) {
    switch (state) {
        case CC_STATE_COMPLETED: return lv_color_hex(UI_MINT);
        case CC_STATE_ERROR:
        case CC_STATE_VOICE_ERROR: return lv_color_hex(UI_ALARM);
        case CC_STATE_WRITING:
        case CC_STATE_RUNNING:
        case CC_STATE_WORKING: return lv_color_hex(UI_TEAL);
        case CC_STATE_APPROVAL_REQUIRED: return lv_color_hex(UI_AMBER);
        case CC_STATE_INPUT_REQUIRED: return lv_color_hex(UI_MAGENTA);
        case CC_STATE_CONFIRMATION_REQUIRED: return lv_color_hex(UI_VIOLET);
        case CC_STATE_SUBMIT_PENDING: return lv_color_hex(UI_VIOLET);
        case CC_STATE_SUBMIT_CONFIRM: return lv_color_hex(UI_AMBER);
        case CC_STATE_DISCONNECTED: return lv_color_hex(UI_DIM);
        default: return lv_color_hex(UI_TEAL);
    }
}

static const char *state_text(cc_device_state_t state) {
    switch (state) {
        case CC_STATE_DISCONNECTED: return "连接已断开";
        case CC_STATE_IDLE: return "Codex 就绪";
        case CC_STATE_SESSION_STARTING: return "会话启动中";
        case CC_STATE_WORKING: return "正在工作";
        case CC_STATE_COMPLETED: return "任务完成";
        case CC_STATE_ERROR: return "系统错误";
        case CC_STATE_APPROVAL_REQUIRED: return "需要审批";
        case CC_STATE_INPUT_REQUIRED: return "需要输入";
        case CC_STATE_CONFIRMATION_REQUIRED: return "长按确认";
        case CC_STATE_LISTENING: return "正在聆听";
        case CC_STATE_VOICE_ERROR: return "麦克风错误";
        case CC_STATE_WRITING: return "正在工作";
        case CC_STATE_RUNNING: return "正在工作";
        case CC_STATE_SUBMIT_PENDING: return "双击 BOOT 发送";
        case CC_STATE_SUBMIT_CONFIRM: return "再按一次发送";
    }
    return "";
}

static lv_obj_t *make_ring(lv_obj_t *parent, int diameter, lv_color_t color) {
    lv_obj_t *arc = lv_arc_create(parent);
    lv_obj_set_size(arc, diameter, diameter);
    lv_obj_center(arc);
    lv_arc_set_rotation(arc, 270);
    lv_arc_set_bg_angles(arc, 0, 360);
    lv_obj_remove_style(arc, NULL, LV_PART_KNOB);
    lv_obj_clear_flag(arc, LV_OBJ_FLAG_CLICKABLE);
    lv_obj_set_style_arc_width(arc, CC_RING_WIDTH_PX, LV_PART_MAIN);
    lv_obj_set_style_arc_width(arc, CC_RING_WIDTH_PX, LV_PART_INDICATOR);
    lv_obj_set_style_arc_color(arc, lv_color_hex(UI_RING_TRACK), LV_PART_MAIN);
    lv_obj_set_style_arc_color(arc, color, LV_PART_INDICATOR);
    return arc;
}

static void log_lvgl_memory(const char *checkpoint) {
    lv_mem_monitor_t monitor;
    lv_mem_monitor(&monitor);
    ESP_LOGI(TAG, "%s: LVGL used=%u%% free=%u largest=%u frag=%u%%",
             checkpoint, monitor.used_pct, (unsigned)monitor.free_size,
             (unsigned)monitor.free_biggest_size, monitor.frag_pct);
}

static lv_obj_t *make_sprite_pixel(lv_obj_t *parent) {
    lv_obj_t *pixel = lv_obj_create(parent);
    lv_obj_set_style_radius(pixel, 0, 0);
    lv_obj_set_style_border_width(pixel, 0, 0);
    lv_obj_set_style_pad_all(pixel, 0, 0);
    lv_obj_clear_flag(pixel, LV_OBJ_FLAG_CLICKABLE);
    return pixel;
}

static void sprite_pixel_set(int index, int x, int y, int width, int height,
                             lv_color_t color, bool visible) {
    lv_obj_t *pixel = sprite[index];
    lv_obj_set_pos(pixel, x, y);
    lv_obj_set_size(pixel, width, height);
    lv_obj_set_style_bg_color(pixel, color, 0);
    lv_obj_set_style_bg_opa(pixel, LV_OPA_COVER, 0);
    if (visible) lv_obj_remove_flag(pixel, LV_OBJ_FLAG_HIDDEN);
    else lv_obj_add_flag(pixel, LV_OBJ_FLAG_HIDDEN);
}

static void render_sprite(cc_device_state_t state, uint8_t frame) {
    const bool pulse = (frame & 1) != 0;
    const bool disconnected = state == CC_STATE_DISCONNECTED;
    const bool fault = state == CC_STATE_ERROR || state == CC_STATE_VOICE_ERROR;
    int x_offset = 0;
    int y_offset = 0;
    if (state == CC_STATE_WORKING || state == CC_STATE_WRITING ||
        state == CC_STATE_RUNNING) y_offset = pulse ? -1 : 1;
    if (state == CC_STATE_COMPLETED) y_offset = frame < 4 ? -5 : 0;
    if (fault) x_offset = pulse ? -3 : 3;
    if (state == CC_STATE_SESSION_STARTING) y_offset = frame < 6 ? 4 - frame : 0;
    lv_obj_align(face, LV_ALIGN_CENTER, x_offset, -8 + y_offset);

    // The mascot is a generated, flash-resident RGB565 pixel asset. Keep the
    // animation layer separate so lifecycle/status effects never redraw or
    // corrupt the base character.
    if (pet_image) {
        lv_obj_remove_flag(pet_image, LV_OBJ_FLAG_HIDDEN);
        lv_obj_set_style_opa(pet_image, disconnected ? LV_OPA_40 : LV_OPA_COVER, 0);
    }
    for (int i = 0; i < GLYPH_COUNT; ++i) {
        sprite_pixel_set(i, 0, 0, 0, 0, lv_color_hex(UI_INK), false);
    }
    const lv_color_t effect_color = state_color(state);
    if (state == CC_STATE_SESSION_STARTING) {
        sprite_pixel_set(GLYPH_EFFECT_0, 12, 30, 6, 6,
                         lv_color_hex(UI_BLUE), frame % 3 == 0);
        sprite_pixel_set(GLYPH_EFFECT_1, 126, 30, 6, 6,
                         lv_color_hex(UI_MINT), frame % 3 == 1);
        sprite_pixel_set(GLYPH_EFFECT_2, 18, 102, 6, 6,
                         lv_color_hex(UI_TEAL), frame % 3 == 2);
    } else if (state == CC_STATE_COMPLETED) {
        sprite_pixel_set(GLYPH_EFFECT_0, 12, 30, 8, 8,
                         lv_color_hex(pulse ? UI_MINT : UI_BLUE), true);
        sprite_pixel_set(GLYPH_EFFECT_1, 124, 42, 8, 8,
                         lv_color_hex(pulse ? UI_BLUE : UI_MINT), true);
        sprite_pixel_set(GLYPH_EFFECT_2, 20, 108, 6, 6,
                         lv_color_hex(UI_TEAL), !pulse);
    } else if (fault) {
        sprite_pixel_set(GLYPH_EFFECT_0, 6, 48, 24, 6, effect_color, pulse);
        sprite_pixel_set(GLYPH_EFFECT_1, 114, 78, 24, 6, effect_color, !pulse);
    } else if (state == CC_STATE_APPROVAL_REQUIRED ||
               state == CC_STATE_CONFIRMATION_REQUIRED ||
               state == CC_STATE_SUBMIT_PENDING ||
               state == CC_STATE_SUBMIT_CONFIRM ||
               state == CC_STATE_INPUT_REQUIRED) {
        sprite_pixel_set(GLYPH_EFFECT_0, 126, 24, 6, 18, effect_color, true);
        sprite_pixel_set(GLYPH_EFFECT_1, 126, 48, 6, 6, effect_color, pulse);
    }
}

static void make_dash_ring(lv_obj_t *parent, int ring_index, int diameter) {
    for (int i = 0; i < 24; ++i) {
        lv_obj_t *segment = lv_arc_create(parent);
        quota_dashes[ring_index][i] = segment;
        lv_obj_set_size(segment, diameter, diameter);
        lv_obj_center(segment);
        lv_arc_set_rotation(segment, 270);
        lv_arc_set_bg_angles(segment, i * 15, i * 15 + 7);
        lv_obj_remove_style(segment, NULL, LV_PART_KNOB);
        lv_obj_clear_flag(segment, LV_OBJ_FLAG_CLICKABLE);
        lv_obj_set_style_arc_width(segment, CC_RING_WIDTH_PX, LV_PART_MAIN);
        lv_obj_set_style_arc_color(segment, lv_color_hex(UI_DIM), LV_PART_MAIN);
        lv_obj_set_style_arc_opa(segment, LV_OPA_TRANSP, LV_PART_INDICATOR);
    }
}

void cc_device_ui_start(void) {
    ESP_LOGI(TAG, "starting OS UI");
    weather_load_settings();
    bsp_display_start();
    bsp_display_lock(-1);
    ui_input = bsp_display_get_input_dev();
    if (ui_input) lv_indev_enable(ui_input, false);
    lv_obj_t *screen = lv_screen_active();
    lv_obj_set_style_bg_color(screen, lv_color_hex(UI_INK), 0);
    lv_obj_set_style_bg_opa(screen, LV_OPA_COVER, 0);
    outer_arc = make_ring(screen, CC_OUTER_RING_RADIUS_PX * 2,
                          lv_color_hex(UI_BLUE));
    inner_arc = make_ring(screen, CC_INNER_RING_RADIUS_PX * 2,
                          lv_color_hex(UI_MINT));
    make_dash_ring(screen, 0, CC_OUTER_RING_RADIUS_PX * 2);
    make_dash_ring(screen, 1, CC_INNER_RING_RADIUS_PX * 2);

    os_status_bar = lv_button_create(screen);
    // Keep Codex-specific state in this compact pill. Device-wide transports
    // live in OS Settings and are intentionally not exposed as Codex menus.
    // inside the circular chord instead of losing their corners at the bezel.
    lv_obj_set_size(os_status_bar, 160, 32);
    lv_obj_align(os_status_bar, LV_ALIGN_TOP_MID, 0, 20);
    lv_obj_set_style_radius(os_status_bar, 16, 0);
    lv_obj_set_style_bg_color(os_status_bar, lv_color_hex(UI_SHELL), 0);
    lv_obj_set_style_bg_opa(os_status_bar, LV_OPA_COVER, 0);
    lv_obj_set_style_border_width(os_status_bar, 0, 0);
    lv_obj_set_style_pad_all(os_status_bar, 0, 0);
    lv_obj_remove_flag(os_status_bar, LV_OBJ_FLAG_SCROLLABLE);
    lv_obj_add_event_cb(os_status_bar, companion_button_event,
                        LV_EVENT_CLICKED, NULL);
    companion_summary_label = connection_text(os_status_bar, "0 任务", 12, 8,
                                               lv_color_hex(UI_TEAL));
    os_link_label = connection_text(os_status_bar, "离线", 110, 8,
                                    lv_color_hex(UI_AMBER));

    clock_label = lv_label_create(screen);
    lv_label_set_text(clock_label, "--:--");
    lv_obj_set_width(clock_label, 100);
    lv_obj_set_style_text_align(clock_label, LV_TEXT_ALIGN_CENTER, 0);
    lv_obj_set_style_text_font(clock_label, &cc_font_zh_14, 0);
    lv_obj_set_style_text_color(clock_label, lv_color_white(), 0);
    lv_obj_align(clock_label, LV_ALIGN_TOP_MID, 0, 60);

    quota_five_label = lv_label_create(screen);
    lv_label_set_text(quota_five_label, "5h --%");
    lv_obj_set_width(quota_five_label, 72);
    lv_obj_set_style_text_align(quota_five_label, LV_TEXT_ALIGN_CENTER, 0);
    lv_obj_set_style_text_font(quota_five_label, &cc_font_zh_14, 0);
    lv_obj_set_style_text_color(quota_five_label, lv_color_hex(UI_BLUE), 0);
    lv_obj_align(quota_five_label, LV_ALIGN_CENTER, -88, -64);
    quota_week_label = lv_label_create(screen);
    lv_label_set_text(quota_week_label, "周 --%");
    lv_obj_set_width(quota_week_label, 72);
    lv_obj_set_style_text_align(quota_week_label, LV_TEXT_ALIGN_CENTER, 0);
    lv_obj_set_style_text_font(quota_week_label, &cc_font_zh_14, 0);
    lv_obj_set_style_text_color(quota_week_label, lv_color_hex(UI_MINT), 0);
    lv_obj_align(quota_week_label, LV_ALIGN_CENTER, 88, -64);

    // Mirror every corner around the physical 180,180 display center.
    const int horizontal_x[] = {76, 266, 76, 266};
    const int horizontal_y[] = {106, 106, 252, 252};
    const int vertical_x[] = {76, 284, 76, 284};
    const int vertical_y[] = {106, 106, 236, 236};
    for (int i = 0; i < 4; ++i) {
        hud_marks[i * 2] = lv_obj_create(screen);
        lv_obj_set_pos(hud_marks[i * 2], horizontal_x[i], horizontal_y[i]);
        lv_obj_set_size(hud_marks[i * 2], 18, 2);
        lv_obj_set_style_radius(hud_marks[i * 2], 0, 0);
        lv_obj_set_style_border_width(hud_marks[i * 2], 0, 0);
        lv_obj_set_style_bg_color(hud_marks[i * 2], lv_color_hex(UI_TEAL), 0);
        lv_obj_set_style_bg_opa(hud_marks[i * 2], LV_OPA_TRANSP, 0);
        hud_marks[i * 2 + 1] = lv_obj_create(screen);
        lv_obj_set_pos(hud_marks[i * 2 + 1], vertical_x[i], vertical_y[i]);
        lv_obj_set_size(hud_marks[i * 2 + 1], 2, 18);
        lv_obj_set_style_radius(hud_marks[i * 2 + 1], 0, 0);
        lv_obj_set_style_border_width(hud_marks[i * 2 + 1], 0, 0);
        lv_obj_set_style_bg_color(hud_marks[i * 2 + 1], lv_color_hex(UI_BLUE), 0);
        lv_obj_set_style_bg_opa(hud_marks[i * 2 + 1], LV_OPA_TRANSP, 0);
    }

    face = lv_obj_create(screen);
    lv_obj_set_size(face, 144, 144);
    lv_obj_center(face);
    lv_obj_set_style_radius(face, 0, 0);
    lv_obj_set_style_bg_opa(face, LV_OPA_TRANSP, 0);
    lv_obj_set_style_border_width(face, 0, 0);
    lv_obj_set_style_pad_all(face, 0, 0);
    lv_obj_remove_flag(face, LV_OBJ_FLAG_SCROLLABLE);
    pet_image = lv_image_create(face);
    lv_image_set_src(pet_image, &cc_pixel_poop);
    lv_obj_center(pet_image);
    for (int i = 0; i < GLYPH_COUNT; ++i) sprite[i] = make_sprite_pixel(face);

    status_label = lv_label_create(screen);
    lv_obj_set_width(status_label, 230);
    lv_obj_set_style_text_align(status_label, LV_TEXT_ALIGN_CENTER, 0);
    lv_obj_set_style_text_font(status_label, &cc_font_zh_14, 0);
    lv_obj_align(status_label, LV_ALIGN_CENTER, 0, 76);
    lv_obj_set_style_bg_color(status_label, lv_color_hex(UI_SHELL), 0);
    lv_obj_set_style_bg_opa(status_label, LV_OPA_COVER, 0);
    lv_obj_set_style_radius(status_label, 18, 0);
    lv_obj_set_style_pad_left(status_label, 14, 0);
    lv_obj_set_style_pad_right(status_label, 14, 0);
    lv_obj_set_style_pad_top(status_label, 8, 0);
    lv_obj_set_style_pad_bottom(status_label, 8, 0);

    for (int i = 0; i < 13; ++i) {
        wave_bars[i] = lv_obj_create(screen);
        lv_obj_set_size(wave_bars[i], 5, 12);
        lv_obj_set_style_radius(wave_bars[i], 0, 0);
        lv_obj_set_style_border_width(wave_bars[i], 0, 0);
        lv_obj_set_style_bg_color(wave_bars[i],
            (i % 4 == 0) ? lv_color_hex(UI_MAGENTA) :
            ((i % 3) ? lv_color_hex(UI_TEAL) : lv_color_hex(UI_BLUE)), 0);
        lv_obj_align(wave_bars[i], LV_ALIGN_CENTER, (i - 6) * 10, 0);
        lv_obj_add_flag(wave_bars[i], LV_OBJ_FLAG_HIDDEN);
    }
    prompt_list = lv_obj_create(screen);
    lv_obj_set_size(prompt_list, 250, 250);
    lv_obj_align(prompt_list, LV_ALIGN_CENTER, 0, 2);
    lv_obj_set_flex_flow(prompt_list, LV_FLEX_FLOW_COLUMN);
    lv_obj_set_flex_align(prompt_list, LV_FLEX_ALIGN_START,
                          LV_FLEX_ALIGN_CENTER, LV_FLEX_ALIGN_CENTER);
    lv_obj_set_style_pad_row(prompt_list, 8, 0);
    lv_obj_set_style_pad_all(prompt_list, 12, 0);
    lv_obj_set_style_bg_color(prompt_list, lv_color_hex(UI_INK), 0);
    lv_obj_set_style_border_width(prompt_list, 0, 0);
    lv_obj_set_scroll_dir(prompt_list, LV_DIR_VER);
    lv_obj_add_flag(prompt_list, LV_OBJ_FLAG_HIDDEN);
    for (int i = 0; i < CC_PROMPT_MAX_OPTIONS; ++i) {
        prompt_buttons[i] = lv_button_create(prompt_list);
        lv_obj_set_size(prompt_buttons[i], 218, 52);
        lv_obj_set_style_radius(prompt_buttons[i], 16, 0);
        lv_obj_set_style_bg_color(prompt_buttons[i], lv_color_hex(UI_SHELL), 0);
        lv_obj_set_style_border_width(prompt_buttons[i], 0, 0);
        lv_obj_set_style_bg_color(prompt_buttons[i], lv_color_hex(UI_AMBER),
                                  LV_STATE_PRESSED);
        lv_obj_add_event_cb(prompt_buttons[i], prompt_button_event, LV_EVENT_ALL,
                            (void *)(uintptr_t)i);
        lv_obj_add_flag(prompt_buttons[i], LV_OBJ_FLAG_HIDDEN);
    }

    // The connection center uses deliberate, large touch targets. The old
    // 26px rows were too easy to mis-hit on a 360px circular display.
    connection_center = lv_obj_create(screen);
    lv_obj_set_size(connection_center, 250, 250);
    lv_obj_align(connection_center, LV_ALIGN_CENTER, 0, 2);
    lv_obj_set_style_radius(connection_center, 24, 0);
    lv_obj_set_style_bg_color(connection_center, lv_color_hex(UI_INK), 0);
    lv_obj_set_style_bg_opa(connection_center, LV_OPA_COVER, 0);
    lv_obj_set_style_border_width(connection_center, 0, 0);
    lv_obj_set_style_pad_all(connection_center, 0, 0);
    lv_obj_set_scroll_dir(connection_center, LV_DIR_VER);
    lv_obj_set_scrollbar_mode(connection_center, LV_SCROLLBAR_MODE_AUTO);
    connection_text(connection_center, "连接与网络", 14, 14,
                    lv_color_white());
    connection_text(connection_center, "蓝牙：已开启", 14, 42,
                    lv_color_hex(UI_TEAL));
    connection_mac_label = connection_text(connection_center, "主机：等待选择", 14, 64,
                                             lv_color_hex(UI_AMBER));
    connection_auth_label = connection_text(connection_center, "安全：等待配对", 14, 86,
                                              lv_color_hex(UI_AMBER));
    connection_mic_label = connection_text(connection_center, "麦克风：正在准备", 14,
                                             108, lv_color_hex(UI_AMBER));
    connection_text(connection_center, "按住 BOOT 开始语音", 14, 130,
                    lv_color_hex(UI_BLUE));
    connection_wifi_label = connection_text(connection_center, "网络：尚未配置", 14,
                                            152, lv_color_hex(UI_AMBER));
    lv_obj_set_width(connection_wifi_label, 218);
    lv_label_set_long_mode(connection_wifi_label, LV_LABEL_LONG_SCROLL_CIRCULAR);
    connection_wifi_button = lv_button_create(connection_center);
    lv_obj_set_size(connection_wifi_button, 218, 42);
    lv_obj_set_pos(connection_wifi_button, 14, 174);
    lv_obj_set_style_radius(connection_wifi_button, 16, 0);
    lv_obj_set_style_bg_color(connection_wifi_button, lv_color_hex(UI_NAVY), 0);
    lv_obj_set_style_border_width(connection_wifi_button, 0, 0);
    lv_obj_set_style_bg_color(connection_wifi_button, lv_color_hex(UI_DIM),
                              LV_STATE_PRESSED);
    lv_obj_add_event_cb(connection_wifi_button, wifi_setup_button_event,
                        LV_EVENT_CLICKED, NULL);
    lv_obj_t *connection_wifi_button_label = lv_label_create(connection_wifi_button);
    lv_label_set_text(connection_wifi_button_label, "配置 Wi-Fi（手机 / 电脑）");
    lv_obj_set_style_text_font(connection_wifi_button_label,
                               &cc_font_zh_14, 0);
    lv_obj_set_style_text_color(connection_wifi_button_label, lv_color_hex(UI_TEAL), 0);
    lv_obj_center(connection_wifi_button_label);
    connection_usb_button = lv_button_create(connection_center);
    lv_obj_set_size(connection_usb_button, 218, 46);
    lv_obj_set_pos(connection_usb_button, 14, 222);
    lv_obj_set_style_radius(connection_usb_button, 16, 0);
    lv_obj_set_style_bg_color(connection_usb_button, lv_color_hex(UI_SHELL), 0);
    lv_obj_set_style_bg_color(connection_usb_button, lv_color_hex(UI_DIM),
                              LV_STATE_PRESSED);
    lv_obj_set_style_border_width(connection_usb_button, 0, 0);
    lv_obj_add_event_cb(connection_usb_button, usb_mode_button_event,
                        LV_EVENT_ALL, NULL);
    connection_usb_button_label = lv_label_create(connection_usb_button);
    lv_obj_set_style_text_font(connection_usb_button_label,
                               &cc_font_zh_14, 0);
    lv_obj_set_style_text_color(connection_usb_button_label, lv_color_hex(UI_MINT), 0);
    lv_obj_center(connection_usb_button_label);
    connection_reset_button = lv_button_create(connection_center);
    lv_obj_set_size(connection_reset_button, 218, 42);
    lv_obj_set_pos(connection_reset_button, 14, 274);
    lv_obj_set_style_radius(connection_reset_button, 16, 0);
    lv_obj_set_style_bg_color(connection_reset_button, lv_color_hex(UI_SHELL), 0);
    lv_obj_set_style_border_width(connection_reset_button, 0, 0);
    lv_obj_set_style_bg_color(connection_reset_button, lv_color_hex(UI_DIM),
                              LV_STATE_PRESSED);
    lv_obj_add_event_cb(connection_reset_button, pairing_reset_button_event,
                        LV_EVENT_ALL, NULL);
    connection_reset_label = lv_label_create(connection_reset_button);
    lv_label_set_text(connection_reset_label, "配对其他设备（长按 2 秒）");
    lv_obj_set_style_text_font(connection_reset_label,
                               &cc_font_zh_14, 0);
    lv_obj_set_style_text_color(connection_reset_label, lv_color_hex(UI_ALARM), 0);
    lv_obj_center(connection_reset_label);
    lv_obj_add_flag(connection_center, LV_OBJ_FLAG_HIDDEN);

    app_sheet = lv_obj_create(screen);
    lv_obj_set_size(app_sheet, 250, 250);
    lv_obj_align(app_sheet, LV_ALIGN_CENTER, 0, 2);
    lv_obj_set_style_radius(app_sheet, 24, 0);
    lv_obj_set_style_bg_color(app_sheet, lv_color_hex(UI_INK), 0);
    lv_obj_set_style_bg_opa(app_sheet, LV_OPA_COVER, 0);
    lv_obj_set_style_border_width(app_sheet, 0, 0);
    lv_obj_set_style_pad_all(app_sheet, 0, 0);
    lv_obj_set_scroll_dir(app_sheet, LV_DIR_VER);
    lv_obj_set_scrollbar_mode(app_sheet, LV_SCROLLBAR_MODE_AUTO);
    app_sheet_title = connection_text(app_sheet, "语音", 18, 18,
                                      lv_color_white());
    app_sheet_detail = connection_text(app_sheet, "", 18, 50,
                                       lv_color_hex(UI_SECONDARY));
    lv_obj_set_width(app_sheet_detail, 214);
    lv_label_set_long_mode(app_sheet_detail, LV_LABEL_LONG_WRAP);
    lv_obj_set_style_text_line_space(app_sheet_detail, 8, 0);

    weather_config_button = lv_button_create(app_sheet);
    lv_obj_set_size(weather_config_button, 214, 44);
    lv_obj_set_pos(weather_config_button, 18, 188);
    lv_obj_set_style_radius(weather_config_button, 16, 0);
    lv_obj_set_style_bg_color(weather_config_button, lv_color_hex(UI_FOREST), 0);
    lv_obj_set_style_bg_color(weather_config_button, lv_color_hex(UI_DIM),
                              LV_STATE_PRESSED);
    lv_obj_set_style_border_width(weather_config_button, 0, 0);
    lv_obj_add_event_cb(weather_config_button, weather_config_event,
                        LV_EVENT_CLICKED, NULL);
    weather_config_label = lv_label_create(weather_config_button);
    lv_label_set_text(weather_config_label, "天气设置        >");
    lv_obj_set_style_text_font(weather_config_label, &cc_font_zh_14, 0);
    lv_obj_set_style_text_color(weather_config_label, lv_color_hex(UI_MINT), 0);
    lv_obj_center(weather_config_label);
    lv_obj_add_flag(weather_config_button, LV_OBJ_FLAG_HIDDEN);

    for (int i = 0; i < 3; ++i) {
        weather_option_buttons[i] = lv_button_create(app_sheet);
        lv_obj_set_size(weather_option_buttons[i], 214, 50);
        lv_obj_set_pos(weather_option_buttons[i], 18, 50 + i * 58);
        lv_obj_set_style_radius(weather_option_buttons[i], 16, 0);
        lv_obj_set_style_bg_color(weather_option_buttons[i],
                                  lv_color_hex(UI_SHELL), 0);
        lv_obj_set_style_bg_color(weather_option_buttons[i], lv_color_hex(UI_DIM),
                                  LV_STATE_PRESSED);
        lv_obj_set_style_border_width(weather_option_buttons[i], 0, 0);
        lv_obj_add_event_cb(weather_option_buttons[i], weather_option_event,
                            LV_EVENT_CLICKED, (void *)(uintptr_t)i);
        weather_option_labels[i] = lv_label_create(weather_option_buttons[i]);
        lv_obj_set_style_text_font(weather_option_labels[i], &cc_font_zh_14, 0);
        lv_obj_set_style_text_color(weather_option_labels[i], lv_color_white(), 0);
        lv_obj_align(weather_option_labels[i], LV_ALIGN_LEFT_MID, 12, 0);
        lv_obj_add_flag(weather_option_buttons[i], LV_OBJ_FLAG_HIDDEN);
    }
    update_weather_option_labels();

    const char *settings_titles[] = {
        "任务与并发        >", "用量与限额        >",
        "语音输入          >",
    };
    const uint32_t settings_colors[] = {
        UI_BLUE, UI_MINT, UI_TEAL,
    };
    for (int i = 0; i < 3; ++i) {
        settings_menu_buttons[i] = lv_button_create(app_sheet);
        lv_obj_set_size(settings_menu_buttons[i], 214, 50);
        lv_obj_set_pos(settings_menu_buttons[i], 18, 52 + i * 58);
        lv_obj_set_style_radius(settings_menu_buttons[i], 16, 0);
        lv_obj_set_style_bg_color(settings_menu_buttons[i],
                                  lv_color_hex(UI_SHELL), 0);
        lv_obj_set_style_bg_color(settings_menu_buttons[i], lv_color_hex(UI_DIM),
                                  LV_STATE_PRESSED);
        lv_obj_set_style_border_width(settings_menu_buttons[i], 0, 0);
        lv_obj_set_style_pad_all(settings_menu_buttons[i], 0, 0);
        lv_obj_add_event_cb(settings_menu_buttons[i], settings_menu_button_event,
                            LV_EVENT_CLICKED, (void *)(uintptr_t)i);
        lv_obj_t *accent = lv_obj_create(settings_menu_buttons[i]);
        lv_obj_set_size(accent, 6, 34);
        lv_obj_align(accent, LV_ALIGN_LEFT_MID, 0, 0);
        lv_obj_set_style_radius(accent, 3, 0);
        lv_obj_set_style_border_width(accent, 0, 0);
        lv_obj_set_style_bg_color(accent, lv_color_hex(settings_colors[i]), 0);
        lv_obj_set_style_pad_all(accent, 0, 0);
        lv_obj_remove_flag(accent, LV_OBJ_FLAG_SCROLLABLE);
        lv_obj_remove_flag(accent, LV_OBJ_FLAG_CLICKABLE);
        lv_obj_t *label = lv_label_create(settings_menu_buttons[i]);
        lv_label_set_text(label, settings_titles[i]);
        lv_obj_set_style_text_font(label, &cc_font_zh_14, 0);
        lv_obj_set_style_text_color(label, lv_color_white(), 0);
        lv_obj_align(label, LV_ALIGN_LEFT_MID, 20, 0);
        lv_obj_add_flag(settings_menu_buttons[i], LV_OBJ_FLAG_HIDDEN);
    }
    lv_obj_add_flag(app_sheet, LV_OBJ_FLAG_HIDDEN);

    log_lvgl_memory("before watch face");
    watch_face = lv_obj_create(screen);
    lv_obj_set_size(watch_face, 320, 320);
    lv_obj_center(watch_face);
    lv_obj_set_style_radius(watch_face, LV_RADIUS_CIRCLE, 0);
    lv_obj_set_style_bg_color(watch_face, lv_color_hex(UI_SCREEN), 0);
    lv_obj_set_style_bg_opa(watch_face, LV_OPA_COVER, 0);
    lv_obj_set_style_border_color(watch_face, lv_color_hex(UI_GRAPHITE), 0);
    lv_obj_set_style_border_width(watch_face, 3, 0);
    lv_obj_set_style_pad_all(watch_face, 0, 0);
    lv_obj_remove_flag(watch_face, LV_OBJ_FLAG_SCROLLABLE);
    // Twelve hour marks retain the watch-face silhouette without spending one
    // LVGL object on every minute subdivision. This matters because all three
    // top-level OS pages remain resident for instant swipe navigation.
    for (int i = 0; i < 12; ++i) {
        const int size = (i % 3) == 0 ? 5 : 3;
        const int angle = i * 30;
        const int x = 160 + ((lv_trigo_sin(angle + 90) * 143) >> LV_TRIGO_SHIFT);
        const int y = 160 + ((lv_trigo_sin(angle) * 143) >> LV_TRIGO_SHIFT);
        lv_obj_t *tick = lv_obj_create(watch_face);
        lv_obj_set_size(tick, size, size);
        lv_obj_set_pos(tick, x - size / 2, y - size / 2);
        lv_obj_set_style_radius(tick, LV_RADIUS_CIRCLE, 0);
        lv_obj_set_style_bg_color(tick,
            lv_color_hex((i % 3) == 0 ? UI_SECONDARY : UI_DIM), 0);
        lv_obj_set_style_border_width(tick, 0, 0);
        lv_obj_set_style_pad_all(tick, 0, 0);
        lv_obj_remove_flag(tick, LV_OBJ_FLAG_SCROLLABLE);
        lv_obj_remove_flag(tick, LV_OBJ_FLAG_CLICKABLE);
    }
    watch_weather_label = connection_text(watch_face, "天气  等待同步", 0, 66,
                                          lv_color_hex(UI_SECONDARY));
    lv_obj_set_width(watch_weather_label, 320);
    lv_obj_set_style_text_align(watch_weather_label, LV_TEXT_ALIGN_CENTER, 0);
    watch_battery_label = connection_text(watch_face, "电量 --%", 0, 40,
                                          lv_color_hex(UI_SECONDARY));
    lv_obj_set_width(watch_battery_label, 320);
    lv_obj_set_style_text_align(watch_battery_label, LV_TEXT_ALIGN_CENTER, 0);
    watch_time_label = lv_label_create(watch_face);
    lv_label_set_text(watch_time_label, "--:--");
    lv_obj_set_width(watch_time_label, 260);
    lv_obj_set_style_text_align(watch_time_label, LV_TEXT_ALIGN_CENTER, 0);
    lv_obj_set_style_text_font(watch_time_label, &lv_font_montserrat_48, 0);
    lv_obj_set_style_text_color(watch_time_label, lv_color_white(), 0);
    lv_obj_align(watch_time_label, LV_ALIGN_CENTER, 0, -18);
    watch_date_label = connection_text(watch_face, "等待时间同步", 0, 182,
                                       lv_color_hex(UI_SECONDARY));
    lv_obj_set_width(watch_date_label, 320);
    lv_obj_set_style_text_align(watch_date_label, LV_TEXT_ALIGN_CENTER, 0);
    watch_sync_label = connection_text(watch_face, "左右滑动切换", 0, 220,
                                       lv_color_hex(UI_DIM));
    lv_obj_set_width(watch_sync_label, 320);
    lv_obj_set_style_text_align(watch_sync_label, LV_TEXT_ALIGN_CENTER, 0);

    os_settings_title = lv_label_create(screen);
    lv_label_set_text(os_settings_title, "设置");
    lv_obj_set_width(os_settings_title, 120);
    lv_obj_align(os_settings_title, LV_ALIGN_TOP_MID, 0, 24);
    lv_obj_set_style_text_align(os_settings_title, LV_TEXT_ALIGN_CENTER, 0);
    lv_obj_set_style_text_font(os_settings_title, &cc_font_zh_14, 0);
    lv_obj_set_style_text_color(os_settings_title, lv_color_white(), 0);

    os_settings_launcher = lv_button_create(screen);
    lv_obj_set_size(os_settings_launcher, 112, 112);
    lv_obj_align(os_settings_launcher, LV_ALIGN_CENTER, 0, -4);
    lv_obj_set_style_radius(os_settings_launcher, LV_RADIUS_CIRCLE, 0);
    lv_obj_set_style_bg_color(os_settings_launcher, lv_color_hex(UI_SHELL), 0);
    lv_obj_set_style_bg_color(os_settings_launcher, lv_color_hex(UI_DIM),
                              LV_STATE_PRESSED);
    lv_obj_set_style_border_color(os_settings_launcher, lv_color_hex(UI_TEAL), 0);
    lv_obj_set_style_border_width(os_settings_launcher, 3, 0);
    lv_obj_add_event_cb(os_settings_launcher, os_settings_button_event,
                        LV_EVENT_CLICKED,
                        (void *)(uintptr_t)OS_APP_SETTINGS_MENU);
    lv_obj_t *settings_glyph = lv_label_create(os_settings_launcher);
    lv_label_set_text(settings_glyph, LV_SYMBOL_SETTINGS);
    lv_obj_set_style_text_font(settings_glyph, &lv_font_montserrat_48, 0);
    lv_obj_set_style_text_color(settings_glyph, lv_color_hex(UI_MINT), 0);
    lv_obj_center(settings_glyph);

    os_settings_panel = lv_obj_create(screen);
    lv_obj_set_size(os_settings_panel, 252, 258);
    lv_obj_set_pos(os_settings_panel, 54, 58);
    lv_obj_set_style_radius(os_settings_panel, 0, 0);
    lv_obj_set_style_bg_opa(os_settings_panel, LV_OPA_TRANSP, 0);
    lv_obj_set_style_border_width(os_settings_panel, 0, 0);
    lv_obj_set_style_pad_all(os_settings_panel, 0, 0);
    lv_obj_set_scroll_dir(os_settings_panel, LV_DIR_VER);
    lv_obj_set_scrollbar_mode(os_settings_panel, LV_SCROLLBAR_MODE_OFF);
    const char *system_glyphs[] = {"N", "S", "D", "I"};
    const char *system_titles[] = {
        "连接与网络", "声音与提示", "显示与表盘", "关于设备",
    };
    const char *system_details[] = {
        "USB、Wi-Fi 与蓝牙", "音量与 8-bit 音效",
        "亮度与默认表盘", "硬件与系统信息",
    };
    const os_app_t system_targets[] = {
        OS_APP_SYSTEM, OS_APP_SOUND, OS_APP_DISPLAY, OS_APP_ABOUT,
    };
    const uint32_t system_colors[] = {UI_TEAL, UI_MINT, UI_BLUE, UI_VIOLET};
    for (int i = 0; i < 4; ++i) {
        os_settings_buttons[i] = os_button(
            os_settings_panel, system_glyphs[i], system_titles[i],
            system_details[i], i * 66, system_colors[i],
            os_settings_button_event, (void *)(uintptr_t)system_targets[i]);
    }

    os_home_title = lv_label_create(screen);
    lv_label_set_text(os_home_title, "应用");
    lv_obj_set_width(os_home_title, 120);
    lv_obj_align(os_home_title, LV_ALIGN_TOP_MID, 0, 24);
    lv_obj_set_style_text_align(os_home_title, LV_TEXT_ALIGN_CENTER, 0);
    lv_obj_set_style_text_font(os_home_title, &cc_font_zh_14, 0);
    lv_obj_set_style_text_color(os_home_title, lv_color_white(), 0);

    os_dock = lv_obj_create(screen);
    lv_obj_set_size(os_dock, 252, 258);
    lv_obj_set_pos(os_dock, 54, 58);
    lv_obj_set_style_radius(os_dock, 0, 0);
    lv_obj_set_style_bg_opa(os_dock, LV_OPA_TRANSP, 0);
    lv_obj_set_style_border_width(os_dock, 0, 0);
    lv_obj_set_style_pad_all(os_dock, 0, 0);
    lv_obj_set_scroll_dir(os_dock, LV_DIR_VER);
    lv_obj_set_scrollbar_mode(os_dock, LV_SCROLLBAR_MODE_OFF);
    const char *app_glyphs[] = {"C", "W", "M", "+"};
    const char *app_titles[] = {"Codex", "天气", "音乐", "工具"};
    const os_app_t app_targets[] = {
        OS_APP_CODEX, OS_APP_WEATHER, OS_APP_MUSIC, OS_APP_TOOLS,
    };
    const uint32_t app_colors[] = {UI_BLUE, UI_MINT, UI_TEAL, UI_VIOLET};
    for (int i = 0; i < 4; ++i) {
        os_app_buttons[i] = os_grid_button(
            os_dock, app_glyphs[i], app_titles[i], i % 2, i / 2,
            app_colors[i], os_app_button_event,
            (void *)(uintptr_t)app_targets[i]);
    }
    lv_obj_add_event_cb(screen, navigation_gesture_event, LV_EVENT_GESTURE, NULL);
    show_os_app(OS_APP_WATCH);
    log_lvgl_memory("OS UI ready");
    // Render the complete first frame while the backlight is still off. This
    // prevents the ST77916's cleared white GRAM from being exposed between
    // panel initialization and the first LVGL flush.
    lv_refr_now(NULL);
    if (ui_input) {
        lv_timer_t *input_timer = lv_timer_create(enable_input_after_startup,
                                                   UI_INPUT_STARTUP_GUARD_MS,
                                                   ui_input);
        if (input_timer) lv_timer_set_repeat_count(input_timer, 1);
    }
    bsp_display_unlock();
    bsp_display_backlight_on();
    last_ui_activity_ms = (uint64_t)(esp_timer_get_time() / 1000);
    display_dimmed = false;
    ui_started = true;
    ESP_LOGI(TAG, "OS UI started");
}

void cc_device_ui_power_tick(uint64_t now_ms, bool external_activity) {
    if (!ui_started) return;
    bsp_display_lock(-1);
    const bool touch_pressed = ui_input &&
        lv_indev_get_state(ui_input) == LV_INDEV_STATE_PRESSED;
    const bool active = external_activity || touch_pressed;
    if (active) {
        last_ui_activity_ms = now_ms;
        if (display_dimmed) {
            (void)bsp_display_brightness_set(UI_ACTIVE_BRIGHTNESS);
            display_dimmed = false;
            ESP_LOGI(TAG, "display restored after activity");
        }
    } else if (!display_dimmed &&
               now_ms - last_ui_activity_ms >= UI_IDLE_DIM_MS) {
        // Never turn the panel fully black: it must remain visibly alive and
        // a touch should not look like it is trying to revive a dead device.
        (void)bsp_display_brightness_set(UI_IDLE_BRIGHTNESS);
        display_dimmed = true;
        ESP_LOGI(TAG, "display dimmed to %d%% after idle", UI_IDLE_BRIGHTNESS);
    }
    bsp_display_unlock();
}

void cc_device_ui_update_battery(bool valid, uint8_t percent, bool charging) {
    if (!watch_battery_label ||
        (battery_rendered_valid == valid &&
         (!valid || (battery_rendered_percent == percent &&
                     battery_rendered_charging == charging)))) return;
    bsp_display_lock(-1);
    char text[24];
    if (!valid) {
        snprintf(text, sizeof(text), "电量 --%%");
    } else if (charging) {
        snprintf(text, sizeof(text), "充电 %u%%", percent);
    } else {
        snprintf(text, sizeof(text), "电量 %u%%", percent);
    }
    lv_label_set_text(watch_battery_label, text);
    lv_obj_set_style_text_color(
        watch_battery_label,
        lv_color_hex(!valid ? UI_SECONDARY :
                     charging ? UI_MINT :
                     percent <= 15 ? UI_ALARM : UI_SECONDARY), 0);
    battery_rendered_valid = valid;
    battery_rendered_percent = percent;
    battery_rendered_charging = charging;
    bsp_display_unlock();
}

void cc_device_ui_set_usb_uac_mode(bool enabled,
                                   cc_usb_mode_selection_fn selection_callback) {
    bsp_display_lock(-1);
    usb_uac_enabled = enabled;
    on_usb_mode_selection = selection_callback;
    if (connection_usb_button_label) {
        lv_label_set_text(connection_usb_button_label,
                          enabled ? "USB 麦克风已开启（长按关闭并重启）"
                                  : "开启 USB 麦克风（长按后重启）");
    }
    if (connection_mic_label) {
        lv_label_set_text(connection_mic_label,
                          enabled ? "麦克风：USB 输入已开启" : "麦克风：蓝牙 / USB 就绪");
        lv_obj_set_style_text_color(connection_mic_label,
                                    enabled ? lv_color_hex(UI_MINT) : lv_color_hex(UI_TEAL), 0);
    }
    bsp_display_unlock();
}

void cc_device_ui_set_wifi_setup(cc_wifi_setup_fn setup_callback) {
    on_wifi_setup = setup_callback;
}

void cc_device_ui_set_wifi_status(const char *status) {
    if (!connection_wifi_label || !status) return;
    bsp_display_lock(-1);
    lv_label_set_text(connection_wifi_label, status);
    lv_obj_set_style_text_color(connection_wifi_label,
                                strstr(status, "已连接") ? lv_color_hex(UI_MINT) :
                                (strstr(status, "失败") ? lv_color_hex(UI_ALARM) :
                                 lv_color_hex(UI_AMBER)), 0);
    bsp_display_unlock();
}

void cc_device_ui_set_paired_host(const char *display_name) {
    if (!display_name) display_name = "";
    bsp_display_lock(-1);
    snprintf(paired_host_name, sizeof(paired_host_name), "%s", display_name);
    connection_render_initialized = false;
    bsp_display_unlock();
}

void cc_device_ui_set_pairing_reset(cc_pairing_reset_fn reset_callback) {
    on_pairing_reset = reset_callback;
}

static void set_quota(lv_obj_t *arc, cc_quota_value_t quota, int ring_index) {
    if (quota.available) {
        lv_obj_remove_flag(arc, LV_OBJ_FLAG_HIDDEN);
        for (int i = 0; i < 24; ++i) {
            lv_obj_add_flag(quota_dashes[ring_index][i], LV_OBJ_FLAG_HIDDEN);
        }
        lv_obj_set_style_arc_color(arc, lv_color_hex(UI_RING_TRACK), LV_PART_MAIN);
        lv_obj_set_style_arc_opa(arc, LV_OPA_COVER, LV_PART_INDICATOR);
        lv_arc_set_value(arc, quota.percent);
    } else {
        // Keep the visual language aligned with the Mac preview: absent quota
        // data leaves a continuous, low-key ring rather than switching to
        // dashes. The companion still never invents a percentage.
        lv_obj_remove_flag(arc, LV_OBJ_FLAG_HIDDEN);
        for (int i = 0; i < 24; ++i) {
            lv_obj_add_flag(quota_dashes[ring_index][i], LV_OBJ_FLAG_HIDDEN);
        }
        lv_obj_set_style_arc_color(arc, lv_color_hex(UI_DIM), LV_PART_MAIN);
        lv_obj_set_style_arc_opa(arc, LV_OPA_TRANSP, LV_PART_INDICATOR);
        lv_arc_set_value(arc, 0);
    }
}

void cc_device_ui_enqueue_task_event(cc_task_event_t event) {
    if (event != CC_TASK_EVENT_STARTED && event != CC_TASK_EVENT_COMPLETED) return;
    if (active_os_app != OS_APP_CODEX) return;
    if (task_event_count == TASK_EVENT_QUEUE_CAPACITY) {
        // Keep the queue bounded but prefer the newest real lifecycle event if
        // the Mac catches up after a long disconnect.
        task_event_head = (uint8_t)((task_event_head + 1) % TASK_EVENT_QUEUE_CAPACITY);
        --task_event_count;
    }
    const uint8_t tail = (uint8_t)((task_event_head + task_event_count) %
                                   TASK_EVENT_QUEUE_CAPACITY);
    task_event_queue[tail] = event;
    ++task_event_count;
}

static void advance_task_event(int64_t now_us) {
    if (task_event_active &&
        now_us - task_event_started_at >= TASK_EVENT_ANIMATION_US) {
        task_event_active = false;
    }
    if (!task_event_active && task_event_count > 0) {
        active_task_event = task_event_queue[task_event_head];
        task_event_head = (uint8_t)((task_event_head + 1) % TASK_EVENT_QUEUE_CAPACITY);
        --task_event_count;
        task_event_active = true;
        task_event_started_at = now_us;
    }
}

static void render_watch_clock_if_needed(void) {
    const time_t epoch = time(NULL);
    const bool time_valid = epoch >= 1577836800;
    const time_t minute = time_valid ? epoch / 60 : 0;
    if (watch_rendered_minute == minute) return;
    watch_rendered_minute = minute;

    if (time_valid) {
        const time_t china_epoch = epoch + 8 * 60 * 60;
        struct tm clock_time;
        gmtime_r(&china_epoch, &clock_time);
        char time_text[8];
        char date_text[40];
        const char *weekdays[] = {
            "周日", "周一", "周二", "周三", "周四", "周五", "周六",
        };
        strftime(time_text, sizeof(time_text), "%H:%M", &clock_time);
        snprintf(date_text, sizeof(date_text), "%s | %02d.%02d.%02d",
                 weekdays[clock_time.tm_wday],
                 (clock_time.tm_year + 1900) % 100,
                 clock_time.tm_mon + 1, clock_time.tm_mday);
        lv_label_set_text(watch_time_label, time_text);
        lv_label_set_text(watch_date_label, date_text);
        lv_label_set_text(watch_sync_label, "左右滑动切换");
    } else {
        lv_label_set_text(watch_time_label, "--:--");
        lv_label_set_text(watch_date_label, "等待时间同步");
        lv_label_set_text(watch_sync_label, "连接主机后自动校时");
    }
}

static void render_connection_center_if_needed(const cc_device_model_t *model) {
    if (!connection_center_visible || !model) return;
    if (connection_render_initialized &&
        connection_rendered_connected == model->connected &&
        strcmp(connection_rendered_host, paired_host_name) == 0) {
        return;
    }

    char host_status[96];
    if (paired_host_name[0] != '\0') {
        snprintf(host_status, sizeof(host_status), "主机：%s%s",
                 paired_host_name, model->connected ? " 已连接" : " 未连接");
    } else {
        snprintf(host_status, sizeof(host_status), "主机：%s",
                 model->connected ? "已连接" : "等待选择");
    }
    lv_label_set_text(connection_mac_label, host_status);
    lv_obj_set_style_text_color(connection_mac_label,
        model->connected ? lv_color_hex(UI_MINT) : lv_color_hex(UI_ALARM), 0);
    lv_label_set_text(connection_auth_label,
                      model->connected ? "安全：已加密" : "安全：等待配对");
    lv_obj_set_style_text_color(connection_auth_label,
        model->connected ? lv_color_hex(UI_TEAL) : lv_color_hex(UI_AMBER), 0);

    connection_rendered_connected = model->connected;
    snprintf(connection_rendered_host, sizeof(connection_rendered_host), "%s",
             paired_host_name);
    connection_render_initialized = true;
}

static bool quota_equal(cc_quota_value_t left, cc_quota_value_t right) {
    return left.available == right.available && left.percent == right.percent;
}

static bool sprite_state_is_animated(cc_device_state_t state,
                                     bool lifecycle_visible) {
    if (lifecycle_visible) return true;
    switch (state) {
        case CC_STATE_WORKING:
        case CC_STATE_ERROR:
        case CC_STATE_APPROVAL_REQUIRED:
        case CC_STATE_INPUT_REQUIRED:
        case CC_STATE_CONFIRMATION_REQUIRED:
        case CC_STATE_VOICE_ERROR:
        case CC_STATE_WRITING:
        case CC_STATE_RUNNING:
        case CC_STATE_SUBMIT_PENDING:
        case CC_STATE_SUBMIT_CONFIRM:
            return true;
        default:
            return false;
    }
}

void cc_device_ui_render(const cc_device_model_t *model, uint16_t audio_level) {
    bsp_display_lock(-1);
    const int64_t now_us = esp_timer_get_time();
    const bool in_codex_app = active_os_app == OS_APP_CODEX &&
                              active_codex_page == CODEX_PAGE_HOME;
    if (active_os_app == OS_APP_WATCH) {
        // A watch face changes once per minute. Rewriting every label and every
        // hidden Codex object at 12 fps caused needless full-screen SPI traffic
        // that presented as a white refresh flash on the physical panel.
        render_watch_clock_if_needed();
        bsp_display_unlock();
        return;
    }
    if (active_os_app == OS_APP_SYSTEM) {
        // Connection Center is event-driven. Rewriting its labels and all of
        // the hidden Codex objects at 12 fps invalidated most of the circular
        // display and appeared as a continuous white refresh after pairing.
        render_connection_center_if_needed(model);
        bsp_display_unlock();
        return;
    }
    if (active_os_app != OS_APP_CODEX) {
        // The app drawer, OS settings and placeholder apps are static until a
        // gesture or click changes them, so they require no periodic mutation.
        bsp_display_unlock();
        return;
    }
    advance_task_event(now_us);
    const bool lifecycle_event_visible = task_event_active && in_codex_app &&
                                         !prompt_visible &&
                                         model->visible_state != CC_STATE_LISTENING;
    const cc_device_state_t visual_state = lifecycle_event_visible
        ? (active_task_event == CC_TASK_EVENT_STARTED ? CC_STATE_SESSION_STARTING
                                                       : CC_STATE_COMPLETED)
        : model->visible_state;
    const bool quota_stale = cc_device_quota_is_stale(
        model, (uint64_t)(now_us / 1000));
    const bool cache_reset = !codex_render_cache.initialized ||
                             codex_render_cache.page != active_codex_page;
    const bool quota_changed = cache_reset ||
        !quota_equal(codex_render_cache.five_hour, model->five_hour) ||
        !quota_equal(codex_render_cache.week, model->week) ||
        codex_render_cache.quota_stale != quota_stale;
    if (in_codex_app && quota_changed) {
        set_quota(outer_arc, model->five_hour, 0);
        set_quota(inner_arc, model->week, 1);
        char five_text[16];
        char week_text[16];
        if (model->five_hour.available) {
            snprintf(five_text, sizeof(five_text), "5h %u%%",
                     model->five_hour.percent);
        } else {
            snprintf(five_text, sizeof(five_text), "5h --%%");
        }
        if (model->week.available) {
            snprintf(week_text, sizeof(week_text), "周 %u%%",
                     model->week.percent);
        } else {
            snprintf(week_text, sizeof(week_text), "周 --%%");
        }
        lv_label_set_text(quota_five_label, five_text);
        lv_label_set_text(quota_week_label, week_text);
        const lv_opa_t quota_opacity = quota_stale ? LV_OPA_40 : LV_OPA_COVER;
        lv_obj_set_style_opa(outer_arc, quota_opacity, LV_PART_MAIN);
        lv_obj_set_style_opa(outer_arc, quota_opacity, LV_PART_INDICATOR);
        lv_obj_set_style_opa(inner_arc, quota_opacity, LV_PART_MAIN);
        lv_obj_set_style_opa(inner_arc, quota_opacity, LV_PART_INDICATOR);
        lv_obj_set_style_opa(quota_five_label, quota_opacity, 0);
        lv_obj_set_style_opa(quota_week_label, quota_opacity, 0);
    } else if (!in_codex_app && cache_reset) {
        set_codex_rings_visible(false);
    }
    const uint8_t frame = (uint8_t)((now_us / 83333) % 12);
    const bool status_changed = cache_reset ||
        codex_render_cache.visual_state != visual_state ||
        codex_render_cache.lifecycle_visible != lifecycle_event_visible ||
        (lifecycle_event_visible &&
         codex_render_cache.lifecycle_event != active_task_event) ||
        codex_render_cache.active_tasks != model->active_tasks;
    if (status_changed) {
        lv_obj_set_style_text_color(status_label, state_color(visual_state), 0);
        char status[72];
        if (lifecycle_event_visible) {
            lv_label_set_text(status_label,
                              active_task_event == CC_TASK_EVENT_STARTED
                                  ? "任务开始" : "处理完成");
        } else if (model->active_tasks > 1 &&
                   model->visible_state != CC_STATE_LISTENING &&
                   model->visible_state != CC_STATE_SUBMIT_PENDING &&
                   model->visible_state != CC_STATE_SUBMIT_CONFIRM) {
            snprintf(status, sizeof(status), "%u 个任务 · %s",
                     model->active_tasks, state_text(model->visible_state));
            lv_label_set_text(status_label, status);
        } else {
            lv_label_set_text(status_label, state_text(model->visible_state));
        }
    }
    if (companion_summary_label &&
        (cache_reset || codex_render_cache.active_tasks != model->active_tasks ||
         codex_render_cache.attention_tasks != model->attention_tasks)) {
        if (model->active_tasks > 0) {
            char summary[24];
            snprintf(summary, sizeof(summary), "%u 任务", model->active_tasks);
            lv_label_set_text(companion_summary_label, summary);
        } else {
            lv_label_set_text(companion_summary_label, "就绪");
        }
        lv_obj_set_style_text_color(companion_summary_label,
            model->attention_tasks > 0 ? lv_color_hex(UI_AMBER) :
                                         lv_color_hex(UI_TEAL), 0);
    }
    if (os_link_label &&
        (cache_reset || codex_render_cache.connected != model->connected)) {
        lv_label_set_text(os_link_label, model->connected ? "在线" : "离线");
        lv_obj_set_style_text_color(os_link_label,
            model->connected ? lv_color_hex(UI_MINT) : lv_color_hex(UI_AMBER), 0);
    }
    if (clock_label && in_codex_app) {
        const time_t epoch = time(NULL);
        const time_t minute = epoch >= 1577836800 ? epoch / 60 : 0;
        if ((cache_reset || codex_render_cache.clock_minute != minute) &&
            epoch >= 1577836800) {
            const time_t china_epoch = epoch + 8 * 60 * 60;
            struct tm clock_time;
            gmtime_r(&china_epoch, &clock_time);
            char clock_text[8];
            strftime(clock_text, sizeof(clock_text), "%H:%M", &clock_time);
            lv_label_set_text(clock_label, clock_text);
        }
    }
    const bool task_detail_changed = cache_reset ||
        codex_render_cache.active_tasks != model->active_tasks ||
        codex_render_cache.attention_tasks != model->attention_tasks ||
        codex_render_cache.recent_completed_tasks != model->recent_completed_tasks ||
        codex_render_cache.visual_state != visual_state;
    if (active_codex_page == CODEX_PAGE_TASKS && task_detail_changed) {
        char detail[160];
        snprintf(detail, sizeof(detail),
                 "活动对话        %u\n需要处理        %u\n刚刚完成        %u\n\n%s",
                 model->active_tasks, model->attention_tasks,
                 model->recent_completed_tasks, state_text(model->visible_state));
        lv_label_set_text(app_sheet_detail, detail);
    } else if (active_codex_page == CODEX_PAGE_USAGE && quota_changed) {
        char detail[176];
        char five[12] = "暂无";
        char week[12] = "暂无";
        if (model->five_hour.available) {
            snprintf(five, sizeof(five), "%u%%", model->five_hour.percent);
        }
        if (model->week.available) {
            snprintf(week, sizeof(week), "%u%%", model->week.percent);
        }
        snprintf(detail, sizeof(detail),
                 "5 小时窗口\n剩余 %s\n\n每周窗口\n剩余 %s",
                 five, week);
        lv_label_set_text(app_sheet_detail, detail);
    }
    const bool listening = active_os_app == OS_APP_CODEX &&
                           model->visible_state == CC_STATE_LISTENING;
    const bool home_visible = active_os_app == OS_APP_CODEX &&
                              active_codex_page == CODEX_PAGE_HOME &&
                              !listening && !prompt_visible;
    const bool visibility_changed = cache_reset ||
        codex_render_cache.listening != listening ||
        codex_render_cache.prompt_visible != prompt_visible;
    if (visibility_changed) {
        if (home_visible) {
            lv_obj_remove_flag(face, LV_OBJ_FLAG_HIDDEN);
            lv_obj_remove_flag(status_label, LV_OBJ_FLAG_HIDDEN);
        } else {
            lv_obj_add_flag(face, LV_OBJ_FLAG_HIDDEN);
            if (!listening && !prompt_visible) {
                lv_obj_add_flag(status_label, LV_OBJ_FLAG_HIDDEN);
            }
        }
        if (listening) {
            lv_obj_remove_flag(status_label, LV_OBJ_FLAG_HIDDEN);
            lv_obj_move_foreground(status_label);
        }
    }
    const bool sprite_animated = sprite_state_is_animated(
        visual_state, lifecycle_event_visible);
    if (!prompt_visible && !listening && in_codex_app &&
        (cache_reset || codex_render_cache.visual_state != visual_state ||
         (sprite_animated && codex_render_cache.sprite_frame != frame))) {
        render_sprite(visual_state, frame);
    }
    if (listening) {
        for (int i = 0; i < 13; ++i) {
            lv_obj_remove_flag(wave_bars[i], LV_OBJ_FLAG_HIDDEN);
            const uint16_t shape = (uint16_t)(26 + ((i * 37 + audio_level) % 72));
            const int height = 8 + (int)(shape * audio_level / 1000);
            lv_obj_set_height(wave_bars[i], height);
            lv_obj_move_foreground(wave_bars[i]);
        }
    } else if (visibility_changed) {
        for (int i = 0; i < 13; ++i) {
            lv_obj_add_flag(wave_bars[i], LV_OBJ_FLAG_HIDDEN);
        }
    }
    codex_render_cache = (codex_render_cache_t) {
        .initialized = true,
        .page = active_codex_page,
        .prompt_visible = prompt_visible,
        .lifecycle_visible = lifecycle_event_visible,
        .lifecycle_event = active_task_event,
        .visual_state = visual_state,
        .connected = model->connected,
        .five_hour = model->five_hour,
        .week = model->week,
        .quota_stale = quota_stale,
        .active_tasks = model->active_tasks,
        .attention_tasks = model->attention_tasks,
        .recent_completed_tasks = model->recent_completed_tasks,
        .listening = listening,
        .clock_minute = time(NULL) >= 1577836800 ? time(NULL) / 60 : 0,
        .sprite_frame = frame,
    };
    bsp_display_unlock();
}

void cc_device_ui_show_prompt(const cc_prompt_payload_t *prompt,
                              cc_prompt_selection_fn selection_callback) {
    if (!prompt) return;
    bsp_display_lock(-1);
    pending_prompt = *prompt;
    prompt_pending = true;
    on_prompt_selection = selection_callback;
    if (active_os_app == OS_APP_CODEX) {
        show_pending_prompt_locked();
    } else {
        ESP_LOGI(TAG, "Codex prompt %lu deferred until app opens",
                 (unsigned long)prompt->id);
    }
    bsp_display_unlock();
}

void cc_device_ui_close_prompt(void) {
    bsp_display_lock(-1);
    prompt_visible = false;
    prompt_pending = false;
    on_prompt_selection = NULL;
    lv_obj_add_flag(prompt_list, LV_OBJ_FLAG_HIDDEN);
    for (uint8_t i = 0; i < CC_PROMPT_MAX_OPTIONS; ++i) {
        lv_obj_add_flag(prompt_buttons[i], LV_OBJ_FLAG_HIDDEN);
    }
    lv_obj_align(status_label, LV_ALIGN_CENTER, 0, 76);
    lv_obj_remove_flag(os_dock, LV_OBJ_FLAG_HIDDEN);
    show_os_app(active_os_app);
    bsp_display_unlock();
}

void cc_device_ui_update_weather(const char *city,
                                 int16_t temperature_tenths_celsius,
                                 uint8_t next_weather_code) {
    if (!city || city[0] == '\0') return;
    bsp_display_lock(-1);
    snprintf(weather_city, sizeof(weather_city), "%s", city);
    weather_temperature_tenths_celsius = temperature_tenths_celsius;
    weather_code = next_weather_code;
    weather_data_valid = true;
    update_watch_weather_label();
    if (active_os_app == OS_APP_WEATHER && !weather_settings_visible) {
        show_weather_home();
    }
    bsp_display_unlock();
}

void cc_device_ui_apply_weather_settings(bool enabled, bool uses_celsius,
                                         uint8_t refresh_minutes) {
    bsp_display_lock(-1);
    weather_sync_enabled = enabled;
    weather_celsius = uses_celsius;
    weather_refresh_index = weather_refresh_index_for_minutes(refresh_minutes);
    weather_save_settings();
    update_weather_option_labels();
    update_watch_weather_label();
    if (active_os_app == OS_APP_WEATHER && !weather_settings_visible) {
        show_weather_home();
    }
    bsp_display_unlock();
}

void cc_device_ui_set_weather_settings_callback(
    cc_weather_settings_fn settings_callback) {
    on_weather_settings = settings_callback;
}

bool cc_device_ui_codex_voice_available(void) {
    return active_os_app == OS_APP_CODEX && !prompt_visible;
}

bool cc_device_ui_codex_app_active(void) {
    return active_os_app == OS_APP_CODEX;
}

void cc_device_ui_set_codex_visibility_callback(
    cc_codex_visibility_fn visibility_callback) {
    on_codex_visibility = visibility_callback;
    if (on_codex_visibility) {
        on_codex_visibility(active_os_app == OS_APP_CODEX);
    }
}
