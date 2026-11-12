#ifndef LEXIS_LIBASS_H
#define LEXIS_LIBASS_H

#include "ass/ass.h"
#include "ass/ass_types.h"

/* AV_CODEC_ID_ASS. The one subtitle codec this player hands to libass instead
   of to avcodec, because such a packet already holds the dialogue line libass
   wants. Declared here rather than beside the other FFmpeg constants so that
   what routes to libass is stated where libass is. */
extern const unsigned int LexisCodecIDASS;

#endif
