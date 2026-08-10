#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
font="$(find /System/Library/AssetsV2/com_apple_MobileAsset_Font8 -type f -name STHEITI.ttf | head -1)"
if [[ -z "$font" ]]; then
  echo "STHeiti system font not found" >&2
  exit 1
fi

# Extract every non-ASCII character from every source that can feed text into
# the UI. Restricting this to CJK ranges missed punctuation such as U+00B7 (·)
# and U+2026 (…) and rendered those characters as LVGL missing-glyph squares.
symbols="$(perl -Mutf8 -CSDA -ne '
  while (/([\x{80}-\x{10FFFF}])/g) {
    $seen{$1} = 1;
  }
  END { print join "", sort keys %seen }
' "$root/main/device_ui.c" "$root/main/wifi_manager.c" "$root/main/app_main.c")"
if [[ -z "$symbols" ]]; then
  echo "No CJK UI glyphs found" >&2
  exit 1
fi
npx --yes lv_font_conv --size 14 --bpp 4 --format lvgl --font "$font" \
  --range 0x20-0x7F --symbols "$symbols" --no-compress --no-kerning \
  --lv-font-name cc_font_zh_14 -o "$root/main/generated/cc_font_zh_14.c"

# ESP-IDF exposes LVGL as "lvgl.h" rather than the desktop-style
# "lvgl/lvgl.h" include path emitted by lv_font_conv.
perl -0pi -e 's/#ifdef LV_LVGL_H_INCLUDE_SIMPLE\n#include "lvgl\.h"\n#else\n#include "lvgl\/lvgl\.h"\n#endif/#include "lvgl.h"/' "$root/main/generated/cc_font_zh_14.c"
