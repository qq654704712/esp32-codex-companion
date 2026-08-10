#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#define CC_HOST_PROFILE_MAGIC "CCP2"
#define CC_HOST_PROFILE_VERSION 1U
#define CC_HOST_ID_MAX 48U
#define CC_HOST_NAME_MAX 64U
#define CC_HOST_SECRET_SIZE 32U

enum {
    CC_HOST_CAP_USB_AUDIO = 1U << 0,
    CC_HOST_CAP_USB_CONTROL = 1U << 1,
    CC_HOST_CAP_BLE_CONTROL = 1U << 2,
    CC_HOST_CAP_BLE_AUDIO = 1U << 3,
    CC_HOST_CAP_WIFI_CONTROL = 1U << 4,
    CC_HOST_CAP_WIFI_AUDIO = 1U << 5,
};

typedef struct {
    char host_id[CC_HOST_ID_MAX + 1U];
    char display_name[CC_HOST_NAME_MAX + 1U];
    uint8_t capabilities;
    uint8_t pairing_secret[CC_HOST_SECRET_SIZE];
    bool legacy;
} cc_host_profile_t;

/**
 * Decode an encrypted BLE provisioning value. The original 32-byte secret is
 * deliberately retained as a migration format; CCP2 adds a stable host ID,
 * user-visible name and transport capabilities without changing the GATT UUID.
 */
bool cc_host_profile_decode(const uint8_t *bytes, size_t length,
                            cc_host_profile_t *profile);
