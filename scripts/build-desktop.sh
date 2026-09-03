#!/usr/bin/env bash
# Build PeanutButter for the current desktop OS and write a zip under dist/.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FRONT="$ROOT/frontend"
DIST="$ROOT/dist"
mkdir -p "$DIST"
cd "$FRONT"

os="$(uname -s)"
case "$os" in
  Linux)
    flutter build linux --release
    stage="$(mktemp -d)"
    mkdir -p "$stage/PeanutButter"
    cp -a build/linux/x64/release/bundle/. "$stage/PeanutButter/"
    cat > "$stage/PeanutButter/run.sh" <<'EOF'
#!/usr/bin/env bash
cd "$(dirname "$0")"
export LD_LIBRARY_PATH="$PWD/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
exec ./peanutbutter "$@"
EOF
    chmod +x "$stage/PeanutButter/run.sh" "$stage/PeanutButter/peanutbutter"
    (cd "$stage" && zip -qr "$DIST/PeanutButter-linux-x64.zip" PeanutButter)
    rm -rf "$stage"
    echo "Wrote $DIST/PeanutButter-linux-x64.zip"
    ;;
  Darwin)
    flutter config --enable-macos-desktop
    flutter build macos --release
    APP=$(find build/macos/Build/Products/Release -maxdepth 1 -name '*.app' | head -1)
    ditto -c -k --sequesterRsrc --keepParent "$APP" "$DIST/PeanutButter-macos.zip"
    echo "Wrote $DIST/PeanutButter-macos.zip"
    ;;
  MINGW*|MSYS*|CYGWIN*|Windows_NT)
    echo "On Windows use: scripts/build-windows.ps1" >&2
    exit 1
    ;;
  *)
    echo "Unsupported OS: $os" >&2
    exit 1
    ;;
esac
