#!/usr/bin/env bash
# Regenerate Linux / macOS / Windows / Android launcher icons from assets/app_icon.png.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FRONT="$ROOT/frontend"
SRC="$FRONT/assets/app_icon.png"

if [[ ! -f "$SRC" ]]; then
  echo "Missing $SRC" >&2
  exit 1
fi

python3 - "$SRC" "$FRONT" <<'PY'
import sys
from pathlib import Path
from PIL import Image

src_path = Path(sys.argv[1])
front = Path(sys.argv[2])
src = Image.open(src_path).convert("RGBA")

def fit(size: int) -> Image.Image:
    return src.resize((size, size), Image.Resampling.LANCZOS)

linux = front / "linux" / "data"
linux.mkdir(parents=True, exist_ok=True)
fit(512).save(linux / "icon.png", optimize=True)

mac = front / "macos" / "Runner" / "Assets.xcassets" / "AppIcon.appiconset"
for size, name in {
    16: "app_icon_16.png",
    32: "app_icon_32.png",
    64: "app_icon_64.png",
    128: "app_icon_128.png",
    256: "app_icon_256.png",
    512: "app_icon_512.png",
    1024: "app_icon_1024.png",
}.items():
    fit(size).save(mac / name, optimize=True)

win = front / "windows" / "runner" / "resources"
win.mkdir(parents=True, exist_ok=True)
ico_sizes = [16, 32, 48, 64, 128, 256]
images = [fit(s) for s in ico_sizes]
images[-1].save(
    win / "app_icon.ico",
    format="ICO",
    sizes=[(s, s) for s in ico_sizes],
    append_images=images[:-1],
)

android = front / "android" / "app" / "src" / "main" / "res"
for folder, size in {
    "mipmap-mdpi": 48,
    "mipmap-hdpi": 72,
    "mipmap-xhdpi": 96,
    "mipmap-xxhdpi": 144,
    "mipmap-xxxhdpi": 192,
}.items():
    fit(size).save(android / folder / "ic_launcher.png", optimize=True)

print(f"Synced icons from {src_path}")
PY
