#!/usr/bin/env bash
# Build and install PeanutButter clients on this Linux PC and Android TV.
#
# Usage:
#   ./scripts/update-apps.sh              # Linux + TV
#   ./scripts/update-apps.sh --linux      # Linux only
#   ./scripts/update-apps.sh --tv         # TV APK only
#   ./scripts/update-apps.sh --no-launch  # install without launching
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FRONT="$ROOT/frontend"
DIST="$ROOT/dist"
TV_HOST="${PB_TV_HOST:-10.0.0.9}"
TV_PORT="${PB_TV_PORT:-5555}"
PKG="app.peanutbutter.peanutbutter"
OPT_DIR="${HOME}/.local/opt/peanutbutter"
BIN_DIR="${HOME}/.local/bin"

do_linux=1
do_tv=1
do_launch=1
for arg in "$@"; do
  case "$arg" in
    --linux) do_tv=0 ;;
    --tv) do_linux=0 ;;
    --no-launch) do_launch=0 ;;
    -h|--help)
      sed -n '2,10p' "$0"
      exit 0
      ;;
  esac
done

if ! command -v flutter >/dev/null 2>&1; then
  echo "flutter is required" >&2
  exit 1
fi

mkdir -p "$DIST" "$OPT_DIR" "$BIN_DIR"
cd "$FRONT"

install_linux() {
  echo "==> Building Linux release"
  # Flutter sometimes expects this path even when unused.
  mkdir -p build/native_assets/linux
  flutter build linux --release

  local bundle="build/linux/x64/release/bundle"
  if [[ ! -x "$bundle/peanutbutter" ]]; then
    echo "Linux bundle missing at $bundle" >&2
    exit 1
  fi

  # Stop running desktop app so files can be replaced.
  pkill -f "^${OPT_DIR}/peanutbutter$" 2>/dev/null || true
  sleep 0.4

  rsync -a --delete "${bundle}/" "${OPT_DIR}/"
  cat > "${BIN_DIR}/peanutbutter" <<EOF
#!/usr/bin/env bash
export LD_LIBRARY_PATH="${OPT_DIR}/lib\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}"
exec "${OPT_DIR}/peanutbutter" "\$@"
EOF
  chmod +x "${BIN_DIR}/peanutbutter" "${OPT_DIR}/peanutbutter"

  # Desktop entry + icon theme so docks/launchers show the jar icon.
  local icon_src="${FRONT}/linux/data/icon.png"
  if [[ ! -f "$icon_src" ]]; then
    icon_src="${OPT_DIR}/data/icon.png"
  fi
  local share="${HOME}/.local/share"
  local icon_name="$PKG"
  mkdir -p \
    "${share}/applications" \
    "${share}/icons/hicolor/128x128/apps" \
    "${share}/icons/hicolor/256x256/apps" \
    "${share}/icons/hicolor/512x512/apps"
  if [[ -f "$icon_src" ]]; then
    cp -f "$icon_src" "${OPT_DIR}/data/icon.png"
    if command -v convert >/dev/null 2>&1; then
      convert "$icon_src" -resize 128x128 "${share}/icons/hicolor/128x128/apps/${icon_name}.png"
      convert "$icon_src" -resize 256x256 "${share}/icons/hicolor/256x256/apps/${icon_name}.png"
      convert "$icon_src" -resize 512x512 "${share}/icons/hicolor/512x512/apps/${icon_name}.png"
    elif command -v python3 >/dev/null 2>&1; then
      python3 - "$icon_src" "$share" "$icon_name" <<'PY'
import sys
from pathlib import Path
from PIL import Image
src, share, name = sys.argv[1], Path(sys.argv[2]), sys.argv[3]
img = Image.open(src).convert('RGBA')
for size in (128, 256, 512):
    out = share / 'icons' / 'hicolor' / f'{size}x{size}' / 'apps' / f'{name}.png'
    out.parent.mkdir(parents=True, exist_ok=True)
    img.resize((size, size), Image.Resampling.LANCZOS).save(out)
PY
    else
      cp -f "$icon_src" "${share}/icons/hicolor/256x256/apps/${icon_name}.png"
    fi
  fi
  cat > "${share}/applications/${icon_name}.desktop" <<EOF
[Desktop Entry]
Version=1.0
Type=Application
Name=PeanutButter
Comment=Self-hosted media catalog
Exec=${BIN_DIR}/peanutbutter
Icon=${icon_name}
Terminal=false
Categories=AudioVideo;Player;TV;
StartupWMClass=${icon_name}
EOF
  if command -v update-desktop-database >/dev/null 2>&1; then
    update-desktop-database "${share}/applications" >/dev/null 2>&1 || true
  fi
  if command -v gtk-update-icon-cache >/dev/null 2>&1; then
    gtk-update-icon-cache -f "${share}/icons/hicolor" >/dev/null 2>&1 || true
  fi

  # Also keep a zip under dist/ for sharing.
  local stage
  stage="$(mktemp -d)"
  mkdir -p "$stage/PeanutButter"
  cp -a "${bundle}/." "$stage/PeanutButter/"
  cat > "$stage/PeanutButter/run.sh" <<'EOF'
#!/usr/bin/env bash
cd "$(dirname "$0")"
export LD_LIBRARY_PATH="$PWD/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
exec ./peanutbutter "$@"
EOF
  chmod +x "$stage/PeanutButter/run.sh" "$stage/PeanutButter/peanutbutter"
  (cd "$stage" && zip -qr "$DIST/PeanutButter-linux-x64.zip" PeanutButter)
  rm -rf "$stage"

  echo "Linux installed → ${OPT_DIR} (launcher: peanutbutter)"
  if [[ "$do_launch" -eq 1 ]]; then
    nohup "${BIN_DIR}/peanutbutter" >/tmp/peanutbutter-desktop.log 2>&1 &
    echo "Linux launched (pid $!)"
  fi
}

install_tv() {
  echo "==> Building Android TV APK"
  flutter build apk --release
  local apk="build/app/outputs/flutter-apk/app-release.apk"
  if [[ ! -f "$apk" ]]; then
    echo "APK missing at $apk" >&2
    exit 1
  fi
  cp -f "$apk" "$DIST/PeanutButter-tv.apk"
  ls -lh "$DIST/PeanutButter-tv.apk"

  if ! command -v adb >/dev/null 2>&1; then
    echo "adb not found — APK saved to dist/ only" >&2
    return 0
  fi

  local target="${TV_HOST}:${TV_PORT}"
  adb connect "$target" >/dev/null 2>&1 || true
  local dev
  dev="$(adb devices | awk -v t="$target" '$1==t && $2=="device"{print $1; exit}')"
  if [[ -z "$dev" ]]; then
    # Fall back to any connected :5555 device.
    dev="$(adb devices | awk '/:5555[[:space:]]+device/{print $1; exit}')"
  fi
  if [[ -z "$dev" ]]; then
    echo "No Android TV found via adb (tried $target). APK is in dist/." >&2
    return 0
  fi

  echo "==> Installing on $dev"
  adb -s "$dev" install -r "$apk"
  adb -s "$dev" shell am force-stop "$PKG" >/dev/null 2>&1 || true
  if [[ "$do_launch" -eq 1 ]]; then
    adb -s "$dev" shell am start -n "${PKG}/.MainActivity" >/dev/null 2>&1 \
      || adb -s "$dev" shell monkey -p "$PKG" -c android.intent.category.LAUNCHER 1 >/dev/null
    echo "TV launched on $dev"
  else
    echo "TV installed on $dev (not launched)"
  fi
}

if [[ "$do_linux" -eq 1 ]]; then
  install_linux
fi
if [[ "$do_tv" -eq 1 ]]; then
  install_tv
fi

echo
echo "Done."
echo "  Linux: peanutbutter"
echo "  TV APK: $DIST/PeanutButter-tv.apk"
