#!/bin/bash
# dataset.sh <films.txt> <out>: the luma of true 4K frames and of their 1080p, made by several downscales,
# clean and through the encodes a library of 1080p films is made of, for train.py and evaluate.py.
# PLEX_BASE and PLEX_TOKEN name the server.
# films.txt, a line a film: name|/library/parts/<id>/<stamp>/file.mkv|minutes|train or test|kernels
films=$1; D=$2; T=$(mktemp -d)
# codec and kb/s: a 1080p library's h264 sits between 3 and 8.5 Mb/s, 4 at its median, its HEVC between 1.5 and 6, 3 at its median
ENCODES="h264b8500 h264b4000 h264b3000 hevcb6000 hevcb3000 hevcb1500"
while IFS='|' read name part minutes split kernels; do
  [ -z "$name" ] && continue
  for frac in ${FRACS:-30 70}; do
    out=$D/$split/$name-$frac; [ -f $out/done ] && continue; /bin/rm -rf $out; mkdir -p $out
    t=$(( minutes * 60 * frac / 100 ))
    # a second of film: what is kept is its last three frames, predicted ones, as most of a film's are
    ffmpeg -v error -headers "X-Plex-Token: $PLEX_TOKEN" -ss $t -i "$PLEX_BASE$part" -frames:v 24 -an -sn -vf "format=yuv420p10le" -c:v ffv1 -y $T/hr.mkv < /dev/null || continue
    ffprobe -v error -select_streams v:0 -show_entries stream=width,height -of csv=p=0 $T/hr.mkv > $out/size
    ffmpeg -v error -i $T/hr.mkv -vf "select=gte(n\,21),extractplanes=y" -fps_mode passthrough -pix_fmt gray10le -f image2 -c:v rawvideo -y "$out/hr%d.y" < /dev/null
    first=1
    for kernel in $kernels; do
      # the 1080p once, lossless: clean ten bit as it is, and the eight bit a release is for the encodes
      ffmpeg -v error -i $T/hr.mkv -vf "scale=iw/2:ih/2:flags=$kernel,format=yuv420p10le" -c:v ffv1 -y $T/lr.mkv < /dev/null
      ffmpeg -v error -i $T/lr.mkv -vf "select=gte(n\,21),extractplanes=y" -fps_mode passthrough -pix_fmt gray10le -f image2 -c:v rawvideo -y "$out/$kernel.c10.%d.y" < /dev/null
      # every encode of the first kernel, the two medians of the second, none of the others
      case $first in 1) encodes=$ENCODES;; 2) encodes="";; *) encodes="";; esac
      first=$((first + 1))
      for tag in $encodes; do
        rate=${tag#*b}
        case $tag in h264*) codec="-c:v libx264 -profile:v high";; *) codec="-c:v libx265 -x265-params log-level=error";; esac
        ffmpeg -v error -i $T/lr.mkv -vf "format=yuv420p" -r 24 $codec -b:v ${rate}k -preset medium -y $T/enc.mkv < /dev/null && \
        ffmpeg -v error -i $T/enc.mkv -vf "select=gte(n\,21),format=yuv420p10le,extractplanes=y" -fps_mode passthrough -pix_fmt gray10le -f image2 -c:v rawvideo -y "$out/$kernel.$tag.%d.y" < /dev/null && \
        echo "$kernel.$tag $(stat -f %z $T/enc.mkv)" >> $out/bytes
      done
    done
    touch $out/done; echo "$split $name $frac $(ls $out | wc -l) files"
  done
done < $films
/bin/rm -rf $T; du -sh $D
