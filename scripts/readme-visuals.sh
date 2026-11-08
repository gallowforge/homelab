#!/bin/bash
# scripts/readme-visuals.sh - render the README images in docs/readme/.
#
# Each visual is an HTML page in docs/readme/src/, one panel of the same
# control-room board (board.css, common.js; the identity is in
# docs/readme/IDENTITY.md). Each page is captured twice with headless Chrome at
# 2x: 1100 CSS px wide for desktops and 540 px for phones (the pages switch
# layout at 700 px). The transparent margin is trimmed and the result saved as
# WebP. The output pages read their text from docs/readme/src/demo/*.txt, which
# scripts/readme-demo.sh captures by running the real scripts on synthetic data.
# The social preview (social.html) is captured once at 1280x640, 1x, as PNG.
#
#   scripts/readme-demo.sh        # optional: capture fresh terminal output
#   scripts/readme-visuals.sh     # all visuals
#   scripts/readme-visuals.sh hero numbers
#   scripts/readme-visuals.sh social
#
# Needs google-chrome (or CHROME=/path/to/chromium) and ImageMagick 7 (magick).
set -euo pipefail

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SRC=$REPO/docs/readme/src
OUT=$REPO/docs/readme
CHROME=${CHROME:-$(command -v google-chrome-stable || command -v google-chrome || command -v chromium || true)}
[ -n "$CHROME" ] || { echo "no Chrome or Chromium found (set CHROME=...)" >&2; exit 2; }
command -v magick >/dev/null || { echo "ImageMagick 7 (magick) is required" >&2; exit 2; }

pages=("$@")
[ ${#pages[@]} -gt 0 ] || pages=(hero numbers frontdoor backups drill alerts drift operator social)

TMP=$(mktemp -d "${TMPDIR:-/tmp}/readme-visuals.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

shoot() { # shoot <page> <css width> <suffix>
  local png="$TMP/$1$3.png"
  "$CHROME" --headless=new --hide-scrollbars --force-device-scale-factor=2 \
    --default-background-color=00000000 --allow-file-access-from-files \
    --virtual-time-budget=9000 --window-size="$2,3000" \
    --user-data-dir="$TMP/profile" --no-first-run --disable-gpu \
    --screenshot="$png" "file://$SRC/$1.html" >/dev/null 2>&1
  magick "$png" -trim +repage -define webp:method=6 -quality 88 "$OUT/$1$3.webp"
  printf '%-28s %s\n' "$1$3.webp" "$(magick identify -format '%wx%h' "$OUT/$1$3.webp")"
}

social() { # the repo's social preview: exactly 1280x640
  "$CHROME" --headless=new --hide-scrollbars --force-device-scale-factor=1 \
    --allow-file-access-from-files --virtual-time-budget=9000 --window-size=1280,640 \
    --user-data-dir="$TMP/profile" --no-first-run --disable-gpu \
    --screenshot="$TMP/social.png" "file://$SRC/social.html" >/dev/null 2>&1
  magick "$TMP/social.png" -strip -define png:compression-level=9 "$OUT/social.png"
  printf '%-28s %s\n' "social.png" "$(magick identify -format '%wx%h' "$OUT/social.png")"
}

for p in "${pages[@]}"; do
  [ -f "$SRC/$p.html" ] || { echo "no page $SRC/$p.html" >&2; exit 2; }
  if [ "$p" = social ]; then social; continue; fi
  shoot "$p" 1100 ""
  shoot "$p" 540 "-mobile"
done
du -ch "$OUT"/*.webp "$OUT"/*.png | tail -1
