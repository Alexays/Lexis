#include "include/lexis_libass.h"

/* AV_CODEC_ID_ASS = 0x17016, the 22nd id after AV_CODEC_ID_FIRST_SUBTITLE.
   FFmpeg appends to that block rather than renumbering it; a test pins it. */
const unsigned int LexisCodecIDASS = 94230u;
