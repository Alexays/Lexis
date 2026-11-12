/* The C ABI over the core's seekable streams, implemented in src/ffi/mod.rs.
   Failure is a null handle plus a code, never a string: a message built from a
   URL or a request would carry the credential with it. */
#ifndef LEXIS_STREAM_H
#define LEXIS_STREAM_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define LEXIS_STREAM_OK 0
#define LEXIS_STREAM_ERR_INVALID 1
#define LEXIS_STREAM_ERR_NOT_FOUND 2
#define LEXIS_STREAM_ERR_UNAUTHORIZED 3
#define LEXIS_STREAM_ERR_IO 4

/* Opaque: only the core knows what is behind it.

   Thread affinity: a handle may move between threads, but it must never be
   used from two at once. Every call takes it mutably and none of them lock. */
typedef struct LexisStream LexisStream;

LexisStream *lexis_stream_open_file(const char *path, int32_t *out_error);

/* An empty auth_header_name sends no credential. */
LexisStream *lexis_stream_open_http_range(const char *url,
                                          const char *auth_header_name,
                                          const char *auth_header_value,
                                          int32_t *out_error);

/* Bytes read, 0 at the end of the stream, -1 on failure, -2 when the
   credential was refused. A rejected credential has its own code so a caller
   can ask for a new one rather than blame the network; every other failure,
   including a seek that fails, is -1. */
int64_t lexis_stream_read(LexisStream *handle, uint8_t *buf, int len);

/* The new position, or -1. whence: 0 start, 1 current, 2 end. */
int64_t lexis_stream_seek(LexisStream *handle, int64_t offset, int32_t whence);

/* The total length, or -1 when it is not known. */
int64_t lexis_stream_size(LexisStream *handle);

void lexis_stream_close(LexisStream *handle);

/* The player's per-file analysis cache: a probe result and keyframe table, so
   a later open of the same file skips findStreamInfo. The stream is the file,
   so nothing here names one: what keys the entry travels inside the handle,
   and a stream no index row names keeps no analysis at all.

   Writes the JSON stored for this stream's file into buf, up to capacity
   bytes; buf may be NULL with capacity 0 to measure first. Returns the JSON's
   full byte length on a match - call again with a buffer at least that big if
   this exceeds capacity - or -1 on a miss: a stream with no row behind it, a
   file never probed, or one whose stored mtime no longer agrees with the
   row's. */
int32_t lexis_stream_analysis_load(LexisStream *handle, uint8_t *buf,
                                   int32_t capacity);

/* Stores json as this stream's file's probe result, replacing whatever was
   there for that file whole. Returns at once and writes on a thread of its
   own, so a first frame never waits on the index's write connection.
   Non-zero when the write was started, 0 for a stream that keeps no
   analysis. */
int32_t lexis_stream_analysis_store(LexisStream *handle, const char *json);

#ifdef __cplusplus
}
#endif

#endif
