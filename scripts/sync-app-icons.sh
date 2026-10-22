#!/usr/bin/env bash
# Regenerate every platform's app icons from frontend/assets/app_icon.png
# (1024x1024, full-bleed square) and the Android TV banner from
# frontend/assets/tv_banner.png (16:9).
#
# The icon's source of truth is frontend/assets/app_icon.svg: after editing
# it, re-render app_icon.png at 1024px, then run this script.
# Needs ImageMagick 7 (`magick`): brew install imagemagick / apt install imagemagick.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FRONT="$ROOT/frontend"
TV="$ROOT/android-native/tv/src/main/res"
SRC="$FRONT/assets/app_icon.png"
BANNER="$FRONT/assets/tv_banner.png"

command -v magick >/dev/null || { echo "ImageMagick 7 (magick) is required" >&2; exit 1; }
for f in "$SRC" "$BANNER"; do
  [[ -f "$f" ]] || { echo "Missing $f" >&2; exit 1; }
done

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Rounded square (corner radius 22.5%) for Windows, Linux, Android and web.
magick "$SRC" -resize 1024x1024 \
  \( -size 1024x1024 xc:none -fill white -draw "roundrectangle 0,0 1023,1023 230,230" \) \
  -compose DstIn -composite "$TMP/rounded.png"

# macOS doesn't shape icons itself: 824px rounded square on a 1024 canvas
# with a soft drop shadow, per Apple's icon grid.
magick "$SRC" -resize 824x824 \
  \( -size 824x824 xc:none -fill white -draw "roundrectangle 0,0 823,823 185,185" \) \
  -compose DstIn -composite "$TMP/mac_tile.png"
magick -size 1024x1024 xc:none \
  \( "$TMP/mac_tile.png" -background black -shadow 30x12+0+0 \) -gravity center -geometry +0+10 -composite \
  "$TMP/mac_tile.png" -gravity center -composite "$TMP/mac.png"

out() { # src size dest
  mkdir -p "$(dirname "$3")"
  magick "$1" -resize "$2x$2" -strip "$3"
}

out "$TMP/rounded.png" 512 "$FRONT/linux/data/icon.png"

mac="$FRONT/macos/Runner/Assets.xcassets/AppIcon.appiconset"
for s in 16 32 64 128 256 512 1024; do
  out "$TMP/mac.png" "$s" "$mac/app_icon_$s.png"
done

mkdir -p "$FRONT/windows/runner/resources"
magick "$TMP/rounded.png" -define icon:auto-resize=256,128,64,48,32,16 \
  "$FRONT/windows/runner/resources/app_icon.ico"

for pair in mdpi:48 hdpi:72 xhdpi:96 xxhdpi:144 xxxhdpi:192; do
  dpi="${pair%%:*}"; s="${pair##*:}"
  out "$TMP/rounded.png" "$s" "$FRONT/android/app/src/main/res/mipmap-$dpi/ic_launcher.png"
  out "$TMP/rounded.png" "$s" "$TV/mipmap-$dpi/ic_launcher.png"
done

# Android TV launcher banner: 320x180dp at xhdpi.
mkdir -p "$TV/drawable-xhdpi"
magick "$BANNER" -resize '640x360!' -strip "$TV/drawable-xhdpi/tv_banner.png"

# Web: favicon + manifest icons (maskable ones stay square; the OS crops them).
out "$TMP/rounded.png" 32 "$FRONT/web/favicon.png"
out "$TMP/rounded.png" 192 "$FRONT/web/icons/Icon-192.png"
out "$TMP/rounded.png" 512 "$FRONT/web/icons/Icon-512.png"
out "$SRC" 192 "$FRONT/web/icons/Icon-maskable-192.png"
out "$SRC" 512 "$FRONT/web/icons/Icon-maskable-512.png"

echo "Synced icons from $SRC and $BANNER"
