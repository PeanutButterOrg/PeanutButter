#!/usr/bin/env bash
# Package Flutter Linux release bundle as .deb and AppImage.
# Usage: ./scripts/package-linux.sh [bundle_dir]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FRONT="$ROOT/frontend"
BUNDLE="${1:-$FRONT/build/linux/x64/release/bundle}"
DIST="${FRONT}/dist"
APP_NAME="PeanutButter"
BIN_NAME="peanutbutter"
APP_ID="app.peanutbutter.peanutbutter"
VERSION="$(
  python3 - <<PY
import re
from pathlib import Path
text = Path(r"$FRONT/pubspec.yaml").read_text()
m = re.search(r"^version:\s*([0-9]+\.[0-9]+\.[0-9]+)", text, re.M)
print(m.group(1) if m else "0.2.0")
PY
)"
ICON_SRC="$FRONT/linux/data/icon.png"

if [[ ! -x "$BUNDLE/$BIN_NAME" ]]; then
  echo "Linux bundle missing at $BUNDLE/$BIN_NAME" >&2
  exit 1
fi
mkdir -p "$DIST"
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

# ---------- .deb ----------
DEB_ROOT="$WORKDIR/deb"
mkdir -p \
  "$DEB_ROOT/DEBIAN" \
  "$DEB_ROOT/usr/bin" \
  "$DEB_ROOT/usr/lib/$BIN_NAME" \
  "$DEB_ROOT/usr/share/applications" \
  "$DEB_ROOT/usr/share/icons/hicolor/256x256/apps" \
  "$DEB_ROOT/usr/share/icons/hicolor/512x512/apps"

rsync -a "$BUNDLE/" "$DEB_ROOT/usr/lib/$BIN_NAME/"
cat > "$DEB_ROOT/usr/bin/$BIN_NAME" <<EOF
#!/usr/bin/env bash
export LD_LIBRARY_PATH="/usr/lib/$BIN_NAME/lib\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}"
exec "/usr/lib/$BIN_NAME/$BIN_NAME" "\$@"
EOF
chmod 755 "$DEB_ROOT/usr/bin/$BIN_NAME" "$DEB_ROOT/usr/lib/$BIN_NAME/$BIN_NAME"

if [[ -f "$ICON_SRC" ]]; then
  python3 - "$ICON_SRC" "$DEB_ROOT/usr/share/icons/hicolor" "$APP_ID" <<'PY'
import sys
from pathlib import Path
from PIL import Image
src, root, name = sys.argv[1], Path(sys.argv[2]), sys.argv[3]
img = Image.open(src).convert("RGBA")
for size in (256, 512):
    out = root / f"{size}x{size}" / "apps" / f"{name}.png"
    out.parent.mkdir(parents=True, exist_ok=True)
    img.resize((size, size), Image.Resampling.LANCZOS).save(out)
PY
fi

cat > "$DEB_ROOT/usr/share/applications/${APP_ID}.desktop" <<EOF
[Desktop Entry]
Version=1.0
Type=Application
Name=${APP_NAME}
Comment=Self-hosted media catalog
Exec=${BIN_NAME}
Icon=${APP_ID}
Terminal=false
Categories=AudioVideo;Player;TV;
StartupWMClass=${APP_ID}
EOF

SIZE_KB="$(du -sk "$DEB_ROOT" | awk '{print $1}')"
cat > "$DEB_ROOT/DEBIAN/control" <<EOF
Package: ${BIN_NAME}
Version: ${VERSION}
Section: video
Priority: optional
Architecture: amd64
Installed-Size: ${SIZE_KB}
Maintainer: PeanutButter <noreply@peanutbutter.local>
Depends: libgtk-3-0, libmpv1 | libmpv2, libwebkit2gtk-4.1-0 | libwebkit2gtk-4.0-37
Description: PeanutButter desktop client
 Self-hosted media catalog client for your own library.
EOF

DEB_OUT="$DIST/${APP_NAME}-linux-amd64.deb"
dpkg-deb --build --root-owner-group "$DEB_ROOT" "$DEB_OUT"
echo "Wrote $DEB_OUT"

# ---------- AppImage ----------
APPDIR="$WORKDIR/${APP_NAME}.AppDir"
mkdir -p \
  "$APPDIR/usr/bin" \
  "$APPDIR/usr/share/applications" \
  "$APPDIR/usr/share/icons/hicolor/256x256/apps"
rsync -a "$BUNDLE/" "$APPDIR/usr/bin/peanutbutter-bundle/"
cat > "$APPDIR/AppRun" <<'EOF'
#!/usr/bin/env bash
HERE="$(dirname "$(readlink -f "$0")")"
export LD_LIBRARY_PATH="$HERE/usr/bin/peanutbutter-bundle/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
exec "$HERE/usr/bin/peanutbutter-bundle/peanutbutter" "$@"
EOF
chmod 755 "$APPDIR/AppRun"

cat > "$APPDIR/${APP_ID}.desktop" <<EOF
[Desktop Entry]
Version=1.0
Type=Application
Name=${APP_NAME}
Comment=Self-hosted media catalog
Exec=AppRun
Icon=${APP_ID}
Terminal=false
Categories=AudioVideo;Player;TV;
StartupWMClass=${APP_ID}
EOF
cp "$APPDIR/${APP_ID}.desktop" "$APPDIR/usr/share/applications/${APP_ID}.desktop"

if [[ -f "$DEB_ROOT/usr/share/icons/hicolor/256x256/apps/${APP_ID}.png" ]]; then
  cp "$DEB_ROOT/usr/share/icons/hicolor/256x256/apps/${APP_ID}.png" \
    "$APPDIR/usr/share/icons/hicolor/256x256/apps/${APP_ID}.png"
  cp "$DEB_ROOT/usr/share/icons/hicolor/256x256/apps/${APP_ID}.png" "$APPDIR/${APP_ID}.png"
  ln -sf "${APP_ID}.png" "$APPDIR/.DirIcon"
fi

cd "$WORKDIR"
curl -fsSL -o appimagetool.AppImage \
  "https://github.com/AppImage/appimagetool/releases/download/continuous/appimagetool-x86_64.AppImage"
chmod +x appimagetool.AppImage
./appimagetool.AppImage --appimage-extract >/dev/null
export ARCH=x86_64
APPIMAGE_OUT="$DIST/${APP_NAME}-linux-x86_64.AppImage"
./squashfs-root/AppRun "$APPDIR" "$APPIMAGE_OUT"
chmod +x "$APPIMAGE_OUT"
echo "Wrote $APPIMAGE_OUT"
