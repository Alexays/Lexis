#!/bin/bash
# dataset.sh <films.txt> <out>: the luma of true 4K frames and of their 1080p, made by several downscales,
# clean and through three encodes, for train.py and evaluate.py. PLEX_BASE and PLEX_TOKEN name the server.
# films.txt, a line a film: name|/library/parts/<id>/<stamp>/file.mkv|minutes|train or test|kernels
films=$1; D=$2; T=$(mktemp -d)
while IFS='|' read name part minutes split kernels; do
  [ -z "$name" ] && continue
  for frac in 25 50 75; do
    out=$D/$split/$name-$frac; [ -f $out/done ] && continue; rm -rf $out; mkdir -p $out
    t=$(( minutes * 60 * frac / 100 ))
    # a second of film: what is kept is its last three frames, predicted ones, as most of a film's are
    ffmpeg -v error -headers "X-Plex-Token: $PLEX_TOKEN" -ss $t -i "$PLEX_BASE$part" -frames:v 24 -an -sn -vf "format=yuv420p10le" -c:v ffv1 -y $T/hr.mkv < /dev/null || continue
    ffprobe -v error -select_streams v:0 -show_entries stream=width,height -of csv=p=0 $T/hr.mkv > $out/size
    ffmpeg -v error -i $T/hr.mkv -vf "select=gte(n\,21),extractplanes=y" -fps_mode passthrough -pix_fmt gray10le -f image2 -c:v rawvideo -y "$out/hr%d.y" < /dev/null
    for kernel in $kernels; do
      # clean ten bit, and three encodes of the eight bit a release is
      ffmpeg -v error -i $T/hr.mkv -vf "select=gte(n\,21),scale=iw/2:ih/2:flags=$kernel,format=yuv420p10le,extractplanes=y" -fps_mode passthrough -pix_fmt gray10le -f image2 -c:v rawvideo -y "$out/$kernel.c10.%d.y" < /dev/null
      for enc in "x264crf20|-r 24 -c:v libx264 -crf 20 -preset medium" "x264crf28|-r 24 -c:v libx264 -crf 28 -preset medium" "x265b2|-r 24 -c:v libx265 -b:v 2000k -preset medium -x265-params log-level=error"; do
        tag=${enc%%|*}; args=${enc#*|}
        ffmpeg -v error -i $T/hr.mkv -vf "scale=iw/2:ih/2:flags=$kernel,format=yuv420p" $args -y $T/lr.mkv < /dev/null && \
        ffmpeg -v error -i $T/lr.mkv -vf "select=gte(n\,21),format=yuv420p10le,extractplanes=y" -fps_mode passthrough -pix_fmt gray10le -f image2 -c:v rawvideo -y "$out/$kernel.$tag.%d.y" < /dev/null && \
        echo "$kernel.$tag $(stat -f %z $T/lr.mkv)" >> $out/bytes
      done
    done
    touch $out/done; echo "$split $name $frac $(ls $out | wc -l) files"
  done
done < $films
/bin/rm -rf $T; du -sh $D
