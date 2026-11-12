#!/bin/bash
# Writes the film LexisShots plays the player on: two hours, two audio
# tracks, one subtitle track and a chapter every quarter hour, the shape of
# the one the native player was measured on. Prints its path.
#
# usage: tv/scripts/make-shots-movie.sh [output.mkv]
set -euo pipefail
OUT=${1:-${TMPDIR:-/tmp}/lexis-shots.mkv}
if [ -f "$OUT" ]; then
    echo "$OUT"
    exit 0
fi
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
python3 - "$WORK" <<'EOF'
import sys

work = sys.argv[1]

def stamp(s):
    return f"{s // 3600:02}:{s // 60 % 60:02}:{s % 60:02},000"

with open(f"{work}/subs.srt", "w") as srt:
    for n, start in enumerate(range(0, 7200, 6), 1):
        srt.write(f"{n}\n{stamp(start)} --> {stamp(start + 4)}\nSubtitle line at {start}\n\n")
with open(f"{work}/chapters.txt", "w") as meta:
    meta.write(";FFMETADATA1\n")
    for n, start in enumerate(range(0, 7200, 900), 1):
        meta.write(f"[CHAPTER]\nTIMEBASE=1/1\nSTART={start}\nEND={start + 900}\ntitle=Chapter {n}\n")
EOF
ffmpeg -hide_banner -loglevel error -y \
    -f lavfi -i "gradients=size=1920x1080:rate=2:duration=7200:speed=0.002:c0=0x1a2a40:c1=0x6a4a30:c2=0x203020:c3=0x402040" \
    -f lavfi -i "sine=frequency=440:duration=7200" \
    -f lavfi -i "sine=frequency=660:duration=7200" \
    -i "$WORK/subs.srt" -i "$WORK/chapters.txt" \
    -map 0:v -map 1:a -map 2:a -map 3:s -map_chapters 4 \
    -c:v libx264 -preset veryfast -crf 40 -g 4 -pix_fmt yuv420p \
    -c:a aac -ac 1 -b:a 16k -c:s srt \
    -metadata:s:a:0 language=fre -metadata:s:a:1 language=eng -metadata:s:s:0 language=fre \
    -disposition:a:0 default -disposition:a:1 0 -disposition:s:0 0 \
    "$OUT"
echo "$OUT"
