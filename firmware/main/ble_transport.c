#include "ble_transport.h"

#include <string.h>

#include "esp_log.h"
#include "ble_framing.h"
#include "host/ble_hs.h"
#include "host/ble_store.h"
#include "host/ble_uuid.h"
#include "nimble/nimble_port.h"
#include "nimble/nimble_port_freertos.h"
#include "nvs.h"
#include "services/gap/ble_svc_gap.h"
#include "services/gatt/ble_svc_gatt.h"

// ESP-IDF's NimBLE security examples declare this store initializer locally;
// the implementation is supplied by the NimBLE store-config component.
void ble_store_config_init(void);

static const char *TAG = "cc_ble";
static const ble_uuid128_t service_uuid = BLE_UUID128_INIT(
    0x01, 0x00, 0x43, 0x49, 0x4D, 0x58, 0x45, 0x44,
    0x4F, 0x43, 0x49, 0x41, 0x4E, 0x45, 0x50, 0x4F);
static const ble_uuid128_t control_uuid = BLE_UUID128_INIT(
    0x02, 0x00, 0x43, 0x49, 0x4D, 0x58, 0x45, 0x44,
    0x4F, 0x43, 0x49, 0x41, 0x4E, 0x45, 0x50, 0x4F);
static const ble_uuid128_t audio_uuid = BLE_UUID128_INIT(
    0x03, 0x00, 0x43, 0x49, 0x4D, 0x58, 0x45, 0x44,
    0x4F, 0x43, 0x49, 0x41, 0x4E, 0x45, 0x50, 0x4F);
static const ble_uuid128_t provision_uuid = BLE_UUID128_INIT(
    0x04, 0x00, 0x43, 0x49, 0x4D, 0x58, 0x45, 0x44,
    0x4F, 0x43, 0x49, 0x41, 0x4E, 0x45, 0x50, 0x4F);

static uint16_t connection_handle = BLE_HS_CONN_HANDLE_NONE;
static uint16_t control_value_handle;
static uint16_t audio_value_handle;
static bool control_subscribed;
static bool audio_subscribed;
static cc_ble_control_fn on_control;
static uint8_t hmac_key[32];
static bool has_hmac_key;
static cc_ble_reassembler_t control_reassembler;
static uint16_t outbound_frame_id;

static bool connection_is_encrypted(uint16_t handle) {
    struct ble_gap_conn_desc description;
    return ble_gap_conn_find(handle, &description) == 0 &&
           description.sec_state.encrypted;
}

static void save_hmac_key(const uint8_t key[32]) {
    nvs_handle_t handle;
    if (nvs_open("cc_security", NVS_READWRITE, &handle) != ESP_OK) return;
    if (nvs_set_blob(handle, "hmac", key, 32) == ESP_OK) nvs_commit(handle);
    nvs_close(handle);
}

static void load_hmac_key(void) {
    nvs_handle_t handle;
    size_t length = sizeof(hmac_key);
    if (nvs_open("cc_security", NVS_READONLY, &handle) != ESP_OK) return;
    if (nvs_get_blob(handle, "hmac", hmac_key, &length) == ESP_OK && length == 32) {
        has_hmac_key = true;
    }
    nvs_close(handle);
}

static int gatt_access(uint16_t conn_handle, uint16_t attr_handle,
                       struct ble_gatt_access_ctxt *context, void *argument) {
    (void)attr_handle;
    (void)argument;
    const size_t length = OS_MBUF_PKTLEN(context->om);
    if (ble_uuid_cmp(context->chr->uuid, &control_uuid.u) == 0) {
        if (length > CC_BLE_GATT_PAYLOAD_LIMIT || !on_control) {
            return BLE_ATT_ERR_INVALID_ATTR_VALUE_LEN;
        }
        uint8_t fragment[CC_BLE_GATT_PAYLOAD_LIMIT];
        if (ble_hs_mbuf_to_flat(context->om, fragment, sizeof(fragment), NULL) != 0) {
            return BLE_ATT_ERR_UNLIKELY;
        }
        size_t packet_length = 0;
        const cc_ble_frame_result_t result = cc_ble_reassembler_accept(
            &control_reassembler, fragment, length, &packet_length);
        if (result == CC_BLE_FRAME_ERROR) return BLE_ATT_ERR_UNLIKELY;
        if (result == CC_BLE_FRAME_COMPLETE) {
            on_control(control_reassembler.buffer, packet_length);
        }
        return 0;
    }
    if (ble_uuid_cmp(context->chr->uuid, &provision_uuid.u) == 0) {
        if (length != sizeof(hmac_key) || !connection_is_encrypted(conn_handle)) {
            return BLE_ATT_ERR_WRITE_NOT_PERMITTED;
        }
        uint8_t candidate[sizeof(hmac_key)];
        if (ble_hs_mbuf_to_flat(context->om, candidate, sizeof(candidate), NULL) != 0) {
            return BLE_ATT_ERR_UNLIKELY;
        }
        if (has_hmac_key) {
            uint8_t difference = 0;
            for (size_t i = 0; i < sizeof(hmac_key); ++i) {
                difference |= hmac_key[i] ^ candidate[i];
            }
            return difference == 0 ? 0 : BLE_ATT_ERR_WRITE_NOT_PERMITTED;
        }
        memcpy(hmac_key, candidate, sizeof(hmac_key));
        save_hmac_key(hmac_key);
        has_hmac_key = true;
        ESP_LOGI(TAG, "application authentication key provisioned");
        return 0;
    }
    return BLE_ATT_ERR_UNLIKELY;
}

static const struct ble_gatt_chr_def characteristics[] = {
    {
        .uuid = &control_uuid.u,
        .access_cb = gatt_access,
        .val_handle = &control_value_handle,
        .flags = BLE_GATT_CHR_F_WRITE | BLE_GATT_CHR_F_WRITE_ENC |
                 BLE_GATT_CHR_F_NOTIFY,
    },
    {
        .uuid = &audio_uuid.u,
        // NimBLE validates that every characteristic has an access callback,
        // including notify-only values. Audio is never read or written through
        // GATT, but the common handler safely rejects such access.
        .access_cb = gatt_access,
        .val_handle = &audio_value_handle,
        .flags = BLE_GATT_CHR_F_NOTIFY,
    },
    {
        .uuid = &provision_uuid.u,
        .access_cb = gatt_access,
        .flags = BLE_GATT_CHR_F_WRITE | BLE_GATT_CHR_F_WRITE_ENC,
    },
    {0},
};

static const struct ble_gatt_svc_def services[] = {
    {
        .type = BLE_GATT_SVC_TYPE_PRIMARY,
        .uuid = &service_uuid.u,
        .characteristics = characteristics,
    },
    {0},
};

static void advertise(void);

static int gap_event(struct ble_gap_event *event, void *argument) {
    (void)argument;
    switch (event->type) {
        case BLE_GAP_EVENT_CONNECT:
            if (event->connect.status == 0) {
                connection_handle = event->connect.conn_handle;
                ESP_LOGI(TAG, "connected handle=%u", connection_handle);
                ble_gap_security_initiate(connection_handle);
            } else {
                ESP_LOGW(TAG, "connect failed status=0x%02x", event->connect.status);
                advertise();
            }
            break;
        case BLE_GAP_EVENT_DISCONNECT:
            ESP_LOGW(TAG, "disconnected reason=0x%02x", event->disconnect.reason);
            connection_handle = BLE_HS_CONN_HANDLE_NONE;
            control_subscribed = false;
            audio_subscribed = false;
            advertise();
            break;
        case BLE_GAP_EVENT_SUBSCRIBE:
            if (event->subscribe.attr_handle == control_value_handle) {
                control_subscribed = event->subscribe.cur_notify;
            } else if (event->subscribe.attr_handle == audio_value_handle) {
                audio_subscribed = event->subscribe.cur_notify;
            }
            ESP_LOGI(TAG, "subscriptions control=%d audio=%d", control_subscribed,
                     audio_subscribed);
            break;
        case BLE_GAP_EVENT_ENC_CHANGE:
            ESP_LOGI(TAG, "encryption change status=%d", event->enc_change.status);
            break;
        default:
            break;
    }
    return 0;
}

static void advertise(void) {
    struct ble_hs_adv_fields fields = {0};
    fields.flags = BLE_HS_ADV_F_DISC_GEN | BLE_HS_ADV_F_BREDR_UNSUP;
    fields.uuids128 = (ble_uuid128_t *)&service_uuid;
    fields.num_uuids128 = 1;
    fields.uuids128_is_complete = 1;

    // Keep a compact, stable identity in the primary advertising packet.
    // Some macOS controller/firmware pairs surface a peripheral before they
    // deliver its scan response.  With UUID + "Codex" in the first 31 bytes,
    // the central can identify this device without weakening the encrypted
    // GATT and application-key trust boundary.
    static const uint8_t short_name[] = "Codex";
    fields.name = (uint8_t *)short_name;
    fields.name_len = sizeof(short_name) - 1;
    fields.name_is_complete = 0;

    // Flags + 128-bit UUID + the full name exceed BLE's 31-byte advertising
    // payload. The primary packet uses the short name above; the full label
    // remains available to settings UI through the scan response.
    int rc = ble_gap_adv_set_fields(&fields);
    if (rc != 0) {
        ESP_LOGE(TAG, "set advertising fields failed: %d", rc);
        return;
    }

    struct ble_hs_adv_fields scan_response = {0};
    const char *name = ble_svc_gap_device_name();
    scan_response.name = (uint8_t *)name;
    scan_response.name_len = strlen(name);
    scan_response.name_is_complete = 1;
    rc = ble_gap_adv_rsp_set_fields(&scan_response);
    if (rc != 0) {
        ESP_LOGE(TAG, "set scan response failed: %d", rc);
        return;
    }

    struct ble_gap_adv_params parameters = {0};
    parameters.conn_mode = BLE_GAP_CONN_MODE_UND;
    parameters.disc_mode = BLE_GAP_DISC_MODE_GEN;
    uint8_t own_address_type;
    if (ble_hs_id_infer_auto(0, &own_address_type) == 0) {
        rc = ble_gap_adv_start(own_address_type, NULL, BLE_HS_FOREVER, &parameters,
                               gap_event, NULL);
        if (rc != 0) ESP_LOGE(TAG, "start advertising failed: %d", rc);
    } else {
        ESP_LOGE(TAG, "unable to infer advertising address type");
    }
}

static void on_sync(void) { advertise(); }

static void host_task(void *argument) {
    (void)argument;
    nimble_port_run();
    nimble_port_freertos_deinit();
}

void cc_ble_start(cc_ble_control_fn control_callback) {
    on_control = control_callback;
    load_hmac_key();
    ESP_ERROR_CHECK(nimble_port_init());
    // Pairing keys must survive reboot. Without this store, a flashed or
    // power-cycled device drops its half of the bond while macOS retains its
    // half and refuses the next encrypted connection.
    ble_store_config_init();
    ble_svc_gap_init();
    ble_svc_gatt_init();
    ble_svc_gap_device_name_set("Codex Companion");
    ble_hs_cfg.sync_cb = on_sync;
    ble_hs_cfg.sm_io_cap = BLE_HS_IO_NO_INPUT_OUTPUT;
    ble_hs_cfg.sm_bonding = 1;
    ble_hs_cfg.sm_sc = 1;
    ble_hs_cfg.sm_mitm = 0;
    ble_hs_cfg.store_status_cb = ble_store_util_status_rr;
    ble_att_set_preferred_mtu(247);
    ESP_ERROR_CHECK(ble_gatts_count_cfg(services));
    ESP_ERROR_CHECK(ble_gatts_add_svcs(services));
    nimble_port_freertos_init(host_task);
}

static bool notify(uint16_t value_handle, bool subscribed,
                   const uint8_t *data, size_t length) {
    if (connection_handle == BLE_HS_CONN_HANDLE_NONE || !subscribed || length > 244) {
        return false;
    }
    if (!has_hmac_key || !connection_is_encrypted(connection_handle)) return false;
    struct os_mbuf *packet = ble_hs_mbuf_from_flat(data, length);
    return packet && ble_gatts_notify_custom(connection_handle, value_handle, packet) == 0;
}

bool cc_ble_is_connected(void) {
    return connection_handle != BLE_HS_CONN_HANDLE_NONE && has_hmac_key &&
           connection_is_encrypted(connection_handle);
}

bool cc_ble_notify_control(const uint8_t *data, size_t length) {
    const uint8_t count = cc_ble_fragment_count(length);
    if (count == 0) return false;
    const uint16_t frame_id = ++outbound_frame_id;
    uint8_t fragment[CC_BLE_GATT_PAYLOAD_LIMIT];
    for (uint8_t index = 0; index < count; ++index) {
        const size_t fragment_length = cc_ble_make_fragment(
            frame_id, index, count, data, length, fragment, sizeof(fragment));
        if (fragment_length == 0 ||
            !notify(control_value_handle, control_subscribed,
                    fragment, fragment_length)) return false;
    }
    return true;
}

bool cc_ble_notify_audio(const uint8_t *data, size_t length) {
    return notify(audio_value_handle, audio_subscribed, data, length);
}

bool cc_ble_copy_hmac_key(uint8_t output[32]) {
    if (!has_hmac_key) return false;
    memcpy(output, hmac_key, sizeof(hmac_key));
    return true;
}

bool cc_ble_clear_pairing(void) {
    // Pairing reset is explicitly user-triggered in the Connection Center.
    // Clear both layers together: leaving either a BLE bond or the app HMAC
    // behind would make the next Mac appear paired but fail provisioning.
    const int store_result = ble_store_clear();
    esp_err_t key_result = ESP_OK;
    nvs_handle_t handle;
    if (nvs_open("cc_security", NVS_READWRITE, &handle) == ESP_OK) {
        key_result = nvs_erase_key(handle, "hmac");
        if (key_result == ESP_ERR_NVS_NOT_FOUND) key_result = ESP_OK;
        if (key_result == ESP_OK) key_result = nvs_commit(handle);
        nvs_close(handle);
    } else {
        key_result = ESP_FAIL;
    }
    memset(hmac_key, 0, sizeof(hmac_key));
    has_hmac_key = false;
    control_subscribed = false;
    audio_subscribed = false;
    memset(&control_reassembler, 0, sizeof(control_reassembler));
    outbound_frame_id = 0;

    if (connection_handle != BLE_HS_CONN_HANDLE_NONE) {
        (void)ble_gap_terminate(connection_handle, BLE_ERR_REM_USER_CONN_TERM);
    } else {
        advertise();
    }
    const bool cleared = store_result == 0 && key_result == ESP_OK;
    ESP_LOGI(TAG, "pairing reset %s", cleared ? "complete" : "incomplete");
    return cleared;
}
