#pragma once

#include "device_model.h"
#include "prompt_payload.h"

typedef void (*cc_prompt_selection_fn)(uint32_t prompt_id, uint8_t option_index,
                                       bool long_press);
typedef void (*cc_usb_mode_selection_fn)(bool enable_uac_mode);
typedef void (*cc_wifi_setup_fn)(void);
typedef bool (*cc_pairing_reset_fn)(void);
typedef void (*cc_weather_settings_fn)(bool enabled, bool uses_celsius,
                                       uint8_t refresh_minutes);
typedef void (*cc_codex_visibility_fn)(bool visible);

void cc_device_ui_start(void);
void cc_device_ui_render(const cc_device_model_t *model, uint16_t audio_level);
/** Keep the screen visible at low idle brightness and restore it on activity. */
void cc_device_ui_power_tick(uint64_t now_ms, bool external_activity);
/** Update the real fuel-gauge reading shown on the watch face. */
void cc_device_ui_update_battery(bool valid, uint8_t percent, bool charging);
/** True only while BOOT voice/submit actions belong to the open Codex app. */
bool cc_device_ui_codex_voice_available(void);
/** True while any page owned by the Codex app is in the foreground. */
bool cc_device_ui_codex_app_active(void);
/** Notify the audio router when Codex enters or leaves the foreground. */
void cc_device_ui_set_codex_visibility_callback(
    cc_codex_visibility_fn visibility_callback);
/** Queue a transient animation without replacing the aggregate Codex state. */
void cc_device_ui_enqueue_task_event(cc_task_event_t event);
void cc_device_ui_show_prompt(const cc_prompt_payload_t *prompt,
                              cc_prompt_selection_fn selection_callback);
void cc_device_ui_close_prompt(void);
/** Configure the Connection Center's explicit USB microphone mode switch. */
void cc_device_ui_set_usb_uac_mode(bool enabled,
                                   cc_usb_mode_selection_fn selection_callback);
/** Update and activate the Connection Center's self-service Wi-Fi portal. */
void cc_device_ui_set_wifi_setup(cc_wifi_setup_fn setup_callback);
void cc_device_ui_set_wifi_status(const char *status);
/** Show the selected host saved by encrypted BLE provisioning. */
void cc_device_ui_set_paired_host(const char *display_name);
/** Long-press action used to forget the host and pair another device. */
void cc_device_ui_set_pairing_reset(cc_pairing_reset_fn reset_callback);
/** Synchronize host-fetched weather and the user-selectable refresh policy. */
void cc_device_ui_update_weather(const char *city,
                                 int16_t temperature_tenths_celsius,
                                 uint8_t weather_code);
void cc_device_ui_apply_weather_settings(bool enabled, bool uses_celsius,
                                         uint8_t refresh_minutes);
void cc_device_ui_set_weather_settings_callback(
    cc_weather_settings_fn settings_callback);
