#include "wifi_transport.h"

#include <errno.h>
#include <string.h>

#include "ble_transport.h"
#include "esp_log.h"
#include "esp_random.h"
#include "esp_timer.h"
#include "lwip/inet.h"
#include "lwip/sockets.h"
#include "mdns.h"
#include "wifi_manager.h"
#include "wifi_wire.h"

#include "freertos/FreeRTOS.h"
#include "freertos/semphr.h"
#include "freertos/task.h"

#define CC_WIFI_DISCOVERY_INTERVAL_MS 3000
#define CC_WIFI_QUERY_TIMEOUT_MS 700
#define CC_WIFI_UDP_PROBE_TIMEOUT_MS 350
#define CC_WIFI_SOCKET_TIMEOUT_SEC 3
#define CC_WIFI_DEFAULT_PORT 49152
#define CC_WIFI_DISCOVERY_PORT 49153

static const uint8_t k_discovery_request[] = "CCDISC2";
static const uint8_t k_discovery_response[] = "CCHOST2";

static const char *TAG = "cc_wifi_link";
static cc_wifi_control_fn g_control_callback;
static SemaphoreHandle_t g_socket_lock;
static int g_socket = -1;
static bool g_connected;
static cc_wifi_session_keys_t g_keys;
static uint64_t g_session_id;
static uint32_t g_outbound_sequence;
static uint64_t g_last_missing_secret_log_ms;

static uint64_t now_ms(void) {
    return (uint64_t)(esp_timer_get_time() / 1000);
}

static void receive_control_loop(int socket_fd);

static bool send_all(int socket_fd, const uint8_t *data, size_t length) {
    while (length > 0) {
        const int sent = send(socket_fd, data, length, 0);
        if (sent <= 0) return false;
        data += sent;
        length -= (size_t)sent;
    }
    return true;
}

static bool receive_exact(int socket_fd, uint8_t *output, size_t length) {
    while (length > 0) {
        const int received = recv(socket_fd, output, length, 0);
        if (received <= 0) return false;
        output += received;
        length -= (size_t)received;
    }
    return true;
}

static void mark_disconnected(int socket_fd) {
    if (socket_fd >= 0) shutdown(socket_fd, SHUT_RDWR);
    if (socket_fd >= 0) close(socket_fd);
    if (g_socket_lock) xSemaphoreTake(g_socket_lock, portMAX_DELAY);
    if (g_socket == socket_fd) g_socket = -1;
    g_connected = false;
    memset(&g_keys, 0, sizeof(g_keys));
    g_session_id = 0;
    g_outbound_sequence = 0;
    if (g_socket_lock) xSemaphoreGive(g_socket_lock);
}

static bool connect_to_ipv4(uint32_t address, uint16_t port, int *socket_fd) {
    if (address == 0 || port == 0 || !socket_fd) return false;
    int fd = socket(AF_INET, SOCK_STREAM, IPPROTO_IP);
    if (fd < 0) return false;
    const struct timeval timeout = {
        .tv_sec = CC_WIFI_SOCKET_TIMEOUT_SEC,
        .tv_usec = 0,
    };
    (void)setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
    (void)setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));
    struct sockaddr_in destination = {0};
    destination.sin_family = AF_INET;
    destination.sin_port = htons(port);
    destination.sin_addr.s_addr = address;
    if (connect(fd, (struct sockaddr *)&destination, sizeof(destination)) != 0) {
        close(fd);
        return false;
    }
    *socket_fd = fd;
    return true;
}

static bool connect_to_result(const mdns_result_t *result, int *socket_fd) {
    if (!result || !result->addr || result->port == 0 || !socket_fd) return false;
    const mdns_ip_addr_t *address = result->addr;
    while (address && address->addr.type != ESP_IPADDR_TYPE_V4) address = address->next;
    return address && connect_to_ipv4(address->addr.u_addr.ip4.addr, result->port,
                                      socket_fd);
}

static bool connect_to_manual_host(int *socket_fd) {
    char host[CC_WIFI_MANUAL_HOST_MAX_LEN] = {0};
    if (!cc_wifi_copy_manual_host(host, sizeof(host))) return false;
    struct in_addr address = {0};
    if (inet_pton(AF_INET, host, &address) != 1) return false;
    return connect_to_ipv4(address.s_addr, CC_WIFI_DEFAULT_PORT, socket_fd);
}

static bool establish_session(int socket_fd) {
    uint8_t pairing_secret[CC_WIFI_PAIRING_SECRET_SIZE];
    uint8_t device_nonce[CC_WIFI_SESSION_NONCE_SIZE];
    uint8_t host_nonce[CC_WIFI_SESSION_NONCE_SIZE];
    uint8_t packet[CC_WIFI_HANDSHAKE_SIZE];
    if (!cc_ble_copy_hmac_key(pairing_secret)) {
        const uint64_t now = now_ms();
        if (g_last_missing_secret_log_ms == 0 ||
            now - g_last_missing_secret_log_ms >= 30000) {
            ESP_LOGW(TAG, "Wi-Fi discovery found no device pairing secret; pair over BLE first");
            g_last_missing_secret_log_ms = now;
        }
        return false;
    }
    esp_fill_random(device_nonce, sizeof(device_nonce));
    if (cc_wifi_encode_handshake(CC_WIFI_HANDSHAKE_DEVICE, device_nonce,
                                 pairing_secret, packet) != CC_WIFI_WIRE_OK ||
        !send_all(socket_fd, packet, sizeof(packet)) ||
        !receive_exact(socket_fd, packet, sizeof(packet)) ||
        cc_wifi_decode_handshake(packet, CC_WIFI_HANDSHAKE_HOST, pairing_secret,
                                 host_nonce) != CC_WIFI_WIRE_OK) {
        ESP_LOGW(TAG, "candidate host rejected the authenticated Wi-Fi handshake");
        memset(pairing_secret, 0, sizeof(pairing_secret));
        return false;
    }
    uint8_t session_nonce[CC_WIFI_SESSION_NONCE_SIZE];
    const cc_wifi_wire_result_t result = cc_wifi_make_session_nonce(
        device_nonce, host_nonce, session_nonce);
    if (result != CC_WIFI_WIRE_OK ||
        cc_wifi_derive_session_keys(pairing_secret, sizeof(pairing_secret),
                                    session_nonce, &g_keys) != CC_WIFI_WIRE_OK) {
        memset(pairing_secret, 0, sizeof(pairing_secret));
        return false;
    }
    g_session_id = cc_wifi_session_id_from_nonce(session_nonce);
    g_outbound_sequence = 0;
    memset(pairing_secret, 0, sizeof(pairing_secret));
    return g_session_id != 0;
}

static bool run_authenticated_connection(int socket_fd, const char *transport_name) {
    if (!establish_session(socket_fd)) {
        close(socket_fd);
        return false;
    }
    if (g_socket_lock) xSemaphoreTake(g_socket_lock, portMAX_DELAY);
    g_socket = socket_fd;
    g_connected = true;
    if (g_socket_lock) xSemaphoreGive(g_socket_lock);
    ESP_LOGI(TAG, "authenticated %s Wi-Fi control connected", transport_name);
    receive_control_loop(socket_fd);
    mark_disconnected(socket_fd);
    return true;
}

static void receive_control_loop(int socket_fd) {
    cc_wifi_replay_window_t replay_window = {0};
    uint8_t packet[CC_WIFI_MAX_PACKET_SIZE];
    uint8_t payload[CC_WIFI_MAX_PAYLOAD_SIZE];
    while (g_connected) {
        uint8_t length_bytes[2];
        if (!receive_exact(socket_fd, length_bytes, sizeof(length_bytes))) break;
        const size_t length = (size_t)((uint16_t)length_bytes[0] << 8 | length_bytes[1]);
        if (length == 0 || length > sizeof(packet) ||
            !receive_exact(socket_fd, packet, length)) break;
        cc_wifi_frame_t frame = {0};
        if (cc_wifi_decode_frame(packet, length, g_keys.control_key, &frame,
                                 payload, sizeof(payload)) != CC_WIFI_WIRE_OK ||
            frame.kind != CC_WIFI_FRAME_CONTROL || frame.session_id != g_session_id ||
            cc_wifi_replay_accept(&replay_window, frame.session_id,
                                  frame.sequence) != CC_WIFI_WIRE_OK) {
            ESP_LOGW(TAG, "rejected Wi-Fi control frame");
            break;
        }
        if (g_control_callback) g_control_callback(frame.payload, frame.payload_len);
    }
}

static bool discover_and_connect(void) {
    mdns_result_t *results = NULL;
    if (mdns_query_ptr("_codex-companion", "_tcp", CC_WIFI_QUERY_TIMEOUT_MS,
                       4, &results) != ESP_OK) {
        return false;
    }
    bool connected = false;
    for (mdns_result_t *result = results; result && !connected; result = result->next) {
        // TXT fields are only hints for candidate selection. The subsequent
        // HMAC handshake is the authority; a forged mDNS response cannot gain
        // control of the device.
        int fd = -1;
        if (connect_to_result(result, &fd)) connected = run_authenticated_connection(fd, "Bonjour");
    }
    mdns_query_results_free(results);
    return connected;
}

static bool connect_manual_fallback(void) {
    int fd = -1;
    if (!connect_to_manual_host(&fd)) return false;
    return run_authenticated_connection(fd, "manual");
}

static bool discover_broadcast_fallback(void) {
    int udp_fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_IP);
    if (udp_fd < 0) return false;
    const int enabled = 1;
    const struct timeval timeout = {
        .tv_sec = 0,
        .tv_usec = CC_WIFI_UDP_PROBE_TIMEOUT_MS * 1000,
    };
    (void)setsockopt(udp_fd, SOL_SOCKET, SO_BROADCAST, &enabled, sizeof(enabled));
    (void)setsockopt(udp_fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
    uint32_t broadcast_address = htonl(INADDR_BROADCAST);
    (void)cc_wifi_get_subnet_broadcast(&broadcast_address);
    const struct sockaddr_in destination = {
        .sin_family = AF_INET,
        .sin_port = htons(CC_WIFI_DISCOVERY_PORT),
        .sin_addr.s_addr = broadcast_address,
    };
    const int sent = sendto(udp_fd, k_discovery_request, sizeof(k_discovery_request) - 1, 0,
                            (const struct sockaddr *)&destination, sizeof(destination));
    if (sent < 0) {
        ESP_LOGW(TAG, "UDP discovery broadcast failed errno=%d", errno);
        close(udp_fd);
        return false;
    }
    ESP_LOGI(TAG, "UDP discovery broadcast sent (%d bytes)", sent);
    uint8_t response[sizeof(k_discovery_response) - 1];
    struct sockaddr_in source = {0};
    socklen_t source_length = sizeof(source);
    int received = -1;
    bool response_found = false;
    // Broadcast-capable stacks can loop our CCDISC2 probe straight back to
    // this socket. Ignore it (and any unrelated UDP datagram) until the
    // bounded receive timeout yields the Mac's CCHOST2 response.
    for (size_t attempt = 0; attempt < 4; ++attempt) {
        source_length = sizeof(source);
        received = recvfrom(udp_fd, response, sizeof(response), 0,
                            (struct sockaddr *)&source, &source_length);
        if (received == (int)sizeof(response) &&
            memcmp(response, k_discovery_response, sizeof(response)) == 0) {
            response_found = true;
            break;
        }
        if (received < 0) break;
    }
    close(udp_fd);
    if (!response_found) {
        ESP_LOGI(TAG, "UDP discovery response timeout or invalid (received=%d)", received);
        return false;
    }
    int tcp_fd = -1;
    if (!connect_to_ipv4(source.sin_addr.s_addr, CC_WIFI_DEFAULT_PORT, &tcp_fd)) return false;
    ESP_LOGI(TAG, "UDP discovery found a Companion host");
    return run_authenticated_connection(tcp_fd, "UDP discovery");
}

static void wifi_transport_task(void *argument) {
    (void)argument;
    ESP_LOGI(TAG, "Wi-Fi control transport task started");
    bool mdns_started = false;
    while (true) {
        if (cc_wifi_status() != CC_WIFI_CONNECTED) {
            vTaskDelay(pdMS_TO_TICKS(CC_WIFI_DISCOVERY_INTERVAL_MS));
            continue;
        }
        // UDP broadcast is attempted first because some routers leave mDNS
        // queries pending indefinitely. It reveals only a candidate address;
        // the CCH2 handshake still authenticates it. Bonjour and the manually
        // configured IPv4 remain recovery paths when broadcast is filtered.
        ESP_LOGI(TAG, "probing Companion hosts over UDP");
        const bool broadcast_discovered = discover_broadcast_fallback();
        bool discovered = false;
        if (!broadcast_discovered) {
            // Initialize mDNS only after the fast UDP path has completed. On
            // some routers mdns_init can wait for multicast setup and would
            // otherwise prevent the daily-use discovery loop from running.
            if (!mdns_started) {
                mdns_started = mdns_init() == ESP_OK;
                if (!mdns_started) {
                    ESP_LOGW(TAG, "mDNS unavailable; using manual fallback if configured");
                }
            }
            discovered = mdns_started && discover_and_connect();
        }
        if (!discovered && !broadcast_discovered) (void)connect_manual_fallback();
        vTaskDelay(pdMS_TO_TICKS(CC_WIFI_DISCOVERY_INTERVAL_MS));
    }
}

void cc_wifi_transport_start(cc_wifi_control_fn control_callback) {
    if (g_socket_lock) return;
    g_control_callback = control_callback;
    g_socket_lock = xSemaphoreCreateMutex();
    if (!g_socket_lock || xTaskCreate(wifi_transport_task, "cc_wifi_link", 6144,
                                      NULL, 5, NULL) != pdPASS) {
        ESP_LOGE(TAG, "failed to start Wi-Fi transport task");
    }
}

bool cc_wifi_transport_is_connected(void) {
    return g_connected;
}

bool cc_wifi_transport_send_control(const uint8_t *data, size_t length) {
    if (!data || length == 0 || length > CC_WIFI_MAX_PAYLOAD_SIZE ||
        !g_socket_lock) return false;
    xSemaphoreTake(g_socket_lock, portMAX_DELAY);
    const int socket_fd = g_socket;
    if (!g_connected || socket_fd < 0) {
        xSemaphoreGive(g_socket_lock);
        return false;
    }
    const uint32_t sequence = ++g_outbound_sequence;
    uint8_t nonce[CC_WIFI_NONCE_SIZE];
    cc_wifi_make_nonce(g_session_id, sequence, nonce);
    const cc_wifi_frame_t frame = {
        .kind = CC_WIFI_FRAME_CONTROL,
        .session_id = g_session_id,
        .sequence = sequence,
        .timestamp_ms = now_ms(),
        .payload = data,
        .payload_len = length,
    };
    uint8_t packet[CC_WIFI_MAX_PACKET_SIZE];
    size_t packet_length = 0;
    bool sent = cc_wifi_encode_frame(&frame, g_keys.control_key, nonce, packet,
                                     sizeof(packet), &packet_length) == CC_WIFI_WIRE_OK;
    uint8_t prefix[2] = {
        (uint8_t)(packet_length >> 8), (uint8_t)packet_length,
    };
    if (sent) sent = send_all(socket_fd, prefix, sizeof(prefix)) &&
                     send_all(socket_fd, packet, packet_length);
    xSemaphoreGive(g_socket_lock);
    return sent;
}
