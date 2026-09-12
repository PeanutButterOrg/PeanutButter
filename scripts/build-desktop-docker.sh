#!/usr/bin/env bash
# Local / selective desktop builds for PeanutButter.
#
# Reality check (Flutter upstream):
#   • Linux  — can build here in Docker (fast, cached)
#   • Windows — must build on Windows (CI or a Windows PC)
#   • macOS   — must build on macOS + Xcode (CI or a Mac)
# A Linux Docker container cannot produce Windows .exe or macOS .app.
#
# Usage:
#   ./scripts/build-desktop-docker.sh                 # Linux via Docker
#   ./scripts/build-desktop-docker.sh --linux         # same
#   ./scripts/build-desktop-docker.sh --image-only    # only (re)build the image
#   ./scripts/build-desktop-docker.sh --ci-windows    # trigger GH Actions Windows job
#   ./scripts/build-desktop-docker.sh --ci-macos      # trigger GH Actions macOS job
#   ./scripts/build-desktop-docker.sh --ci-windows --ci-macos --watch
#   ./scripts/build-desktop-docker.sh --ci-all --watch --download
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IMAGE="${PB_LINUX_IMAGE:-peanutbutter-linux-desktop}"
DOCKERFILE="$ROOT/packaging/docker/Dockerfile.linux-desktop"
PUB_VOL="${PB_PUB_CACHE_VOL:-peanutbutter-pub-cache}"
DIST="$ROOT/frontend/dist"

do_linux=0
do_image_only=0
do_ci_linux=0
do_ci_windows=0
do_ci_macos=0
do_watch=0
do_download=0
have_target=0

for arg in "$@"; do
  case "$arg" in
    --linux) do_linux=1; have_target=1 ;;
    --image-only) do_image_only=1; have_target=1 ;;
    --ci-linux) do_ci_linux=1; have_target=1 ;;
    --ci-windows) do_ci_windows=1; have_target=1 ;;
    --ci-macos) do_ci_macos=1; have_target=1 ;;
    --ci-all) do_ci_linux=1; do_ci_windows=1; do_ci_macos=1; have_target=1 ;;
    --watch) do_watch=1 ;;
    --download) do_download=1 ;;
    -h|--help)
      sed -n '2,22p' "$0"
      exit 0
      ;;
    *)
      echo "Unknown arg: $arg" >&2
      exit 1
      ;;
  esac
done

# Default: local Linux Docker build.
if [[ "$have_target" -eq 0 ]]; then
  do_linux=1
fi

need_docker() {
  command -v docker >/dev/null 2>&1 || {
    echo "docker is required for local Linux builds" >&2
    exit 1
  }
}

build_image() {
  need_docker
  echo "==> Building $IMAGE (first time is slow; later builds reuse layers)"
  docker build -t "$IMAGE" -f "$DOCKERFILE" "$ROOT/packaging/docker"
}

run_linux_docker() {
  need_docker
  if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
    build_image
  fi
  mkdir -p "$DIST"
  echo "==> Linux desktop build inside Docker (pub cache volume: $PUB_VOL)"
  docker run --rm \
    -e HOME=/tmp \
    -e PUB_CACHE=/cache/pub \
    -v "$ROOT:/work:rw" \
    -v "${PUB_VOL}:/cache/pub" \
    -w /work/frontend \
    "$IMAGE" \
    bash -lc '
      set -euo pipefail
      flutter config --enable-linux-desktop >/dev/null
      mkdir -p build/native_assets/linux
      flutter pub get
      flutter build linux --release
      chmod +x /work/scripts/package-linux.sh
      mkdir -p dist/PeanutButter
      cp -a build/linux/x64/release/bundle/. dist/PeanutButter/
      printf "%s\n" "#!/usr/bin/env bash" "cd \"\$(dirname \"\$0\")\"" \
        "export LD_LIBRARY_PATH=\"\$PWD/lib\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}\"" \
        "exec ./peanutbutter \"\$@\"" > dist/PeanutButter/run.sh
      chmod +x dist/PeanutButter/run.sh dist/PeanutButter/peanutbutter
      (cd dist && zip -qr PeanutButter-linux-x64-portable.zip PeanutButter)
      /work/scripts/package-linux.sh build/linux/x64/release/bundle
      (cd dist && zip -qr PeanutButter-linux-amd64-deb.zip PeanutButter-linux-amd64.deb)
      (cd dist && zip -qr PeanutButter-linux-x86_64-AppImage.zip PeanutButter-linux-x86_64.AppImage)
      ls -lh dist/PeanutButter-linux-* || true
    '
  echo "Linux artifacts → $DIST"
  ls -lh "$DIST"/PeanutButter-linux-* 2>/dev/null || true
}

trigger_ci() {
  command -v gh >/dev/null 2>&1 || {
    echo "gh (GitHub CLI) is required for --ci-* options" >&2
    exit 1
  }
  local linux=false windows=false macos=false
  [[ "$do_ci_linux" -eq 1 ]] && linux=true
  [[ "$do_ci_windows" -eq 1 ]] && windows=true
  [[ "$do_ci_macos" -eq 1 ]] && macos=true
  echo "==> Triggering Desktop builds (linux=$linux windows=$windows macos=$macos)"
  gh workflow run desktop-builds.yml \
    --ref "$(git -C "$ROOT" rev-parse --abbrev-ref HEAD)" \
    -f linux="$linux" \
    -f windows="$windows" \
    -f macos="$macos"
  echo "Queued. Track with: gh run list --workflow=desktop-builds.yml -L 3"
  if [[ "$do_watch" -eq 1 || "$do_download" -eq 1 ]]; then
    echo "==> Waiting for the new run…"
    sleep 3
    local run_id
    run_id="$(gh run list --workflow=desktop-builds.yml -L 1 --json databaseId -q '.[0].databaseId')"
    [[ -n "$run_id" ]] || { echo "Could not find workflow run id" >&2; exit 1; }
    if [[ "$do_watch" -eq 1 ]]; then
      gh run watch "$run_id" --exit-status
    else
      # Still wait for completion before download.
      gh run watch "$run_id" --exit-status
    fi
    if [[ "$do_download" -eq 1 ]]; then
      mkdir -p "$ROOT/dist/ci"
      gh run download "$run_id" -D "$ROOT/dist/ci"
      echo "Downloaded artifacts → $ROOT/dist/ci"
      find "$ROOT/dist/ci" -type f | head -40
    fi
  fi
}

if [[ "$do_image_only" -eq 1 ]]; then
  build_image
fi
if [[ "$do_linux" -eq 1 ]]; then
  run_linux_docker
fi
if [[ "$do_ci_linux$do_ci_windows$do_ci_macos" != *1* ]]; then
  :
elif [[ "$do_ci_linux" -eq 1 || "$do_ci_windows" -eq 1 || "$do_ci_macos" -eq 1 ]]; then
  trigger_ci
fi
