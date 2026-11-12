#!/bin/bash
# Builds FFmpeg as a single dynamic FFmpeg.xcframework for macOS, tvOS and the
# tvOS simulator, and copies its public headers into the CFFmpeg shim.
# LGPL only: --enable-gpl and --enable-nonfree must never appear here.
set -euo pipefail

FFMPEG_VERSION=7.1.5
FFMPEG_SHA256=de668509caf9e35e3cd162473441fdb29538c6d96ed080292b3cf9e6fc5d558f
MACOS_MIN=14.0
TVOS_MIN=27.0

# dav1d: BSD 2-Clause, a build-time vendor like FFmpeg itself - no new
# runtime dependency, no new licence family. AV1 software speed is the one
# reason this joins the build at all (task 2.6); everything else FFmpeg
# already decodes without it.
DAV1D_VERSION=1.5.4
DAV1D_SHA256=a1d5b63d2d38ec9bd03acf643caa51fa22edd1e89c5a109c4807717216bbec07

PLAYER_DIR=$(cd "$(dirname "$0")/.." && pwd)
WORK="$PLAYER_DIR/.build-ffmpeg"
SRC="$WORK/ffmpeg-$FFMPEG_VERSION"
TARBALL="$WORK/ffmpeg-$FFMPEG_VERSION.tar.xz"
STAGE="$WORK/stage"
OUT="$PLAYER_DIR/Vendor/FFmpeg.xcframework"
HEADERS="$PLAYER_DIR/Sources/CFFmpeg/include"
JOBS=$(sysctl -n hw.ncpu)

DAV1D_WORK="$PLAYER_DIR/.build-dav1d"
DAV1D_SRC="$DAV1D_WORK/dav1d-$DAV1D_VERSION"
DAV1D_TARBALL="$DAV1D_WORK/dav1d-$DAV1D_VERSION.tar.gz"

CONFIGURE_FLAGS=(
  --disable-autodetect --enable-zlib
  --disable-gpl --disable-nonfree --disable-version3
  --disable-programs --disable-doc --disable-debug
  --disable-avdevice --disable-avfilter --disable-postproc
  --disable-encoders --disable-muxers --disable-devices --disable-network
  --disable-audiotoolbox --disable-videotoolbox
  --disable-shared --enable-static --enable-pic
  --enable-libdav1d
)

# Nothing is promoted to its final path until it has been verified, so an
# interrupted download or extraction cannot poison the cache for later runs.
fetch_source() {
  mkdir -p "$WORK"
  if [ ! -f "$TARBALL" ]; then
    curl -sSL --fail -o "$TARBALL.part" \
      "https://ffmpeg.org/releases/ffmpeg-$FFMPEG_VERSION.tar.xz"
    echo "$FFMPEG_SHA256  $TARBALL.part" | shasum -a 256 -c -
    mv "$TARBALL.part" "$TARBALL"
  else
    echo "$FFMPEG_SHA256  $TARBALL" | shasum -a 256 -c -
  fi
  if [ ! -d "$SRC" ]; then
    rm -rf "$SRC.part"
    mkdir -p "$SRC.part"
    tar xf "$TARBALL" -C "$SRC.part" --strip-components=1
    mv "$SRC.part" "$SRC"
  fi
}

fetch_dav1d_source() {
  mkdir -p "$DAV1D_WORK"
  if [ ! -f "$DAV1D_TARBALL" ]; then
    curl -sSL --fail -o "$DAV1D_TARBALL.part" \
      "https://code.videolan.org/videolan/dav1d/-/archive/$DAV1D_VERSION/dav1d-$DAV1D_VERSION.tar.gz"
    echo "$DAV1D_SHA256  $DAV1D_TARBALL.part" | shasum -a 256 -c -
    mv "$DAV1D_TARBALL.part" "$DAV1D_TARBALL"
  else
    echo "$DAV1D_SHA256  $DAV1D_TARBALL" | shasum -a 256 -c -
  fi
  if [ ! -d "$DAV1D_SRC" ]; then
    rm -rf "$DAV1D_SRC.part"
    mkdir -p "$DAV1D_SRC.part"
    tar xf "$DAV1D_TARBALL" -C "$DAV1D_SRC.part" --strip-components=1
    mv "$DAV1D_SRC.part" "$DAV1D_SRC"
  fi
}

# build_dav1d_target <name> <sdk> <triple> - meson/ninja cross file per
# target, the same stamp-key-then-install-then-NEON-check shape build_target
# uses for FFmpeg itself. Prints the target's own install prefix on stdout,
# which is how the caller finds its .pc file and static library.
build_dav1d_target() {
  local name=$1 sdk=$2 triple=$3
  local prefix="$DAV1D_WORK/install/$name"
  local builddir="$DAV1D_WORK/build/$name"
  local stamp_key
  stamp_key=$(printf '%s\n' "$DAV1D_VERSION" "$sdk" "$triple" | shasum -a 256 | cut -d' ' -f1)
  if [ -f "$prefix/.stamp" ] && [ "$(cat "$prefix/.stamp")" = "$stamp_key" ]; then
    echo "$prefix"
    return
  fi
  local sysroot
  sysroot=$(xcrun --sdk "$sdk" --show-sdk-path)
  local cross_file="$DAV1D_WORK/$name-cross.txt"
  cat > "$cross_file" <<CROSSFILE
[binaries]
c = ['xcrun', '-sdk', '$sdk', 'clang']
ar = ['xcrun', '-sdk', '$sdk', 'ar']
strip = ['xcrun', '-sdk', '$sdk', 'strip']
pkg-config = ['pkg-config']

[built-in options]
c_args = ['-arch', 'arm64', '-target', '$triple', '-isysroot', '$sysroot']
c_link_args = ['-arch', 'arm64', '-target', '$triple', '-isysroot', '$sysroot']

[host_machine]
system = 'darwin'
cpu_family = 'aarch64'
cpu = 'aarch64'
endian = 'little'
CROSSFILE
  rm -rf "$builddir" "$prefix"
  meson setup "$builddir" "$DAV1D_SRC" --cross-file "$cross_file" \
    --default-library=static --buildtype=release \
    -Denable_tools=false -Denable_examples=false -Denable_tests=false -Denable_docs=false \
    -Dbitdepths=8,16 --prefix="$prefix" >&2
  meson compile -C "$builddir" >&2
  meson install -C "$builddir" >&2
  # Confirmed in the vendored build's own output rather than assumed: dav1d
  # names no separate "neon" feature for arm64 (it is the mandatory AArch64
  # baseline, unconditionally built - the plan's literal "grep the configure
  # log for neon" does not apply to this library on this architecture), so
  # the check instead reads the linked archive's own symbol table, where
  # every arm_64_*.S routine dav1d built shows up by its own _neon suffix.
  # A pipe into `grep -q` is the wrong shape here: grep exits the instant it
  # finds a match, closing the pipe while nm is still writing, and under
  # pipefail that SIGPIPE (not grep's own success) becomes the pipeline's
  # status. Capturing nm's output first sidesteps it.
  local symbols
  symbols=$(nm "$prefix/lib/libdav1d.a" 2>/dev/null || true)
  if ! grep -qi neon <<<"$symbols"; then
    echo "dav1d ($name) has no NEON symbols in its own static library - stopping" >&2
    exit 1
  fi
  echo "$stamp_key" > "$prefix/.stamp"
  echo "$prefix"
}

# build_target <name> <sdk> <triple> <arch>
build_target() {
  local name=$1 sdk=$2 triple=$3 arch=$4
  local prefix="$WORK/install/$name"
  local builddir="$WORK/build/$name"
  local dav1d_prefix
  dav1d_prefix=$(build_dav1d_target "$name" "$sdk" "$triple")
  # The stamp keys on everything that changes the output, so editing a
  # configure flag, a triple or the dav1d version rebuilds instead of
  # reusing a stale install.
  local stamp_key
  stamp_key=$(printf '%s\n' "$FFMPEG_VERSION" "$DAV1D_VERSION" "$sdk" "$triple" "$arch" \
    "${CONFIGURE_FLAGS[@]}" | shasum -a 256 | cut -d' ' -f1)
  if [ -f "$prefix/.stamp" ] && [ "$(cat "$prefix/.stamp")" = "$stamp_key" ]; then
    echo "== $name up to date"
    return
  fi
  local sysroot
  sysroot=$(xcrun --sdk "$sdk" --show-sdk-path)
  rm -rf "$builddir" "$prefix"
  mkdir -p "$builddir"
  (
    cd "$builddir"
    # PKG_CONFIG_LIBDIR, not PKG_CONFIG_PATH: restricts pkg-config to only
    # this target's own dav1d.pc, so a host dav1d (say, from Homebrew) can
    # never leak into a cross build for a different arch or SDK.
    PKG_CONFIG_LIBDIR="$dav1d_prefix/lib/pkgconfig" \
      "$SRC/configure" --prefix="$prefix" "${CONFIGURE_FLAGS[@]}" \
      --enable-cross-compile --target-os=darwin --arch="$arch" \
      --cc="xcrun -sdk $sdk clang" \
      --as="xcrun -sdk $sdk clang" \
      --extra-cflags="-arch $arch -target $triple -isysroot $sysroot -I$dav1d_prefix/include" \
      --extra-ldflags="-arch $arch -target $triple -isysroot $sysroot -L$dav1d_prefix/lib"
    make -j"$JOBS"
    make install
  )
  echo "$stamp_key" > "$prefix/.stamp"
}

# make_framework <name> <sdk> <triple> <minimum os version>
make_framework() {
  local name=$1 sdk=$2 triple=$3 minimum=$4
  local prefix="$WORK/install/$name"
  local dav1d_prefix="$DAV1D_WORK/install/$name"
  local stage="$STAGE/$name"
  local framework="$stage/FFmpeg.framework"
  local sysroot
  sysroot=$(xcrun --sdk "$sdk" --show-sdk-path)
  rm -rf "$stage"
  mkdir -p "$stage"
  cp "$prefix"/lib/*.a "$stage/"
  cp "$dav1d_prefix/lib/libdav1d.a" "$stage/"
  # libswscale carries its own copy of libavutil's half2float table, which
  # -all_load would pull in twice and fail the link on a duplicate symbol.
  ar d "$stage/libswscale.a" half2float.o || true

  # macOS embedding and codesigning require the versioned bundle layout;
  # tvOS requires the flat one.
  local binary plist install_name
  if [ "$sdk" = macosx ]; then
    mkdir -p "$framework/Versions/A/Resources"
    ln -s A "$framework/Versions/Current"
    ln -s Versions/Current/FFmpeg "$framework/FFmpeg"
    ln -s Versions/Current/Resources "$framework/Resources"
    binary="$framework/Versions/A/FFmpeg"
    plist="$framework/Versions/A/Resources/Info.plist"
    install_name="@rpath/FFmpeg.framework/Versions/A/FFmpeg"
  else
    mkdir -p "$framework"
    binary="$framework/FFmpeg"
    plist="$framework/Info.plist"
    install_name="@rpath/FFmpeg.framework/FFmpeg"
  fi

  xcrun -sdk "$sdk" clang -dynamiclib \
    -target "$triple" -isysroot "$sysroot" \
    -install_name "$install_name" \
    -Wl,-all_load \
    "$stage/libavformat.a" "$stage/libavcodec.a" "$stage/libswresample.a" \
    "$stage/libswscale.a" "$stage/libavutil.a" "$stage/libdav1d.a" \
    -lz -lm \
    -framework CoreFoundation -framework CoreVideo -framework CoreMedia \
    -o "$binary"
  cat > "$plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>org.lexis.FFmpeg</string>
<key>CFBundleName</key><string>FFmpeg</string>
<key>CFBundleExecutable</key><string>FFmpeg</string>
<key>CFBundlePackageType</key><string>FMWK</string>
<key>CFBundleVersion</key><string>$FFMPEG_VERSION</string>
<key>CFBundleShortVersionString</key><string>$FFMPEG_VERSION</string>
<key>MinimumOSVersion</key><string>$minimum</string>
</dict></plist>
PLIST

  # LGPL 2.1 asks that the licence travel with the binary, and that what was
  # built from the unmodified sources be stated. The notice records the
  # configuration verbatim so the build can be reproduced from the artifact.
  local licenses="$framework"
  if [ "$sdk" = macosx ]; then
    licenses="$framework/Versions/A/Resources"
  fi
  cp "$SRC/COPYING.LGPLv2.1" "$licenses/COPYING.LGPLv2.1"
  cp "$DAV1D_SRC/COPYING" "$licenses/COPYING.dav1d-BSD-2-Clause"
  {
    echo "FFmpeg $FFMPEG_VERSION"
    echo "License: LGPL 2.1 or later, unmodified"
    echo "Source: https://ffmpeg.org/releases/ffmpeg-$FFMPEG_VERSION.tar.xz"
    echo "Configure flags:"
    printf '  %s\n' "${CONFIGURE_FLAGS[@]}"
    echo
    echo "dav1d $DAV1D_VERSION"
    echo "License: BSD 2-Clause, unmodified"
    echo "Source: https://code.videolan.org/videolan/dav1d/-/archive/$DAV1D_VERSION/dav1d-$DAV1D_VERSION.tar.gz"
  } > "$licenses/FFMPEG_NOTICE.txt"
}

fetch_source
fetch_dav1d_source

build_target macos macosx "arm64-apple-macos$MACOS_MIN" arm64
build_target tvos appletvos "arm64-apple-tvos$TVOS_MIN" arm64
build_target tvsim appletvsimulator "arm64-apple-tvos$TVOS_MIN-simulator" arm64

make_framework macos macosx "arm64-apple-macos$MACOS_MIN" "$MACOS_MIN"
make_framework tvos appletvos "arm64-apple-tvos$TVOS_MIN" "$TVOS_MIN"
make_framework tvsim appletvsimulator "arm64-apple-tvos$TVOS_MIN-simulator" "$TVOS_MIN"

rm -rf "$OUT"
mkdir -p "$(dirname "$OUT")"
xcodebuild -create-xcframework \
  -framework "$STAGE/macos/FFmpeg.framework" \
  -framework "$STAGE/tvos/FFmpeg.framework" \
  -framework "$STAGE/tvsim/FFmpeg.framework" \
  -output "$OUT"

# The installed public headers are identical for the three targets (same
# options, same arch), so one copy serves the whole package.
for dir in libavcodec libavformat libavutil libswresample libswscale; do
  rm -rf "${HEADERS:?}/$dir"
  cp -R "$WORK/install/macos/include/$dir" "$HEADERS/$dir"
done

echo "built $OUT"
