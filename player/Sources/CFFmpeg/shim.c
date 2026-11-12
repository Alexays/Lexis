#include "lexis_ffmpeg.h"
#include <errno.h>

const int LexisErrorEOF = AVERROR_EOF;
const int LexisErrorAgain = AVERROR(EAGAIN);
const int LexisErrorInvalidData = AVERROR_INVALIDDATA;
const int64_t LexisNoPTS = AV_NOPTS_VALUE;
const int LexisSeekSize = AVSEEK_SIZE;
const int LexisSeekForce = AVSEEK_FORCE;
const int LexisErrorIO = AVERROR(EIO);
const int LexisErrorExit = AVERROR_EXIT;
const int64_t LexisTimeBase = AV_TIME_BASE;
const int LexisErrorUnauthorized = AVERROR_HTTP_UNAUTHORIZED;
const int LexisDispositionDefault = AV_DISPOSITION_DEFAULT;
const int LexisDispositionForced = AV_DISPOSITION_FORCED;
const int LexisCodecPropBitmapSub = AV_CODEC_PROP_BITMAP_SUB;
