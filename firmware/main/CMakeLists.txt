idf_component_register(
    SRCS "app_main.c" "device_ui.c" "generated/cc_font_zh_14.c" "generated/cc_pixel_poop.c" "battery_monitor.c" "ble_transport.c" "host_profile.c" "audio_stream.c" "wireless_audio_router.c" "usb_audio_mode.c" "usb_control.c" "usb_hid_ptt.c" "wifi_manager.c" "wifi_state.c" "wifi_transport.c" "pairing_manager.c" "connection_center.c"
    INCLUDE_DIRS "."
    LDFRAGMENTS "lvgl_psram.lf"
    REQUIRES
        audio_codec
        ble_framing
        bt
        control_protocol
        device_model
        driver
        esp_timer
        esp_event
        esp_http_server
        esp_netif
        esp_wifi
        espressif__mdns
        espressif__usb_device_uac
        espressif__tinyusb
        mbedtls
        nvs_flash
        prompt_payload
        wifi_wire
        waveshare_bsp
    EMBED_FILES "generated/task_complete_dog_pack.pcm"
)
