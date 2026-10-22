#!/usr/bin/env bash
# Build a self-contained universal (arm64 + x86_64) liblibtorrent_flutter.dylib
# into ../macos/. libtorrent + OpenSSL are linked statically, so the app only
# depends on system libraries at runtime.
#
# Why: upstream's GitHub prebuilt was compiled against a different
# libtorrent::torrent_status ABI than the libtorrent linked into it. Every
# status field Dart read (metadata, peers, bytes done, state) was garbage, so
# streams never opened on macOS. Building the bridge against libtorrent's own
# exported CMake target keeps the ABI defines in lockstep.
#
# Needs: Xcode command line tools, cmake, ninja, Boost headers
# (`brew install cmake ninja boost`, or set BOOST_INCLUDE_DIR).
# Output is cached: re-runs are a no-op unless --force is passed.
set -euo pipefail

LIBTORRENT_VERSION="${LIBTORRENT_VERSION:-2.1.2}"
OPENSSL_VERSION="${OPENSSL_VERSION:-3.5.4}"
MACOS_MIN="${MACOS_MIN:-12.0}"
ARCHS=(${ARCHS:-arm64 x86_64})

HERE="$(cd "$(dirname "$0")" && pwd)"
PLUGIN="$(cd "$HERE/.." && pwd)"
OUT="$PLUGIN/macos/liblibtorrent_flutter.dylib"
STAMP="$PLUGIN/macos/.liblibtorrent_flutter.stamp"
WORK="${LTF_BUILD_DIR:-$PLUGIN/.native-build/macos}"
JOBS="$(sysctl -n hw.ncpu 2>/dev/null || echo 4)"

want_stamp="lt=$LIBTORRENT_VERSION ssl=$OPENSSL_VERSION min=$MACOS_MIN archs=${ARCHS[*]} src=$(shasum -a 256 "$PLUGIN/src/torrent_bridge.cpp" "$PLUGIN/src/torrent_bridge.h" "$PLUGIN/src/CMakeLists.txt" | shasum -a 256 | cut -c1-16)"
if [[ "${1:-}" != "--force" && -f "$OUT" && -f "$STAMP" && "$(cat "$STAMP")" == "$want_stamp" ]]; then
  echo "liblibtorrent_flutter.dylib is up to date ($want_stamp)"
  exit 0
fi

for tool in cmake ninja curl clang lipo; do
  command -v "$tool" >/dev/null || { echo "missing build tool: $tool" >&2; exit 1; }
done

BOOST_INCLUDE_DIR="${BOOST_INCLUDE_DIR:-}"
if [[ -z "$BOOST_INCLUDE_DIR" ]] && command -v brew >/dev/null; then
  p="$(brew --prefix boost 2>/dev/null || true)"
  [[ -n "$p" && -f "$p/include/boost/version.hpp" ]] && BOOST_INCLUDE_DIR="$p/include"
fi
if [[ -z "$BOOST_INCLUDE_DIR" || ! -f "$BOOST_INCLUDE_DIR/boost/version.hpp" ]]; then
  echo "Boost headers not found: brew install boost (or set BOOST_INCLUDE_DIR)" >&2
  exit 1
fi

mkdir -p "$WORK/src"
fetch() { # url dest
  [[ -f "$2" ]] && return 0
  curl -fL --retry 3 -o "$2.part" "$1" || { echo "download failed: $1" >&2; exit 1; }
  mv -f "$2.part" "$2"
}
fetch "https://github.com/openssl/openssl/releases/download/openssl-$OPENSSL_VERSION/openssl-$OPENSSL_VERSION.tar.gz" \
  "$WORK/src/openssl-$OPENSSL_VERSION.tar.gz"
fetch "https://github.com/arvidn/libtorrent/releases/download/v$LIBTORRENT_VERSION/libtorrent-rasterbar-$LIBTORRENT_VERSION.tar.gz" \
  "$WORK/src/libtorrent-rasterbar-$LIBTORRENT_VERSION.tar.gz"

export MACOSX_DEPLOYMENT_TARGET="$MACOS_MIN"
slices=()
for arch in "${ARCHS[@]}"; do
  prefix="$WORK/$arch/prefix"

  if [[ ! -f "$prefix/lib/libssl.a" ]]; then
    echo "==> OpenSSL $OPENSSL_VERSION ($arch)"
    rm -rf "$WORK/$arch/openssl" && mkdir -p "$WORK/$arch/openssl"
    tar -xzf "$WORK/src/openssl-$OPENSSL_VERSION.tar.gz" -C "$WORK/$arch/openssl" --strip-components=1
    (
      cd "$WORK/$arch/openssl"
      ./Configure "darwin64-$arch-cc" no-shared no-tests no-docs no-apps \
        "-mmacosx-version-min=$MACOS_MIN" --prefix="$prefix" --libdir=lib >/dev/null
      make -j"$JOBS" >/dev/null
      make install_sw >/dev/null
    )
  fi

  if [[ ! -f "$prefix/lib/libtorrent-rasterbar.a" ]]; then
    echo "==> libtorrent $LIBTORRENT_VERSION ($arch)"
    rm -rf "$WORK/$arch/libtorrent" && mkdir -p "$WORK/$arch/libtorrent"
    tar -xzf "$WORK/src/libtorrent-rasterbar-$LIBTORRENT_VERSION.tar.gz" -C "$WORK/$arch/libtorrent" --strip-components=1
    cmake -S "$WORK/$arch/libtorrent" -B "$WORK/$arch/libtorrent/build" -G Ninja \
      -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_OSX_ARCHITECTURES="$arch" \
      -DCMAKE_OSX_DEPLOYMENT_TARGET="$MACOS_MIN" \
      -DCMAKE_INSTALL_PREFIX="$prefix" \
      -DCMAKE_PREFIX_PATH="$prefix" \
      -DOPENSSL_ROOT_DIR="$prefix" \
      -DOPENSSL_USE_STATIC_LIBS=TRUE \
      -DBoost_INCLUDE_DIR="$BOOST_INCLUDE_DIR" \
      -DCMAKE_CXX_FLAGS="-isystem $BOOST_INCLUDE_DIR" \
      -DBUILD_SHARED_LIBS=OFF \
      -Dbuild_tests=OFF -Dbuild_examples=OFF -Dbuild_tools=OFF -Dpython-bindings=OFF \
      -Dencryption=ON -Ddeprecated-functions=ON -Dwebtorrent=OFF >/dev/null
    cmake --build "$WORK/$arch/libtorrent/build" -j"$JOBS"
    cmake --install "$WORK/$arch/libtorrent/build" >/dev/null
  fi

  echo "==> torrent_bridge ($arch)"
  bridge="$WORK/$arch/bridge"
  rm -rf "$bridge"
  cmake -S "$PLUGIN/src" -B "$bridge" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_OSX_ARCHITECTURES="$arch" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$MACOS_MIN" \
    -DCMAKE_PREFIX_PATH="$prefix" \
    -DOPENSSL_ROOT_DIR="$prefix" \
    -DLTF_STATIC_DEPS=ON \
    -DBoost_INCLUDE_DIR="$BOOST_INCLUDE_DIR" >/dev/null
  cmake --build "$bridge" -j"$JOBS" >/dev/null
  slices+=("$bridge/liblibtorrent_flutter.dylib")
done

lipo -create "${slices[@]}" -output "$OUT"
install_name_tool -id "@rpath/liblibtorrent_flutter.dylib" "$OUT"
strip -x "$OUT"
codesign --force -s - "$OUT" >/dev/null

# Must not reference Homebrew / build-tree libraries at runtime.
if otool -L "$OUT" | grep -E '^\s' | grep -vE '^\s+(/usr/lib/|/System/|@rpath/liblibtorrent_flutter)' ; then
  echo "unexpected non-system dependency in $OUT" >&2
  exit 1
fi
echo "$want_stamp" > "$STAMP"
lipo -info "$OUT"
ls -lh "$OUT"
