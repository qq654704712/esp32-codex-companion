#include "pairing_manager.h"

#include <assert.h>
#include <string.h>

typedef struct {
    unsigned int saves;
    unsigned int removals;
    cc_pairing_host_t stored;
} fake_storage_t;

static bool save_host(const cc_pairing_host_t *host, void *context) {
    fake_storage_t *storage = context;
    storage->saves++;
    storage->stored = *host;
    return true;
}

static bool remove_host(const char *host_id, void *context) {
    fake_storage_t *storage = context;
    assert(strcmp(storage->stored.host_id, host_id) == 0);
    storage->removals++;
    memset(&storage->stored, 0, sizeof(storage->stored));
    return true;
}

static cc_pairing_host_t candidate(void) {
    cc_pairing_host_t host = {0};
    strcpy(host.host_id, "office-mac");
    strcpy(host.display_name, "Office Mac");
    strcpy(host.endpoint, "192.168.1.2:45831");
    memset(host.public_key, 0x11, sizeof(host.public_key));
    memset(host.pairing_secret, 0x22, sizeof(host.pairing_secret));
    return host;
}

int main(void) {
    fake_storage_t storage = {0};
    cc_pairing_manager_t pairing;
    cc_pairing_init(&pairing, save_host, remove_host, &storage);
    cc_pairing_host_t host = candidate();

    cc_pairing_host_t empty_material = host;
    memset(empty_material.pairing_secret, 0, sizeof(empty_material.pairing_secret));
    assert(cc_pairing_begin_recovery(&pairing, &empty_material, "123456", 0, 0) ==
           CC_PAIRING_INVALID_ARGUMENT);

    assert(cc_pairing_begin_recovery(&pairing, &host, "123456", 100, 1000) ==
           CC_PAIRING_OK);
    assert(cc_pairing_confirm_sas(&pairing, false, 200) == CC_PAIRING_REJECTED);
    assert(!cc_pairing_has_primary_host(&pairing));
    assert(storage.saves == 0);

    assert(cc_pairing_begin_recovery(&pairing, &host, "123456", 300, 1000) ==
           CC_PAIRING_OK);
    assert(cc_pairing_confirm_sas(&pairing, true, 400) ==
           CC_PAIRING_PEER_PENDING);
    assert(storage.saves == 0);
    assert(cc_pairing_confirm_peer(&pairing, true, 500) == CC_PAIRING_OK);
    assert(cc_pairing_has_primary_host(&pairing));
    assert(storage.saves == 1);

    assert(cc_pairing_unpair(&pairing, "office-mac", 1499) ==
           CC_PAIRING_HOLD_REQUIRED);
    assert(cc_pairing_has_primary_host(&pairing));
    assert(cc_pairing_unpair(&pairing, "office-mac", 1500) == CC_PAIRING_OK);
    assert(!cc_pairing_has_primary_host(&pairing));
    assert(storage.removals == 1);

    assert(cc_pairing_begin_recovery(&pairing, &host, "123456", 1000, 10) ==
           CC_PAIRING_OK);
    assert(cc_pairing_confirm_peer(&pairing, true, 1011) == CC_PAIRING_EXPIRED);
    assert(storage.saves == 1);
    assert(!cc_pairing_has_primary_host(&pairing));

    return 0;
}
