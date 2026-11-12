#!/bin/zsh
# bench.sh: Adele's still shot through the player's Enhanced rendering at its own size, into $NET_ROOT/adele.E (~/prisme).
W=${NET_ROOT:-~/prisme}; /bin/rm -rf $W/adele.E; mkdir -p $W/adele.E
cd "$(dirname "$0")/../../.." && LEXIS_BENCH_DEBAND=1.78 LEXIS_BENCH_EIGHTBIT=1 LEXIS_BENCH=1 LEXIS_BENCH_SEQUENCE=1 \
  LEXIS_BENCH_FRAMES=$W/adele LEXIS_BENCH_OUT=$W/adele.E LEXIS_BENCH_LOOKS="E:0.20,0.08,0.08,1.5,0.6,0.6,1,0.6,0.1,3" \
  swift test --skip-build --filter "QualityBench/testEnhancedLookOnFrames" > /dev/null 2>&1
ls $W/adele.E | wc -l
