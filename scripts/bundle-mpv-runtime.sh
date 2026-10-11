#!/usr/bin/env bash
# Copy libmpv's transitive shared libraries into a Flutter Linux bundle lib/
# directory so portable/AppImage/.deb wrappers that set LD_LIBRARY_PATH work
# on hosts that do not have FFmpeg 6 / libplacebo matching the vendored mpv.
#
# Usage: ./scripts/bundle-mpv-runtime.sh <bundle_lib_dir>
set -euo pipefail

LIB_DIR="${1:-}"
if [[ -z "$LIB_DIR" || ! -d "$LIB_DIR" ]]; then
  echo "Usage: $0 <bundle_lib_dir>" >&2
  exit 1
fi

MPV=""
for candidate in \
  "$LIB_DIR/libmpv.so.2" \
  "$LIB_DIR/libmpv.so" \
  "$LIB_DIR/libmpv.so.2.2.0"
do
  if [[ -e "$candidate" ]]; then
    MPV="$candidate"
    break
  fi
done

if [[ -z "$MPV" ]]; then
  echo "bundle-mpv-runtime: no libmpv in $LIB_DIR (skipping)" >&2
  exit 0
fi

# Skip core glibc / loader libs — always use the host's.
should_skip() {
  case "$1" in
    libc.so*|libm.so*|libdl.so*|librt.so*|libpthread.so*|libresolv.so*|\
    libgcc_s.so*|libstdc++.so*|ld-linux*.so*|libglib-2.0.so*|libgobject-2.0.so*|\
    libgio-2.0.so*|libgmodule-2.0.so*|libgtk*|libgdk*|libcairo*|libpango*|\
    libX11.so*|libXext.so*|libwayland*|libEGL.so*|libGL.so*|libGLdispatch*|\
    libGLX.so*|libdrm.so*|libgbm.so*|libpulse*|libasound.so*|libpipewire*|\
    libjack.so*|libfontconfig*|libfreetype*|libharfbuzz*|libpng*|libz.so*|\
    libbz2.so*|liblzma.so*|libsystemd.so*|libdbus*|libselinux*|libmount*|\
    libblkid*|libudev*|libffi.so*|libpcre*|libexpat*|libuuid*)
      return 0
      ;;
  esac
  return 1
}

copied=0
# Two passes so newly copied deps can pull their own deps (e.g. libavcodec → libx264).
for _pass in 1 2 3; do
  mapfile -t roots < <(find "$LIB_DIR" -maxdepth 1 \( -name 'libmpv.so*' -o -name 'libav*.so*' -o -name 'libsw*.so*' -o -name 'libplacebo.so*' -o -name 'libbluray.so*' -o -name 'librubberband.so*' -o -name 'libpostproc.so*' \) 2>/dev/null | sort -u)
  for root in "${roots[@]}"; do
    [[ -e "$root" ]] || continue
    while read -r dep; do
      [[ -n "$dep" && -e "$dep" ]] || continue
      base="$(basename "$dep")"
      should_skip "$base" && continue
      if [[ ! -e "$LIB_DIR/$base" ]]; then
        cp -aL "$dep" "$LIB_DIR/$base"
        copied=$((copied + 1))
      fi
    done < <(ldd "$root" 2>/dev/null | awk '/=> \// {print $3} /^[[:space:]]*\// {print $1}')
  done
done

echo "bundle-mpv-runtime: ensured runtime libs in $LIB_DIR (+$copied new)"
# Sanity: libmpv should resolve inside the bundle when LD_LIBRARY_PATH is set.
if command -v ldd >/dev/null; then
  missing="$(ldd "$MPV" 2>/dev/null | awk '/not found/ {print}' || true)"
  if [[ -n "$missing" ]]; then
    echo "bundle-mpv-runtime: warning — still unresolved:" >&2
    echo "$missing" >&2
  fi
fi
