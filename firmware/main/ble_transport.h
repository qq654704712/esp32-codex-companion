#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

typedef void (*cc_ble_control_fn)(const uint8_t *data, size_t length);

void cc_ble_start(cc_ble_control_fn control_callback);
bool cc_ble_is_connected(void);
bool cc_ble_notify_control(const uint8_t *data, size_t length);
bool cc_ble_notify_audio(const uint8_t *data, size_t length);
bool cc_ble_copy_hmac_key(uint8_t output[32]);
/** Forget the current BLE bond and application pairing key for recovery pairing. */
bool cc_ble_clear_pairing(void);
