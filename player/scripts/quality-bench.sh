#!/bin/bash
# Scores the HDR upscale against the 4K picture it came from, clean and
# through a streaming-grade HEVC encode, with ffmpeg's VMAF NEG and SSIM.
# usage: player/scripts/quality-bench.sh <4K-or-larger image> [crf]
set -euo pipefail
PLAYER=$(cd "$(dirname "$0")/.." && pwd)
IMAGE=$(cd "$(dirname "$1")" && pwd)/$(basename "$1")
CRF="${2:-22}"
OUT=$(mktemp -d)
MODEL=$(brew --prefix libvmaf)/share/libvmaf/model/vmaf_4k_v0.6.1neg.json
RAW="-f rawvideo -pix_fmt gray10le"

bench() {
    (cd "$PLAYER" && env LEXIS_BENCH=1 LEXIS_BENCH_IMAGE="$IMAGE" LEXIS_BENCH_OUT="$1" "${@:2}" \
        swift test --filter "QualityBench/testHDRUpscaleAgainstItsSource" 2>&1 \
        | grep -E "^(scaler |bilinear|catmull|lanczos3|metalfx)" || true)
}

score() {
    for name in bilinear metalfx; do
        vmaf=$(ffmpeg -hide_banner -loglevel error $RAW -s 3840x2160 -i "$1/$name.gray10" \
            $RAW -s 3840x2160 -i "$1/reference.gray10" \
            -lavfi "[0:v]format=yuv420p10le[d];[1:v]format=yuv420p10le[r];[d][r]libvmaf=model='path=$MODEL':log_path=$1/$name.json:log_fmt=json" \
            -f null - && python3 -c "import json;print(round(json.load(open('$1/$name.json'))['pooled_metrics']['vmaf']['mean'],2))")
        ssim=$(ffmpeg -hide_banner $RAW -s 3840x2160 -i "$1/$name.gray10" $RAW -s 3840x2160 -i "$1/reference.gray10" \
            -lavfi ssim -f null - 2>&1 | grep -o "All:[0-9.]*" | cut -d: -f2)
        printf "  %-10s VMAF NEG %6s   SSIM %s\n" "$name" "$vmaf" "$ssim"
    done
}

mkdir -p "$OUT/clean" "$OUT/hevc"
echo "clean 1080p"
bench "$OUT/clean"
score "$OUT/clean"

# the same 1080p as a streaming service would send it: HEVC, ten bit
ffmpeg -hide_banner -loglevel error $RAW -s 1920x1080 -i "$OUT/clean/small.gray10" \
    -pix_fmt yuv420p10le -c:v libx265 -crf "$CRF" -preset medium -x265-params log-level=error "$OUT/small.mp4"
ffmpeg -hide_banner -loglevel error -i "$OUT/small.mp4" -pix_fmt gray10le -f rawvideo "$OUT/small-hevc.gray10"
echo "HEVC crf $CRF 1080p"
bench "$OUT/hevc" LEXIS_BENCH_SMALL="$OUT/small-hevc.gray10"
score "$OUT/hevc"
echo "pictures in $OUT"
