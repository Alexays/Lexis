#!/bin/bash
# Builds a Release app and installs it on a paired Apple TV. A plain `build`
# skips the strip an archive does, so DEPLOYMENT_POSTPROCESSING asks for it.
# usage: tv/scripts/install-tv.sh [device-name-or-udid]
set -euo pipefail
TV_DIR=$(cd "$(dirname "$0")/.." && pwd)
DEVICE="${1:-TV}"
DERIVED="$TV_DIR/.build-tv"
"$TV_DIR/scripts/build-core.sh"
cd "$TV_DIR"
xcodegen generate --quiet
xcodebuild -project Lexis.xcodeproj -scheme Lexis \
    -configuration Release -destination "platform=tvOS,name=$DEVICE" \
    -derivedDataPath "$DERIVED" -allowProvisioningUpdates \
    CODE_SIGN_STYLE=Automatic \
    DEPLOYMENT_POSTPROCESSING=YES \
    build
xcrun devicectl device install app --device "$DEVICE" \
    "$DERIVED/Build/Products/Release-appletvos/Lexis.app"
