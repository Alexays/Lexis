//! The C ABI the player's FFmpeg I/O callbacks call. Every entry point is
//! panic-safe and null-safe: FFmpeg calls these from its own thread, and an
//! unwind across the boundary would take the process down.

use crate::source::plex::{shared_stream_agent, RangeReader};
use crate::source::{ReadSeek, SourceError};
use std::ffi::{c_char, c_int, CStr};
use std::io::{Read, Seek, SeekFrom};
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::ptr;
use std::sync::Weak;

pub const LEXIS_STREAM_OK: i32 = 0;
pub const LEXIS_STREAM_ERR_INVALID: i32 = 1;
pub const LEXIS_STREAM_ERR_NOT_FOUND: i32 = 2;
pub const LEXIS_STREAM_ERR_UNAUTHORIZED: i32 = 3;
pub const LEXIS_STREAM_ERR_IO: i32 = 4;

/// What a read answers when the credential was refused. Distinct from -1, so
/// the app can ask for a new one instead of blaming the network.
pub const LEXIS_STREAM_READ_UNAUTHORIZED: i64 = -2;

/// The handle the player holds. `Box<dyn ReadSeek>` is a fat pointer, so it
/// travels boxed inside a struct whose pointer is thin.
pub struct LexisStream {
    pub(crate) inner: Box<dyn ReadSeek>,
    /// Where the player's probe of this file is kept, and what keys it. None
    /// for a stream opened by path alone: no index row names it, so there is
    /// nothing to key a cached probe by.
    pub(crate) analysis: Option<AnalysisKey>,
}

/// One file's slot in the player's analysis cache. The core owns the
/// connection, so a load costs a lock and a query rather than opening the
/// index and running its migration gate at the exact moment a viewer is
/// waiting for a picture.
pub(crate) struct AnalysisKey {
    pub(crate) core: Weak<crate::api::LexisCore>,
    /// Source id and file id, never a path with a token.
    pub(crate) identity: String,
    pub(crate) mtime: i64,
    /// What the measuring call of `lexis_stream_analysis_load` read, handed
    /// over by the filling one rather than queried and copied a second time.
    pub(crate) loaded: Option<String>,
}

fn set_error(out: *mut i32, code: i32) {
    if !out.is_null() {
        unsafe { *out = code }
    }
}

fn code_for(e: &SourceError) -> i32 {
    match e {
        SourceError::NotFound(_) => LEXIS_STREAM_ERR_NOT_FOUND,
        SourceError::InvalidPath(_) => LEXIS_STREAM_ERR_INVALID,
        SourceError::Refused(_) => LEXIS_STREAM_ERR_INVALID,
        SourceError::Unauthorized => LEXIS_STREAM_ERR_UNAUTHORIZED,
        SourceError::Io(_) => LEXIS_STREAM_ERR_IO,
    }
}

/// # Safety
/// `p` is null or a valid C string that outlives the returned borrow.
unsafe fn borrow_str<'a>(p: *const c_char) -> Option<&'a str> {
    if p.is_null() {
        return None;
    }
    CStr::from_ptr(p).to_str().ok()
}

/// Opens a local file. Failure is a null handle and a code in `out_error`;
/// errors never cross as strings, which is what keeps a credential out of them.
///
/// # Safety
/// `path` is a valid C string, `out_error` is null or writable.
#[no_mangle]
pub unsafe extern "C" fn lexis_stream_open_file(
    path: *const c_char,
    out_error: *mut i32,
) -> *mut LexisStream {
    catch_unwind(AssertUnwindSafe(|| {
        let Some(path) = (unsafe { borrow_str(path) }) else {
            set_error(out_error, LEXIS_STREAM_ERR_INVALID);
            return ptr::null_mut();
        };
        match std::fs::File::open(path) {
            Ok(file) => {
                set_error(out_error, LEXIS_STREAM_OK);
                Box::into_raw(Box::new(LexisStream {
                    inner: Box::new(file),
                    analysis: None,
                }))
            }
            Err(e) => {
                set_error(
                    out_error,
                    match e.kind() {
                        std::io::ErrorKind::NotFound => LEXIS_STREAM_ERR_NOT_FOUND,
                        std::io::ErrorKind::PermissionDenied => LEXIS_STREAM_ERR_UNAUTHORIZED,
                        _ => LEXIS_STREAM_ERR_IO,
                    },
                );
                ptr::null_mut()
            }
        }
    }))
    .unwrap_or_else(|_| {
        set_error(out_error, LEXIS_STREAM_ERR_IO);
        ptr::null_mut()
    })
}

/// Opens an HTTP resource as a seekable stream of Range requests. An empty
/// `auth_header_name` sends no credential.
///
/// # Safety
/// The three strings are valid C strings, `out_error` is null or writable.
#[no_mangle]
pub unsafe extern "C" fn lexis_stream_open_http_range(
    url: *const c_char,
    auth_header_name: *const c_char,
    auth_header_value: *const c_char,
    out_error: *mut i32,
) -> *mut LexisStream {
    catch_unwind(AssertUnwindSafe(|| {
        let (Some(url), Some(name), Some(value)) = (
            unsafe { borrow_str(url) },
            unsafe { borrow_str(auth_header_name) },
            unsafe { borrow_str(auth_header_value) },
        ) else {
            set_error(out_error, LEXIS_STREAM_ERR_INVALID);
            return ptr::null_mut();
        };
        let agent = shared_stream_agent(url);
        match RangeReader::open(agent, url.to_string(), name, value) {
            Ok(reader) => {
                set_error(out_error, LEXIS_STREAM_OK);
                Box::into_raw(Box::new(LexisStream {
                    inner: Box::new(reader),
                    analysis: None,
                }))
            }
            Err(e) => {
                set_error(out_error, code_for(&e));
                ptr::null_mut()
            }
        }
    }))
    .unwrap_or_else(|_| {
        set_error(out_error, LEXIS_STREAM_ERR_IO);
        ptr::null_mut()
    })
}

/// Bytes read, 0 at end of stream, -1 on failure, -2 when the credential was
/// refused.
///
/// # Safety
/// `handle` is null or a handle from an open call that is not yet closed;
/// `buf` points to at least `len` writable bytes.
#[no_mangle]
pub unsafe extern "C" fn lexis_stream_read(
    handle: *mut LexisStream,
    buf: *mut u8,
    len: c_int,
) -> i64 {
    catch_unwind(AssertUnwindSafe(|| {
        // a zero-length read would answer 0, which the caller reads as the end
        if handle.is_null() || buf.is_null() || len <= 0 {
            return -1;
        }
        let stream = unsafe { &mut *handle };
        let out = unsafe { std::slice::from_raw_parts_mut(buf, len as usize) };
        match stream.inner.read(out) {
            Ok(n) => n as i64,
            // ErrorKind is what From<SourceError> already carries: a 401 comes
            // through as PermissionDenied, everything else is plain I/O
            Err(e) if e.kind() == std::io::ErrorKind::PermissionDenied => {
                LEXIS_STREAM_READ_UNAUTHORIZED
            }
            Err(_) => -1,
        }
    }))
    .unwrap_or(-1)
}

/// The new position, or -1. `whence` is 0 from the start, 1 from the current
/// position, 2 from the end.
///
/// # Safety
/// `handle` is null or a handle from an open call that is not yet closed.
#[no_mangle]
pub unsafe extern "C" fn lexis_stream_seek(
    handle: *mut LexisStream,
    offset: i64,
    whence: i32,
) -> i64 {
    catch_unwind(AssertUnwindSafe(|| {
        if handle.is_null() {
            return -1;
        }
        let from = match whence {
            0 if offset >= 0 => SeekFrom::Start(offset as u64),
            1 => SeekFrom::Current(offset),
            2 => SeekFrom::End(offset),
            _ => return -1,
        };
        let stream = unsafe { &mut *handle };
        match stream.inner.seek(from) {
            Ok(pos) if pos <= i64::MAX as u64 => pos as i64,
            _ => -1,
        }
    }))
    .unwrap_or(-1)
}

/// The total length, or -1 when it is not known. Costs three seeks: arithmetic
/// on a `RangeReader`, three lseek calls on a file, never a network round trip.
///
/// # Safety
/// `handle` is null or a handle from an open call that is not yet closed.
#[no_mangle]
pub unsafe extern "C" fn lexis_stream_size(handle: *mut LexisStream) -> i64 {
    catch_unwind(AssertUnwindSafe(|| {
        if handle.is_null() {
            return -1;
        }
        let stream = unsafe { &mut *handle };
        let Ok(current) = stream.inner.stream_position() else {
            return -1;
        };
        let end = stream.inner.seek(SeekFrom::End(0));
        // the position is restored even when the size lookup failed
        if stream.inner.seek(SeekFrom::Start(current)).is_err() {
            return -1;
        }
        match end {
            Ok(len) if len <= i64::MAX as u64 => len as i64,
            _ => -1,
        }
    }))
    .unwrap_or(-1)
}

/// # Safety
/// `handle` is null or a handle from an open call that is not yet closed. It
/// must not be used afterwards.
#[no_mangle]
pub unsafe extern "C" fn lexis_stream_close(handle: *mut LexisStream) {
    let _ = catch_unwind(AssertUnwindSafe(|| {
        if !handle.is_null() {
            drop(unsafe { Box::from_raw(handle) });
        }
    }));
}

/// The player's per-file analysis cache. Writes the JSON stored for this
/// stream's own file into `buf`, up to `capacity` bytes; `buf` may be null
/// with `capacity` 0 to measure first. Returns the JSON's full byte length on
/// a match - call again with a buffer at least that big if this exceeds
/// `capacity` - or -1 when nothing matches: a stream nothing keeps an index
/// row for, a file never probed before, or one whose stored mtime no longer
/// agrees with the row's own.
///
/// # Safety
/// `handle` is a live stream from this ABI; `buf` points to at least
/// `capacity` writable bytes, or is null with `capacity` 0.
#[no_mangle]
pub unsafe extern "C" fn lexis_stream_analysis_load(
    handle: *mut LexisStream,
    buf: *mut u8,
    capacity: i32,
) -> i32 {
    catch_unwind(AssertUnwindSafe(|| {
        let Some(key) = (unsafe { handle.as_mut() }).and_then(|h| h.analysis.as_mut()) else {
            return -1;
        };
        if key.loaded.is_none() {
            let Some(core) = key.core.upgrade() else {
                return -1;
            };
            key.loaded = core.load_analysis(&key.identity, key.mtime);
        }
        let Some(json) = key.loaded.as_ref() else {
            return -1;
        };
        let len = json.len();
        if !buf.is_null() && capacity >= 0 && len <= capacity as usize {
            unsafe { std::slice::from_raw_parts_mut(buf, len) }.copy_from_slice(json.as_bytes());
            key.loaded = None;
        }
        i32::try_from(len).unwrap_or(-1)
    }))
    .unwrap_or(-1)
}

/// Keeps `json` as this stream's file's probe result, replacing whatever was
/// there for that file whole. Returns at once and writes on a thread of its
/// own: the index's write connection is the one a scan holds, and a viewer
/// waiting for a first frame must not queue behind one. Non-zero when the
/// write was started, 0 for a stream that keeps no analysis.
///
/// # Safety
/// `handle` is a live stream from this ABI and `json` a valid, NUL-terminated
/// C string.
#[no_mangle]
pub unsafe extern "C" fn lexis_stream_analysis_store(
    handle: *mut LexisStream,
    json: *const c_char,
) -> i32 {
    catch_unwind(AssertUnwindSafe(|| {
        let (Some(key), Some(json)) = (
            (unsafe { handle.as_ref() }).and_then(|h| h.analysis.as_ref()),
            unsafe { borrow_str(json) },
        ) else {
            return 0;
        };
        let (core, identity, mtime) = (key.core.clone(), key.identity.clone(), key.mtime);
        let json = json.to_string();
        std::thread::spawn(move || {
            crate::lower_thread_qos();
            if let Some(core) = core.upgrade() {
                core.store_analysis(&identity, mtime, &json);
            }
        });
        1
    }))
    .unwrap_or(0)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::plex::fake::{range_server, FakeServer, Reply};
    use std::ffi::CString;

    fn body(n: usize) -> Vec<u8> {
        (0..n).map(|i| (i % 251) as u8).collect()
    }

    #[test]
    fn a_file_reads_seeks_and_reports_its_size() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("clip.mkv");
        let data = body(5000);
        std::fs::write(&path, &data).unwrap();
        let c_path = CString::new(path.to_str().unwrap()).unwrap();
        let mut error = -7;
        let mut buf = [0u8; 64];

        unsafe {
            let handle = lexis_stream_open_file(c_path.as_ptr(), &mut error);
            assert!(!handle.is_null());
            assert_eq!(error, LEXIS_STREAM_OK);
            assert_eq!(lexis_stream_size(handle), 5000);

            assert_eq!(lexis_stream_read(handle, buf.as_mut_ptr(), 8), 8);
            assert_eq!(buf[..8], data[..8]);
            assert_eq!(lexis_stream_seek(handle, 1000, 0), 1000);
            assert_eq!(lexis_stream_read(handle, buf.as_mut_ptr(), 4), 4);
            assert_eq!(buf[..4], data[1000..1004]);
            assert_eq!(lexis_stream_seek(handle, -10, 2), 4990);
            assert_eq!(lexis_stream_read(handle, buf.as_mut_ptr(), 64), 10);
            assert_eq!(buf[..10], data[4990..]);
            // the end of the stream is 0, never an error
            assert_eq!(lexis_stream_read(handle, buf.as_mut_ptr(), 64), 0);
            lexis_stream_close(handle);
        }
    }

    #[test]
    fn a_missing_file_is_a_null_handle_with_a_code() {
        let path = CString::new("/nope/missing.mkv").unwrap();
        let mut error = -7;
        unsafe {
            assert!(lexis_stream_open_file(path.as_ptr(), &mut error).is_null());
        }
        assert_eq!(error, LEXIS_STREAM_ERR_NOT_FOUND);
    }

    #[test]
    fn every_entry_point_survives_a_null_argument() {
        let mut error = -7;
        let mut buf = [0u8; 4];
        unsafe {
            assert!(lexis_stream_open_file(ptr::null(), &mut error).is_null());
            assert_eq!(error, LEXIS_STREAM_ERR_INVALID);
            let stream =
                lexis_stream_open_http_range(ptr::null(), ptr::null(), ptr::null(), &mut error);
            assert!(stream.is_null());
            assert_eq!(error, LEXIS_STREAM_ERR_INVALID);
            // a null out_error is legal too
            assert!(lexis_stream_open_file(ptr::null(), ptr::null_mut()).is_null());

            assert_eq!(lexis_stream_read(ptr::null_mut(), buf.as_mut_ptr(), 4), -1);
            assert_eq!(lexis_stream_seek(ptr::null_mut(), 0, 0), -1);
            assert_eq!(lexis_stream_size(ptr::null_mut()), -1);
            lexis_stream_close(ptr::null_mut());
        }
    }

    #[test]
    fn a_bad_read_or_seek_is_minus_one_not_a_crash() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("clip.mkv");
        std::fs::write(&path, body(64)).unwrap();
        let c_path = CString::new(path.to_str().unwrap()).unwrap();
        let mut buf = [0u8; 4];

        unsafe {
            let handle = lexis_stream_open_file(c_path.as_ptr(), ptr::null_mut());
            assert_eq!(lexis_stream_read(handle, ptr::null_mut(), 4), -1);
            assert_eq!(lexis_stream_read(handle, buf.as_mut_ptr(), 0), -1);
            assert_eq!(lexis_stream_seek(handle, -1, 0), -1); // before the start
            assert_eq!(lexis_stream_seek(handle, 0, 99), -1); // no such whence
            assert_eq!(lexis_stream_size(handle), 64); // and the handle still works
            lexis_stream_close(handle);
        }
    }

    #[test]
    fn an_http_range_stream_reads_and_seeks_over_the_network() {
        let data = body(700 * 1024);
        let server = range_server(data.clone());
        let url = CString::new(format!("{}/library/parts/1/1/f.mkv", server.base_url)).unwrap();
        let name = CString::new("X-Plex-Token").unwrap();
        let value = CString::new("tok").unwrap();
        let mut error = -7;
        let mut buf = [0u8; 16];

        unsafe {
            let handle = lexis_stream_open_http_range(
                url.as_ptr(),
                name.as_ptr(),
                value.as_ptr(),
                &mut error,
            );
            assert!(!handle.is_null());
            assert_eq!(error, LEXIS_STREAM_OK);
            assert_eq!(lexis_stream_size(handle), data.len() as i64);
            assert_eq!(lexis_stream_read(handle, buf.as_mut_ptr(), 8), 8);
            assert_eq!(buf[..8], data[..8]);
            assert_eq!(lexis_stream_seek(handle, 400_000, 0), 400_000);
            assert_eq!(lexis_stream_read(handle, buf.as_mut_ptr(), 16), 16);
            assert_eq!(buf, data[400_000..400_016]);
            lexis_stream_close(handle);
        }
        assert_eq!(server.requests()[0].header("X-Plex-Token"), Some("tok"));
    }

    #[test]
    fn the_caller_names_the_auth_header_and_that_name_is_what_is_sent() {
        let server = range_server(body(64));
        let url = CString::new(format!("{}/f.mkv", server.base_url)).unwrap();
        let name = CString::new("Authorization").unwrap();
        let value = CString::new("Bearer tok").unwrap();

        unsafe {
            let handle = lexis_stream_open_http_range(
                url.as_ptr(),
                name.as_ptr(),
                value.as_ptr(),
                ptr::null_mut(),
            );
            assert!(!handle.is_null());
            lexis_stream_close(handle);
        }
        let req = &server.requests()[0];
        assert_eq!(req.header("Authorization"), Some("Bearer tok"));
        assert_eq!(req.header("X-Plex-Token"), None); // no name of its own
    }

    #[test]
    fn a_rejected_credential_is_its_own_code() {
        let server = FakeServer::start(|_req| Reply::status(401));
        let url = CString::new(format!("{}/library/parts/1/1/f.mkv", server.base_url)).unwrap();
        let name = CString::new("X-Plex-Token").unwrap();
        let value = CString::new("stale").unwrap();
        let mut error = -7;
        unsafe {
            let handle = lexis_stream_open_http_range(
                url.as_ptr(),
                name.as_ptr(),
                value.as_ptr(),
                &mut error,
            );
            assert!(handle.is_null());
        }
        assert_eq!(error, LEXIS_STREAM_ERR_UNAUTHORIZED);
    }

    #[test]
    fn a_redirect_is_never_followed_so_the_credential_stays_on_the_host() {
        let elsewhere = FakeServer::start(|_req| Reply::status(200));
        let target = format!("{}/stolen.mkv", elsewhere.base_url);
        let redirector = FakeServer::start(move |_req| Reply {
            status: 302,
            headers: vec![("Location".to_string(), target.clone())],
            body: Vec::new(),
        });
        let url = CString::new(format!("{}/f.mkv", redirector.base_url)).unwrap();
        let name = CString::new("X-Plex-Token").unwrap();
        let value = CString::new("tok").unwrap();
        let mut error = -7;

        unsafe {
            let handle = lexis_stream_open_http_range(
                url.as_ptr(),
                name.as_ptr(),
                value.as_ptr(),
                &mut error,
            );
            assert!(handle.is_null());
        }
        assert_eq!(error, LEXIS_STREAM_ERR_IO);
        assert!(elsewhere.requests().is_empty()); // the token never left the host
    }

    #[test]
    fn a_server_that_dies_mid_stream_reads_as_an_error_not_an_end_of_stream() {
        let data = body(700 * 1024);
        let seen = std::sync::atomic::AtomicUsize::new(0);
        let server = FakeServer::start(move |_req| {
            if seen.fetch_add(1, std::sync::atomic::Ordering::SeqCst) > 0 {
                return Reply::status(500);
            }
            Reply {
                status: 206,
                headers: vec![(
                    "Content-Range".to_string(),
                    format!("bytes 0-262143/{}", data.len()),
                )],
                body: data[..262_144].to_vec(),
            }
        });
        let url = CString::new(format!("{}/f.mkv", server.base_url)).unwrap();
        let empty = CString::new("").unwrap();
        let mut buf = [0u8; 8];

        unsafe {
            let handle = lexis_stream_open_http_range(
                url.as_ptr(),
                empty.as_ptr(),
                empty.as_ptr(),
                ptr::null_mut(),
            );
            assert!(!handle.is_null());
            assert_eq!(lexis_stream_seek(handle, 400_000, 0), 400_000);
            assert_eq!(lexis_stream_read(handle, buf.as_mut_ptr(), 8), -1);
            lexis_stream_close(handle);
        }
        // the unauthenticated open sent no credential header
        assert_eq!(server.requests()[0].header("X-Plex-Token"), None);
    }

    #[test]
    fn a_credential_rejected_mid_stream_has_its_own_read_code() {
        let data = body(700 * 1024);
        let seen = std::sync::atomic::AtomicUsize::new(0);
        let server = FakeServer::start(move |_req| {
            if seen.fetch_add(1, std::sync::atomic::Ordering::SeqCst) > 0 {
                return Reply::status(401);
            }
            Reply {
                status: 206,
                headers: vec![(
                    "Content-Range".to_string(),
                    format!("bytes 0-262143/{}", data.len()),
                )],
                body: data[..262_144].to_vec(),
            }
        });
        let url = CString::new(format!("{}/f.mkv", server.base_url)).unwrap();
        let name = CString::new("X-Plex-Token").unwrap();
        let value = CString::new("stale").unwrap();
        let mut buf = [0u8; 8];

        unsafe {
            let handle = lexis_stream_open_http_range(
                url.as_ptr(),
                name.as_ptr(),
                value.as_ptr(),
                ptr::null_mut(),
            );
            assert!(!handle.is_null());
            assert_eq!(lexis_stream_seek(handle, 400_000, 0), 400_000);
            // -2, not -1: a revoked token is not a dead network, and only the
            // code can tell the app which one to complain about
            assert_eq!(
                lexis_stream_read(handle, buf.as_mut_ptr(), 8),
                LEXIS_STREAM_READ_UNAUTHORIZED
            );
            lexis_stream_close(handle);
        }
    }
}
