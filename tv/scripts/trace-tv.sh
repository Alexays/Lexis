#!/bin/bash
# Launches the installed app on the Apple TV with its trace on, or fetches
# the trace it wrote: health (hangs, hitches, CPU per thread, memory, heat),
# the player's open, buffer and GPU lines.
# usage: tv/scripts/trace-tv.sh start [device]   then use the app with the remote
#        tv/scripts/trace-tv.sh fetch [device]   copies the log to tv/.trace/
set -euo pipefail
TV_DIR=$(cd "$(dirname "$0")/.." && pwd)
DEVICE="${2:-TV}"
BUNDLE=io.github.alexays.lexis
case "${1:-}" in
start)
    xcrun devicectl device process launch --device "$DEVICE" --terminate-existing \
        --environment-variables '{"LEXIS_TRACE_FILE": "1"}' "$BUNDLE"
    ;;
fetch)
    mkdir -p "$TV_DIR/.trace"
    OUT="$TV_DIR/.trace/lexis-trace-$(date +%Y%m%d-%H%M%S).log"
    xcrun devicectl device copy from --device "$DEVICE" --domain-type appDataContainer \
        --domain-identifier "$BUNDLE" --source Library/Caches/lexis-trace.log --destination "$OUT"
    echo "$OUT"
    grep -E "\[lexis.health\] (hang|hitch|thermal|cpu)" "$OUT" | tail -60 || true
    ;;
*)
    echo "usage: $0 start|fetch [device]" >&2
    exit 1
    ;;
esac
