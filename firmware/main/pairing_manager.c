#include "pairing_manager.h"

#include <string.h>

static bool cc_pairing_string_fits(const char *value, size_t max_length,
                                   bool allow_empty) {
    if (value == NULL) return false;
    size_t length = strnlen(value, max_length + 1U);
    return (allow_empty || length > 0U) && length <= max_length;
}

static bool cc_pairing_sas_is_valid(const char *sas) {
    if (!cc_pairing_string_fits(sas, CC_PAIRING_SAS_LENGTH, false) ||
        strlen(sas) != CC_PAIRING_SAS_LENGTH) {
        return false;
    }
    for (size_t index = 0; index < CC_PAIRING_SAS_LENGTH; index++) {
        if (sas[index] < '0' || sas[index] > '9') return false;
    }
    return true;
}

static bool cc_pairing_bytes_have_entropy(const uint8_t *bytes, size_t length) {
    uint8_t combined = 0;
    for (size_t index = 0; index < length; index++) combined |= bytes[index];
    return combined != 0;
}

static bool cc_pairing_host_is_valid(const cc_pairing_host_t *host) {
    return host != NULL &&
           cc_pairing_string_fits(host->host_id, CC_PAIRING_HOST_ID_MAX, false) &&
           cc_pairing_string_fits(host->display_name,
                                  CC_PAIRING_DISPLAY_NAME_MAX, false) &&
           cc_pairing_string_fits(host->endpoint,
                                  CC_PAIRING_ENDPOINT_MAX, true) &&
           cc_pairing_bytes_have_entropy(host->public_key,
                                         sizeof(host->public_key)) &&
           cc_pairing_bytes_have_entropy(host->pairing_secret,
                                         sizeof(host->pairing_secret));
}

static bool cc_pairing_deadline_passed(uint32_t now_ms, uint32_t deadline_ms) {
    return (int32_t)(now_ms - deadline_ms) > 0;
}

static void cc_pairing_clear_pending(cc_pairing_manager_t *manager) {
    memset(&manager->pending_host, 0, sizeof(manager->pending_host));
    memset(manager->sas, 0, sizeof(manager->sas));
    manager->local_confirmed = false;
    manager->peer_confirmed = false;
    manager->expires_at_ms = 0;
    manager->state = manager->has_primary_host ? CC_PAIRING_BOUND : CC_PAIRING_IDLE;
}

static cc_pairing_result_t cc_pairing_check_active(
    cc_pairing_manager_t *manager, uint32_t now_ms) {
    if (manager == NULL) return CC_PAIRING_INVALID_ARGUMENT;
    if (manager->state != CC_PAIRING_AWAITING_SAS &&
        manager->state != CC_PAIRING_AWAITING_PEER) {
        return CC_PAIRING_NOT_ACTIVE;
    }
    if (cc_pairing_deadline_passed(now_ms, manager->expires_at_ms)) {
        cc_pairing_clear_pending(manager);
        return CC_PAIRING_EXPIRED;
    }
    return CC_PAIRING_OK;
}

static cc_pairing_result_t cc_pairing_commit_if_ready(
    cc_pairing_manager_t *manager) {
    if (!manager->local_confirmed || !manager->peer_confirmed) {
        manager->state = CC_PAIRING_AWAITING_PEER;
        return CC_PAIRING_PEER_PENDING;
    }
    if (manager->save == NULL ||
        !manager->save(&manager->pending_host, manager->storage_context)) {
        cc_pairing_clear_pending(manager);
        return CC_PAIRING_PERSIST_FAILED;
    }
    manager->primary_host = manager->pending_host;
    manager->has_primary_host = true;
    cc_pairing_clear_pending(manager);
    return CC_PAIRING_OK;
}

void cc_pairing_init(cc_pairing_manager_t *manager,
                     cc_pairing_save_fn save,
                     cc_pairing_remove_fn remove,
                     void *storage_context) {
    if (manager == NULL) return;
    memset(manager, 0, sizeof(*manager));
    manager->save = save;
    manager->remove = remove;
    manager->storage_context = storage_context;
}

cc_pairing_result_t cc_pairing_begin_recovery(
    cc_pairing_manager_t *manager,
    const cc_pairing_host_t *candidate,
    const char *sas,
    uint32_t now_ms,
    uint32_t timeout_ms) {
    if (manager == NULL || !cc_pairing_host_is_valid(candidate) ||
        !cc_pairing_sas_is_valid(sas)) {
        return CC_PAIRING_INVALID_ARGUMENT;
    }
    if (manager->state == CC_PAIRING_AWAITING_SAS ||
        manager->state == CC_PAIRING_AWAITING_PEER) {
        return CC_PAIRING_BUSY;
    }
    manager->pending_host = *candidate;
    memcpy(manager->sas, sas, CC_PAIRING_SAS_LENGTH + 1U);
    manager->local_confirmed = false;
    manager->peer_confirmed = false;
    if (timeout_ms == 0U) timeout_ms = CC_PAIRING_DEFAULT_TIMEOUT_MS;
    manager->expires_at_ms = now_ms + timeout_ms;
    manager->state = CC_PAIRING_AWAITING_SAS;
    return CC_PAIRING_OK;
}

cc_pairing_result_t cc_pairing_confirm_sas(cc_pairing_manager_t *manager,
                                           bool sas_matches,
                                           uint32_t now_ms) {
    cc_pairing_result_t active = cc_pairing_check_active(manager, now_ms);
    if (active != CC_PAIRING_OK) return active;
    if (!sas_matches) {
        cc_pairing_clear_pending(manager);
        return CC_PAIRING_REJECTED;
    }
    manager->local_confirmed = true;
    return cc_pairing_commit_if_ready(manager);
}

cc_pairing_result_t cc_pairing_confirm_peer(cc_pairing_manager_t *manager,
                                            bool peer_accepted,
                                            uint32_t now_ms) {
    cc_pairing_result_t active = cc_pairing_check_active(manager, now_ms);
    if (active != CC_PAIRING_OK) return active;
    if (!peer_accepted) {
        cc_pairing_clear_pending(manager);
        return CC_PAIRING_REJECTED;
    }
    manager->peer_confirmed = true;
    return cc_pairing_commit_if_ready(manager);
}

void cc_pairing_cancel(cc_pairing_manager_t *manager) {
    if (manager != NULL) cc_pairing_clear_pending(manager);
}

bool cc_pairing_has_primary_host(const cc_pairing_manager_t *manager) {
    return manager != NULL && manager->has_primary_host;
}

cc_pairing_result_t cc_pairing_unpair(cc_pairing_manager_t *manager,
                                      const char *host_id,
                                      uint32_t held_ms) {
    if (manager == NULL ||
        !cc_pairing_string_fits(host_id, CC_PAIRING_HOST_ID_MAX, false)) {
        return CC_PAIRING_INVALID_ARGUMENT;
    }
    if (!manager->has_primary_host ||
        strcmp(manager->primary_host.host_id, host_id) != 0) {
        return CC_PAIRING_HOST_NOT_FOUND;
    }
    if (held_ms < CC_PAIRING_DESTRUCTIVE_HOLD_MS) {
        return CC_PAIRING_HOLD_REQUIRED;
    }
    if (manager->remove == NULL ||
        !manager->remove(host_id, manager->storage_context)) {
        return CC_PAIRING_PERSIST_FAILED;
    }
    memset(&manager->primary_host, 0, sizeof(manager->primary_host));
    manager->has_primary_host = false;
    manager->state = CC_PAIRING_IDLE;
    return CC_PAIRING_OK;
}
