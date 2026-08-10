#include <assert.h>
#include <stdio.h>
#include <string.h>

#include "host_profile.h"

static void test_legacy_secret_is_accepted(void) {
    uint8_t secret[32] = {1};
    cc_host_profile_t profile;
    assert(cc_host_profile_decode(secret, sizeof(secret), &profile));
    assert(profile.legacy);
    assert(strcmp(profile.host_id, "legacy") == 0);
    assert(memcmp(profile.pairing_secret, secret, sizeof(secret)) == 0);
}

static void test_versioned_profile_is_decoded(void) {
    const char *host_id = "host-1234";
    const char *name = "Studio Mac";
    uint8_t packet[128] = {'C', 'C', 'P', '2', 1, 0x3e, 9, 10};
    memset(packet + 8, 0x5a, 32);
    memcpy(packet + 40, host_id, 9);
    memcpy(packet + 49, name, 10);
    cc_host_profile_t profile;
    assert(cc_host_profile_decode(packet, 59, &profile));
    assert(!profile.legacy);
    assert(strcmp(profile.host_id, host_id) == 0);
    assert(strcmp(profile.display_name, name) == 0);
    assert(profile.capabilities == 0x3e);
    assert(profile.pairing_secret[0] == 0x5a);
}

static void test_malformed_profile_is_rejected(void) {
    uint8_t packet[40] = {'C', 'C', 'P', '2', 1, 0, 49, 1};
    cc_host_profile_t profile;
    assert(!cc_host_profile_decode(packet, sizeof(packet), &profile));
}

int main(void) {
    test_legacy_secret_is_accepted();
    test_versioned_profile_is_decoded();
    test_malformed_profile_is_rejected();
    puts("host_profile tests passed");
    return 0;
}
