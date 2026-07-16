#include "usb_control.h"

#include <string.h>

#include "freertos/FreeRTOS.h"
#include "freertos/queue.h"
#include "tusb.h"

static QueueHandle_t g_rx_queue;
static cc_usb_control_line_fn g_line_callback;
static char g_line[40];
static size_t g_line_length;
static bool g_host_seen;

void cc_usb_control_start(cc_usb_control_line_fn line_callback) {
    g_line_callback = line_callback;
    g_host_seen = false;
    if (!g_rx_queue) g_rx_queue = xQueueCreate(96, sizeof(uint8_t));
}

// TinyUSB calls this from its own task. Keep it bounded and defer all UI/model
// work to cc_usb_control_poll(), which runs on the application task.
void tud_cdc_rx_cb(uint8_t interface_number) {
    uint8_t buffer[32];
    while (tud_cdc_n_available(interface_number)) {
        const uint32_t count = tud_cdc_n_read(interface_number, buffer, sizeof(buffer));
        for (uint32_t i = 0; i < count; ++i) {
            if (g_rx_queue) (void)xQueueSend(g_rx_queue, &buffer[i], 0);
        }
    }
}

void cc_usb_control_poll(void) {
    if (!g_rx_queue) return;
    uint8_t byte;
    while (xQueueReceive(g_rx_queue, &byte, 0) == pdTRUE) {
        if (byte == '\r') continue;
        if (byte == '\n') {
            g_line[g_line_length] = '\0';
            if (g_line_length != 0 && g_line_callback) {
                // The CDC port is only exposed by the locally attached UAC
                // device. Mark it live only after a complete host line, so
                // an electrical reconnect never masquerades as an active
                // Companion session.
                g_host_seen = true;
                g_line_callback(g_line);
            }
            g_line_length = 0;
            continue;
        }
        if (byte >= 0x20 && byte <= 0x7e && g_line_length + 1 < sizeof(g_line)) {
            g_line[g_line_length++] = (char)byte;
        } else {
            g_line_length = 0;
        }
    }
}

bool cc_usb_control_send(const char *line) {
    // AppleUSBCDC can keep DTR low for a composite UAC+CDC device even while
    // the data endpoints are fully configured. BOOT edges are safe to send as
    // soon as the CDC interface is ready; the Mac owns the port locally.
    if (!line || !tud_cdc_n_ready(0)) return false;
    const size_t length = strlen(line);
    return tud_cdc_write(line, (uint32_t)length) == length && tud_cdc_write_flush() != 0;
}

bool cc_usb_control_is_connected(void) {
    // macOS opens the CDC sideband without a stable DTR transition when it is
    // bundled with a UAC microphone. The authenticated local heartbeat is the
    // actual ownership signal; app_main applies a six-second timeout if those
    // heartbeats stop, so no stale USB session can remain connected.
    return g_host_seen;
}
