#include "wifi_manager.h"

#include <inttypes.h>
#include <stdio.h>
#include <string.h>

#include "esp_event.h"
#include "esp_heap_caps.h"
#include "esp_http_server.h"
#include "esp_log.h"
#include "esp_mac.h"
#include "esp_netif.h"
#include "esp_random.h"
#include "esp_wifi.h"
#include "nvs.h"

static cc_wifi_model_t g_model;
static const char *TAG = "cc_wifi";
static bool g_initialized;
static bool g_event_loop_owned;
static esp_netif_t *g_sta_netif;
static esp_netif_t *g_ap_netif;
static httpd_handle_t g_portal;
static bool g_reconnect_after_disconnect;
static bool g_realtime;
static char g_portal_hint[96] = "网络：尚未配置";
static char g_manual_host[CC_WIFI_MANUAL_HOST_MAX_LEN];

#define CC_WIFI_NVS_NAMESPACE "cc_wifi"
#define CC_WIFI_NVS_HOST_KEY "mac_host"
#define CC_WIFI_SOFTAP_MIN_INTERNAL_FREE (24U * 1024U)
#define CC_WIFI_SOFTAP_MIN_INTERNAL_BLOCK (8U * 1024U)

static void set_hint(const char *text) {
    snprintf(g_portal_hint, sizeof(g_portal_hint), "%s", text ? text : "网络：发生错误");
}

static void copy_wifi_field(uint8_t *destination, size_t capacity, const char *source) {
    if (!destination || capacity == 0 || !source) return;
    const size_t length = strnlen(source, capacity);
    memcpy(destination, source, length);
}

static int hex_value(char c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

static bool form_value(const char *body, const char *name, char *output,
                       size_t output_size) {
    if (!body || !name || !output || output_size == 0) return false;
    const size_t name_length = strlen(name);
    const char *cursor = body;
    while (cursor && *cursor) {
        const char *next = strchr(cursor, '&');
        if (strncmp(cursor, name, name_length) == 0 && cursor[name_length] == '=') {
            cursor += name_length + 1;
            size_t written = 0;
            while (*cursor && cursor != next) {
                char value = *cursor++;
                if (value == '+') value = ' ';
                else if (value == '%' && cursor[0] && cursor[1]) {
                    const int high = hex_value(cursor[0]);
                    const int low = hex_value(cursor[1]);
                    if (high < 0 || low < 0) return false;
                    value = (char)((high << 4) | low);
                    cursor += 2;
                }
                if (written + 1 >= output_size) return false;
                output[written++] = value;
            }
            output[written] = '\0';
            return true;
        }
        cursor = next ? next + 1 : NULL;
    }
    return false;
}

static void load_manual_host(void) {
    g_manual_host[0] = '\0';
    nvs_handle_t handle;
    size_t length = sizeof(g_manual_host);
    if (nvs_open(CC_WIFI_NVS_NAMESPACE, NVS_READONLY, &handle) == ESP_OK) {
        if (nvs_get_str(handle, CC_WIFI_NVS_HOST_KEY, g_manual_host, &length) != ESP_OK ||
            !cc_wifi_is_valid_ipv4(g_manual_host)) {
            g_manual_host[0] = '\0';
        }
        nvs_close(handle);
    }
}

static bool save_manual_host(const char *host) {
    nvs_handle_t handle;
    if (nvs_open(CC_WIFI_NVS_NAMESPACE, NVS_READWRITE, &handle) != ESP_OK) return false;
    esp_err_t result = ESP_OK;
    if (host && *host) result = nvs_set_str(handle, CC_WIFI_NVS_HOST_KEY, host);
    else result = nvs_erase_key(handle, CC_WIFI_NVS_HOST_KEY);
    if (result == ESP_ERR_NVS_NOT_FOUND) result = ESP_OK;
    if (result == ESP_OK) result = nvs_commit(handle);
    nvs_close(handle);
    if (result != ESP_OK) return false;
    snprintf(g_manual_host, sizeof(g_manual_host), "%s", host ? host : "");
    return true;
}

static void stop_portal(void) {
    if (g_portal) {
        httpd_stop(g_portal);
        g_portal = NULL;
    }
}

static esp_err_t portal_root(httpd_req_t *request) {
    static const char page[] =
        "<!doctype html><meta name=viewport content='width=device-width,initial-scale=1'>"
        "<title>Codex Companion</title><style>body{background:#020304;color:#d7fff0;"
        "font-family:-apple-system,sans-serif;margin:28px}input,button{display:block;width:100%;"
        "box-sizing:border-box;margin:12px 0;padding:13px;background:#0e1b20;color:#d7fff0;"
        "border:1px solid #00d1b8;border-radius:8px}button{background:#0b4f37;font-weight:700}</style>"
        "<h1>Codex Companion</h1><p>为设备配置 Wi-Fi。</p>"
        "<form method=post action=/configure><input name=ssid placeholder='Wi-Fi 名称' required>"
        "<input name=password type=password placeholder='密码（开放网络留空）'>"
        "<input name=mac_host inputmode=decimal placeholder='Mac IPv4 备用地址（可选）'>"
        "<button>连接</button></form><p>留空 Mac IPv4 可自动发现；连接成功后设置热点会关闭。</p>";
    httpd_resp_set_type(request, "text/html; charset=utf-8");
    return httpd_resp_send(request, page, HTTPD_RESP_USE_STRLEN);
}

static esp_err_t portal_configure(httpd_req_t *request) {
    if (request->content_len <= 0 || request->content_len > 384) {
        httpd_resp_send_err(request, HTTPD_400_BAD_REQUEST, "invalid request");
        return ESP_FAIL;
    }
    char body[385] = {0};
    int received = httpd_req_recv(request, body, request->content_len);
    if (received != request->content_len) {
        httpd_resp_send_err(request, HTTPD_500_INTERNAL_SERVER_ERROR, "read failed");
        return ESP_FAIL;
    }
    char ssid[sizeof(((wifi_config_t *)0)->sta.ssid)] = {0};
    char password[sizeof(((wifi_config_t *)0)->sta.password)] = {0};
    char manual_host[CC_WIFI_MANUAL_HOST_MAX_LEN] = {0};
    if (!form_value(body, "ssid", ssid, sizeof(ssid)) || ssid[0] == '\0' ||
        !form_value(body, "password", password, sizeof(password))) {
        httpd_resp_send_err(request, HTTPD_400_BAD_REQUEST, "缺少 Wi-Fi 名称");
        return ESP_FAIL;
    }
    if (form_value(body, "mac_host", manual_host, sizeof(manual_host)) &&
        manual_host[0] && !cc_wifi_is_valid_ipv4(manual_host)) {
        httpd_resp_send_err(request, HTTPD_400_BAD_REQUEST, "Mac 备用地址必须是 IPv4");
        return ESP_FAIL;
    }
    if (!save_manual_host(manual_host)) {
        httpd_resp_send_err(request, HTTPD_500_INTERNAL_SERVER_ERROR, "无法保存 Mac 备用地址");
        return ESP_FAIL;
    }
    wifi_config_t config = {0};
    copy_wifi_field(config.sta.ssid, sizeof(config.sta.ssid), ssid);
    copy_wifi_field(config.sta.password, sizeof(config.sta.password), password);
    config.sta.scan_method = WIFI_ALL_CHANNEL_SCAN;
    config.sta.failure_retry_cnt = 5;
    // The ESP-IDF station configuration owns its normal NVS persistence. The
    // setup page itself is protected by a per-session WPA2 AP password; a
    // secure-NVS migration remains required before production deployment.
    if (esp_wifi_set_storage(WIFI_STORAGE_FLASH) != ESP_OK ||
        esp_wifi_set_config(WIFI_IF_STA, &config) != ESP_OK) {
        httpd_resp_send_err(request, HTTPD_500_INTERNAL_SERVER_ERROR, "Wi-Fi 设置失败");
        return ESP_FAIL;
    }
    cc_wifi_event(&g_model, CC_WIFI_CREDENTIALS_ACCEPTED, 0);
    set_hint("网络：正在连接");
    // Keep APSTA active until the station obtains an IP. Closing the setup AP
    // here destroys the HTTP response and, when STA is already associated,
    // esp_wifi_connect() refuses to switch to the newly saved credentials.
    // Drive the reconnect from WIFI_EVENT_STA_DISCONNECTED instead.
    g_reconnect_after_disconnect = true;
    const esp_err_t disconnect_result = esp_wifi_disconnect();
    if (disconnect_result == ESP_ERR_WIFI_NOT_CONNECT) {
        g_reconnect_after_disconnect = false;
        if (esp_wifi_connect() != ESP_OK) {
            cc_wifi_event(&g_model, CC_WIFI_CONNECTION_FAILED, 0);
            set_hint("网络：连接失败");
            httpd_resp_send_err(request, HTTPD_500_INTERNAL_SERVER_ERROR,
                                "Wi-Fi 连接失败");
            return ESP_FAIL;
        }
    } else if (disconnect_result != ESP_OK) {
        g_reconnect_after_disconnect = false;
        cc_wifi_event(&g_model, CC_WIFI_CONNECTION_FAILED, 0);
        set_hint("网络：连接失败");
        httpd_resp_send_err(request, HTTPD_500_INTERNAL_SERVER_ERROR,
                            "Wi-Fi 设置失败");
        return ESP_FAIL;
    }
    httpd_resp_sendstr(request, "正在连接，请返回设备屏幕查看状态。");
    // The portal is stopped by IP_EVENT_STA_GOT_IP, outside this HTTPD request
    // callback, so its response context cannot be destroyed mid-send.
    return ESP_OK;
}

static void wifi_event_handler(void *context, esp_event_base_t base,
                               int32_t id, void *event_data) {
    (void)context;
    (void)event_data;
    if (base == WIFI_EVENT && id == WIFI_EVENT_STA_DISCONNECTED) {
        if (g_reconnect_after_disconnect) {
            g_reconnect_after_disconnect = false;
            if (esp_wifi_connect() != ESP_OK) {
                cc_wifi_event(&g_model, CC_WIFI_CONNECTION_FAILED, 0);
                set_hint("网络：连接失败");
            }
            return;
        }
        if (g_model.state == CC_WIFI_STA_CONNECTING ||
            g_model.state == CC_WIFI_CONNECTED) {
            cc_wifi_event(&g_model, CC_WIFI_CONNECTION_FAILED, 0);
            set_hint("网络：连接失败");
        }
    } else if (base == IP_EVENT && id == IP_EVENT_STA_GOT_IP) {
        cc_wifi_event(&g_model, CC_WIFI_STA_GOT_IP, 0);
        set_hint("网络：已连接");
        stop_portal();
        // The response has completed and STA is usable; now retire the setup
        // AP so the device returns to normal station-only operation.
        if (g_ap_netif) (void)esp_wifi_set_mode(WIFI_MODE_STA);
    }
}

bool cc_wifi_start(void) {
    g_model = cc_wifi_model_initial();
    if (g_initialized) return true;
    load_manual_host();
    if (esp_netif_init() != ESP_OK) return false;
    const esp_err_t loop = esp_event_loop_create_default();
    if (loop == ESP_OK) g_event_loop_owned = true;
    else if (loop != ESP_ERR_INVALID_STATE) return false;
    g_sta_netif = esp_netif_create_default_wifi_sta();
    if (!g_sta_netif) return false;
    const wifi_init_config_t init = WIFI_INIT_CONFIG_DEFAULT();
    if (esp_wifi_init(&init) != ESP_OK) return false;
    ESP_ERROR_CHECK(esp_event_handler_register(WIFI_EVENT, ESP_EVENT_ANY_ID,
                                               wifi_event_handler, NULL));
    ESP_ERROR_CHECK(esp_event_handler_register(IP_EVENT, IP_EVENT_STA_GOT_IP,
                                               wifi_event_handler, NULL));
    wifi_config_t existing = {0};
    if (esp_wifi_get_config(WIFI_IF_STA, &existing) != ESP_OK) return false;
    if (esp_wifi_set_mode(WIFI_MODE_STA) != ESP_OK || esp_wifi_start() != ESP_OK) return false;
    // Idle control/weather traffic is bursty, so modem sleep materially
    // extends battery standby. PTT temporarily disables it through
    // cc_wifi_set_realtime() before the first 20 ms microphone frame.
    if (esp_wifi_set_ps(WIFI_PS_MIN_MODEM) != ESP_OK) return false;
    g_realtime = false;
    g_initialized = true;
    if (existing.sta.ssid[0]) {
        cc_wifi_event(&g_model, CC_WIFI_CREDENTIALS_ACCEPTED, 0);
        set_hint("网络：正在连接");
        (void)esp_wifi_connect();
    } else {
        set_hint("网络：尚未配置");
    }
    return true;
}

void cc_wifi_set_realtime(bool enabled) {
    if (!g_initialized || g_realtime == enabled) return;
    const wifi_ps_type_t mode = enabled ? WIFI_PS_NONE : WIFI_PS_MIN_MODEM;
    const esp_err_t result = esp_wifi_set_ps(mode);
    if (result != ESP_OK) {
        ESP_LOGW(TAG, "failed to set Wi-Fi power mode: %s",
                 esp_err_to_name(result));
        return;
    }
    g_realtime = enabled;
    ESP_LOGI(TAG, "Wi-Fi power mode: %s",
             enabled ? "microphone realtime" : "idle modem sleep");
}

bool cc_wifi_begin_provisioning(void) {
    if (!g_initialized && !cc_wifi_start()) return false;
    ESP_LOGI(TAG, "before SoftAP: internal=%u largest=%u psram=%u",
             (unsigned)heap_caps_get_free_size(MALLOC_CAP_INTERNAL),
             (unsigned)heap_caps_get_largest_free_block(MALLOC_CAP_INTERNAL),
             (unsigned)heap_caps_get_free_size(MALLOC_CAP_SPIRAM));
    if (!g_ap_netif) g_ap_netif = esp_netif_create_default_wifi_ap();
    if (!g_ap_netif) return false;
    const size_t internal_free = heap_caps_get_free_size(MALLOC_CAP_INTERNAL);
    const size_t internal_largest =
        heap_caps_get_largest_free_block(MALLOC_CAP_INTERNAL);
    if (internal_free < CC_WIFI_SOFTAP_MIN_INTERNAL_FREE ||
        internal_largest < CC_WIFI_SOFTAP_MIN_INTERNAL_BLOCK) {
        ESP_LOGE(TAG,
                 "refusing SoftAP: internal=%u largest=%u (minimum %u/%u)",
                 (unsigned)internal_free, (unsigned)internal_largest,
                 (unsigned)CC_WIFI_SOFTAP_MIN_INTERNAL_FREE,
                 (unsigned)CC_WIFI_SOFTAP_MIN_INTERNAL_BLOCK);
        set_hint("网络：启动失败");
        return false;
    }
    uint8_t mac[6] = {0};
    esp_read_mac(mac, ESP_MAC_WIFI_STA);
    const uint32_t random = esp_random();
    char ssid[33];
    char password[17];
    snprintf(ssid, sizeof(ssid), "Codex-%02X%02X", mac[4], mac[5]);
    snprintf(password, sizeof(password), "%08" PRIX32, random);
    wifi_config_t ap = {0};
    copy_wifi_field(ap.ap.ssid, sizeof(ap.ap.ssid), ssid);
    copy_wifi_field(ap.ap.password, sizeof(ap.ap.password), password);
    ap.ap.ssid_len = strlen(ssid);
    ap.ap.channel = 1;
    ap.ap.max_connection = 2;
    ap.ap.authmode = WIFI_AUTH_WPA2_PSK;
    if (esp_wifi_set_mode(WIFI_MODE_APSTA) != ESP_OK ||
        esp_wifi_set_config(WIFI_IF_AP, &ap) != ESP_OK) return false;
    ESP_LOGI(TAG, "after SoftAP: internal=%u largest=%u psram=%u",
             (unsigned)heap_caps_get_free_size(MALLOC_CAP_INTERNAL),
             (unsigned)heap_caps_get_largest_free_block(MALLOC_CAP_INTERNAL),
             (unsigned)heap_caps_get_free_size(MALLOC_CAP_SPIRAM));
    if (!g_portal) {
        httpd_config_t config = HTTPD_DEFAULT_CONFIG();
        config.max_uri_handlers = 4;
        if (httpd_start(&g_portal, &config) != ESP_OK) return false;
        const httpd_uri_t root = {.uri = "/", .method = HTTP_GET, .handler = portal_root};
        const httpd_uri_t configure = {.uri = "/configure", .method = HTTP_POST,
                                       .handler = portal_configure};
        if (httpd_register_uri_handler(g_portal, &root) != ESP_OK ||
            httpd_register_uri_handler(g_portal, &configure) != ESP_OK) {
            stop_portal();
            return false;
        }
    }
    cc_wifi_event(&g_model, CC_WIFI_BEGIN_PROVISIONING, 0);
    snprintf(g_portal_hint, sizeof(g_portal_hint), "设置热点 %s / 密码 %s / 192.168.4.1",
             ssid, password);
    ESP_LOGI(TAG, "%s", g_portal_hint);
    return true;
}

cc_wifi_state_t cc_wifi_status(void) {
    return g_model.state;
}

const char *cc_wifi_portal_hint(void) { return g_portal_hint; }

bool cc_wifi_copy_manual_host(char *output, size_t output_size) {
    if (!output || output_size == 0 || !g_manual_host[0]) return false;
    snprintf(output, output_size, "%s", g_manual_host);
    return true;
}

bool cc_wifi_get_subnet_broadcast(uint32_t *address) {
    if (!address || !g_sta_netif) return false;
    esp_netif_ip_info_t info = {0};
    if (esp_netif_get_ip_info(g_sta_netif, &info) != ESP_OK ||
        info.ip.addr == 0 || info.netmask.addr == 0) {
        return false;
    }
    *address = info.ip.addr | ~info.netmask.addr;
    return true;
}

void cc_wifi_clear_credentials(void) {
    stop_portal();
    if (g_initialized) {
        (void)esp_wifi_disconnect();
        (void)esp_wifi_restore();
    }
    cc_wifi_event(&g_model, CC_WIFI_CLEAR_CREDENTIALS, 0);
    set_hint("网络：尚未配置");
}
