#!/bin/bash
# enhanced_dataset.sh <data> <out> <split> [hdr name...]: every extract of <data>/<split> through the player's
# Enhanced rendering at its own size, luma kept: what Prisme scales in that rendering, and the true 4K through
# the same rendering to learn it against. The names after the split are the HDR films. Run from player/, the
# tests built; TAGS picks the sources, the true 4K and three Lanczos ones by default.
split=$3; SRC=$1/$split; DST=$2/$split; shift 3; HDR=" $* "; TMP=$(mktemp -d)
TOOLS=$(cd "$(dirname "$0")" && pwd)
LOOK="E:0.20,0.08,0.08,1.5,0.6,0.6,3,0.6,0.1,3"
for d in $SRC/*; do
  name=$(basename $d); out=$DST/$name; [ -f $out/done ] && continue; mkdir -p $out
  IFS=, read W H _ < $d/size; w=$((W/2)); h=$((H/2))
  hdr=0; case "$HDR" in *" ${name%-*} "*) hdr=1;; esac
  for tag in ${TAGS:-hr lanczos.c10 lanczos.x264crf28 lanczos.x265b2}; do
    /bin/rm -rf $TMP/in $TMP/out; mkdir -p $TMP/in $TMP/out
    python3 - $d $tag $W $H $TMP/in <<'PY'
import sys, numpy as np
d, tag, W, H, o = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4]), sys.argv[5]
w, h = (W, H) if tag == 'hr' else (W // 2, H // 2)
for n in (1, 2, 3):
    y = np.fromfile(f'{d}/hr{n}.y' if tag == 'hr' else f'{d}/{tag}.{n}.y', '<u2')
    np.concatenate([y, np.full(w * h // 2, 512, '<u2')]).tofile(f'{o}/f{n:03d}-{w}x{h}.yuv')
PY
    # an encode is rendered as the player renders it: by its own starvation, as eight bit
    case $tag in hr|*.c10) extra="LEXIS_BENCH_DEBAND=1";;
      *) s=$(python3 -c "
import sys; sys.path.insert(0,'$TOOLS'); import prisme
b=dict(l.split() for l in open('$d/bytes')); print(round(prisme.strength_of(int(b['$tag']),24,$w,$h,'${tag#*.}'[:4]),3))"); extra="LEXIS_BENCH_DEBAND=$s LEXIS_BENCH_EIGHTBIT=1";;
    esac
    [ $hdr = 1 ] && extra="$extra LEXIS_BENCH_HDR=1"
    env $extra LEXIS_BENCH=1 LEXIS_BENCH_SEQUENCE=1 LEXIS_BENCH_FRAMES=$TMP/in LEXIS_BENCH_OUT=$TMP/out LEXIS_BENCH_LOOKS="$LOOK" swift test --skip-build --filter "QualityBench/testEnhancedLookOnFrames" > /dev/null 2>&1
    for n in 1 2 3; do
      f=$(ls $TMP/out/f00$n-*.E.yuv 2>/dev/null | head -1); [ -z "$f" ] && continue
      if [ $tag = hr ]; then dd if=$f of=$out/hr$n.y bs=$((W*H*2)) count=1 2>/dev/null; else dd if=$f of=$out/$tag.$n.y bs=$((w*h*2)) count=1 2>/dev/null; fi
    done
  done
  /bin/cp -f $d/size $d/bytes $out/ 2>/dev/null; touch $out/done; echo "$split $name $(ls $out | wc -l)"
done
/bin/rm -rf $TMP; du -sh $DST
