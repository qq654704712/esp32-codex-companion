# Upstream origin

This component is vendored from the official Waveshare repository at commit
`139e6db584f3737fcfc6a958ee83b79fb69d317c`:

`Examples/ESP-IDF-V5.5.3/02_lvgl_demo/components/waveshare__esp32_s3_touch_lcd_1_85B`

The upstream directory accidentally contains `CHECKSUMS.json` and manifest
metadata for the unrelated `esp32_s3_cam_ovxxxx` component. ESP-IDF Component
Manager therefore rejects the otherwise correct LCD BSP because the listed
file hashes do not match its contents. This vendored copy removes only that
invalid checksum file and corrects the descriptive origin fields in
`idf_component.yml`; the C source, headers, CMake, Kconfig, README and license
remain the files from the pinned commit.
