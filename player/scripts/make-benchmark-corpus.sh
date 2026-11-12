#!/bin/bash
# Builds the benchmark corpus from ffmpeg: short, generated clips, one per
# codec Lexis meets, so anyone who clones the repository can rebuild the
# identical corpus and compare their numbers to the owner's. The clips
# themselves are never committed (see player/.gitignore) - only this script
# is. Dolby Vision and the malformed encodes real collections are full of
# are deliberately out of scope; a manual pass over the owner's own library
# is what covers those.
#
# Every clip carries a tag ffmpeg writes into the file itself: a checksum of
# the exact settings that produced it. A clip is accepted only when its tag
# matches what this run of the script would use, its audio and video codecs
# and pixel format are right, and every frame the clip is supposed to hold
# is actually readable from it. Change a setting, and every clip it affects
# rebuilds on the next run without anyone having to remember to delete
# anything; a clip a process died in the middle of writing rebuilds the same
# way, because the frames after the interruption were never written.
#
# A codec whose encoder is missing from this machine's ffmpeg is reported
# and skipped when no file sits under its name; when one already does, it is
# reported separately as present but unverifiable, since a machine without
# the encoder cannot rebuild it if it is wrong and has no business vouching
# for it either. That state is written next to the clip itself, as
# <file>.unverifiable, not only printed - so a bench run reading the
# corpus days later can tell the difference without anyone's scrollback.
#
# Every present clip's video encoder is also recorded, in manifest.json next
# to the corpus: the AV1 encoder differs between machines (libsvtav1 vs
# libaom-av1), and so do x264/x265 versions between ffmpeg builds - a report
# assembled from these clips carries that alongside every number, so a
# cross-machine comparison can say "different encoder, look into it" instead
# of "worse".
#
# Usage: player/scripts/make-benchmark-corpus.sh [output-dir]
#   output-dir defaults to player/.bench-corpus
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
OUT="${1:-$SCRIPT_DIR/../.bench-corpus}"

if ! command -v ffmpeg >/dev/null 2>&1; then
    echo "ffmpeg is not on PATH: cannot generate the corpus, stopping" >&2
    exit 1
fi

mkdir -p "$OUT"

SIZE="960x540"
RATE=24
DURATION=10
TOTAL_FRAMES=$((RATE * DURATION))
# A keyframe every 1 s, forced rather than left to each encoder's default
# GOP: app/scripts/seed-e2e.sh hit a synthetic clip whose default GOP made a
# seek land seconds short of its target on flat, cut-free test content. The
# seek-latency measurement (Task 6) would silently measure that artifact
# instead of the player.
GOP=$RATE

MASTER_DISPLAY="G(13250,34500)B(7500,3000)R(34000,16000)WP(15635,16450)L(10000000,1)"
MAX_CLL="1000,400"

TAG_KEY="lexis_corpus_tag"

MISSING=()
UNVERIFIABLE=()

# ffmpeg's own version, the coarse signal a bench report can compare across
# two machines: a full per-library x264/x265/svt-av1 version is not exposed
# by ffprobe on the file itself, but a different ffmpeg build is already
# enough to say "different, look into it" rather than "worse" when a decode
# time moves between two runs that used different encoders.
FFMPEG_VERSION=$(ffmpeg -version 2>/dev/null | head -n 1 | awk '{print $3}')

# The video encoder that produced (or would produce) each present clip,
# name only - accumulated as "file":"encoder" pairs by record_manifest and
# written out as manifest.json next to the corpus, so a bench report
# assembled from these clips days later, possibly on a different machine
# entirely, can say which encoder made each one instead of assuming they
# all match.
MANIFEST_ENTRIES=""

record_manifest() {
    if [ -n "$MANIFEST_ENTRIES" ]; then
        MANIFEST_ENTRIES="$MANIFEST_ENTRIES,"
    fi
    MANIFEST_ENTRIES="$MANIFEST_ENTRIES\"$1\":\"$2\""
}

has_encoder() {
    ffmpeg -hide_banner -encoders 2>/dev/null | grep -q " $1 "
}

# The durable record that this machine could not confirm a clip: a sibling
# file the corpus directory itself carries, so a bench run reading the
# corpus days later - or this script's own next run - can tell an
# unverified clip from a verified one without anyone's terminal
# scrollback. Cleared the moment a clip is rebuilt or passes clip_ok
# again, so it never outlives the condition that wrote it.
mark_unverifiable() {
    echo "$2" > "$1.unverifiable"
}

clear_unverifiable() {
    rm -f "$1.unverifiable"
}

# A checksum of every argument, joined so that "a" "bc" and "ab" "c" never
# collide. Called with the whole recipe of a clip - shared size/rate/
# duration plus that codec's exact ffmpeg arguments - so any change to any
# of it changes the tag, and a clip tagged under an old recipe rebuilds
# instead of being kept forever with settings this run no longer uses.
settings_tag() {
    printf '%s\0' "$@" | cksum | cut -d ' ' -f 1
}

# codec_name,pix_fmt of a file's first video stream, or empty if the file
# does not exist or ffprobe cannot read it.
video_codec_pix_fmt() {
    # ffprobe re-prints a stream's entries once its codec is confirmed by a
    # first packet, which MPEG-TS needs and mp4/mkv do not: head keeps only
    # the first copy, which already carries the same values as the rest.
    ffprobe -v error -select_streams v:0 \
        -show_entries stream=codec_name,pix_fmt -of default=nw=1:nk=1 "$1" 2>/dev/null \
        | head -n 2 | paste -sd, - 2>/dev/null || true
}

audio_codec() {
    ffprobe -v error -select_streams a:0 \
        -show_entries stream=codec_name -of default=nw=1:nk=1 "$1" 2>/dev/null | head -n 1 || true
}

subtitle_codec() {
    ffprobe -v error -select_streams s:0 \
        -show_entries stream=codec_name -of default=nw=1:nk=1 "$1" 2>/dev/null | head -n 1 || true
}

# The tag as ffmpeg wrote it, wherever a container is willing to keep a
# free-form key/value pair. mp4 needs +use_metadata_tags at encode time to
# keep an unrecognised key at all; Matroska keeps it as-is (ffprobe's own
# lookup here is already case-insensitive, so the muxer uppercasing the key
# does not matter). MPEG-TS has no free-form container metadata at all -
# only the fixed DVB service_name/service_provider descriptors survive a
# remux - so a .ts repurposes service_name to carry "key=value" whole.
# MPEG program stream has neither: the muxer takes no metadata of any kind
# (measured against ffmpeg 8.1: title, comment and service_name all read
# back empty), so a .mpg carries its tag in a sibling file instead. The
# sibling cannot make a wrong clip pass on its own - every other check in
# clip_ok reads the clip itself.
read_tag() {
    case "$1" in
        *.ts)
            ffprobe -v error -show_entries program_tags=service_name \
                -of default=nw=1:nk=1 "$1" 2>/dev/null
            ;;
        *.mpg)
            cat "$1.tag" 2>/dev/null || true
            ;;
        *)
            ffprobe -v error -show_entries "format_tags=$TAG_KEY" \
                -of default=nw=1:nk=1 "$1" 2>/dev/null
            ;;
    esac
}

expected_tag_field() {
    case "$1" in
        *.ts) echo "$TAG_KEY=$2" ;;
        *) echo "$2" ;;
    esac
}

# The ffmpeg arguments that write a clip's tag into the clip itself, into
# TAG_ARGS - empty for a container that cannot hold one, whose tag
# `write_tag_sibling` puts next to it instead.
tag_args_for() {
    case "$1" in
        *.ts) TAG_ARGS=(-metadata "service_name=$TAG_KEY=$2") ;;
        *.mpg) TAG_ARGS=() ;;
        *) TAG_ARGS=(-metadata "$TAG_KEY=$2") ;;
    esac
}

write_tag_sibling() {
    case "$1" in
        *.mpg) printf '%s' "$2" > "$1.tag" ;;
    esac
}

# The presentation time of every video packet actually read, one per line.
# A container's own duration is written before the first frame is encoded,
# so a process killed partway through leaves it intact even though most of
# the file never arrived (confirmed: a truncated hevc10.mkv still reports
# its full 10s duration this way). Reading every packet is the only thing a
# stump cannot fake: it has fewer lines, and the last one falls short.
video_packet_times() {
    ffprobe -v error -select_streams v:0 -show_entries packet=pts_time \
        -of default=nw=1:nk=1 "$1" 2>/dev/null | grep '^[0-9]' || true
}

# True only when a clip is exactly what this run of the script would
# produce: right codec, right pixel format, right audio, right subtitle
# stream (empty for a clip that carries none), the tag this run's settings
# hash to, and the full frame count and duration this run's DURATION and
# RATE imply.
clip_ok() {
    local file="$1" codec="$2" pix_fmt="$3" audio="$4" subtitle="$5" tag="$6"
    [ "$(video_codec_pix_fmt "$file")" = "$codec,$pix_fmt" ] || return 1
    [ "$(audio_codec "$file")" = "$audio" ] || return 1
    [ "$(subtitle_codec "$file")" = "$subtitle" ] || return 1
    [ "$(read_tag "$file")" = "$(expected_tag_field "$file" "$tag")" ] || return 1
    local times frame_count max_pts
    times=$(video_packet_times "$file")
    frame_count=$(printf '%s\n' "$times" | grep -c .)
    [ "$frame_count" -eq "$TOTAL_FRAMES" ] || return 1
    max_pts=$(printf '%s\n' "$times" | sort -n | tail -1)
    awk -v m="${max_pts:-0}" -v d="$DURATION" 'BEGIN { exit !(m > d - 1) }'
}

# HDR10 needs its own check beyond clip_ok: the PQ transfer function tag and
# the mastering-display side data the player reads back
# (player/Sources/LexisPlayer/Demuxer.swift) to tone-map. ffmpeg's HEVC
# encoder embeds mastering-display as in-band SEI, which ffprobe and the
# demuxer only see once something has decoded a frame - never at container
# level. So hdr10.mkv is built in two passes: the first bakes the SEI into
# an intermediate HEVC stream, the second decodes it and re-encodes it,
# which is what makes ffmpeg surface the metadata as stream-level side data
# the second file's container actually carries.
# The interlaced row's own check beyond clip_ok, the way HDR10 has one: a
# clip that came out progressive would measure exactly what h264.mp4 already
# does and nothing would say so. Top field first, as the row asks for.
interlaced_ok() {
    [ "$(ffprobe -v error -select_streams v:0 -show_entries stream=field_order \
        -of default=nw=1:nk=1 "$1" 2>/dev/null | head -n 1)" = "tt" ]
}

hdr10_metadata_ok() {
    local transfer
    transfer=$(ffprobe -v error -select_streams v:0 \
        -show_entries stream=color_transfer -of default=nw=1:nk=1 "$1" 2>/dev/null | head -n 1 || true)
    [ "$transfer" = "smpte2084" ] || return 1
    ffprobe -v error -select_streams v:0 \
        -show_entries stream_side_data=side_data_type -of default=nw=1:nk=1 "$1" 2>/dev/null \
        | grep -q "Mastering display metadata"
}

# The two inputs every row shares: a moving picture with real detail to
# encode, and a tone to fill whatever audio codec the row is about.
INPUTS=(-f lavfi -i "testsrc2=size=$SIZE:rate=$RATE:duration=$DURATION"
    -f lavfi -i "sine=frequency=440:duration=$DURATION")

# One corpus row, whole: check the encoders this machine needs for it, keep
# a clip already sitting there if it is exactly what this run would write,
# encode it otherwise, and account for it either way (manifest.json, the
# MISSING or UNVERIFIABLE list, the .unverifiable marker). Arguments:
#   label      what the MISSING and UNVERIFIABLE lists call this row
#   file       the clip's name in $OUT
#   encoders   every encoder this row needs, space separated: the video one
#              and, on an audio row, that stream's own
#   manifest   the video encoder recorded in manifest.json for this clip
#   codec pix_fmt audio subtitle
#              what clip_ok has to read back off the finished file;
#              subtitle is "" for a clip carrying none
# then `--`, the input arguments, `--`, and the output arguments. The tag is
# hashed over the shared size/rate/duration plus both argument lists, so a
# change to one row's recipe rebuilds that row and leaves the rest alone.
build_clip() {
    local label=$1 file=$2 encoders=$3 manifest=$4
    local codec=$5 pix_fmt=$6 audio=$7 subtitle=$8
    shift 8
    local inputs=() args=()
    shift  # the -- before the inputs
    while [ "$1" != "--" ]; do inputs+=("$1"); shift; done
    shift
    args=("$@")

    local path="$OUT/$file" tag missing="" encoder
    tag=$(settings_tag "$SIZE" "$RATE" "$DURATION" "${inputs[@]}" "${args[@]}")
    for encoder in $encoders; do
        has_encoder "$encoder" || missing="$missing $encoder"
    done

    if [ -n "$missing" ]; then
        local named=${missing# }
        if [ -e "$path" ]; then
            echo "no$missing in this ffmpeg: $file exists but cannot be verified or rebuilt" >&2
            UNVERIFIABLE+=("$label ($file present, $named not built into this ffmpeg)")
            mark_unverifiable "$path" "$named not built into this ffmpeg: cannot verify or rebuild"
            record_manifest "$file" "$manifest"
        else
            echo "no$missing in this ffmpeg: skipping $file" >&2
            MISSING+=("$label ($named not built into this ffmpeg)")
            clear_unverifiable "$path"
        fi
        return
    fi

    if clip_ok "$path" "$codec" "$pix_fmt" "$audio" "$subtitle" "$tag"; then
        clear_unverifiable "$path"
        record_manifest "$file" "$manifest"
        echo "$file already matches, leaving it"
        return
    fi

    tag_args_for "$file" "$tag"
    ffmpeg -y -hide_banner -loglevel error "${inputs[@]}" "${args[@]}" "${TAG_ARGS[@]+"${TAG_ARGS[@]}"}" "$path"
    write_tag_sibling "$path" "$tag"
    clip_ok "$path" "$codec" "$pix_fmt" "$audio" "$subtitle" "$tag" \
        || { echo "$file: did not verify after encoding" >&2; exit 1; }
    clear_unverifiable "$path"
    record_manifest "$file" "$manifest"
    echo "wrote $file"
}

echo "== H.264 -> h264.mp4 =="
build_clip "H.264" h264.mp4 libx264 libx264 h264 yuv420p aac "" \
    -- "${INPUTS[@]}" -- \
    -c:v libx264 -pix_fmt yuv420p -profile:v high -level 4.0 \
    -g "$GOP" -keyint_min "$GOP" -sc_threshold 0 \
    -c:a aac -b:a 128k -movflags +faststart+use_metadata_tags

echo "== HEVC 8-bit -> hevc8.mp4 =="
build_clip "HEVC 8-bit" hevc8.mp4 libx265 libx265 hevc yuv420p aac "" \
    -- "${INPUTS[@]}" -- \
    -c:v libx265 -pix_fmt yuv420p -tag:v hvc1 \
    -x265-params "keyint=$GOP:min-keyint=$GOP:scenecut=0:log-level=error" \
    -c:a aac -b:a 128k -movflags +faststart+use_metadata_tags

echo "== HEVC 10-bit -> hevc10.mkv =="
build_clip "HEVC 10-bit" hevc10.mkv libx265 libx265 hevc yuv420p10le aac "" \
    -- "${INPUTS[@]}" -- \
    -c:v libx265 -pix_fmt yuv420p10le -profile:v main10 \
    -x265-params "keyint=$GOP:min-keyint=$GOP:scenecut=0:log-level=error" \
    -c:a aac -b:a 128k

echo "== HDR10 -> hdr10.mkv =="
HDR10_COLOR_ARGS=(-color_primaries bt2020 -color_trc smpte2084 -colorspace bt2020nc)
HDR10_VIDEO_ARGS=(-c:v libx265 -pix_fmt yuv420p10le -profile:v main10 \
    -x265-params "keyint=$GOP:min-keyint=$GOP:scenecut=0:log-level=error:hdr10=1:repeat-headers=1:master-display=$MASTER_DISPLAY:max-cll=$MAX_CLL")
HDR10_AUDIO_ARGS=(-c:a eac3 -b:a 192k)
HDR10_TAG=$(settings_tag "$SIZE" "$RATE" "$DURATION" \
    "${HDR10_COLOR_ARGS[@]}" "${HDR10_VIDEO_ARGS[@]}" "${HDR10_AUDIO_ARGS[@]}")
if ! has_encoder libx265; then
    if [ -e "$OUT/hdr10.mkv" ]; then
        echo "no libx265 in this ffmpeg: hdr10.mkv exists but cannot be verified or rebuilt" >&2
        UNVERIFIABLE+=("HDR10 (hdr10.mkv present, libx265 not built into this ffmpeg)")
        mark_unverifiable "$OUT/hdr10.mkv" "libx265 not built into this ffmpeg: cannot verify or rebuild"
        record_manifest "hdr10.mkv" "libx265"
    else
        echo "no libx265 in this ffmpeg: skipping hdr10.mkv" >&2
        MISSING+=("HDR10 (libx265 not built into this ffmpeg)")
        clear_unverifiable "$OUT/hdr10.mkv"
    fi
elif clip_ok "$OUT/hdr10.mkv" hevc yuv420p10le eac3 "" "$HDR10_TAG" && hdr10_metadata_ok "$OUT/hdr10.mkv"; then
    clear_unverifiable "$OUT/hdr10.mkv"
    record_manifest "hdr10.mkv" "libx265"
    echo "hdr10.mkv already matches, leaving it"
else
    INTERMEDIATE="$OUT/.hdr10-intermediate.mkv"
    ffmpeg -y -hide_banner -loglevel error \
        "${HDR10_COLOR_ARGS[@]}" \
        -f lavfi -i "testsrc2=size=$SIZE:rate=$RATE:duration=$DURATION" \
        -f lavfi -i "sine=frequency=440:duration=$DURATION" \
        "${HDR10_VIDEO_ARGS[@]}" "${HDR10_AUDIO_ARGS[@]}" \
        "$INTERMEDIATE"
    # Pass two only re-encodes video (to surface the SEI as container-level
    # side data, see hdr10_metadata_ok); audio is already right, so it is
    # copied rather than run through a second lossy encode.
    ffmpeg -y -hide_banner -loglevel error \
        -i "$INTERMEDIATE" \
        "${HDR10_VIDEO_ARGS[@]}" -c:a copy -metadata "$TAG_KEY=$HDR10_TAG" \
        "$OUT/hdr10.mkv"
    rm -f "$INTERMEDIATE"
    clip_ok "$OUT/hdr10.mkv" hevc yuv420p10le eac3 "" "$HDR10_TAG" && hdr10_metadata_ok "$OUT/hdr10.mkv" \
        || { echo "hdr10.mkv: did not verify after encoding" >&2; exit 1; }
    clear_unverifiable "$OUT/hdr10.mkv"
    record_manifest "hdr10.mkv" "libx265"
    echo "wrote hdr10.mkv"
fi

echo "== AV1 -> av1.mkv =="
if has_encoder libsvtav1; then
    AV1_ARGS=(-c:v libsvtav1 -pix_fmt yuv420p -crf 32 -preset 8 \
        -svtav1-params "keyint=$GOP:scd=0" \
        -c:a aac -b:a 128k)
    AV1_TAG=$(settings_tag "$SIZE" "$RATE" "$DURATION" "${AV1_ARGS[@]}")
    if clip_ok "$OUT/av1.mkv" av1 yuv420p aac "" "$AV1_TAG"; then
        clear_unverifiable "$OUT/av1.mkv"
        record_manifest "av1.mkv" "libsvtav1"
        echo "av1.mkv already matches, leaving it"
    else
        SVT_LOG=0 ffmpeg -y -hide_banner -loglevel error \
            -f lavfi -i "testsrc2=size=$SIZE:rate=$RATE:duration=$DURATION" \
            -f lavfi -i "sine=frequency=440:duration=$DURATION" \
            "${AV1_ARGS[@]}" -metadata "$TAG_KEY=$AV1_TAG" \
            "$OUT/av1.mkv"
        clip_ok "$OUT/av1.mkv" av1 yuv420p aac "" "$AV1_TAG" \
            || { echo "av1.mkv: did not verify after encoding" >&2; exit 1; }
        clear_unverifiable "$OUT/av1.mkv"
        record_manifest "av1.mkv" "libsvtav1"
        echo "wrote av1.mkv"
    fi
elif has_encoder libaom-av1; then
    AV1_ARGS=(-c:v libaom-av1 -pix_fmt yuv420p -crf 32 -b:v 0 -cpu-used 6 \
        -g "$GOP" -keyint_min "$GOP" \
        -c:a aac -b:a 128k)
    AV1_TAG=$(settings_tag "$SIZE" "$RATE" "$DURATION" "${AV1_ARGS[@]}")
    if clip_ok "$OUT/av1.mkv" av1 yuv420p aac "" "$AV1_TAG"; then
        clear_unverifiable "$OUT/av1.mkv"
        record_manifest "av1.mkv" "libaom-av1"
        echo "av1.mkv already matches, leaving it"
    else
        ffmpeg -y -hide_banner -loglevel error \
            -f lavfi -i "testsrc2=size=$SIZE:rate=$RATE:duration=$DURATION" \
            -f lavfi -i "sine=frequency=440:duration=$DURATION" \
            "${AV1_ARGS[@]}" -metadata "$TAG_KEY=$AV1_TAG" \
            "$OUT/av1.mkv"
        clip_ok "$OUT/av1.mkv" av1 yuv420p aac "" "$AV1_TAG" \
            || { echo "av1.mkv: did not verify after encoding" >&2; exit 1; }
        clear_unverifiable "$OUT/av1.mkv"
        record_manifest "av1.mkv" "libaom-av1"
        echo "wrote av1.mkv"
    fi
elif [ -e "$OUT/av1.mkv" ]; then
    echo "no AV1 encoder (libsvtav1 or libaom-av1) in this ffmpeg: av1.mkv exists but cannot be verified or rebuilt" >&2
    UNVERIFIABLE+=("AV1 (av1.mkv present, neither libsvtav1 nor libaom-av1 built into this ffmpeg)")
    mark_unverifiable "$OUT/av1.mkv" "no AV1 encoder (libsvtav1 or libaom-av1) in this ffmpeg: cannot verify or rebuild"
    # neither candidate encoder is present to check the file's own tag
    # against, so which of the two built it is unknown, not guessed
    record_manifest "av1.mkv" "unknown"
else
    echo "no AV1 encoder (libsvtav1 or libaom-av1) in this ffmpeg: skipping av1.mkv" >&2
    MISSING+=("AV1 (neither libsvtav1 nor libaom-av1 built into this ffmpeg)")
    clear_unverifiable "$OUT/av1.mkv"
fi

echo "== VP9 -> vp9.mkv =="
build_clip "VP9" vp9.mkv libvpx-vp9 libvpx-vp9 vp9 yuv420p aac "" \
    -- "${INPUTS[@]}" -- \
    -c:v libvpx-vp9 -pix_fmt yuv420p -crf 32 -b:v 0 -cpu-used 4 \
    -g "$GOP" -keyint_min "$GOP" \
    -c:a aac -b:a 128k

echo "== VP8 -> vp8.mkv =="
build_clip "VP8" vp8.mkv libvpx libvpx vp8 yuv420p aac "" \
    -- "${INPUTS[@]}" -- \
    -c:v libvpx -pix_fmt yuv420p -crf 32 -b:v 0 -cpu-used 4 \
    -g "$GOP" -keyint_min "$GOP" \
    -c:a aac -b:a 128k

echo "== MPEG-2 -> mpeg2.ts =="
build_clip "MPEG-2" mpeg2.ts "mpeg2video ac3" mpeg2video mpeg2video yuv420p ac3 "" \
    -- "${INPUTS[@]}" -- \
    -c:v mpeg2video -pix_fmt yuv420p -qscale:v 4 \
    -g "$GOP" -keyint_min "$GOP" -sc_threshold 0 \
    -c:a ac3 -b:a 192k

echo "== MPEG-1 -> mpeg1.mpg =="
build_clip "MPEG-1" mpeg1.mpg "mpeg1video mp2" mpeg1video mpeg1video yuv420p mp2 "" \
    -- "${INPUTS[@]}" -- \
    -c:v mpeg1video -pix_fmt yuv420p -qscale:v 4 \
    -g "$GOP" -keyint_min "$GOP" -sc_threshold 0 \
    -c:a mp2 -b:a 192k

echo "== MPEG-4 Part 2 -> mpeg4.mp4 =="
build_clip "MPEG-4 Part 2" mpeg4.mp4 mpeg4 mpeg4 mpeg4 yuv420p aac "" \
    -- "${INPUTS[@]}" -- \
    -c:v mpeg4 -pix_fmt yuv420p -qscale:v 4 \
    -g "$GOP" -keyint_min "$GOP" -sc_threshold 0 \
    -c:a aac -b:a 128k -movflags +faststart+use_metadata_tags

echo "== VC-1 -> vc1.mkv =="
# No ffmpeg build has ever shipped a VC-1 encoder, only a decoder, so this
# row is permanently on the "not produced" list and the matrix's VC-1 cell
# stays owed to a real title from the owner's own library. Declared anyway:
# a codec named in the matrix and absent from the corpus has to be visible
# as an absence, not as a row nobody wrote down.
build_clip "VC-1" vc1.mkv vc1 vc1 vc1 yuv420p aac "" \
    -- "${INPUTS[@]}" -- \
    -c:v vc1 -pix_fmt yuv420p -g "$GOP" -keyint_min "$GOP" \
    -c:a aac -b:a 128k

echo "== interlaced H.264 -> interlaced-h264.ts =="
# Top field first, both the encoder's own interlaced mode and the flag the
# container carries: what a broadcast recording actually looks like, and the
# only clip here whose field order the player has to read rather than assume.
build_clip "interlaced H.264" interlaced-h264.ts "libx264 ac3" libx264 h264 yuv420p ac3 "" \
    -- "${INPUTS[@]}" -- \
    -c:v libx264 -pix_fmt yuv420p -profile:v high -level 4.0 \
    -flags +ilme+ildct -top 1 -x264opts "tff=1" \
    -g "$GOP" -keyint_min "$GOP" -sc_threshold 0 \
    -c:a ac3 -b:a 192k
if [ -e "$OUT/interlaced-h264.ts" ] && ! interlaced_ok "$OUT/interlaced-h264.ts"; then
    echo "interlaced-h264.ts: encoded progressive, which measures nothing h264.mp4 does not" >&2
    exit 1
fi

echo "== H.264 + AC-3 -> h264-ac3.mp4 =="
# The video rows above already carry two passthrough-eligible tracks
# (mpeg2.ts's AC-3, hdr10.mkv's E-AC-3), but both sit on a video codec this
# corpus already flags on its own - MPEG-2 for no hardware decoder, HDR10
# for tone-mapping. Every audio row from here down pairs its format with
# H.264, the one video codec every device here decodes cleanly, so a finding
# reads as about the audio route and nothing else.
build_clip "H.264 + AC-3" h264-ac3.mp4 "libx264 ac3" libx264 h264 yuv420p ac3 "" \
    -- "${INPUTS[@]}" -- \
    -c:v libx264 -pix_fmt yuv420p -profile:v high -level 4.0 \
    -g "$GOP" -keyint_min "$GOP" -sc_threshold 0 \
    -c:a ac3 -b:a 192k -movflags +faststart+use_metadata_tags

# The video half of every audio row below, identical throughout so the only
# thing that moves between them is the audio codec.
AUDIO_ROW_VIDEO=(-c:v libx264 -pix_fmt yuv420p -profile:v high -level 4.0
    -g "$GOP" -keyint_min "$GOP" -sc_threshold 0)

echo "== H.264 + DTS -> dts.mkv =="
# dca and truehd are both behind ffmpeg's experimental gate; -strict -2 is
# what opens them, and nothing else about either encoder needs coaxing
# (measured against ffmpeg 8.1: a mono 44.1 kHz source encodes fine).
build_clip "H.264 + DTS" dts.mkv "libx264 dca" libx264 h264 yuv420p dts "" \
    -- "${INPUTS[@]}" -- \
    "${AUDIO_ROW_VIDEO[@]}" -c:a dca -strict -2 -b:a 768k

echo "== H.264 + TrueHD -> truehd.mkv =="
build_clip "H.264 + TrueHD" truehd.mkv "libx264 truehd" libx264 h264 yuv420p truehd "" \
    -- "${INPUTS[@]}" -- \
    "${AUDIO_ROW_VIDEO[@]}" -c:a truehd -strict -2

echo "== H.264 + FLAC -> flac.mkv =="
build_clip "H.264 + FLAC" flac.mkv "libx264 flac" libx264 h264 yuv420p flac "" \
    -- "${INPUTS[@]}" -- \
    "${AUDIO_ROW_VIDEO[@]}" -c:a flac

echo "== H.264 + Opus -> opus.mkv =="
build_clip "H.264 + Opus" opus.mkv "libx264 libopus" libx264 h264 yuv420p opus "" \
    -- "${INPUTS[@]}" -- \
    "${AUDIO_ROW_VIDEO[@]}" -c:a libopus -b:a 128k

echo "== H.264 + Vorbis -> vorbis.mkv =="
# Two candidate encoders, the way AV1 has: libvorbis where the build carries
# it, and otherwise ffmpeg's own Vorbis encoder, which sits behind the
# experimental gate and refuses a mono source (measured against ffmpeg 8.1),
# hence the stereo downmix on that path alone.
if has_encoder libvorbis; then
    VORBIS_ENCODER=libvorbis
    VORBIS_AUDIO=(-c:a libvorbis -b:a 128k)
else
    VORBIS_ENCODER=vorbis
    VORBIS_AUDIO=(-c:a vorbis -strict -2 -ac 2 -b:a 128k)
fi
build_clip "H.264 + Vorbis" vorbis.mkv "libx264 $VORBIS_ENCODER" libx264 h264 yuv420p vorbis "" \
    -- "${INPUTS[@]}" -- \
    "${AUDIO_ROW_VIDEO[@]}" "${VORBIS_AUDIO[@]}"

echo "== H.264 + MP3 -> mp3.mp4 =="
build_clip "H.264 + MP3" mp3.mp4 "libx264 libmp3lame" libx264 h264 yuv420p mp3 "" \
    -- "${INPUTS[@]}" -- \
    "${AUDIO_ROW_VIDEO[@]}" -c:a libmp3lame -b:a 192k \
    -movflags +faststart+use_metadata_tags

echo "== H.264 + PCM -> pcm.mov =="
# QuickTime rather than mp4: the mp4 muxer has no box for raw PCM, and this
# row exists to measure the one audio path that is never decoded at all.
build_clip "H.264 + PCM" pcm.mov "libx264 pcm_s16le" libx264 h264 yuv420p pcm_s16le "" \
    -- "${INPUTS[@]}" -- \
    "${AUDIO_ROW_VIDEO[@]}" -c:a pcm_s16le -movflags +faststart+use_metadata_tags

echo "== bitmap subtitles -> pgs.mkv, vobsub.mkv =="
# Neither row can be generated from a script on any ffmpeg build, and that
# is a fact about ffmpeg rather than about this machine: there is no PGS
# encoder at all, and the dvdsub encoder that does exist refuses a text
# source outright ("Subtitle encoding currently only possible from text to
# text or bitmap to bitmap"), so a VobSub stream can only be transcoded from
# a bitmap subtitle nothing here can make. Both are reported rather than
# dropped: the matrix names them, so their absence has to be visible, and
# covering them needs a real title from the owner's own library.
for row in \
    "pgs.mkv|PGS|ffmpeg has no PGS encoder, on any build" \
    "vobsub.mkv|VobSub|dvdsub encodes bitmap to bitmap only, and nothing here makes the bitmap"
do
    SUBTITLE_FILE=${row%%|*}
    SUBTITLE_REST=${row#*|}
    SUBTITLE_LABEL=${SUBTITLE_REST%%|*}
    SUBTITLE_WHY=${SUBTITLE_REST#*|}
    if [ -e "$OUT/$SUBTITLE_FILE" ]; then
        echo "$SUBTITLE_FILE is present, but this script cannot verify or rebuild it: $SUBTITLE_WHY" >&2
        UNVERIFIABLE+=("$SUBTITLE_LABEL ($SUBTITLE_FILE present, $SUBTITLE_WHY)")
        mark_unverifiable "$OUT/$SUBTITLE_FILE" "$SUBTITLE_WHY: cannot verify or rebuild"
        # nothing here knows which tool wrote it, so the encoder is unknown,
        # not guessed
        record_manifest "$SUBTITLE_FILE" "unknown"
    else
        echo "$SUBTITLE_WHY: skipping $SUBTITLE_FILE" >&2
        MISSING+=("$SUBTITLE_LABEL ($SUBTITLE_WHY)")
        clear_unverifiable "$OUT/$SUBTITLE_FILE"
    fi
done

printf '{"ffmpeg":"%s","clips":{%s}}\n' "$FFMPEG_VERSION" "$MANIFEST_ENTRIES" \
    > "$OUT/manifest.json"

echo
echo "corpus written to $OUT"
ls -la "$OUT"

if [ ${#MISSING[@]} -gt 0 ]; then
    echo
    echo "not produced on this machine's ffmpeg:"
    for reason in "${MISSING[@]}"; do
        echo "  - $reason"
    done
fi

if [ ${#UNVERIFIABLE[@]} -gt 0 ]; then
    echo
    echo "present but unverifiable: this ffmpeg cannot rebuild these, so this"
    echo "script does not vouch for them - treat any bench numbers on them as"
    echo "measuring a codec nobody here confirmed. Each also carries a"
    echo "<file>.unverifiable marker in $OUT, so this holds even after this"
    echo "terminal closes:"
    for reason in "${UNVERIFIABLE[@]}"; do
        echo "  - $reason"
    done
fi
