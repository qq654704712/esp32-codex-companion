#include "host_profile.h"

#include <string.h>

#define CC_HOST_PROFILE_HEADER_SIZE 40U

bool cc_host_profile_decode(const uint8_t *bytes, size_t length,
                            cc_host_profile_t *profile) {
    if (bytes == NULL || profile == NULL) return false;
    memset(profile, 0, sizeof(*profile));

    if (length == CC_HOST_SECRET_SIZE) {
        memcpy(profile->pairing_secret, bytes, CC_HOST_SECRET_SIZE);
        memcpy(profile->host_id, "legacy", sizeof("legacy"));
        memcpy(profile->display_name, "Paired host", sizeof("Paired host"));
        profile->capabilities = CC_HOST_CAP_BLE_CONTROL | CC_HOST_CAP_BLE_AUDIO |
                                CC_HOST_CAP_WIFI_CONTROL | CC_HOST_CAP_WIFI_AUDIO;
        profile->legacy = true;
        return true;
    }

    if (length < CC_HOST_PROFILE_HEADER_SIZE ||
        memcmp(bytes, CC_HOST_PROFILE_MAGIC, 4) != 0 ||
        bytes[4] != CC_HOST_PROFILE_VERSION) {
        return false;
    }
    const uint8_t capabilities = bytes[5];
    const size_t host_id_length = bytes[6];
    const size_t name_length = bytes[7];
    if (host_id_length == 0U || host_id_length > CC_HOST_ID_MAX ||
        name_length == 0U || name_length > CC_HOST_NAME_MAX ||
        length != CC_HOST_PROFILE_HEADER_SIZE + host_id_length + name_length) {
        return false;
    }
    memcpy(profile->pairing_secret, bytes + 8U, CC_HOST_SECRET_SIZE);
    memcpy(profile->host_id, bytes + CC_HOST_PROFILE_HEADER_SIZE, host_id_length);
    memcpy(profile->display_name,
           bytes + CC_HOST_PROFILE_HEADER_SIZE + host_id_length, name_length);
    profile->host_id[host_id_length] = '\0';
    profile->display_name[name_length] = '\0';
    profile->capabilities = capabilities;
    profile->legacy = false;
    return true;
}
