#pragma once

#include "device_model.h"
#include "prompt_payload.h"

typedef void (*cc_prompt_selection_fn)(uint32_t prompt_id, uint8_t option_index,
                                       bool long_press);
typedef void (*cc_usb_mode_selection_fn)(bool enable_uac_mode);
typedef void (*cc_wifi_setup_fn)(void);
typedef void (*cc_pairing_reset_fn)(void);

void cc_device_ui_start(void);
void cc_device_ui_render(const cc_device_model_t *model, uint16_t audio_level);
void cc_device_ui_show_prompt(const cc_prompt_payload_t *prompt,
                              cc_prompt_selection_fn selection_callback);
void cc_device_ui_close_prompt(void);
/** Configure the Connection Center's explicit USB microphone mode switch. */
void cc_device_ui_set_usb_uac_mode(bool enabled,
                                   cc_usb_mode_selection_fn selection_callback);
/** Update and activate the Connection Center's self-service Wi-Fi portal. */
void cc_device_ui_set_wifi_setup(cc_wifi_setup_fn setup_callback);
void cc_device_ui_set_wifi_status(const char *status);
/** Long-press action used to erase the current BLE recovery pairing. */
void cc_device_ui_set_pairing_reset(cc_pairing_reset_fn reset_callback);
