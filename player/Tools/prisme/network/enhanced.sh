#!/bin/zsh
# enhanced.sh <split>: every extract of $NET_ROOT/data/<split> (~/prisme) through the player's Enhanced rendering at its own size,
# luma kept, into $NET_ROOT/enhanced: the true 4K and the Lanczos sources. HDR films read as PQ (hdr.txt names them).
W=${NET_ROOT:-~/prisme}; PLAYER=$(cd "$(dirname "$0")/../../.." && pwd); split=$1; TMP=$(mktemp -d); HDR=" $(cat $W/hdr.txt | tr '\n' ' ') "
LOOK="E:0.20,0.08,0.08,1.5,0.6,0.6,1,0.6,0.1,3"
for d in $W/data/$split/*; do
  name=$(basename $d); out=$W/enhanced/$split/$name; [ -f $out/done ] && continue; [ -f $d/done ] || continue; mkdir -p $out
  IFS=, read Wd Hd _ < $d/size; w=$((Wd/2)); h=$((Hd/2))
  hdr=0; case "$HDR" in *" ${name%-*} "*) hdr=1;; esac
  for tag in ${=TAGS:-hr lanczos.c10 lanczos.h264b8500 lanczos.h264b4000 lanczos.hevcb3000 lanczos.hevcb1500}; do
    [ $tag = hr ] || [ -f $d/$tag.1.y ] || continue
    /bin/rm -rf $TMP/in $TMP/out; mkdir -p $TMP/in $TMP/out
    $W/venv/bin/python - $d $tag $Wd $Hd $TMP/in <<'PY'
import sys, numpy as np
d, tag, W, H, o = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4]), sys.argv[5]
w, h = (W, H) if tag == 'hr' else (W // 2, H // 2)
for n in (1, 2, 3):
    y = np.fromfile(f'{d}/hr{n}.y' if tag == 'hr' else f'{d}/{tag}.{n}.y', '<u2')
    np.concatenate([y, np.full(w * h // 2, 512, '<u2')]).tofile(f'{o}/f{n:03d}-{w}x{h}.yuv')
PY
    # an encode is rendered as the player renders it: by its own strength, as eight bit
    case $tag in hr|*.c10) extra="LEXIS_BENCH_DEBAND=1";;
      *) s=$($W/venv/bin/python -c "import sys; sys.path.insert(0,'$(dirname "$0")'); from net import strength; print(round(strength('$d','${tag%%.*}','${tag#*.}'),3))")
         extra="LEXIS_BENCH_DEBAND=$s LEXIS_BENCH_EIGHTBIT=1";;
    esac
    [ $hdr = 1 ] && extra="$extra LEXIS_BENCH_HDR=1"
    (cd $PLAYER && env ${=extra} LEXIS_BENCH=1 LEXIS_BENCH_SEQUENCE=1 LEXIS_BENCH_FRAMES=$TMP/in LEXIS_BENCH_OUT=$TMP/out \
      LEXIS_BENCH_LOOKS="$LOOK" swift test --skip-build --filter "QualityBench/testEnhancedLookOnFrames" > /dev/null 2>&1)
    for n in 1 2 3; do
      f=$(ls $TMP/out/f00$n-*.E.yuv 2>/dev/null | head -1); [ -z "$f" ] && continue
      if [ $tag = hr ]; then dd if=$f of=$out/hr$n.y bs=$((Wd*Hd*2)) count=1 2>/dev/null; else dd if=$f of=$out/$tag.$n.y bs=$((w*h*2)) count=1 2>/dev/null; fi
    done
  done
  /bin/cp -f $d/size $d/bytes $out/ 2>/dev/null; touch $out/done; echo "$split $name $(ls $out | wc -l)"
done
/bin/rm -rf $TMP
