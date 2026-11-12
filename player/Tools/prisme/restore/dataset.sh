#!/bin/bash
# dataset.sh <films.txt> <out>: the luma of true 4K frames and of the same 4K through the encodes a starved 4K stream
# is made of, for train.py and evaluate.py. PLEX_BASE and PLEX_TOKEN name the server; ~/prisme/hdr.txt the HDR films.
# films.txt, a line a film: name|/library/parts/<id>/<stamp>/file.mkv|minutes|train or test
# A test moment keeps its last eight frames, for the stability; a train moment one, a different one at each moment.
films=$1; D=$2; T=$(mktemp -d); HDR=" $(cat ~/prisme/hdr.txt | tr '\n' ' ') "
# codec, bits and kb/s. A 4K HDR stream is ten bit HEVC, 6 to 15 Mb/s when starved; an SDR one is HEVC in eight or
# ten bits, or H.264 at 10 to 20. The 40 Mb/s HEVC is the bits to spare the network must leave alone.
ENCODES_HDR="hevc10b6000 hevc10b9000 hevc10b12000 hevc10b15000"
ENCODES_SDR="hevc10b6000 hevc8b8000 hevc8b12000 h264b10000 h264b20000"
# a second's bitrate by the CRF that spends it, found in a few encodes: one pass under or over spends a clip this short
# by up to three times, and a second pass on 24 frames by up to four
enc() {
  crf=24; slope=6
  for try in 1 2 3 4 5 6; do
    ffmpeg -v error -i $T/$name.hr.mkv -vf "format=$fmt" -r 24 $codec -crf $crf -preset medium -y $T/$name.enc.mkv < /dev/null || return 1
    kbps=$(( $(stat -f %z $T/$name.enc.mkv) * 8 / 1000 ))
    awk -v a=$kbps -v r=$rate 'BEGIN { exit !(a > 0.9 * r && a < 1.1 * r) }' && return 0
    # CRF steps per halving of the bitrate, from the last two encodes once there are two
    [ $try -gt 1 ] && slope=$(awk -v c=$crf -v p=$last -v a=$kbps -v q=$lastk 'BEGIN { s = a == q ? 6 : (p - c) / (log(a / q) / log(2)); printf "%.2f", (s < 2 ? 2 : (s > 15 ? 15 : s)) }')
    last=$crf; lastk=$kbps
    crf=$(awk -v c=$crf -v s=$slope -v a=$kbps -v r=$rate 'BEGIN { c += s * log(a / r) / log(2); printf "%.1f", (c < 1 ? 1 : (c > 51 ? 51 : c)) }')
  done
}
while IFS='|' read name part minutes split kernels; do
  [ -z "$name" ] && continue
  case "$HDR" in *" $name "*) encodes=$ENCODES_HDR;; *) encodes=$ENCODES_SDR;; esac
  [ $split = test ] && encodes="$encodes hevc10b40000"
  for frac in ${FRACS:-30 70}; do
    out=$D/$split/$name-$frac; [ -f $out/done ] && continue; /bin/rm -rf $out; mkdir -p $out
    t=$(( minutes * 60 * frac / 100 ))
    if [ $split = test ]; then keep="gte(n\,16)"; else keep="eq(n\,$(( 23 - frac / 10 % 3 * 2 )))"; fi
    # a second of film: the frames kept are its last ones, predicted ones, as most of a film's are
    # the server drops reads when several run at once: one at a time across workers, read again until it is whole
    until mkdir $D/.fetch 2> /dev/null; do sleep 1; done
    for try in 1 2 3 4 5; do
      ffmpeg -v error -headers "X-Plex-Token: $PLEX_TOKEN" -ss $t -i "$PLEX_BASE$part" -frames:v 24 -an -sn -vf "format=yuv420p10le" -c:v ffv1 -y $T/$name.hr.mkv < /dev/null 2> /dev/null
      [ "$(ffprobe -v error -count_frames -show_entries stream=nb_read_frames -of csv=p=0 $T/$name.hr.mkv 2> /dev/null)" = 24 ] && break; sleep $((try * 5))
    done
    rmdir $D/.fetch
    ffprobe -v error -select_streams v:0 -show_entries stream=width,height -of csv=p=0 $T/$name.hr.mkv > $out/size
    ffmpeg -v error -i $T/$name.hr.mkv -vf "select=$keep,extractplanes=y" -fps_mode passthrough -pix_fmt gray10le -f image2 -c:v rawvideo -y "$out/hr%d.y" < /dev/null
    for tag in $encodes; do
      rate=${tag#*b}
      case $tag in
        h264*) codec="-c:v libx264 -profile:v high"; fmt=yuv420p;;
        hevc8*) codec="-c:v libx265 -x265-params log-level=error"; fmt=yuv420p;;
        *) codec="-c:v libx265 -x265-params log-level=error"; fmt=yuv420p10le;;
      esac
      enc && \
      ffmpeg -v error -i $T/$name.enc.mkv -vf "select=$keep,format=yuv420p10le,extractplanes=y" -fps_mode passthrough -pix_fmt gray10le -f image2 -c:v rawvideo -y "$out/$tag.%d.y" < /dev/null && \
      echo "$tag $(stat -f %z $T/$name.enc.mkv)" >> $out/bytes
    done
    [ $(ls $out/*.y | wc -l) -gt 3 ] && touch $out/done; echo "$split $name $frac $(ls $out | wc -l) files"
  done
done < $films
/bin/rm -rf $T; du -sh $D
