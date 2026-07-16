#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SOURCE="$ROOT/firmware/main/device_ui.c"

# The simulator draws the shell from x=24..120 and its casing from x=30..114.
# The physical renderer must leave the six-pixel right border at x=114..120;
# placing it at x=108 would put it underneath the casing layer.
grep -Fq 'sprite_pixel_set(GLYPH_PATCH_TOP, 114, 30, 6, 60, outline, true);' "$SOURCE"
grep -Fq 'sprite_pixel_set(GLYPH_CONTEXT_TOP, 30, 30, 84, 60, casing, true);' "$SOURCE"

echo "device UI layout tests passed"
