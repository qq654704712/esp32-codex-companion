#include "wireless_audio_router.h"

#include "audio_codec.h"
#include "ble_transport.h"
#include "wifi_transport.h"

static cc_wireless_audio_route_t g_route;
static uint16_t g_ble_sequence;
static bool g_ptt_held;
static bool g_loss_pending;
static uint32_t g_loss_started_ms;

#define CC_WIRELESS_ROUTE_LOSS_GRACE_MS 2000U

static bool route_is_available(void) {
    if (g_route == CC_WIRELESS_AUDIO_WIFI) {
        return cc_wifi_transport_is_audio_available();
    }
    if (g_route == CC_WIRELESS_AUDIO_BLE) return cc_ble_is_connected();
    return false;
}

cc_wireless_audio_route_t cc_wireless_audio_route_begin(void) {
    g_ble_sequence = 0;
    g_loss_pending = false;
    if (cc_wifi_transport_is_audio_available()) {
        g_route = CC_WIRELESS_AUDIO_WIFI;
    } else if (cc_ble_is_connected()) {
        g_route = CC_WIRELESS_AUDIO_BLE;
    } else {
        g_route = CC_WIRELESS_AUDIO_NONE;
    }
    g_ptt_held = g_route != CC_WIRELESS_AUDIO_NONE;
    return g_route;
}

void cc_wireless_audio_route_finish(void) {
    g_ptt_held = false;
    g_loss_pending = false;
}

bool cc_wireless_audio_route_send(const int16_t *samples, size_t sample_count) {
    if (!samples || sample_count != CC_AUDIO_SAMPLES_PER_FRAME) return false;
    if (g_route == CC_WIRELESS_AUDIO_WIFI) {
        if (!cc_wifi_transport_is_audio_available()) return false;
        return cc_wifi_transport_send_audio_pcm16(samples, sample_count);
    }
    if (g_route == CC_WIRELESS_AUDIO_BLE) {
        if (!cc_ble_is_connected()) return false;
        uint8_t encoded[CC_AUDIO_ENCODED_FRAME_SIZE];
        if (cc_adpcm_encode_frame(g_ble_sequence++, samples, encoded,
                                  sizeof(encoded)) == 0) {
            return false;
        }
        return cc_ble_notify_audio(encoded, sizeof(encoded));
    }
    return false;
}

bool cc_wireless_audio_route_lost_at(uint32_t now_ms) {
    if (!g_ptt_held) return false;
    if (route_is_available()) {
        g_loss_pending = false;
        return false;
    }
    if (!g_loss_pending) {
        g_loss_pending = true;
        g_loss_started_ms = now_ms;
        return false;
    }
    return (uint32_t)(now_ms - g_loss_started_ms) >=
           CC_WIRELESS_ROUTE_LOSS_GRACE_MS;
}

cc_wireless_audio_route_t cc_wireless_audio_route_current(void) {
    return g_route;
}

void cc_wireless_audio_route_cancel(void) {
    g_route = CC_WIRELESS_AUDIO_NONE;
    g_ble_sequence = 0;
    g_ptt_held = false;
    g_loss_pending = false;
    g_loss_started_ms = 0;
}
