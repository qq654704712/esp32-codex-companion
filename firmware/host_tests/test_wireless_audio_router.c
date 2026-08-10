#include <assert.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>

#include "audio_codec.h"
#include "wireless_audio_router.h"

static bool wifi_available;
static bool ble_connected;
static unsigned wifi_sends;
static unsigned ble_sends;
static uint16_t last_ble_sequence;

bool cc_wifi_transport_is_audio_available(void) { return wifi_available; }
bool cc_ble_is_connected(void) { return ble_connected; }

bool cc_wifi_transport_send_audio_pcm16(const int16_t *samples,
                                        size_t sample_count) {
    assert(samples != NULL);
    assert(sample_count == CC_AUDIO_SAMPLES_PER_FRAME);
    wifi_sends++;
    return true;
}

bool cc_ble_notify_audio(const uint8_t *data, size_t length) {
    assert(data != NULL);
    assert(length == CC_AUDIO_ENCODED_FRAME_SIZE);
    last_ble_sequence = (uint16_t)((uint16_t)data[0] << 8 | data[1]);
    ble_sends++;
    return true;
}

static void reset_stubs(void) {
    wifi_available = false;
    ble_connected = false;
    wifi_sends = 0;
    ble_sends = 0;
    last_ble_sequence = 0;
    cc_wireless_audio_route_cancel();
}

static void test_wifi_is_preferred_and_locked(void) {
    reset_stubs();
    wifi_available = true;
    ble_connected = true;
    int16_t pcm[CC_AUDIO_SAMPLES_PER_FRAME] = {0};
    assert(cc_wireless_audio_route_begin() == CC_WIRELESS_AUDIO_WIFI);
    assert(cc_wireless_audio_route_send(pcm, CC_AUDIO_SAMPLES_PER_FRAME));
    assert(wifi_sends == 1 && ble_sends == 0);

    wifi_available = false;
    assert(!cc_wireless_audio_route_lost_at(100));
    assert(!cc_wireless_audio_route_lost_at(2099));
    // A recovered route clears the pending-loss timer.
    wifi_available = true;
    assert(!cc_wireless_audio_route_lost_at(2100));
    wifi_available = false;
    assert(!cc_wireless_audio_route_lost_at(2200));
    assert(cc_wireless_audio_route_lost_at(4200));
    assert(!cc_wireless_audio_route_send(pcm, CC_AUDIO_SAMPLES_PER_FRAME));
    assert(ble_sends == 0);  // Never switch transports during one press.
}

static void test_ble_fallback_resets_each_press(void) {
    reset_stubs();
    ble_connected = true;
    int16_t pcm[CC_AUDIO_SAMPLES_PER_FRAME] = {0};
    assert(cc_wireless_audio_route_begin() == CC_WIRELESS_AUDIO_BLE);
    assert(cc_wireless_audio_route_send(pcm, CC_AUDIO_SAMPLES_PER_FRAME));
    assert(last_ble_sequence == 0);
    assert(cc_wireless_audio_route_send(pcm, CC_AUDIO_SAMPLES_PER_FRAME));
    assert(last_ble_sequence == 1);
    assert(cc_wireless_audio_route_begin() == CC_WIRELESS_AUDIO_BLE);
    assert(cc_wireless_audio_route_send(pcm, CC_AUDIO_SAMPLES_PER_FRAME));
    assert(last_ble_sequence == 0);
}

static void test_no_route_is_explicit(void) {
    reset_stubs();
    assert(cc_wireless_audio_route_begin() == CC_WIRELESS_AUDIO_NONE);
    assert(!cc_wireless_audio_route_lost_at(1));
}

int main(void) {
    test_wifi_is_preferred_and_locked();
    test_ble_fallback_resets_each_press();
    test_no_route_is_explicit();
    puts("wireless_audio_router tests passed");
    return 0;
}
