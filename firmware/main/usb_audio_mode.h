#pragma once

#include <stdbool.h>

typedef enum {
    CC_USB_MODE_NORMAL = 0,
    CC_USB_MODE_UAC_MIC = 1,
} cc_usb_mode_t;

/** Loads the requested USB mode from NVS; normal mode is always the default. */
cc_usb_mode_t cc_usb_mode_load(void);
/** Persists a requested boot mode. The caller performs the restart. */
bool cc_usb_mode_store(cc_usb_mode_t mode);
/** Starts the native input-only USB Audio Class microphone. */
bool cc_usb_uac_start(void);
