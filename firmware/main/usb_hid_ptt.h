#pragma once

#include <stdbool.h>

/** Queue the hardware BOOT state for the USB HID keyboard interface. */
void cc_usb_hid_ptt_set(bool down);
/** Sends the queued F13 down/up report when the HID endpoint is ready. */
void cc_usb_hid_ptt_poll(void);
