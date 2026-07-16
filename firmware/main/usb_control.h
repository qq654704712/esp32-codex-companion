#pragma once

#include <stdbool.h>

typedef void (*cc_usb_control_line_fn)(const char *line);

/** Starts the CDC sideband carried alongside the native USB microphone. */
void cc_usb_control_start(cc_usb_control_line_fn line_callback);
/** Drains TinyUSB RX bytes on the application task and emits complete lines. */
void cc_usb_control_poll(void);
/** Sends a small newline-terminated event to the locally connected Mac. */
bool cc_usb_control_send(const char *line);
/** True after the Mac has opened the CDC port and sent a control line. */
bool cc_usb_control_is_connected(void);
