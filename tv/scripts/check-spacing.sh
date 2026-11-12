#!/bin/bash
# Fails when a margin is written as a number anywhere outside Theme.swift and
# outside the player, whose measures come from the tvOS reference and not
# from this app's rhythm.
#
# usage: tv/scripts/check-spacing.sh
set -euo pipefail
TV_DIR=$(cd "$(dirname "$0")/.." && pwd)
# `spacing: 0` stays a number: zero is the absence of a margin, not a value
# of the scale, and `Space.s0` would be a name for nothing.
found=$(grep -rnE '\.padding\((\.[a-z]+, *)?[0-9]|spacing: [1-9]' "$TV_DIR/Sources" \
    --include='*.swift' \
    | grep -v '/App/Theme.swift:' \
    | grep -v '/Screens/Player/' \
    | grep -v '/Screens/PlayerScreen.swift:' \
    || true)
if [ -n "$found" ]; then
    echo "margins written as numbers, which belong in Theme.Space:"
    echo "$found"
    exit 1
fi
# A line that does not fit is set smaller, never cut: `.fits()` carries the
# shrink, and a bare `.lineLimit` would put the ellipsis back.
cut=$(grep -rn '\.lineLimit(' "$TV_DIR/Sources" --include='*.swift' \
    | grep -v '/Components/Fits.swift:' \
    | grep -v '/Screens/Player/' \
    || true)
if [ -n "$cut" ]; then
    echo "text cut with an ellipsis, which belongs in .fits():"
    echo "$cut"
    exit 1
fi
echo "every margin comes from Theme, and no text is cut"
