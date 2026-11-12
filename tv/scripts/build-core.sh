#!/bin/bash
# Builds the Rust core for the Apple TV and its simulator, wraps the two
# static libraries in an xcframework, and generates the Swift bindings over
# them. Everything lands under tv/LexisCore, which the Xcode project takes as
# a local package.
#
# usage: tv/scripts/build-core.sh
set -euo pipefail
TV_DIR=$(cd "$(dirname "$0")/.." && pwd)
CORE_DIR=$(cd "$TV_DIR/../core" && pwd)
PACKAGE="$TV_DIR/LexisCore"
DEVICE_TRIPLE=aarch64-apple-tvos
SIM_TRIPLE=aarch64-apple-tvos-sim
export TVOS_DEPLOYMENT_TARGET=27.0

cd "$CORE_DIR"
# the staticlib alone: the app links nothing else, and the cdylib and rlib
# Cargo.toml also declares would each cost a link of their own
cargo rustc --release --lib --target "$DEVICE_TRIPLE" --crate-type staticlib
cargo rustc --release --lib --target "$SIM_TRIPLE" --crate-type staticlib
DEVICE_LIB="$CORE_DIR/target/$DEVICE_TRIPLE/release/liblexis_core.a"
SIM_LIB="$CORE_DIR/target/$SIM_TRIPLE/release/liblexis_core.a"

STAMP_KEY=$(shasum -a 256 "$DEVICE_LIB" "$SIM_LIB" | shasum -a 256 | cut -d' ' -f1)
OUT="$PACKAGE/LexisCoreFramework.xcframework"
if [ -f "$OUT/.stamp" ] && [ "$(cat "$OUT/.stamp")" = "$STAMP_KEY" ]; then
  echo "xcframework up to date"
else
  STAGE=$(mktemp -d)
  xcodebuild -create-xcframework \
    -library "$DEVICE_LIB" \
    -library "$SIM_LIB" \
    -output "$STAGE/LexisCoreFramework.xcframework"
  rm -rf "$OUT"
  mv "$STAGE/LexisCoreFramework.xcframework" "$OUT"
  rmdir "$STAGE"
  echo "$STAMP_KEY" > "$OUT/.stamp"
fi

BINDINGS=$(mktemp -d)
cargo run --quiet --features cli --bin uniffi-bindgen -- generate \
  --library "$DEVICE_LIB" --language swift --out-dir "$BINDINGS"
mkdir -p "$PACKAGE/Sources/LexisCore" "$PACKAGE/Sources/lexis_coreFFI/include"
mv "$BINDINGS/lexis_core.swift" "$PACKAGE/Sources/LexisCore/lexis_core.swift"
mv "$BINDINGS/lexis_coreFFI.h" "$PACKAGE/Sources/lexis_coreFFI/include/lexis_coreFFI.h"
rm -rf "$BINDINGS"
# SwiftPM wants a source file in a C target, and generates the module map
# itself from the include directory.
printf '#include "lexis_coreFFI.h"\n' > "$PACKAGE/Sources/lexis_coreFFI/lexis_coreFFI.c"
echo "bindings written to $PACKAGE"
