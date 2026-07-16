#include "usb_audio_mode.h"

#include <stddef.h>

#include "audio_stream.h"
#include "esp_log.h"
#include "nvs.h"
#include "usb_device_uac.h"

#define CC_USB_NVS_NAMESPACE "cc_usb"
#define CC_USB_NVS_KEY "mode"

static const char *TAG = "cc_usb_uac";

cc_usb_mode_t cc_usb_mode_load(void) {
    nvs_handle_t handle;
    uint8_t raw = CC_USB_MODE_NORMAL;
    if (nvs_open(CC_USB_NVS_NAMESPACE, NVS_READONLY, &handle) == ESP_OK) {
        (void)nvs_get_u8(handle, CC_USB_NVS_KEY, &raw);
        nvs_close(handle);
    }
    return raw == CC_USB_MODE_UAC_MIC ? CC_USB_MODE_UAC_MIC : CC_USB_MODE_NORMAL;
}

bool cc_usb_mode_store(cc_usb_mode_t mode) {
    nvs_handle_t handle;
    if (nvs_open(CC_USB_NVS_NAMESPACE, NVS_READWRITE, &handle) != ESP_OK) return false;
    const esp_err_t result = nvs_set_u8(handle, CC_USB_NVS_KEY, (uint8_t)mode);
    const esp_err_t commit = result == ESP_OK ? nvs_commit(handle) : result;
    nvs_close(handle);
    return commit == ESP_OK;
}

static esp_err_t uac_input(uint8_t *buffer, size_t length, size_t *bytes_read,
                           void *context) {
    (void)context;
    if (!cc_audio_stream_read_usb_pcm16(buffer, length)) {
        return ESP_FAIL;
    }
    if (bytes_read) *bytes_read = length;
    return ESP_OK;
}

bool cc_usb_uac_start(void) {
    // usb_device_uac receives all descriptor details from sdkconfig. It is an
    // input-only, macOS-tuned 16 kHz PCM microphone in this project.
    uac_device_config_t config = {
        .skip_tinyusb_init = false,
        .output_cb = NULL,
        .input_cb = uac_input,
        .set_mute_cb = NULL,
        .set_volume_cb = NULL,
        .cb_ctx = NULL,
    };
    const esp_err_t result = uac_device_init(&config);
    if (result != ESP_OK) {
        ESP_LOGE(TAG, "UAC init failed: %s", esp_err_to_name(result));
        return false;
    }
    ESP_LOGI(TAG, "native USB UAC microphone started");
    return true;
}
