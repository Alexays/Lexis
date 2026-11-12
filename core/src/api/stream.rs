use super::{on_thread, source_error, CoreError, LexisCore};
use crate::ffi::{lexis_stream_close, AnalysisKey, LexisStream};
use crate::index::queries::file_location;
use std::sync::atomic::Ordering;
use std::sync::Arc;
use std::time::Duration;

/// How often the connection a press on play needs is renewed. Nothing holds
/// an idle HTTP connection up indefinitely - a server drops one when it likes,
/// and a dropped one costs the whole cold open again - so one is re-opened
/// often enough that a viewer who browsed for a while still finds one waiting.
const WARM_EVERY: Duration = Duration::from_secs(20);

/// A stream opened for a caller that has not taken it yet: closed if it is
/// dropped instead, so an open nobody waits for any more leaks nothing.
struct Opened(u64);

impl Drop for Opened {
    fn drop(&mut self) {
        unsafe { lexis_stream_close(self.0 as *mut LexisStream) };
    }
}

#[uniffi::export]
impl LexisCore {
    /// Opens a file for playback and hands back the raw `LexisStream *` as an
    /// integer. The credential stays here: the source config never crosses the
    /// FFI, only the bytes it yields. The lookup and the first range fetch run
    /// on a thread of their own, so the caller never blocks on either.
    ///
    /// The caller owns the handle and closes it exactly once with
    /// `lexis_stream_close`. Handing it to a player that takes ownership of a
    /// stream counts as closing it; dropping the integer leaks a socket or a
    /// file descriptor for the life of the process. A stream that lands after
    /// the future was dropped is closed here.
    pub async fn open_stream(self: Arc<Self>, file_id: i64) -> Result<u64, CoreError> {
        let opened = on_thread(move || self.open_stream_blocking(file_id).map(Opened)).await?;
        let handle = opened.0;
        std::mem::forget(opened);
        Ok(handle)
    }

    /// Opens a connection to every configured source and keeps one open from
    /// then on, so that a press on play finds one in the pool instead of
    /// paying for a name lookup and a handshake with the viewer watching.
    /// Measured on an Apple TV whose network had been idle: 3.3 s to resolve
    /// the server's name and 13.5 s more to connect to it, against 5 ms for
    /// the same fetch over a connection that was already up.
    ///
    /// Call it as early as the app has a screen; it returns at once and does
    /// its work on a thread of its own. A second call does nothing, and the
    /// thread stops when the core it warms is dropped.
    pub fn keep_sources_warm(&self) {
        if self.warming.swap(true, Ordering::Relaxed) {
            return;
        }
        let weak = self.self_ref.clone();
        std::thread::spawn(move || {
            crate::lower_thread_qos();
            let mut first = true;
            loop {
                let Some(this) = weak.upgrade() else {
                    return;
                };
                let ids: Vec<String> = this
                    .configs
                    .lock()
                    .iter()
                    .map(|c| c.id().to_string())
                    .collect();
                // no lock is held across `warm`: it is a round trip to a server
                let t0 = std::time::Instant::now();
                for id in ids {
                    if let Some(source) = this.built_source(&id) {
                        source.warm();
                    }
                }
                // only the first: it is the one that pays, and the rest would
                // be a line every twenty seconds for the life of the process
                if first {
                    eprintln!(
                        "[lexis.open] sources warm after {} ms",
                        t0.elapsed().as_millis()
                    );
                    first = false;
                }
                drop(this);
                std::thread::sleep(WARM_EVERY);
            }
        });
    }
}

impl LexisCore {
    /// `open_stream`'s work, on the caller's own thread.
    pub(crate) fn open_stream_blocking(&self, file_id: i64) -> Result<u64, CoreError> {
        let t0 = std::time::Instant::now();
        // both guards end before the source does any I/O: opening a Plex part
        // is a network round trip, and browsing must not wait behind it
        let (located, waited) = {
            let db = self.read_db.lock();
            let waited = t0.elapsed();
            (file_location(&db, file_id)?, waited)
        };
        let queried = t0.elapsed();
        let (source_id, path, mtime) = located.ok_or_else(|| CoreError::NotFound {
            msg: format!("no file with id {file_id} in the index"),
        })?;
        let source = self
            .built_source(&source_id)
            .ok_or_else(|| CoreError::SourceUnavailable {
                source_id: source_id.clone(),
                msg: "the source that holds this file is not configured".to_string(),
            })?;
        let built = t0.elapsed();
        let stream = source
            .open(&path)
            .map_err(|e| source_error(&source_id, e))?;
        eprintln!(
            "[lexis.open] core open_stream: db wait {} ms, query {} ms, source {} ms, open {} ms",
            waited.as_millis(),
            (queried - waited).as_millis(),
            (built - queried).as_millis(),
            (t0.elapsed() - built).as_millis(),
        );
        Ok(Box::into_raw(Box::new(LexisStream {
            inner: stream,
            analysis: Some(AnalysisKey {
                core: self.self_ref.clone(),
                identity: format!("{source_id}:{file_id}"),
                mtime,
                loaded: None,
            }),
        })) as u64)
    }

    /// The player's probe of one file, read back through the browsing
    /// connection: a scan holding the write connection must not make pressing
    /// play wait.
    pub(crate) fn load_analysis(&self, identity: &str, mtime: i64) -> Option<String> {
        self.read_db
            .lock()
            .load_analysis(identity, mtime)
            .ok()
            .flatten()
    }

    /// The other half, on the write connection. A failure is dropped: the
    /// cache is an optimisation, and the next open probes cold and stores
    /// again.
    pub(crate) fn store_analysis(&self, identity: &str, mtime: i64, json: &str) {
        let _ = self.db.lock().store_analysis(identity, mtime, json);
    }
}

#[cfg(test)]
mod stream_tests {
    use super::*;
    use crate::api::library::ApiMediaKind;
    use crate::api::testing::{started, wait};
    use crate::api::HostStore;
    use crate::ffi::{
        lexis_stream_analysis_load, lexis_stream_analysis_store, lexis_stream_close,
        lexis_stream_open_file, lexis_stream_read, lexis_stream_size, LexisStream,
    };
    use crate::plex::fake::{FakeServer, Reply, EPISODES_JSON, MOVIES_JSON, SECTIONS_JSON};
    use crate::source::local::LocalModule;
    use crate::source::module::SourceModule;
    use crate::source::plex::PlexModule;
    use parking_lot::Mutex;
    use std::collections::HashMap;
    use std::ffi::CString;
    use std::fs;
    use std::ptr;

    #[derive(Default)]
    struct MemStore(Mutex<HashMap<String, Vec<u8>>>);
    impl HostStore for MemStore {
        fn get(&self, key: String) -> Option<Vec<u8>> {
            self.0.lock().get(&key).cloned()
        }
        fn set(&self, key: String, value: Vec<u8>) {
            self.0.lock().insert(key, value);
        }
    }

    /// Everything the handle is good for, and then it is closed: the tests are
    /// what prove the caller can own a raw pointer safely.
    fn read_all(handle: u64) -> Vec<u8> {
        let handle = handle as *mut LexisStream;
        let size = unsafe { lexis_stream_size(handle) };
        let mut buf = vec![0u8; size as usize];
        let n = unsafe { lexis_stream_read(handle, buf.as_mut_ptr(), size as i32) };
        unsafe { lexis_stream_close(handle) };
        buf.truncate(n as usize);
        buf
    }

    /// A Plex server that answers the library API and serves its parts over
    /// Range, which is what a file id resolved to a stream needs from it.
    fn library_with_parts(body: Vec<u8>) -> FakeServer {
        FakeServer::start(move |req| {
            if req.url == "/library/sections" {
                return Reply::json(SECTIONS_JSON);
            }
            if req.url.starts_with("/library/sections/1/all") {
                return Reply::json(MOVIES_JSON);
            }
            if req.url.starts_with("/library/sections/2/all") {
                return Reply::json(EPISODES_JSON);
            }
            if req.url.starts_with("/library/parts/") {
                let range = req.header("Range").unwrap_or("bytes=0-");
                let (from, to) = range.trim_start_matches("bytes=").split_once('-').unwrap();
                let start: usize = from.parse().unwrap_or(0);
                let end = to
                    .parse::<usize>()
                    .unwrap_or(usize::MAX)
                    .min(body.len() - 1);
                return Reply {
                    status: 206,
                    headers: vec![(
                        "Content-Range".to_string(),
                        format!("bytes {start}-{end}/{}", body.len()),
                    )],
                    body: body[start..=end].to_vec(),
                };
            }
            Reply::status(404)
        })
    }

    fn indexed_local() -> (tempfile::TempDir, tempfile::TempDir, Arc<LexisCore>) {
        let media = tempfile::tempdir().unwrap();
        fs::create_dir_all(media.path().join("Movies")).unwrap();
        fs::write(media.path().join("Movies/Dune (2021).mkv"), b"hello dune").unwrap();
        let cache = tempfile::tempdir().unwrap();
        let core = LexisCore::new(
            cache.path().to_string_lossy().into_owned(),
            Arc::new(MemStore::default()),
        )
        .unwrap();
        core.add_or_replace(
            LocalModule.id(),
            "local1".into(),
            std::collections::BTreeMap::from([(
                "root".to_string(),
                media.path().to_string_lossy().into_owned(),
            )]),
        )
        .unwrap();
        core.scan_all(false).unwrap();
        (media, cache, core)
    }

    #[test]
    fn a_local_file_opens_by_the_id_the_library_listed() {
        let (_media, _cache, core) = indexed_local();
        let titles = core.list_titles(ApiMediaKind::Movie, 0, 10).unwrap();
        let file_id = titles[0]
            .first_file_id
            .expect("the listed title names a file");
        let handle = core.open_stream_blocking(file_id).unwrap();
        assert_ne!(handle, 0);
        assert_eq!(read_all(handle), b"hello dune");
    }

    /// The player's probe cache, through the handle the player already holds:
    /// no path, no identity and no mtime cross the ABI, because the stream
    /// itself is the file.
    #[test]
    fn an_analysis_round_trips_through_the_stream_handle() {
        let (_media, _cache, core) = indexed_local();
        let file_id = core.list_titles(ApiMediaKind::Movie, 0, 10).unwrap()[0]
            .first_file_id
            .unwrap();
        let handle = core.open_stream_blocking(file_id).unwrap() as *mut LexisStream;
        let json = CString::new(r#"{"duration":9000}"#).unwrap();

        unsafe {
            // nothing stored yet: a measuring call answers -1, not 0
            assert_eq!(lexis_stream_analysis_load(handle, ptr::null_mut(), 0), -1);
            assert_ne!(lexis_stream_analysis_store(handle, json.as_ptr()), 0);

            // the store runs on a thread of its own, so the read back waits
            // for it rather than racing it
            let mut len = -1;
            for _ in 0..200 {
                len = lexis_stream_analysis_load(handle, ptr::null_mut(), 0);
                if len > 0 {
                    break;
                }
                std::thread::sleep(std::time::Duration::from_millis(10));
            }
            assert_eq!(len, json.as_bytes().len() as i32);
            let mut buf = vec![0u8; len as usize];
            assert_eq!(
                lexis_stream_analysis_load(handle, buf.as_mut_ptr(), len),
                len
            );
            assert_eq!(buf, json.as_bytes());

            // the fill hands over what the measure read, even when a store
            // lands in between: the two calls always agree on the length
            let measured = lexis_stream_analysis_load(handle, ptr::null_mut(), 0);
            let longer = CString::new(r#"{"duration":9000,"keyframes":[1,2,3]}"#).unwrap();
            assert_ne!(lexis_stream_analysis_store(handle, longer.as_ptr()), 0);
            let fresh = core.open_stream_blocking(file_id).unwrap() as *mut LexisStream;
            for _ in 0..200 {
                if lexis_stream_analysis_load(fresh, ptr::null_mut(), 0)
                    == longer.as_bytes().len() as i32
                {
                    break;
                }
                std::thread::sleep(std::time::Duration::from_millis(10));
            }
            lexis_stream_close(fresh);
            let mut buf = vec![0u8; measured as usize];
            assert_eq!(
                lexis_stream_analysis_load(handle, buf.as_mut_ptr(), measured),
                measured
            );
            assert_eq!(buf, json.as_bytes());

            lexis_stream_close(handle);
        }

        // a stream nothing keeps an index row for keeps no analysis either
        let path = CString::new(
            _media
                .path()
                .join("Movies/Dune (2021).mkv")
                .to_str()
                .unwrap(),
        )
        .unwrap();
        unsafe {
            let loose = lexis_stream_open_file(path.as_ptr(), ptr::null_mut());
            assert_eq!(lexis_stream_analysis_load(loose, ptr::null_mut(), 0), -1);
            assert_eq!(lexis_stream_analysis_store(loose, json.as_ptr()), 0);
            lexis_stream_close(loose);
        }
    }

    #[test]
    fn a_plex_part_opens_by_its_id_and_the_token_stays_in_a_header() {
        let data: Vec<u8> = (0..1000u32).map(|i| (i % 251) as u8).collect();
        let server = library_with_parts(data.clone());
        let cache = tempfile::tempdir().unwrap();
        let core = LexisCore::new(
            cache.path().to_string_lossy().into_owned(),
            Arc::new(MemStore::default()),
        )
        .unwrap();
        core.add_or_replace(
            PlexModule.id(),
            "plex1".into(),
            std::collections::BTreeMap::from([
                ("base_url".to_string(), server.base_url.clone()),
                ("token".to_string(), "s3cr3t".into()),
            ]),
        )
        .unwrap();
        core.scan_all(false).unwrap();

        let titles = core.list_titles(ApiMediaKind::Movie, 0, 10).unwrap();
        let file_id = titles[0].first_file_id.unwrap();
        assert_eq!(read_all(core.open_stream_blocking(file_id).unwrap()), data);

        let part = server
            .requests()
            .into_iter()
            .find(|r| r.url.starts_with("/library/parts/"))
            .expect("the stream went to the part the sync stored");
        assert_eq!(part.header("X-Plex-Token"), Some("s3cr3t"));
        // never in the URL: that is what keeps it out of proxy and server logs
        assert!(!part.url.contains("s3cr3t"));
    }

    #[test]
    fn an_unknown_id_and_an_unconfigured_source_both_fail_without_a_handle() {
        let (_media, _cache, core) = indexed_local();
        let file_id = core.list_titles(ApiMediaKind::Movie, 0, 10).unwrap()[0]
            .first_file_id
            .unwrap();

        assert!(matches!(
            core.open_stream_blocking(999_999),
            Err(CoreError::NotFound { .. })
        ));
        // a file row outlives a source list that no longer names its source;
        // every real mutator drops the built-source cache along with the
        // config, so the test does too
        core.configs.lock().clear();
        core.built_sources.lock().clear();
        assert!(matches!(
            core.open_stream_blocking(file_id),
            Err(CoreError::SourceUnavailable { .. })
        ));
    }

    #[test]
    fn a_rejected_token_is_unauthorized_and_carries_no_credential() {
        let server = FakeServer::start(|req| {
            if req.url == "/library/sections" {
                return Reply::json(SECTIONS_JSON);
            }
            if req.url.starts_with("/library/sections/1/all") {
                return Reply::json(MOVIES_JSON);
            }
            if req.url.starts_with("/library/sections/2/all") {
                return Reply::json(EPISODES_JSON);
            }
            // the token is good enough to browse and stale by the time it plays
            Reply::status(401)
        });
        let cache = tempfile::tempdir().unwrap();
        let core = LexisCore::new(
            cache.path().to_string_lossy().into_owned(),
            Arc::new(MemStore::default()),
        )
        .unwrap();
        core.add_or_replace(
            PlexModule.id(),
            "plex1".into(),
            std::collections::BTreeMap::from([
                ("base_url".to_string(), server.base_url.clone()),
                ("token".to_string(), "s3cr3t".into()),
            ]),
        )
        .unwrap();
        core.scan_all(false).unwrap();

        let file_id = core.list_titles(ApiMediaKind::Movie, 0, 10).unwrap()[0]
            .first_file_id
            .unwrap();
        let err = core.open_stream_blocking(file_id).unwrap_err();
        assert!(matches!(err, CoreError::Unauthorized { .. }));
        assert!(!err.to_string().contains("s3cr3t"), "{err}");
    }

    /// Like `library_with_parts`, but the part fetch costs `delay_ms` before
    /// it answers: the first byte a real cold connection makes `open_stream`
    /// wait on.
    fn slow_library_with_parts(body: Vec<u8>, delay_ms: u64) -> FakeServer {
        FakeServer::start(move |req| {
            if req.url == "/library/sections" {
                return Reply::json(SECTIONS_JSON);
            }
            if req.url.starts_with("/library/sections/1/all") {
                return Reply::json(MOVIES_JSON);
            }
            if req.url.starts_with("/library/sections/2/all") {
                return Reply::json(EPISODES_JSON);
            }
            if req.url.starts_with("/library/parts/") {
                std::thread::sleep(std::time::Duration::from_millis(delay_ms));
                let range = req.header("Range").unwrap_or("bytes=0-");
                let (from, to) = range.trim_start_matches("bytes=").split_once('-').unwrap();
                let start: usize = from.parse().unwrap_or(0);
                let end = to
                    .parse::<usize>()
                    .unwrap_or(usize::MAX)
                    .min(body.len() - 1);
                return Reply {
                    status: 206,
                    headers: vec![(
                        "Content-Range".to_string(),
                        format!("bytes {start}-{end}/{}", body.len()),
                    )],
                    body: body[start..=end].to_vec(),
                };
            }
            Reply::status(404)
        })
    }

    /// A core with one file behind a part fetch that costs `delay_ms`, and
    /// that file's own id.
    fn slow_plex_file(delay_ms: u64) -> (Arc<LexisCore>, Vec<u8>, i64, FakeServer) {
        let data: Vec<u8> = (0..1000u32).map(|i| (i % 251) as u8).collect();
        let server = slow_library_with_parts(data.clone(), delay_ms);
        let cache = tempfile::tempdir().unwrap();
        let core = LexisCore::new(
            cache.path().to_string_lossy().into_owned(),
            Arc::new(MemStore::default()),
        )
        .unwrap();
        core.add_or_replace(
            PlexModule.id(),
            "plex1".into(),
            std::collections::BTreeMap::from([
                ("base_url".to_string(), server.base_url.clone()),
                ("token".to_string(), "tok".into()),
            ]),
        )
        .unwrap();
        core.scan_all(false).unwrap();
        let file_id = core.list_titles(ApiMediaKind::Movie, 0, 10).unwrap()[0]
            .first_file_id
            .unwrap();
        (core, data, file_id, server)
    }

    #[test]
    fn open_stream_opens_on_a_thread_of_its_own_and_hands_back_the_handle() {
        let (core, data, file_id, _server) = slow_plex_file(200);

        let start = std::time::Instant::now();
        let open = started(core.clone().open_stream(file_id));
        assert!(
            start.elapsed() < std::time::Duration::from_millis(100),
            "the first poll waited on the open itself: {:?}",
            start.elapsed()
        );

        assert_eq!(read_all(wait(open).unwrap()), data);
    }

    /// Every `/identity` the server has seen since `from`.
    fn warm_ups(server: &FakeServer, from: usize) -> Vec<crate::plex::fake::Req> {
        server
            .requests()
            .into_iter()
            .skip(from)
            .filter(|r| r.url == "/identity")
            .collect()
    }

    #[test]
    fn keeping_sources_warm_puts_a_connection_up_before_anything_is_opened() {
        let (core, _data, _file_id, server) = slow_plex_file(0);
        let after_scan = server.requests().len();

        core.keep_sources_warm();

        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(5);
        loop {
            match warm_ups(&server, after_scan).first() {
                Some(warm) => {
                    // reachability, not a request that needed a credential:
                    // the whole point is that it happens before the viewer
                    // asks for anything
                    assert_eq!(warm.header("X-Plex-Token"), None, "{warm:?}");
                    return;
                }
                None => {
                    assert!(
                        std::time::Instant::now() < deadline,
                        "nothing ever warmed the connection"
                    );
                    std::thread::sleep(std::time::Duration::from_millis(10));
                }
            }
        }
    }

    #[test]
    fn a_second_call_to_keep_sources_warm_starts_no_second_thread() {
        let (core, _data, _file_id, server) = slow_plex_file(0);
        let after_scan = server.requests().len();

        core.keep_sources_warm();
        core.keep_sources_warm();
        // a second thread warms on starting, not on its first interval, so
        // it would already be in the log by now
        std::thread::sleep(std::time::Duration::from_millis(500));

        assert_eq!(warm_ups(&server, after_scan).len(), 1);
    }
}
