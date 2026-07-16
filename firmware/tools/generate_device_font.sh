#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
font="$(find /System/Library/AssetsV2/com_apple_MobileAsset_Font8 -type f -name STHEITI.ttf | head -1)"
if [[ -z "$font" ]]; then
  echo "STHeiti system font not found" >&2
  exit 1
fi

# Keep this list in sync with the Chinese strings in main/device_ui.c and
# main/wifi_manager.c. ASCII supplies the dynamic Codex/Mac/USB fragments.
# These full-width punctuation marks are rendered on the LVGL screen too;
# without them LVGL correctly substitutes a visible missing-glyph box.
symbols='连接已断开就绪会话启动中正在工作任务完成系统错误需要审批输入长按确认聆听麦克风准备运行中心蓝牙开启等待安全配对按键住网络尚未配置手机重置秒关闭并为设备名称密码开放留空备用地址可选自动发现成功后设置热点缺少必须是无法保存请返回屏幕查看状态失败发生加择：（），。；'
npx --yes lv_font_conv --size 14 --bpp 4 --format lvgl --font "$font" \
  --range 0x20-0x7F --symbols "$symbols" --no-compress --no-kerning \
  --lv-font-name cc_font_zh_14 -o "$root/main/generated/cc_font_zh_14.c"

# ESP-IDF exposes LVGL as "lvgl.h" rather than the desktop-style
# "lvgl/lvgl.h" include path emitted by lv_font_conv.
perl -0pi -e 's/#ifdef LV_LVGL_H_INCLUDE_SIMPLE\n#include "lvgl\.h"\n#else\n#include "lvgl\/lvgl\.h"\n#endif/#include "lvgl.h"/' "$root/main/generated/cc_font_zh_14.c"
