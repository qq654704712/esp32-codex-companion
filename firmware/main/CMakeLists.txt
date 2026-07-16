idf_component_register(
    SRCS "app_main.c" "device_ui.c" "generated/cc_font_zh_14.c" "ble_transport.c" "audio_stream.c" "usb_audio_mode.c" "usb_control.c" "usb_hid_ptt.c" "wifi_manager.c" "wifi_state.c" "wifi_transport.c"
    INCLUDE_DIRS "."
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
        nvs_flash
        prompt_payload
        wifi_wire
        waveshare_bsp
)
