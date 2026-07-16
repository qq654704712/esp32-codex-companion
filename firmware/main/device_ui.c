#include "device_ui.h"

#include <string.h>

#include "bsp/esp-bsp.h"
#include "generated/cc_font_zh_14.h"
#include "esp_timer.h"
#include "lvgl.h"

static lv_obj_t *outer_arc;
static lv_obj_t *inner_arc;
static lv_obj_t *quota_dashes[2][24];
static lv_obj_t *face;
static lv_obj_t *status_label;
static lv_obj_t *wave_bars[13];
static lv_obj_t *hud_marks[8];
static lv_obj_t *prompt_buttons[CC_PROMPT_MAX_OPTIONS];
static lv_obj_t *prompt_list;
static lv_obj_t *connection_handle;
static lv_obj_t *connection_center;
static lv_obj_t *connection_mac_label;
static lv_obj_t *connection_auth_label;
static lv_obj_t *connection_mic_label;
static lv_obj_t *connection_wifi_label;
static lv_obj_t *connection_usb_button;
static lv_obj_t *connection_usb_button_label;
static lv_obj_t *connection_wifi_button;
static lv_obj_t *connection_reset_button;
static bool prompt_requires_hold[CC_PROMPT_MAX_OPTIONS];
static int64_t prompt_press_started[CC_PROMPT_MAX_OPTIONS];
static uint32_t prompt_id;
static bool prompt_visible;
static bool connection_center_visible;
static cc_prompt_selection_fn on_prompt_selection;
static cc_usb_mode_selection_fn on_usb_mode_selection;
static cc_wifi_setup_fn on_wifi_setup;
static cc_pairing_reset_fn on_pairing_reset;
static bool usb_uac_enabled;
static int64_t usb_mode_pressed_at;
static int64_t pairing_reset_pressed_at;

enum {
    GLYPH_PROMPT_TOP,
    GLYPH_PROMPT_SIDE,
    GLYPH_PROMPT_BOTTOM,
    GLYPH_TOOL_TOP,
    GLYPH_TOOL_SIDE,
    GLYPH_TOOL_BOTTOM,
    GLYPH_PATCH_TOP,
    GLYPH_PATCH_SIDE,
    GLYPH_PATCH_BOTTOM,
    GLYPH_CONTEXT_TOP,
    GLYPH_CONTEXT_SIDE,
    GLYPH_CONTEXT_BOTTOM,
    GLYPH_CORE,
    GLYPH_CARET_TOP,
    GLYPH_CARET_SIDE,
    GLYPH_TOKEN_0,
    GLYPH_TOKEN_1,
    GLYPH_TOKEN_2,
    GLYPH_TOKEN_3,
    GLYPH_AUX_0,
    GLYPH_AUX_1,
    GLYPH_EFFECT_0,
    GLYPH_EFFECT_1,
    GLYPH_EFFECT_2,
    GLYPH_EFFECT_3,
    GLYPH_EFFECT_4,
    GLYPH_EFFECT_5,
    GLYPH_COUNT,
};

static lv_obj_t *sprite[GLYPH_COUNT];

#define UI_INK 0x010203
#define UI_NAVY 0x041321
#define UI_FOREST 0x072D12
#define UI_TEAL 0x00D1B8
#define UI_BLUE 0x1A94FF
#define UI_MINT 0x9EEF33
#define UI_AMBER 0xFF661F
#define UI_ALARM 0xFF3847
// Keep accent colors in the requested navy / green / cyan family. The names
// remain for state routing compatibility, but neither resolves to purple.
#define UI_MAGENTA 0x00B8C8
#define UI_VIOLET 0x4EE28A
#define UI_DIM 0x172833
#define UI_RING_TRACK 0x142933
#define UI_GRAPHITE 0x333F47
#define UI_SHELL 0x0E1215
#define UI_SCREEN 0x020304
#define UI_SIGNAL 0xFF4055

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

static void connection_center_event(lv_event_t *event) {
    if (lv_event_get_code(event) != LV_EVENT_CLICKED || !connection_center) return;
    // A child-button click can bubble through the panel. Only the Connection
    // handle or the empty panel itself may open/close the center.
    const lv_obj_t *target = lv_event_get_target(event);
    if (target != connection_center && target != connection_handle) return;
    connection_center_visible = !connection_center_visible;
    if (connection_center_visible) {
        lv_obj_remove_flag(connection_center, LV_OBJ_FLAG_HIDDEN);
        lv_obj_move_foreground(connection_center);
    } else {
        lv_obj_add_flag(connection_center, LV_OBJ_FLAG_HIDDEN);
        lv_obj_move_foreground(connection_handle);
    }
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
    } else if (code == LV_EVENT_RELEASED && on_pairing_reset &&
               (esp_timer_get_time() - pairing_reset_pressed_at) >= 2000000) {
        on_pairing_reset();
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

static lv_color_t state_color(cc_device_state_t state) {
    switch (state) {
        case CC_STATE_COMPLETED: return lv_color_hex(UI_MINT);
        case CC_STATE_ERROR:
        case CC_STATE_VOICE_ERROR: return lv_color_hex(UI_ALARM);
        case CC_STATE_WRITING: return lv_color_hex(UI_MINT);
        case CC_STATE_RUNNING: return lv_color_hex(UI_TEAL);
        case CC_STATE_APPROVAL_REQUIRED: return lv_color_hex(UI_AMBER);
        case CC_STATE_INPUT_REQUIRED: return lv_color_hex(UI_MAGENTA);
        case CC_STATE_CONFIRMATION_REQUIRED: return lv_color_hex(UI_VIOLET);
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
        case CC_STATE_WRITING: return "正在输入";
        case CC_STATE_RUNNING: return "正在运行";
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
    if (state == CC_STATE_WORKING) y_offset = pulse ? -1 : 1;
    if (state == CC_STATE_COMPLETED) y_offset = frame < 4 ? -5 : 0;
    if (fault) x_offset = pulse ? -3 : 3;
    if (state == CC_STATE_SESSION_STARTING) y_offset = frame < 6 ? 4 - frame : 0;
    lv_obj_align(face, LV_ALIGN_CENTER, x_offset, -8 + y_offset);

    // Screen-first pocket terminal pet. The dark shell is intentionally calm;
    // the saturated colors live in the HUD and in a single status signal.
    const lv_color_t outline = lv_color_hex(disconnected ? UI_DIM : UI_GRAPHITE);
    const lv_color_t casing = lv_color_hex(disconnected ? UI_NAVY : UI_SHELL);
    const lv_color_t screen_edge = lv_color_hex(disconnected ? UI_DIM : UI_GRAPHITE);
    const lv_color_t signal = lv_color_hex(disconnected ? UI_DIM : UI_SIGNAL);
    sprite_pixel_set(GLYPH_PROMPT_TOP, 60, 6, 6, 12, outline, true);
    sprite_pixel_set(GLYPH_PROMPT_SIDE, 66, 0, 12, 6, outline, true);
    sprite_pixel_set(GLYPH_PROMPT_BOTTOM, 72, 6, 6, 12, outline, true);
    sprite_pixel_set(GLYPH_TOOL_TOP, 42, 18, 60, 6, outline, true);
    sprite_pixel_set(GLYPH_TOOL_SIDE, 30, 24, 84, 6, outline, true);
    sprite_pixel_set(GLYPH_TOOL_BOTTOM, 24, 30, 6, 60, outline, true);
    // Keep the right outline outside the x=30..114 casing fill.  The prior
    // x=108 placement was overpainted by GLYPH_CONTEXT_TOP on real hardware.
    sprite_pixel_set(GLYPH_PATCH_TOP, 114, 30, 6, 60, outline, true);
    sprite_pixel_set(GLYPH_PATCH_SIDE, 30, 90, 84, 12, outline, true);
    sprite_pixel_set(GLYPH_PATCH_BOTTOM, 42, 102, 60, 6, outline, true);
    sprite_pixel_set(GLYPH_CONTEXT_TOP, 30, 30, 84, 60, casing, true);
    sprite_pixel_set(GLYPH_CONTEXT_SIDE, 36, 90, 72, 6, casing, true);
    sprite_pixel_set(GLYPH_CONTEXT_BOTTOM, 36, 36, 72, 42, screen_edge, true);
    sprite_pixel_set(GLYPH_CORE, 42, 42, 60, 30, lv_color_hex(UI_SCREEN), true);
    sprite_pixel_set(GLYPH_CARET_TOP, 18, 48, 6, 24, outline, true);
    sprite_pixel_set(GLYPH_CARET_SIDE, 120, 48, 6, 24, outline, true);

    // The permanent casing stays intact. State animation is drawn in its own
    // layer, matching the Mac scene's overlay model instead of replacing the
    // pet's screen, LED, or underframe.
    for (int i = GLYPH_EFFECT_0; i < GLYPH_COUNT; ++i) {
        sprite_pixel_set(i, 0, 0, 0, 0, lv_color_hex(UI_INK), false);
    }
    // Two little underframe pads and a single warm status LED.
    sprite_pixel_set(GLYPH_TOKEN_0, 42, 108, 18, 12, outline, true);
    sprite_pixel_set(GLYPH_TOKEN_1, 84, 108, 18, 12, outline, true);
    sprite_pixel_set(GLYPH_TOKEN_2, 48, 108, 6, 6, casing, true);
    sprite_pixel_set(GLYPH_TOKEN_3, 90, 108, 6, 6, casing, true);
    sprite_pixel_set(GLYPH_AUX_0, 102, 84, 6, 6, signal, true);
    sprite_pixel_set(GLYPH_AUX_1, 36, 84, 12, 6, outline, true);
    if (state == CC_STATE_IDLE) {
        sprite_pixel_set(GLYPH_EFFECT_0, 48, 48, 6, 6, signal, true);
        sprite_pixel_set(GLYPH_EFFECT_1, 54, 54, 6, 6, signal, true);
        sprite_pixel_set(GLYPH_EFFECT_2, 48, 60, 6, 6, signal, true);
        sprite_pixel_set(GLYPH_EFFECT_3, 66, 60, pulse ? 18 : 6, 6, signal, true);
    } else if (state == CC_STATE_SESSION_STARTING) {
        sprite_pixel_set(GLYPH_EFFECT_0, 60, 6, 6, 6, lv_color_hex(UI_MINT), true);
        sprite_pixel_set(GLYPH_EFFECT_1, 72, 6, 6, 6, lv_color_hex(UI_MINT), true);
        sprite_pixel_set(GLYPH_EFFECT_2, 12, 30, 6, 6, lv_color_hex(UI_TEAL), true);
        sprite_pixel_set(GLYPH_EFFECT_3, 126, 30, 6, 6, lv_color_hex(UI_TEAL), true);
        sprite_pixel_set(GLYPH_EFFECT_4, 48, 48, 48, 6, lv_color_hex(UI_MINT), true);
    } else if (state == CC_STATE_WORKING) {
        const int scan_x = 42 + (frame % 8) * 6;
        sprite_pixel_set(GLYPH_EFFECT_0, 48, 48, 6, 6, signal, true);
        sprite_pixel_set(GLYPH_EFFECT_1, 54, 54, 6, 6, signal, true);
        sprite_pixel_set(GLYPH_EFFECT_2, 48, 60, 6, 6, signal, true);
        sprite_pixel_set(GLYPH_EFFECT_3, 66, 60, 18, 6, signal, true);
        sprite_pixel_set(GLYPH_EFFECT_4, scan_x, 48, 12, 6, signal, true);
        sprite_pixel_set(GLYPH_EFFECT_5, 126, 48 + (frame % 3) * 6, 6, 6,
                         lv_color_hex(UI_TEAL), true);
    } else if (state == CC_STATE_COMPLETED) {
        const lv_color_t sparkle = lv_color_hex(pulse ? UI_MINT : UI_BLUE);
        sprite_pixel_set(GLYPH_EFFECT_0, 54, 54, 6, 6, lv_color_hex(UI_MINT), true);
        sprite_pixel_set(GLYPH_EFFECT_1, 60, 60, 6, 6, lv_color_hex(UI_MINT), true);
        sprite_pixel_set(GLYPH_EFFECT_2, 66, 66, 6, 6, lv_color_hex(UI_MINT), true);
        sprite_pixel_set(GLYPH_EFFECT_3, 72, 60, 12, 6, lv_color_hex(UI_MINT), true);
        sprite_pixel_set(GLYPH_EFFECT_4, 6, 36, 6, 6, sparkle, true);
        sprite_pixel_set(GLYPH_EFFECT_5, 132, 42, 6, 6, sparkle, true);
    } else if (state == CC_STATE_APPROVAL_REQUIRED ||
               state == CC_STATE_CONFIRMATION_REQUIRED) {
        const lv_color_t warning = lv_color_hex(state == CC_STATE_APPROVAL_REQUIRED ? UI_AMBER :
                                                 (pulse ? UI_VIOLET : UI_MINT));
        sprite_pixel_set(GLYPH_EFFECT_0, 60, 48, 24, 6, warning, true);
        sprite_pixel_set(GLYPH_EFFECT_1, 60, 54, 6, 12, warning, true);
        sprite_pixel_set(GLYPH_EFFECT_2, 78, 54, 6, 12, warning, true);
        sprite_pixel_set(GLYPH_EFFECT_3, 42 + (frame % 7) * 6, 66, 12, 6, warning, true);
        sprite_pixel_set(GLYPH_EFFECT_4, 12, 54, 6, 6, warning, true);
        sprite_pixel_set(GLYPH_EFFECT_5, 126, 54, 6, 6, warning, true);
    } else if (state == CC_STATE_INPUT_REQUIRED) {
        sprite_pixel_set(GLYPH_EFFECT_0, 48, 48, 6, 6, lv_color_hex(UI_MAGENTA), true);
        sprite_pixel_set(GLYPH_EFFECT_1, 54, 54, 6, 6, lv_color_hex(UI_MAGENTA), true);
        sprite_pixel_set(GLYPH_EFFECT_2, 48, 60, 6, 6, lv_color_hex(UI_MAGENTA), true);
        sprite_pixel_set(GLYPH_EFFECT_3, 66, 60, 18, 6, lv_color_hex(UI_MAGENTA), true);
        sprite_pixel_set(GLYPH_EFFECT_4, 108, 24, 24, 18, lv_color_hex(UI_MAGENTA), true);
        sprite_pixel_set(GLYPH_EFFECT_5, 114, 42, 6, 6, lv_color_hex(UI_MAGENTA), true);
    } else if (fault) {
        const lv_color_t glitch = lv_color_hex(pulse ? UI_SIGNAL : UI_BLUE);
        sprite_pixel_set(GLYPH_EFFECT_0, 48, 48, 12, 6, signal, true);
        sprite_pixel_set(GLYPH_EFFECT_1, 78, 48, 12, 6, signal, true);
        sprite_pixel_set(GLYPH_EFFECT_2, 54, 60, 6, 6, signal, true);
        sprite_pixel_set(GLYPH_EFFECT_3, 72, 60, 6, 6, signal, true);
        sprite_pixel_set(GLYPH_EFFECT_4, 12, 66, 18, 6, glitch, true);
        sprite_pixel_set(GLYPH_EFFECT_5, 120, 78, 18, 6, glitch, true);
    } else if (disconnected) {
        const lv_color_t flicker = lv_color_hex(pulse ? UI_DIM : UI_BLUE);
        sprite_pixel_set(GLYPH_EFFECT_0, 42, 54, 60, 6, flicker, true);
        sprite_pixel_set(GLYPH_EFFECT_1, 66, 60, 12, 6, flicker, true);
        sprite_pixel_set(GLYPH_EFFECT_2, 12, 48, 6, 6, flicker, true);
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
    bsp_display_start();
    bsp_display_backlight_on();
    bsp_display_lock(-1);
    lv_obj_t *screen = lv_screen_active();
    lv_obj_set_style_bg_color(screen, lv_color_hex(UI_INK), 0);
    lv_obj_set_style_bg_opa(screen, LV_OPA_COVER, 0);
    outer_arc = make_ring(screen, CC_OUTER_RING_RADIUS_PX * 2,
                          lv_color_hex(UI_BLUE));
    inner_arc = make_ring(screen, CC_INNER_RING_RADIUS_PX * 2,
                          lv_color_hex(UI_MINT));
    make_dash_ring(screen, 0, CC_OUTER_RING_RADIUS_PX * 2);
    make_dash_ring(screen, 1, CC_INNER_RING_RADIUS_PX * 2);

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
        lv_obj_set_style_bg_opa(hud_marks[i * 2], LV_OPA_50, 0);
        hud_marks[i * 2 + 1] = lv_obj_create(screen);
        lv_obj_set_pos(hud_marks[i * 2 + 1], vertical_x[i], vertical_y[i]);
        lv_obj_set_size(hud_marks[i * 2 + 1], 2, 18);
        lv_obj_set_style_radius(hud_marks[i * 2 + 1], 0, 0);
        lv_obj_set_style_border_width(hud_marks[i * 2 + 1], 0, 0);
        lv_obj_set_style_bg_color(hud_marks[i * 2 + 1], lv_color_hex(UI_BLUE), 0);
        lv_obj_set_style_bg_opa(hud_marks[i * 2 + 1], LV_OPA_50, 0);
    }

    face = lv_obj_create(screen);
    lv_obj_set_size(face, 144, 144);
    lv_obj_center(face);
    lv_obj_set_style_radius(face, 0, 0);
    lv_obj_set_style_bg_opa(face, LV_OPA_TRANSP, 0);
    lv_obj_set_style_border_width(face, 0, 0);
    lv_obj_set_style_pad_all(face, 0, 0);
    lv_obj_remove_flag(face, LV_OBJ_FLAG_SCROLLABLE);
    for (int i = 0; i < GLYPH_COUNT; ++i) sprite[i] = make_sprite_pixel(face);

    status_label = lv_label_create(screen);
    lv_obj_set_style_text_font(status_label, &cc_font_zh_14, 0);
    lv_obj_align(status_label, LV_ALIGN_CENTER, 0, 76);

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
    lv_obj_set_size(prompt_list, 220, 218);
    lv_obj_align(prompt_list, LV_ALIGN_CENTER, 0, -4);
    lv_obj_set_flex_flow(prompt_list, LV_FLEX_FLOW_COLUMN);
    lv_obj_set_flex_align(prompt_list, LV_FLEX_ALIGN_START,
                          LV_FLEX_ALIGN_CENTER, LV_FLEX_ALIGN_CENTER);
    lv_obj_set_style_pad_row(prompt_list, 6, 0);
    lv_obj_set_style_bg_color(prompt_list, lv_color_hex(UI_NAVY), 0);
    lv_obj_set_style_border_color(prompt_list, lv_color_hex(UI_TEAL), 0);
    lv_obj_set_style_border_width(prompt_list, 2, 0);
    lv_obj_set_scroll_dir(prompt_list, LV_DIR_VER);
    lv_obj_add_flag(prompt_list, LV_OBJ_FLAG_HIDDEN);
    for (int i = 0; i < CC_PROMPT_MAX_OPTIONS; ++i) {
        prompt_buttons[i] = lv_button_create(prompt_list);
        lv_obj_set_size(prompt_buttons[i], 196, 34);
        lv_obj_set_style_radius(prompt_buttons[i], 0, 0);
        lv_obj_set_style_bg_color(prompt_buttons[i], lv_color_hex(UI_FOREST), 0);
        lv_obj_set_style_border_color(prompt_buttons[i], lv_color_hex(UI_DIM), 0);
        lv_obj_set_style_border_width(prompt_buttons[i], 2, 0);
        lv_obj_set_style_bg_color(prompt_buttons[i], lv_color_hex(UI_AMBER),
                                  LV_STATE_PRESSED);
        lv_obj_add_event_cb(prompt_buttons[i], prompt_button_event, LV_EVENT_ALL,
                            (void *)(uintptr_t)i);
        lv_obj_add_flag(prompt_buttons[i], LV_OBJ_FLAG_HIDDEN);
    }

    // The connection center uses deliberate, large touch targets. The old
    // 26px rows were too easy to mis-hit on a 360px circular display.
    connection_center = lv_obj_create(screen);
    lv_obj_set_size(connection_center, 316, 320);
    lv_obj_align(connection_center, LV_ALIGN_TOP_MID, 0, 28);
    lv_obj_set_style_radius(connection_center, 0, 0);
    lv_obj_set_style_bg_color(connection_center, lv_color_hex(UI_SHELL), 0);
    lv_obj_set_style_bg_opa(connection_center, LV_OPA_COVER, 0);
    lv_obj_set_style_border_color(connection_center, lv_color_hex(UI_TEAL), 0);
    lv_obj_set_style_border_width(connection_center, 2, 0);
    lv_obj_set_style_pad_all(connection_center, 0, 0);
    lv_obj_remove_flag(connection_center, LV_OBJ_FLAG_SCROLLABLE);
    connection_text(connection_center, "连接中心", 18, 14,
                    lv_color_hex(UI_MINT));
    connection_text(connection_center, "蓝牙：已开启", 18, 42,
                    lv_color_hex(UI_TEAL));
    connection_mac_label = connection_text(connection_center, "Mac：等待连接", 18, 64,
                                             lv_color_hex(UI_AMBER));
    connection_auth_label = connection_text(connection_center, "安全：等待配对", 18, 86,
                                              lv_color_hex(UI_AMBER));
    connection_mic_label = connection_text(connection_center, "麦克风：正在准备", 18,
                                             108, lv_color_hex(UI_AMBER));
    connection_text(connection_center, "按键：按住 BOOT = Fn", 18, 130,
                    lv_color_hex(UI_BLUE));
    connection_wifi_label = connection_text(connection_center, "网络：尚未配置", 18,
                                            152, lv_color_hex(UI_AMBER));
    lv_obj_set_width(connection_wifi_label, 278);
    lv_label_set_long_mode(connection_wifi_label, LV_LABEL_LONG_SCROLL_CIRCULAR);
    connection_wifi_button = lv_button_create(connection_center);
    lv_obj_set_size(connection_wifi_button, 278, 42);
    lv_obj_set_pos(connection_wifi_button, 18, 174);
    lv_obj_set_style_radius(connection_wifi_button, 0, 0);
    lv_obj_set_style_bg_color(connection_wifi_button, lv_color_hex(UI_NAVY), 0);
    lv_obj_set_style_border_color(connection_wifi_button, lv_color_hex(UI_TEAL), 0);
    lv_obj_set_style_border_width(connection_wifi_button, 1, 0);
    lv_obj_add_event_cb(connection_wifi_button, wifi_setup_button_event,
                        LV_EVENT_CLICKED, NULL);
    lv_obj_t *connection_wifi_button_label = lv_label_create(connection_wifi_button);
    lv_label_set_text(connection_wifi_button_label, "配置 Wi-Fi（手机 / Mac）");
    lv_obj_set_style_text_font(connection_wifi_button_label,
                               &cc_font_zh_14, 0);
    lv_obj_set_style_text_color(connection_wifi_button_label, lv_color_hex(UI_TEAL), 0);
    lv_obj_center(connection_wifi_button_label);
    connection_usb_button = lv_button_create(connection_center);
    lv_obj_set_size(connection_usb_button, 278, 46);
    lv_obj_set_pos(connection_usb_button, 18, 222);
    lv_obj_set_style_radius(connection_usb_button, 0, 0);
    lv_obj_set_style_bg_color(connection_usb_button, lv_color_hex(UI_FOREST), 0);
    lv_obj_set_style_border_color(connection_usb_button, lv_color_hex(UI_BLUE), 0);
    lv_obj_set_style_border_width(connection_usb_button, 1, 0);
    lv_obj_add_event_cb(connection_usb_button, usb_mode_button_event,
                        LV_EVENT_ALL, NULL);
    connection_usb_button_label = lv_label_create(connection_usb_button);
    lv_obj_set_style_text_font(connection_usb_button_label,
                               &cc_font_zh_14, 0);
    lv_obj_set_style_text_color(connection_usb_button_label, lv_color_hex(UI_MINT), 0);
    lv_obj_center(connection_usb_button_label);
    connection_reset_button = lv_button_create(connection_center);
    lv_obj_set_size(connection_reset_button, 278, 38);
    lv_obj_set_pos(connection_reset_button, 18, 274);
    lv_obj_set_style_radius(connection_reset_button, 0, 0);
    lv_obj_set_style_bg_color(connection_reset_button, lv_color_hex(UI_SHELL), 0);
    lv_obj_set_style_border_color(connection_reset_button, lv_color_hex(UI_ALARM), 0);
    lv_obj_set_style_border_width(connection_reset_button, 1, 0);
    lv_obj_add_event_cb(connection_reset_button, pairing_reset_button_event,
                        LV_EVENT_ALL, NULL);
    lv_obj_t *connection_reset_label = lv_label_create(connection_reset_button);
    lv_label_set_text(connection_reset_label, "重置蓝牙配对（长按 2 秒）");
    lv_obj_set_style_text_font(connection_reset_label,
                               &cc_font_zh_14, 0);
    lv_obj_set_style_text_color(connection_reset_label, lv_color_hex(UI_ALARM), 0);
    lv_obj_center(connection_reset_label);
    lv_obj_add_event_cb(connection_center, connection_center_event,
                        LV_EVENT_CLICKED, NULL);
    lv_obj_add_flag(connection_center, LV_OBJ_FLAG_HIDDEN);

    connection_handle = lv_button_create(screen);
    lv_obj_set_size(connection_handle, 92, 26);
    lv_obj_align(connection_handle, LV_ALIGN_TOP_MID, 0, 3);
    lv_obj_set_style_radius(connection_handle, 0, 0);
    lv_obj_set_style_bg_color(connection_handle, lv_color_hex(UI_NAVY), 0);
    lv_obj_set_style_border_color(connection_handle, lv_color_hex(UI_TEAL), 0);
    lv_obj_set_style_border_width(connection_handle, 1, 0);
    lv_obj_add_event_cb(connection_handle, connection_center_event,
                        LV_EVENT_CLICKED, NULL);
    lv_obj_t *connection_handle_label = lv_label_create(connection_handle);
    lv_label_set_text(connection_handle_label, "连接");
    lv_obj_set_style_text_font(connection_handle_label,
                               &cc_font_zh_14, 0);
    lv_obj_set_style_text_color(connection_handle_label, lv_color_hex(UI_MINT), 0);
    lv_obj_center(connection_handle_label);
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

void cc_device_ui_render(const cc_device_model_t *model, uint16_t audio_level) {
    bsp_display_lock(-1);
    set_quota(outer_arc, model->five_hour, 0);
    set_quota(inner_arc, model->week, 1);
    const bool quota_stale = cc_device_quota_is_stale(
        model, (uint64_t)(esp_timer_get_time() / 1000));
    const lv_opa_t quota_opacity = quota_stale ? LV_OPA_40 : LV_OPA_COVER;
    lv_obj_set_style_opa(outer_arc, quota_opacity, LV_PART_MAIN);
    lv_obj_set_style_opa(outer_arc, quota_opacity, LV_PART_INDICATOR);
    lv_obj_set_style_opa(inner_arc, quota_opacity, LV_PART_MAIN);
    lv_obj_set_style_opa(inner_arc, quota_opacity, LV_PART_INDICATOR);
    const lv_color_t accent = state_color(model->visible_state);
    const uint8_t frame = (uint8_t)((esp_timer_get_time() / 83333) % 12);
    lv_obj_set_style_text_color(status_label, accent, 0);
    lv_label_set_text(status_label, state_text(model->visible_state));
    if (connection_center_visible) {
        lv_label_set_text(connection_mac_label,
                          model->connected ? "Mac：已连接" : "Mac：未连接");
        lv_obj_set_style_text_color(connection_mac_label,
            model->connected ? lv_color_hex(UI_MINT) : lv_color_hex(UI_ALARM), 0);
        lv_label_set_text(connection_auth_label,
                          model->connected ? "安全：已加密" : "安全：等待配对");
        lv_obj_set_style_text_color(connection_auth_label,
            model->connected ? lv_color_hex(UI_TEAL) : lv_color_hex(UI_AMBER), 0);
    }
    const bool listening = model->visible_state == CC_STATE_LISTENING;
    if (listening || prompt_visible) lv_obj_add_flag(face, LV_OBJ_FLAG_HIDDEN);
    else lv_obj_remove_flag(face, LV_OBJ_FLAG_HIDDEN);
    if (!prompt_visible) render_sprite(model->visible_state, frame);
    for (int i = 0; i < 13; ++i) {
        if (listening) {
            lv_obj_remove_flag(wave_bars[i], LV_OBJ_FLAG_HIDDEN);
            const uint16_t shape = (uint16_t)(26 + ((i * 37 + audio_level) % 72));
            const int height = 8 + (int)(shape * audio_level / 1000);
            lv_obj_set_height(wave_bars[i], height);
        } else {
            lv_obj_add_flag(wave_bars[i], LV_OBJ_FLAG_HIDDEN);
        }
    }
    bsp_display_unlock();
}

void cc_device_ui_show_prompt(const cc_prompt_payload_t *prompt,
                              cc_prompt_selection_fn selection_callback) {
    if (!prompt) return;
    bsp_display_lock(-1);
    prompt_id = prompt->id;
    on_prompt_selection = selection_callback;
    prompt_visible = true;
    connection_center_visible = false;
    lv_obj_add_flag(connection_center, LV_OBJ_FLAG_HIDDEN);
    lv_obj_move_foreground(connection_handle);
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
    bsp_display_unlock();
}

void cc_device_ui_close_prompt(void) {
    bsp_display_lock(-1);
    prompt_visible = false;
    on_prompt_selection = NULL;
    lv_obj_add_flag(prompt_list, LV_OBJ_FLAG_HIDDEN);
    for (uint8_t i = 0; i < CC_PROMPT_MAX_OPTIONS; ++i) {
        lv_obj_add_flag(prompt_buttons[i], LV_OBJ_FLAG_HIDDEN);
    }
    lv_obj_align(status_label, LV_ALIGN_CENTER, 0, 76);
    bsp_display_unlock();
}
