@_exported import CLexisStream
import LexisPlayer

/// Wraps a handle from the core in the callbacks a demuxer reads through. The
/// C functions are the callbacks themselves: nothing in between can throw, and
/// nothing here knows what is behind the handle.
///
/// The returned value owns the handle. Whoever takes it (a `Demuxer`, a
/// `LexisPlayer`) closes it exactly once; drop it without handing it on and
/// call `close` yourself, or the stream leaks its socket.
///
/// This is a target of its own, not part of `LexisPlayer`, because it is the
/// only Swift here that needs the core's symbols and `LexisPlayer` must keep
/// linking without them: TestBench depends on it and does not link the core.
public func coreStream(handle: OpaquePointer) -> MediaStreamIO {
    MediaStreamIO(
        handle: UnsafeMutableRawPointer(handle),
        read: { handle, buffer, length in
            lexis_stream_read(OpaquePointer(handle), buffer, length)
        },
        seek: { handle, offset, whence in
            lexis_stream_seek(OpaquePointer(handle), offset, whence)
        },
        size: { handle in lexis_stream_size(OpaquePointer(handle)) },
        close: { handle in lexis_stream_close(OpaquePointer(handle)) },
        analysisLoad: { handle, buffer, capacity in
            lexis_stream_analysis_load(OpaquePointer(handle), buffer, capacity)
        },
        analysisStore: { handle, json in
            lexis_stream_analysis_store(OpaquePointer(handle), json)
        }
    )
}
