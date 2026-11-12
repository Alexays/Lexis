#ifndef LEXIS_FFMPEG_H
#define LEXIS_FFMPEG_H

#include "libavformat/avformat.h"
#include "libavcodec/avcodec.h"
#include "libavutil/avutil.h"
#include "libavutil/error.h"
#include "libavutil/pixdesc.h"
#include "libswresample/swresample.h"
#include "libavutil/mastering_display_metadata.h"
#include "libavutil/dovi_meta.h"
#include "libavutil/hdr_dynamic_metadata.h"

/* AVERROR_EOF and AV_NOPTS_VALUE are macros, which Swift cannot see. */
extern const int LexisErrorEOF;
extern const int LexisErrorAgain;
extern const int LexisErrorInvalidData;
extern const int64_t LexisNoPTS;

/* AVSEEK_SIZE, AVSEEK_FORCE and AVERROR(EIO), for the custom I/O callbacks. */
extern const int LexisSeekSize;
extern const int LexisSeekForce;
extern const int LexisErrorIO;

/* AVERROR_EXIT: what a read the caller cancelled reports. */
extern const int LexisErrorExit;

/* AV_TIME_BASE: the unit of AVFormatContext.duration and of a seek target. */
extern const int64_t LexisTimeBase;

/* AVERROR_HTTP_UNAUTHORIZED, which the read callback answers for a refused
   credential. Defined whether or not FFmpeg was built with networking. */
extern const int LexisErrorUnauthorized;

/* AV_DISPOSITION_DEFAULT and AV_DISPOSITION_FORCED: what a container says
   about a track before anyone picks one. */
extern const int LexisDispositionDefault;
extern const int LexisDispositionForced;

/* AV_CODEC_PROP_BITMAP_SUB: what tells a bitmap subtitle from a text one,
   without opening a decoder for it. */
extern const int LexisCodecPropBitmapSub;

#endif
