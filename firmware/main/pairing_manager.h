#ifndef CODEX_COMPANION_PAIRING_MANAGER_H
#define CODEX_COMPANION_PAIRING_MANAGER_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#define CC_PAIRING_HOST_ID_MAX 48
#define CC_PAIRING_DISPLAY_NAME_MAX 64
#define CC_PAIRING_ENDPOINT_MAX 64
#define CC_PAIRING_PUBLIC_KEY_SIZE 32
#define CC_PAIRING_SECRET_SIZE 32
#define CC_PAIRING_SAS_LENGTH 6
#define CC_PAIRING_DEFAULT_TIMEOUT_MS 90000U
#define CC_PAIRING_DESTRUCTIVE_HOLD_MS 1500U

typedef enum {
    CC_PAIRING_OK = 0,
    CC_PAIRING_INVALID_ARGUMENT,
    CC_PAIRING_BUSY,
    CC_PAIRING_NOT_ACTIVE,
    CC_PAIRING_REJECTED,
    CC_PAIRING_EXPIRED,
    CC_PAIRING_PEER_PENDING,
    CC_PAIRING_PERSIST_FAILED,
    CC_PAIRING_HOLD_REQUIRED,
    CC_PAIRING_HOST_NOT_FOUND,
} cc_pairing_result_t;

typedef enum {
    CC_PAIRING_IDLE = 0,
    CC_PAIRING_AWAITING_SAS,
    CC_PAIRING_AWAITING_PEER,
    CC_PAIRING_BOUND,
} cc_pairing_state_t;

typedef struct {
    char host_id[CC_PAIRING_HOST_ID_MAX + 1];
    char display_name[CC_PAIRING_DISPLAY_NAME_MAX + 1];
    char endpoint[CC_PAIRING_ENDPOINT_MAX + 1];
    uint8_t public_key[CC_PAIRING_PUBLIC_KEY_SIZE];
    uint8_t pairing_secret[CC_PAIRING_SECRET_SIZE];
} cc_pairing_host_t;

typedef bool (*cc_pairing_save_fn)(const cc_pairing_host_t *host, void *context);
typedef bool (*cc_pairing_remove_fn)(const char *host_id, void *context);

typedef struct {
    cc_pairing_state_t state;
    bool has_primary_host;
    bool local_confirmed;
    bool peer_confirmed;
    uint32_t expires_at_ms;
    char sas[CC_PAIRING_SAS_LENGTH + 1];
    cc_pairing_host_t pending_host;
    cc_pairing_host_t primary_host;
    cc_pairing_save_fn save;
    cc_pairing_remove_fn remove;
    void *storage_context;
} cc_pairing_manager_t;

void cc_pairing_init(cc_pairing_manager_t *manager,
                     cc_pairing_save_fn save,
                     cc_pairing_remove_fn remove,
                     void *storage_context);

cc_pairing_result_t cc_pairing_begin_recovery(
    cc_pairing_manager_t *manager,
    const cc_pairing_host_t *candidate,
    const char *sas,
    uint32_t now_ms,
    uint32_t timeout_ms);

/** Confirms the code shown on the device. A mismatch cancels the exchange. */
cc_pairing_result_t cc_pairing_confirm_sas(cc_pairing_manager_t *manager,
                                           bool sas_matches,
                                           uint32_t now_ms);

/** Records the authenticated peer confirmation received over encrypted BLE. */
cc_pairing_result_t cc_pairing_confirm_peer(cc_pairing_manager_t *manager,
                                            bool peer_accepted,
                                            uint32_t now_ms);

void cc_pairing_cancel(cc_pairing_manager_t *manager);
bool cc_pairing_has_primary_host(const cc_pairing_manager_t *manager);

/** Requires a continuous local hold before deleting the selected host. */
cc_pairing_result_t cc_pairing_unpair(cc_pairing_manager_t *manager,
                                      const char *host_id,
                                      uint32_t held_ms);

#endif
