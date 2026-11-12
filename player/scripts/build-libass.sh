#!/bin/bash
# Builds libass and its dependencies as a single dynamic LibASS.xcframework for
# macOS, tvOS and the tvOS simulator, and copies libass's public headers into
# the CLibass shim.
#
# Licences: libass ISC, FreeType FTL, HarfBuzz Old MIT, FriBidi LGPL 2.1.
# FreeType is dual FTL/GPLv2 and is taken under the FTL. No GPL code is built
# here and --disable-fontconfig keeps fontconfig and expat out of the tree.
set -euo pipefail

LIBASS_VERSION=0.17.4
LIBASS_SHA256=78f1179b838d025e9c26e8fef33f8092f65611444ffa1bfc0cfac6a33511a05a
FREETYPE_VERSION=2.13.3
FREETYPE_SHA256=0550350666d427c74daeb85d5ac7bb353acba5f76956395995311a9c6f063289
HARFBUZZ_VERSION=10.4.0
HARFBUZZ_SHA256=480b6d25014169300669aa1fc39fb356c142d5028324ea52b3a27648b9beaad8
FRIBIDI_VERSION=1.0.16
FRIBIDI_SHA256=1b1cde5b235d40479e91be2f0e88a309e3214c8ab470ec8a2744d82a5a9ea05c
MACOS_MIN=14.0
TVOS_MIN=27.0

PLAYER_DIR=$(cd "$(dirname "$0")/.." && pwd)
WORK="$PLAYER_DIR/.build-libass"
STAGE="$WORK/stage"
OUT="$PLAYER_DIR/Vendor/LibASS.xcframework"
HEADERS="$PLAYER_DIR/Sources/CLibass/include"
EXPORTS="$PLAYER_DIR/scripts/libass-exported.sym"
JOBS=$(sysctl -n hw.ncpu)

FREETYPE_FLAGS=(
  --enable-static --disable-shared
  --with-zlib=no --with-bzip2=no --with-png=no --with-harfbuzz=no
  --with-brotli=no --with-librsvg=no
  --without-ats --without-fsspec --without-fsref
  --without-quickdraw-toolbox --without-quickdraw-carbon --without-old-mac-fonts
)
FRIBIDI_FLAGS=(
  --enable-static --disable-shared --disable-debug --disable-deprecated
)
# One translation unit: HarfBuzz ships no configure, only meson. HB_NO_MT drops
# its atomic refcounting, which is sound only because one queue owns every
# libass object in this player (see AssRenderer).
HARFBUZZ_FLAGS=(
  -std=c++17 -fno-exceptions -fno-rtti
  -DHAVE_FREETYPE=1 -DHAVE_CORETEXT=1 -DHB_NO_MT=1
)
# asm stays on: libass ships hand-written AArch64 rasterizer, blur and blend,
# which is the per-frame path on both architectures this framework targets.
LIBASS_FLAGS=(
  --enable-static --disable-shared
  --disable-fontconfig --enable-large-tiles
)

# fetch <name> <version> <sha256> <url>
fetch() {
  local name=$1 version=$2 sha=$3 url=$4
  local tarball="$WORK/$name-$version.tar.xz"
  local src="$WORK/$name-$version"
  mkdir -p "$WORK"
  if [ ! -f "$tarball" ]; then
    curl -sSL --fail -o "$tarball.part" "$url"
    echo "$sha  $tarball.part" | shasum -a 256 -c -
    mv "$tarball.part" "$tarball"
  else
    echo "$sha  $tarball" | shasum -a 256 -c -
  fi
  if [ ! -d "$src" ]; then
    rm -rf "$src.part"
    mkdir -p "$src.part"
    tar xf "$tarball" -C "$src.part" --strip-components=1
    mv "$src.part" "$src"
  fi
}

fetch_sources() {
  fetch freetype "$FREETYPE_VERSION" "$FREETYPE_SHA256" \
    "https://download.savannah.gnu.org/releases/freetype/freetype-$FREETYPE_VERSION.tar.xz"
  fetch fribidi "$FRIBIDI_VERSION" "$FRIBIDI_SHA256" \
    "https://github.com/fribidi/fribidi/releases/download/v$FRIBIDI_VERSION/fribidi-$FRIBIDI_VERSION.tar.xz"
  fetch harfbuzz "$HARFBUZZ_VERSION" "$HARFBUZZ_SHA256" \
    "https://github.com/harfbuzz/harfbuzz/releases/download/$HARFBUZZ_VERSION/harfbuzz-$HARFBUZZ_VERSION.tar.xz"
  fetch libass "$LIBASS_VERSION" "$LIBASS_SHA256" \
    "https://github.com/libass/libass/releases/download/$LIBASS_VERSION/libass-$LIBASS_VERSION.tar.xz"
}

# build_target <name> <sdk> <triple> <arch> <configure host> <configure build>
#
# The last two are not decoration. autoconf canonicalises every Apple SDK to the
# same triple, decides it is a native build and tries to run a test binary,
# which fails for tvOS; the only thing it checks is whether the two strings
# differ.
build_target() {
  local name=$1 sdk=$2 triple=$3 arch=$4 conf_host=$5 conf_build=$6
  local prefix="$WORK/install/$name"
  local builddir="$WORK/build/$name"
  local stamp_key
  stamp_key=$(printf '%s\n' \
    "$LIBASS_VERSION" "$FREETYPE_VERSION" "$HARFBUZZ_VERSION" "$FRIBIDI_VERSION" \
    "$sdk" "$triple" "$arch" "$conf_host" "$conf_build" \
    "${FREETYPE_FLAGS[@]}" "${FRIBIDI_FLAGS[@]}" "${HARFBUZZ_FLAGS[@]}" \
    "${LIBASS_FLAGS[@]}" | shasum -a 256 | cut -d' ' -f1)
  if [ -f "$prefix/.stamp" ] && [ "$(cat "$prefix/.stamp")" = "$stamp_key" ]; then
    echo "== $name up to date"
    return
  fi
  local sysroot host_sysroot
  sysroot=$(xcrun --sdk "$sdk" --show-sdk-path)
  host_sysroot=$(xcrun --sdk macosx --show-sdk-path)
  rm -rf "$builddir" "$prefix"
  mkdir -p "$builddir/freetype" "$builddir/fribidi" "$builddir/harfbuzz" \
    "$builddir/libass" "$prefix/lib/pkgconfig"

  export CC CXX AR RANLIB CFLAGS CXXFLAGS LDFLAGS PKG_CONFIG_LIBDIR PKG_CONFIG_PATH
  CC=$(xcrun --sdk "$sdk" -f clang)
  CXX=$(xcrun --sdk "$sdk" -f clang++)
  AR=$(xcrun --sdk "$sdk" -f ar)
  RANLIB=$(xcrun --sdk "$sdk" -f ranlib)
  CFLAGS="-arch $arch -target $triple -isysroot $sysroot -fPIC -O2"
  CXXFLAGS="$CFLAGS"
  LDFLAGS="$CFLAGS"
  PKG_CONFIG_LIBDIR="$prefix/lib/pkgconfig"
  PKG_CONFIG_PATH="$prefix/lib/pkgconfig"

  # FreeType builds one tool, apinames, for the build machine, with CC and none
  # of CFLAGS. A resolved clang path finds no headers without a sysroot.
  (
    cd "$builddir/freetype"
    "$WORK/freetype-$FREETYPE_VERSION/configure" --prefix="$prefix" \
      --host="$conf_host" --build="$conf_build" "${FREETYPE_FLAGS[@]}"
    make -j"$JOBS" CCexe_CFLAGS="-isysroot $host_sysroot"
    make install CCexe_CFLAGS="-isysroot $host_sysroot"
  )
  (
    cd "$builddir/fribidi"
    "$WORK/fribidi-$FRIBIDI_VERSION/configure" --prefix="$prefix" \
      --host="$conf_host" --build="$conf_build" "${FRIBIDI_FLAGS[@]}"
    make -j"$JOBS"
    make install
  )
  (
    cd "$builddir/harfbuzz"
    "$CXX" $CXXFLAGS "${HARFBUZZ_FLAGS[@]}" \
      -I"$prefix/include/freetype2" -I"$WORK/harfbuzz-$HARFBUZZ_VERSION/src" \
      -c "$WORK/harfbuzz-$HARFBUZZ_VERSION/src/harfbuzz.cc" -o harfbuzz.o
    "$AR" rcs libharfbuzz.a harfbuzz.o
    cp libharfbuzz.a "$prefix/lib/"
    mkdir -p "$prefix/include/harfbuzz"
    cp "$WORK/harfbuzz-$HARFBUZZ_VERSION/src"/hb*.h "$prefix/include/harfbuzz/"
    # libass finds harfbuzz through pkg-config and nothing else provides one
    printf 'prefix=%s\nlibdir=${prefix}/lib\nincludedir=${prefix}/include\n\nName: harfbuzz\nDescription: HarfBuzz text shaping\nVersion: %s\nLibs: -L${libdir} -lharfbuzz -lc++\nCflags: -I${includedir}/harfbuzz\n' \
      "$prefix" "$HARFBUZZ_VERSION" > "$prefix/lib/pkgconfig/harfbuzz.pc"
  )
  (
    cd "$builddir/libass"
    "$WORK/libass-$LIBASS_VERSION/configure" --prefix="$prefix" \
      --host="$conf_host" --build="$conf_build" "${LIBASS_FLAGS[@]}"
    make -j"$JOBS"
    make install
  )
  # What the rest of this script and every reader depends on being true.
  grep -q '^#define CONFIG_CORETEXT 1' "$builddir/libass/config.h"
  grep -q 'undef CONFIG_FONTCONFIG' "$builddir/libass/config.h"
  echo "$stamp_key" > "$prefix/.stamp"
}

# make_framework <name> <sdk> <triple> <minimum os version>
make_framework() {
  local name=$1 sdk=$2 triple=$3 minimum=$4
  local prefix="$WORK/install/$name"
  local stage="$STAGE/$name"
  local framework="$stage/LibASS.framework"
  local sysroot
  sysroot=$(xcrun --sdk "$sdk" --show-sdk-path)
  rm -rf "$stage"
  mkdir -p "$stage"

  # macOS embedding and codesigning require the versioned bundle layout;
  # tvOS requires the flat one.
  local binary plist install_name licenses
  if [ "$sdk" = macosx ]; then
    mkdir -p "$framework/Versions/A/Resources"
    ln -s A "$framework/Versions/Current"
    ln -s Versions/Current/LibASS "$framework/LibASS"
    ln -s Versions/Current/Resources "$framework/Resources"
    binary="$framework/Versions/A/LibASS"
    plist="$framework/Versions/A/Resources/Info.plist"
    install_name="@rpath/LibASS.framework/Versions/A/LibASS"
    licenses="$framework/Versions/A/Resources"
  else
    mkdir -p "$framework"
    binary="$framework/LibASS"
    plist="$framework/Info.plist"
    install_name="@rpath/LibASS.framework/LibASS"
    licenses="$framework"
  fi

  # -all_load because a static archive contributes nothing to a dylib unless
  # something already in the link references it. The export list keeps
  # FreeType, HarfBuzz and FriBidi internals out of the dynamic symbol table:
  # this process already loads FFmpeg.framework.
  xcrun -sdk "$sdk" clang -dynamiclib \
    -target "$triple" -isysroot "$sysroot" \
    -install_name "$install_name" \
    -Wl,-all_load -Wl,-exported_symbols_list,"$EXPORTS" \
    "$prefix/lib/libass.a" "$prefix/lib/libharfbuzz.a" \
    "$prefix/lib/libfribidi.a" "$prefix/lib/libfreetype.a" \
    -liconv -lc++ -lm \
    -framework CoreText -framework CoreGraphics -framework CoreFoundation \
    -o "$binary"
  cat > "$plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>org.lexis.LibASS</string>
<key>CFBundleName</key><string>LibASS</string>
<key>CFBundleExecutable</key><string>LibASS</string>
<key>CFBundlePackageType</key><string>FMWK</string>
<key>CFBundleVersion</key><string>$LIBASS_VERSION</string>
<key>CFBundleShortVersionString</key><string>$LIBASS_VERSION</string>
<key>MinimumOSVersion</key><string>$minimum</string>
</dict></plist>
PLIST

  # FriBidi is LGPL 2.1 and asks that its licence travel with the binary; the
  # other three ask for their notices. The configuration is recorded verbatim so
  # the artifact can be reproduced from what ships beside it.
  cp "$WORK/libass-$LIBASS_VERSION/COPYING" "$licenses/COPYING.libass-ISC"
  cp "$WORK/freetype-$FREETYPE_VERSION/docs/FTL.TXT" "$licenses/COPYING.freetype-FTL"
  cp "$WORK/harfbuzz-$HARFBUZZ_VERSION/COPYING" "$licenses/COPYING.harfbuzz-MIT"
  # harfbuzz.cc compiles in the Universal Shaping Engine table, which its
  # top-level COPYING points at a subdirectory for rather than covering.
  cp "$WORK/harfbuzz-$HARFBUZZ_VERSION/src/ms-use/COPYING" \
    "$licenses/COPYING.harfbuzz-ms-use-MIT"
  cp "$WORK/fribidi-$FRIBIDI_VERSION/COPYING" "$licenses/COPYING.fribidi-LGPLv2.1"
  {
    echo "libass $LIBASS_VERSION, ISC, unmodified"
    echo "  https://github.com/libass/libass/releases/download/$LIBASS_VERSION/libass-$LIBASS_VERSION.tar.xz"
    printf '  %s\n' "${LIBASS_FLAGS[@]}"
    echo "FreeType $FREETYPE_VERSION, taken under the FreeType License (FTL), unmodified"
    echo "  https://download.savannah.gnu.org/releases/freetype/freetype-$FREETYPE_VERSION.tar.xz"
    printf '  %s\n' "${FREETYPE_FLAGS[@]}"
    echo "HarfBuzz $HARFBUZZ_VERSION, Old MIT, unmodified"
    echo "  https://github.com/harfbuzz/harfbuzz/releases/download/$HARFBUZZ_VERSION/harfbuzz-$HARFBUZZ_VERSION.tar.xz"
    echo "  Universal Shaping Engine tables: MIT, Copyright (c) Microsoft"
    echo "  Corporation, see COPYING.harfbuzz-ms-use-MIT"
    printf '  %s\n' "${HARFBUZZ_FLAGS[@]}"
    echo "FriBidi $FRIBIDI_VERSION, LGPL 2.1 or later, unmodified"
    echo "  https://github.com/fribidi/fribidi/releases/download/v$FRIBIDI_VERSION/fribidi-$FRIBIDI_VERSION.tar.xz"
    printf '  %s\n' "${FRIBIDI_FLAGS[@]}"
  } > "$licenses/LIBASS_NOTICE.txt"
}

fetch_sources

build_target macos macosx "arm64-apple-macos$MACOS_MIN" arm64 \
  aarch64-apple-darwin aarch64-apple-darwin
build_target tvos appletvos "arm64-apple-tvos$TVOS_MIN" arm64 \
  aarch64-apple-darwin x86_64-apple-darwin
build_target tvsim appletvsimulator "arm64-apple-tvos$TVOS_MIN-simulator" arm64 \
  aarch64-apple-darwin x86_64-apple-darwin

make_framework macos macosx "arm64-apple-macos$MACOS_MIN" "$MACOS_MIN"
make_framework tvos appletvos "arm64-apple-tvos$TVOS_MIN" "$TVOS_MIN"
make_framework tvsim appletvsimulator "arm64-apple-tvos$TVOS_MIN-simulator" "$TVOS_MIN"

rm -rf "$OUT"
mkdir -p "$(dirname "$OUT")"
xcodebuild -create-xcframework \
  -framework "$STAGE/macos/LibASS.framework" \
  -framework "$STAGE/tvos/LibASS.framework" \
  -framework "$STAGE/tvsim/LibASS.framework" \
  -output "$OUT"

# The installed public headers are identical for the three targets.
rm -rf "${HEADERS:?}/ass"
cp -R "$WORK/install/macos/include/ass" "$HEADERS/ass"

echo "built $OUT"
