#include "usb_hid_ptt.h"

#include <string.h>

#include "tusb.h"

static bool g_requested_down;
static bool g_report_pending;

void cc_usb_hid_ptt_set(bool down) {
    g_requested_down = down;
    g_report_pending = true;
}

void cc_usb_hid_ptt_poll(void) {
    if (!g_report_pending || !tud_hid_ready()) return;

    uint8_t keycodes[6] = {0};
    if (g_requested_down) keycodes[0] = HID_KEY_F13;
    if (tud_hid_keyboard_report(0, 0, keycodes)) {
        g_report_pending = false;
    }
}
