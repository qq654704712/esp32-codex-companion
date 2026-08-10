#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SOURCE="$ROOT/firmware/main/device_ui.c"
FONT="$ROOT/firmware/main/generated/cc_font_zh_14.c"
PET="$ROOT/firmware/main/generated/cc_pixel_poop.c"

# Codex uses the generated pixel mascot as a real RGB565 asset. State effects
# remain separate so animation never redraws the base character.
grep -Fq '#include "generated/cc_pixel_poop.h"' "$SOURCE"
grep -Fq 'lv_image_set_src(pet_image, &cc_pixel_poop);' "$SOURCE"
grep -Fq '.header.cf = LV_COLOR_FORMAT_RGB565' "$PET"
grep -Fq '.header.w = 96' "$PET"
grep -Fq '.header.h = 96' "$PET"

# Pairing reset lives inside a scrollable circular-screen panel. It must fire
# while the touch is held rather than depending on a release event that the
# parent scroll gesture can cancel, and it must provide visible confirmation.
grep -Fq 'code == LV_EVENT_PRESSING && !pairing_reset_fired' "$SOURCE"
grep -Fq '"配对已清除，正在重新连接"' "$SOURCE"

# Codex navigation is gesture-first. Its header contains task/link state only;
# USB, Wi-Fi and Bluetooth are global OS settings, not Codex submenus.
grep -Fq 'companion_button_event' "$SOURCE"
grep -Fq 'LV_EVENT_GESTURE' "$SOURCE"
grep -Fq '#define UI_INPUT_STARTUP_GUARD_MS 4000' "$SOURCE"
grep -Fq 'lv_indev_enable(ui_input, false);' "$SOURCE"
grep -Fq 'lv_indev_wait_release(indev);' "$SOURCE"
grep -Fq 'touch input enabled after startup guard' "$SOURCE"
grep -Fq 'cc_device_ui_codex_voice_available' "$SOURCE"
grep -Fq 'cc_device_ui_codex_app_active' "$SOURCE"
grep -Fq 'BOOT ignored outside Codex app' "$ROOT/firmware/main/app_main.c"
grep -Fq 'boot_interaction_armed = cc_device_ui_codex_voice_available();' \
  "$ROOT/firmware/main/app_main.c"
grep -Fq 'CODEX_PAGE_SETTINGS' "$SOURCE"
grep -Fq '"任务与并发        >", "用量与限额        >",' "$SOURCE"
grep -Fq '"语音输入          >"' "$SOURCE"
grep -Fq '"连接与网络", "声音与提示", "显示与表盘", "关于设备",' "$SOURCE"
if grep -Fq 'CODEX_PAGE_CONNECTION' "$SOURCE"; then
  echo "device-wide connections are still nested inside Codex" >&2
  exit 1
fi
if grep -Fq 'connection_text(os_status_bar, "Companion"' "$SOURCE"; then
  echo "Codex header still exposes the obsolete Companion title" >&2
  exit 1
fi
if grep -Eq 'os_back_button|codex_nav' "$SOURCE"; then
  echo "legacy Codex back/tab navigation is still present" >&2
  exit 1
fi

# Task lifecycle effects are a bounded FIFO that overrides only the transient
# visual state. The aggregate running state remains untouched underneath it.
grep -Fq 'TASK_EVENT_QUEUE_CAPACITY 8' "$SOURCE"
grep -Fq 'TASK_EVENT_ANIMATION_US 4000000' "$SOURCE"
grep -Fq 'cc_device_ui_enqueue_task_event' "$SOURCE"
grep -Fq 'active_task_event == CC_TASK_EVENT_STARTED' "$SOURCE"
grep -Fq '"任务开始" : "处理完成"' "$SOURCE"
if grep -Fq '"正在输入"' "$SOURCE"; then
  echo "obsolete writing status is still user-visible" >&2
  exit 1
fi
grep -Fq 'case CC_STATE_RUNNING: return "正在工作";' "$SOURCE"
grep -Fq 'state == CC_STATE_WORKING || state == CC_STATE_WRITING ||' "$SOURCE"

# Codex lifecycle sounds, animations and interactive prompts are app-local.
# Task events received on the watch face are dropped, leaving no delayed bark
# or stale animation when the user later opens Codex. A pending authorization
# remains available, but it cannot replace the watch face until Codex opens.
grep -Fq 'if (active_os_app != OS_APP_CODEX) return;' "$SOURCE"
grep -Fq 'Codex task effect suppressed outside app' \
  "$ROOT/firmware/main/app_main.c"
grep -Fq 'USB Codex task effect suppressed outside app' \
  "$ROOT/firmware/main/app_main.c"
grep -Fq 'pending_prompt = *prompt;' "$SOURCE"
grep -Fq 'Codex prompt %lu deferred until app opens' "$SOURCE"
grep -Fq 'show_pending_prompt_locked();' "$SOURCE"
grep -Fq 'cc_device_ui_set_codex_visibility_callback' \
  "$ROOT/firmware/main/app_main.c"
grep -Fq 'if (!tone_queue || !task_tones_enabled) return;' \
  "$ROOT/firmware/main/audio_stream.c"
grep -Fq 'offset < total_frames && !active && task_tones_enabled' \
  "$ROOT/firmware/main/audio_stream.c"
grep -Fq 'cc_audio_set_task_tones_enabled(visible);' \
  "$ROOT/firmware/main/app_main.c"

# The OS has three cyclic top-level surfaces. It boots to the watch face, and
# left/right gestures cycle Settings -> Apps -> Watch without edge dead ends.
grep -Fq 'show_os_app(OS_APP_WATCH);' "$SOURCE"
grep -Fq 'direction == LV_DIR_LEFT' "$SOURCE"
grep -Fq 'direction == LV_DIR_RIGHT' "$SOURCE"
grep -Fq 'active_os_app == OS_APP_SETTINGS ? OS_APP_HOME' "$SOURCE"
grep -Fq 'active_os_app == OS_APP_SETTINGS ? OS_APP_WATCH' "$SOURCE"
grep -Fq 'lv_obj_set_size(watch_face, 320, 320);' "$SOURCE"
grep -Fq '&lv_font_montserrat_48' "$SOURCE"
grep -Fq '"天气  等待同步"' "$SOURCE"

# The watch face reports the board fuel gauge. Standby never switches the
# panel fully off: after one minute it remains visibly alive at 25%, and any
# touch/button/work activity restores full brightness.
grep -Fq 'watch_battery_label' "$SOURCE"
grep -Fq 'snprintf(text, sizeof(text), "电量 %u%%", percent);' "$SOURCE"
grep -Fq 'snprintf(text, sizeof(text), "充电 %u%%", percent);' "$SOURCE"
grep -Fq '#define UI_IDLE_DIM_MS 60000' "$SOURCE"
grep -Fq '#define UI_IDLE_BRIGHTNESS 25' "$SOURCE"
grep -Fq 'bsp_display_brightness_set(UI_IDLE_BRIGHTNESS)' "$SOURCE"
grep -Fq 'lv_indev_get_state(ui_input) == LV_INDEV_STATE_PRESSED' "$SOURCE"
if sed -n '/void cc_device_ui_power_tick/,/^}/p' "$SOURCE" |
    grep -Fq 'bsp_display_backlight_off'; then
  echo "idle power policy still turns the circular display fully black" >&2
  exit 1
fi
grep -Fq '#define BQ27220_ADDRESS 0x55' \
  "$ROOT/firmware/main/battery_monitor.c"
grep -Fq '#define BQ27220_REG_STATE_OF_CHARGE 0x2C' \
  "$ROOT/firmware/main/battery_monitor.c"
grep -Fq 'i2c_master_transmit_receive' \
  "$ROOT/firmware/main/battery_monitor.c"
grep -Fq 'cc_device_ui_update_battery(' "$ROOT/firmware/main/app_main.c"

# Wi-Fi modem sleep is the normal standby state, but microphone capture holds
# a realtime lease through its final 200 ms tail. The app loop is watched so a
# genuine firmware deadlock resets instead of remaining as a black screen.
grep -Fq 'esp_wifi_set_ps(WIFI_PS_MIN_MODEM)' \
  "$ROOT/firmware/main/wifi_manager.c"
grep -Fq 'enabled ? WIFI_PS_NONE : WIFI_PS_MIN_MODEM' \
  "$ROOT/firmware/main/wifi_manager.c"
grep -Fq 'time_ms + CC_PTT_POST_ROLL_MS + 50U' \
  "$ROOT/firmware/main/app_main.c"
grep -Fq 'esp_task_wdt_add(NULL)' "$ROOT/firmware/main/app_main.c"
grep -Fq 'esp_task_wdt_reset()' "$ROOT/firmware/main/app_main.c"
grep -Fq 'CONFIG_ESP_TASK_WDT_PANIC=y' "$ROOT/firmware/sdkconfig.defaults"

# Static OS surfaces must not rewrite hidden Codex objects at the 12 fps idle
# cadence. Connection Center updates only when its visible state changes.
grep -Fq 'if (active_os_app == OS_APP_SYSTEM)' "$SOURCE"
grep -Fq 'render_connection_center_if_needed(model);' "$SOURCE"
grep -Fq 'connection_render_initialized &&' "$SOURCE"
grep -Fq 'codex_render_cache_t' "$SOURCE"
grep -Fq 'const bool quota_changed = cache_reset' "$SOURCE"
grep -Fq 'sprite_state_is_animated' "$SOURCE"
grep -Fq 'lv_refr_now(NULL);' "$SOURCE"
if grep -Fq 'active_os_app != OS_APP_CODEX && active_os_app != OS_APP_SYSTEM' "$SOURCE"; then
  echo "Connection Center still enters the periodic Codex renderer" >&2
  exit 1
fi

# Provisioning keeps its SoftAP and HTTP response alive while deliberately
# disconnecting an existing station. The new credentials are connected from
# the disconnect event, and station-only mode resumes after a new IP arrives.
grep -Fq 'g_reconnect_after_disconnect = true;' \
  "$ROOT/firmware/main/wifi_manager.c"
grep -Fq 'if (g_reconnect_after_disconnect)' \
  "$ROOT/firmware/main/wifi_manager.c"
grep -Fq 'if (g_ap_netif) (void)esp_wifi_set_mode(WIFI_MODE_STA);' \
  "$ROOT/firmware/main/wifi_manager.c"

# The app drawer is a round-safe 2x2 launcher. Settings remains a top-level
# cyclic surface, but opens its list only after the user taps the gear icon.
grep -Fq 'lv_obj_set_size(os_dock, 252, 258);' "$SOURCE"
grep -Fq 'lv_obj_set_size(button, 112, 110);' "$SOURCE"
grep -Fq 'const int column = i % 2;' "$SOURCE" || \
  grep -Fq 'i % 2, i / 2' "$SOURCE"
grep -Fq 'lv_label_set_text(settings_glyph, LV_SYMBOL_SETTINGS);' "$SOURCE"
grep -Fq 'OS_APP_SETTINGS_MENU' "$SOURCE"
grep -Fq 'const char *app_titles[] = {"Codex", "天气", "音乐", "工具"};' "$SOURCE"
grep -Fq 'OS_APP_CODEX, OS_APP_WEATHER, OS_APP_MUSIC, OS_APP_TOOLS,' "$SOURCE"
grep -Fq 'lv_label_set_text(weather_config_label, "天气设置        >");' "$SOURCE"
grep -Fq '"城市来源      主机同步"' "$SOURCE"
grep -Fq '"温度单位      摄氏 °C"' "$SOURCE"
grep -Fq 'weather_refresh_index = (weather_refresh_index + 1) % 3;' "$SOURCE"
grep -Fq 'active_os_app == OS_APP_WEATHER &&' "$SOURCE"
grep -Fq 'weather_settings_visible) {' "$SOURCE"
grep -Fq 'weather_save_settings();' "$SOURCE"

# Numeric quota labels supplement the two existing usage rings without
# inventing percentages when the host has no fresh quota data.
grep -Fq 'lv_label_set_text(quota_five_label, "5h --%");' "$SOURCE"
grep -Fq 'snprintf(five_text, sizeof(five_text), "5h %u%%"' "$SOURCE"
grep -Fq 'snprintf(week_text, sizeof(week_text), "周 %u%%"' "$SOURCE"

# Start uses its rising 8-bit arpeggio; completion uses the approved three-
# second real dog-pack recording without synthesizing repeated bark pulses.
grep -Fq '#define CC_TASK_TONE_AMPLITUDE 0x20000000' \
  "$ROOT/firmware/main/audio_stream.c"
grep -Fq '#define CC_TASK_TONE_VOLUME 82' "$ROOT/firmware/main/audio_stream.c"
grep -Fq '{523, 100}, {659, 120}, {784, 240}' "$ROOT/firmware/main/audio_stream.c"
grep -Fq 'task_complete_dog_pack_start' "$ROOT/firmware/main/audio_stream.c"
grep -Fq 'CC_COMPLETION_AUDIO_CHUNK_FRAMES 320' "$ROOT/firmware/main/audio_stream.c"
test "$(wc -c < "$ROOT/firmware/main/generated/task_complete_dog_pack.pcm")" -eq 96000
grep -Fq 'EMBED_FILES "generated/task_complete_dog_pack.pcm"' \
  "$ROOT/firmware/main/CMakeLists.txt"

# The generated LVGL font must contain every non-ASCII glyph used by the OS.
# This catches the square-character regression before flashing hardware.
perl -Mutf8 -CSDA -e '
  my ($font_path, @sources) = @ARGV;
  open my $font_fh, "<:encoding(UTF-8)", $font_path or die $!;
  local $/; my $font = <$font_fh>;
  my %missing;
  for my $path (@sources) {
    open my $fh, "<:encoding(UTF-8)", $path or die $!;
    my $text = <$fh>;
    while ($text =~ /([\x{80}-\x{10FFFF}])/g) {
      $missing{$1} = 1 if index($font, $1) < 0;
    }
  }
  die "font missing glyphs: " . join("", sort keys %missing) . "\n" if %missing;
' "$FONT" "$SOURCE" "$ROOT/firmware/main/wifi_manager.c" \
  "$ROOT/firmware/main/app_main.c"

grep -Fq '·' "$FONT"
grep -Fq '…' "$FONT"

echo "device UI layout tests passed"
