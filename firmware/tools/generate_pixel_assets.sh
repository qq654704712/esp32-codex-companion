#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
source_image="$root/assets/codex_pixel_poop_source.png"
output_c="$root/main/generated/cc_pixel_poop.c"
output_h="$root/main/generated/cc_pixel_poop.h"
palette="$(mktemp -t cc-pixel-palette).png"
indexed="$(mktemp -t cc-pixel-indexed).png"
raw="$(mktemp -t cc-pixel-rgb565).bin"
trap 'rm -f "$palette" "$indexed" "$raw"' EXIT

if [[ ! -f "$source_image" ]]; then
  echo "Missing source asset: $source_image" >&2
  exit 1
fi

# Quantize the generated artwork before RGB565 conversion. This preserves the
# intentional 16-bit pixel look and prevents subtle gradients from wasting
# flash or turning into visible color noise on the 360 px display.
ffmpeg -y -loglevel error -i "$source_image" \
  -vf 'scale=96:96:flags=neighbor,palettegen=max_colors=16:reserve_transparent=0' \
  "$palette"
ffmpeg -y -loglevel error -i "$source_image" -i "$palette" \
  -lavfi 'scale=96:96:flags=neighbor[x];[x][1:v]paletteuse=dither=none' \
  "$indexed"
ffmpeg -y -loglevel error -i "$indexed" -pix_fmt rgb565le \
  -f rawvideo "$raw"

{
  printf '%s\n' '#pragma once' '' '#include "lvgl.h"' '' \
    'extern const lv_image_dsc_t cc_pixel_poop;'
} > "$output_h"

{
  printf '%s\n' '#include "cc_pixel_poop.h"' '' \
    '#ifndef LV_ATTRIBUTE_MEM_ALIGN' \
    '#define LV_ATTRIBUTE_MEM_ALIGN' \
    '#endif' '' \
    'const LV_ATTRIBUTE_MEM_ALIGN LV_ATTRIBUTE_LARGE_CONST uint8_t cc_pixel_poop_map[] = {'
  xxd -p -c 16 "$raw" | sed 's/../0x&,/g; s/^/    /'
  printf '%s\n' '};' '' \
    'const lv_image_dsc_t cc_pixel_poop = {' \
    '    .header.magic = LV_IMAGE_HEADER_MAGIC,' \
    '    .header.cf = LV_COLOR_FORMAT_RGB565,' \
    '    .header.flags = 0,' \
    '    .header.w = 96,' \
    '    .header.h = 96,' \
    '    .header.stride = 192,' \
    '    .data_size = sizeof(cc_pixel_poop_map),' \
    '    .data = cc_pixel_poop_map,' \
    '};'
} > "$output_c"

echo "Generated $output_c"
