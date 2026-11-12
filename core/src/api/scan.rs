use super::{
    scan_error, unix_now, CoreError, LexisCore, QueuedWrite, SourceConfig, SourceStatus,
    SOURCE_STATUS_KEY,
};
use crate::index::scan::scan;
use crate::source::Source;
use futures_channel::oneshot;
use parking_lot::Mutex;
use std::sync::Arc;

/// What one source contributed to a scan. `error` is the display form of the
/// CoreError that source failed with, so the UI can name the source that broke
/// without failing the whole scan. `unauthorized` is that error's variant, kept
/// as a flag because a rejected credential asks the user for a new token while
/// every other failure only asks for another scan later; matching on the
/// message to tell them apart would be matching on prose.
#[derive(Debug, Clone, uniffi::Record)]
pub struct SourceScanResult {
    pub id: String,
    pub files_seen: u32,
    pub files_upserted: u32,
    pub files_removed: u32,
    pub error: Option<String>,
    pub unauthorized: bool,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct ScanReport {
    pub files_seen: u32,
    pub files_upserted: u32,
    pub files_removed: u32,
    pub sources_failed: u32,
    pub per_source: Vec<SourceScanResult>,
    /// Plex writes still owed to a server after this scan drained what it
    /// could. Zero is the normal state; anything else is history not syncing.
    pub queued_writes: u32,
}

/// How far a background scan has gotten: `sources_done` out of
/// `sources_total`, and which one is in flight right now (empty once every
/// source has answered).
#[derive(Debug, Clone, Default, uniffi::Record)]
pub struct ScanProgress {
    pub sources_total: u32,
    pub sources_done: u32,
    pub current_source: String,
}

/// The one scan in flight, and every caller waiting on its report.
pub(super) struct RunningScan {
    progress: Arc<Mutex<ScanProgress>>,
    full: bool,
    /// A full scan was asked for while this one, which is not, was running.
    full_owed: bool,
    waiters: Vec<oneshot::Sender<Result<ScanReport, CoreError>>>,
}

#[uniffi::export]
impl LexisCore {
    /// The scan's playback brake, the same contract as `pause_pass` and
    /// `pause_artwork`: true parks a running scan between sources and
    /// between pages, holding no lock and making no request until it is
    /// stood back down. Setting it with nothing running costs nothing; the
    /// next scan consults the same flag from its first source on.
    pub fn pause_scan(&self, value: bool) {
        self.scan_paused.set(value);
    }

    /// Scans every source on a thread of its own and resolves with the
    /// report: a Plex source's network round trips never hold the caller.
    ///
    /// A scan already running is not doubled: the caller waits on the one in
    /// flight rather than starting one that would race it over the
    /// same rows, and every waiter gets the same report.
    /// `full` asks every source for everything it holds rather than letting it
    /// say nothing has changed. False is the sweep this app runs on its own,
    /// which is allowed to believe a section's stamp or a directory's mtime;
    /// true is what a viewer pressing Scan means by it, and the only answer
    /// that is a guarantee.
    pub async fn scan(self: Arc<Self>, full: bool) -> Result<ScanReport, CoreError> {
        let (tx, rx) = oneshot::channel();
        {
            let mut running = self.running_scan.lock();
            if let Some(run) = running.as_mut() {
                // a viewer asking for everything is not answered by a sweep that
                // believed the stamps: the running scan owes one more, full pass
                if full && !run.full {
                    run.full_owed = true;
                }
                run.waiters.push(tx);
            } else {
                // set here, before the thread runs, so a progress read landing
                // before it starts already shows the real total
                let progress = Arc::new(Mutex::new(ScanProgress {
                    sources_total: self.configs.lock().len() as u32,
                    ..ScanProgress::default()
                }));
                *running = Some(RunningScan {
                    progress: progress.clone(),
                    full,
                    full_owed: false,
                    waiters: vec![tx],
                });
                let this = self.clone();
                std::thread::Builder::new()
                    .name("lexis.scan".into())
                    .spawn(move || {
                        crate::lower_thread_qos();
                        let mut result = this.do_scan(&progress, full);
                        loop {
                            // read under the guard a waiter joins under, so a full
                            // scan asked for at the last moment is never lost
                            let mut running = this.running_scan.lock();
                            let run = running.as_mut().expect("only this thread ends the scan");
                            if run.full_owed {
                                run.full_owed = false;
                                run.full = true;
                                drop(running);
                                *progress.lock() = ScanProgress::default();
                                result = this.do_scan(&progress, true);
                                continue;
                            }
                            let mut waiters = running.take().expect("checked above").waiters;
                            drop(running);
                            let last = waiters.pop();
                            for waiter in waiters {
                                let _ = waiter.send(result.clone());
                            }
                            if let Some(last) = last {
                                let _ = last.send(result);
                            }
                            break;
                        }
                    })
                    .expect("spawn a thread");
            }
        }
        rx.await.expect("the scan thread panicked")
    }

    /// How far the scan in flight has gotten, or `None` once nothing runs.
    pub fn current_scan(&self) -> Option<ScanProgress> {
        let running = self.running_scan.lock();
        let progress = running.as_ref()?.progress.lock().clone();
        Some(progress)
    }

    /// Whether any scan since the last call added, rewrote or removed a file,
    /// a watch another client made included, and clears it. One reader: the
    /// app, which redraws and restarts the pass on it.
    pub fn take_library_changed(&self) -> bool {
        self.library_changed
            .swap(false, std::sync::atomic::Ordering::Relaxed)
    }
}

#[cfg(test)]
impl LexisCore {
    /// Never fails as a whole: a source that broke says so in its own
    /// `per_source` row, and one unreachable source must not hide the rest of
    /// the library. The Result is kept for failures that could yet be global.
    ///
    /// `scan`'s work on the caller's own thread, blocking for as long as
    /// every source's network round trips take.
    pub fn scan_all(&self, full: bool) -> Result<ScanReport, CoreError> {
        self.do_scan(&Mutex::new(ScanProgress::default()), full)
    }
}

impl LexisCore {
    /// `scan_all`'s own work, reporting how far it has gotten into `progress`
    /// as it goes: read by `current_scan` while a background scan runs it, and
    /// by nobody while `scan_all` runs it synchronously on the caller's own
    /// thread.
    fn do_scan(&self, progress: &Mutex<ScanProgress>, full: bool) -> Result<ScanReport, CoreError> {
        let configs: Vec<SourceConfig> = self.configs.lock().clone();
        // the sources and the drains come first, before the index guard below:
        // building a source takes the source list, and every mutator takes the
        // source list before the index. A scan that took them the other way
        // round would deadlock against a source edited while it runs, for as
        // long as a server that is away takes to time out.
        //
        // Draining here also keeps every write this device owes ahead of every
        // mirror: the server hears us before it answers for the same items.
        let now = unix_now();
        let built: Vec<(String, Option<Arc<dyn Source>>)> = configs
            .iter()
            .map(|c| (c.id.clone(), self.built_source(&c.id)))
            .collect();
        progress.lock().sources_total = configs.len() as u32;
        // what the drains below got through: the sync that follows answers for
        // the same items, with whatever the server has made of them
        let mut settled: Vec<QueuedWrite> = Vec::new();
        for (id, source) in &built {
            if source.as_ref().is_some_and(|s| s.watch_sync().is_some()) {
                settled.extend(self.drain_queue(id, now));
            }
        }
        let mut report = ScanReport {
            files_seen: 0,
            files_upserted: 0,
            files_removed: 0,
            sources_failed: 0,
            per_source: Vec::with_capacity(configs.len()),
            queued_writes: 0,
        };
        for (config, (_, source)) in configs.iter().zip(&built) {
            // a source removed since the snapshot built no source above, and
            // is not scanned at all rather than reported as one that scanned
            // nothing
            let Some(source) = source else {
                progress.lock().sources_done += 1;
                continue;
            };
            progress.lock().current_source = config.id().to_string();
            // playback above all: parked here between sources, holding nothing
            self.scan_paused.wait();
            let result = match source.catalogue() {
                // a catalogue source enumerates its own items: its server's
                // own API is authoritative for them (spec: Storage model).
                // The write connection goes in behind its mutex, and the pull
                // takes the guard per page transaction, never across its
                // network calls - a playback report waits out one commit,
                // not one source.
                Some(catalogue) => catalogue.pull(&self.db, &self.scan_paused, full),
                None => {
                    // a directory walk has no network in it: one transaction,
                    // one guard, for the whole source
                    let db = self.db.lock();
                    scan(&db, source.as_ref(), full)
                }
            }
            .map_err(|e| scan_error(&config.id, e));
            match result {
                Ok(stats) => {
                    report.files_seen += stats.files_seen;
                    report.files_upserted += stats.files_upserted;
                    report.files_removed += stats.files_removed;
                    report.per_source.push(SourceScanResult {
                        id: config.id().to_string(),
                        files_seen: stats.files_seen,
                        files_upserted: stats.files_upserted,
                        files_removed: stats.files_removed,
                        error: None,
                        unauthorized: false,
                    });
                }
                Err(e) => {
                    report.sources_failed += 1;
                    report.per_source.push(SourceScanResult {
                        id: config.id().to_string(),
                        files_seen: 0,
                        files_upserted: 0,
                        files_removed: 0,
                        unauthorized: matches!(e, CoreError::Unauthorized { .. }),
                        error: Some(e.to_string()),
                    });
                }
            }
            let mut p = progress.lock();
            p.sources_done += 1;
            p.current_source.clear();
        }
        // a purge rebuilt the file rows this state points at, so the durable
        // copies are what put back the watch state, the titles taken out of
        // the resume row and the opinions, none of which a server holds. A
        // scan that changed no file rebuilt nothing, and has nothing to undo.
        if report.files_upserted > 0 || report.files_removed > 0 {
            let db = self.db.lock();
            let tx = db
                .conn()
                .unchecked_transaction()
                .map_err(crate::index::db::IndexError::from)?;
            self.restore_watch_state(&db, &settled)?;
            self.restore_dismissals(&db)?;
            self.restore_verdicts(&db)?;
            tx.commit().map_err(crate::index::db::IndexError::from)?;
        }
        report.queued_writes = self.queued_writes();
        if report.files_upserted > 0 || report.files_removed > 0 {
            self.library_changed
                .store(true, std::sync::atomic::Ordering::Relaxed);
        }
        {
            let mut status = self.status.lock();
            for row in &report.per_source {
                status.insert(
                    row.id.clone(),
                    SourceStatus {
                        last_scan: now,
                        last_error: row.error.clone(),
                    },
                );
            }
            if let Ok(bytes) = serde_json::to_vec(&*status) {
                self.store.set(SOURCE_STATUS_KEY.to_string(), bytes);
            }
        }
        Ok(report)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::api::library::ApiMediaKind;
    use crate::api::testing::*;
    use crate::source::local::LocalModule;
    use crate::source::module::SourceModule;
    use crate::source::plex::PlexModule;
    use crate::source::PlaybackState;
    use parking_lot::Condvar;
    use std::fs;
    use std::path::PathBuf;
    use std::sync::atomic::{AtomicBool, Ordering};
    use std::time::Duration;

    /// One local source and one Plex source, both already indexed, standing
    /// in for the owner's real library: a fix here must protect a source it
    /// never touches as much as the one that broke. Every field but `core`
    /// and `root` only needs to outlive the caller, keeping its temp dir and
    /// fake server from tearing down under a still-open db connection.
    struct TwoSourceLibrary {
        core: Arc<LexisCore>,
        root: PathBuf,
        _media: tempfile::TempDir,
        _cache: tempfile::TempDir,
        _server: crate::plex::fake::FakeServer,
    }

    fn library_with_two_sources() -> TwoSourceLibrary {
        let media = media_dir();
        let root = media.path().to_path_buf();
        let server = crate::plex::fake::library();
        let cache = tempfile::tempdir().unwrap();
        let store = Arc::new(MemStore::default());
        let core =
            LexisCore::new(cache.path().to_string_lossy().into_owned(), store.clone()).unwrap();
        core.add_or_replace(
            LocalModule.id(),
            "local1".into(),
            std::collections::BTreeMap::from([(
                "root".to_string(),
                root.to_string_lossy().into_owned(),
            )]),
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
        let first = core.scan_all(false).unwrap();
        assert_eq!(first.sources_failed, 0);
        TwoSourceLibrary {
            core,
            root,
            _media: media,
            _cache: cache,
            _server: server,
        }
    }

    #[test]
    fn only_a_scan_that_changed_the_library_says_so() {
        use crate::plex::fake::{shelf_library, Shelf, ShelfItem};
        let shelf = Arc::new(Mutex::new(Shelf {
            movie_stamp: 5000,
            show_stamp: 5000,
            movies: vec![ShelfItem::film(1, 4000)],
            ..Shelf::default()
        }));
        let server = shelf_library(shelf.clone());
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
        assert!(
            core.take_library_changed(),
            "the first scan indexed the library"
        );
        assert!(!core.take_library_changed(), "and reading it clears it");

        core.scan_all(false).unwrap();
        assert!(
            !core.take_library_changed(),
            "a sweep that found nothing says nothing"
        );

        shelf.lock().movies[0].viewed = Some(7000);
        core.scan_all(false).unwrap();
        assert!(
            core.take_library_changed(),
            "a watch on another client is a change"
        );
    }

    #[test]
    fn scan_and_list_through_the_api() {
        let media = media_dir();
        let cache = tempfile::tempdir().unwrap();
        let store = Arc::new(MemStore::default());
        let core =
            LexisCore::new(cache.path().to_string_lossy().into_owned(), store.clone()).unwrap();
        core.add_or_replace(
            LocalModule.id(),
            "local1".into(),
            std::collections::BTreeMap::from([(
                "root".to_string(),
                media.path().to_string_lossy().into_owned(),
            )]),
        )
        .unwrap();
        let report = core.scan_all(false).unwrap();
        assert_eq!(report.files_upserted, 1);
        let titles = core.list_titles(ApiMediaKind::Movie, 0, 10).unwrap();
        assert_eq!(titles.len(), 1);
        assert_eq!(titles[0].name, "Dune");
        assert_eq!(titles[0].year, Some(2021));
        assert_eq!(core.search("dun".into(), 10).unwrap().hits.len(), 1);
    }

    #[test]
    fn a_thread_panicking_under_the_index_locks_leaves_the_core_usable() {
        let media = media_dir();
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
        let held = core.clone();
        let panicked = std::thread::spawn(move || {
            let _db = held.db.lock();
            let _read_db = held.read_db.lock();
            let _configs = held.configs.lock();
            panic!("a bug while every lock is held");
        })
        .join();
        assert!(panicked.is_err());
        assert_eq!(core.scan_all(false).unwrap().files_upserted, 1);
        assert_eq!(
            core.list_titles(ApiMediaKind::Movie, 0, 10).unwrap().len(),
            1
        );
    }

    #[test]
    fn listing_sees_every_committed_scan() {
        let media = media_dir();
        let cache = tempfile::tempdir().unwrap();
        let store = Arc::new(MemStore::default());
        let core =
            LexisCore::new(cache.path().to_string_lossy().into_owned(), store.clone()).unwrap();
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
        assert_eq!(
            core.list_titles(ApiMediaKind::Movie, 0, 10).unwrap().len(),
            1
        );

        // the read connection must not be stuck on the snapshot it first saw
        fs::write(media.path().join("Movies/Alien (1979).mkv"), b"x").unwrap();
        core.scan_all(false).unwrap();
        assert_eq!(
            core.list_titles(ApiMediaKind::Movie, 0, 10).unwrap().len(),
            2
        );
        assert_eq!(core.search("alien".into(), 10).unwrap().hits.len(), 1);
    }

    #[test]
    fn one_broken_source_does_not_abort_the_others() {
        let media = media_dir();
        let cache = tempfile::tempdir().unwrap();
        let store = Arc::new(MemStore::default());
        let core =
            LexisCore::new(cache.path().to_string_lossy().into_owned(), store.clone()).unwrap();
        core.add_or_replace(
            LocalModule.id(),
            "broken".into(),
            std::collections::BTreeMap::from([(
                "root".to_string(),
                "/nonexistent/lexis-root".into(),
            )]),
        )
        .unwrap();
        core.add_or_replace(
            LocalModule.id(),
            "good".into(),
            std::collections::BTreeMap::from([(
                "root".to_string(),
                media.path().to_string_lossy().into_owned(),
            )]),
        )
        .unwrap();

        let report = core.scan_all(false).unwrap();
        assert_eq!(report.files_upserted, 1);
        assert_eq!(report.sources_failed, 1);
        assert_eq!(
            core.list_titles(ApiMediaKind::Movie, 0, 10).unwrap().len(),
            1
        );
    }

    #[test]
    fn a_source_whose_root_vanishes_after_being_indexed_keeps_every_other_sources_rows() {
        let TwoSourceLibrary {
            core,
            root,
            _media,
            _cache,
            _server,
        } = library_with_two_sources();
        let before_movies = core.list_titles(ApiMediaKind::Movie, 0, 10).unwrap().len();
        let before_shows = core.list_titles(ApiMediaKind::Show, 0, 10).unwrap().len();
        assert!(before_movies > 0 && before_shows > 0);

        // the drive backing local1 is gone; its root cannot be listed at all
        fs::remove_dir_all(&root).unwrap();

        let second = core.scan_all(false).unwrap();
        assert_eq!(second.sources_failed, 1);
        let local = second.per_source.iter().find(|s| s.id == "local1").unwrap();
        assert_eq!(local.files_removed, 0);
        assert_eq!(
            core.list_titles(ApiMediaKind::Movie, 0, 10).unwrap().len(),
            before_movies,
            "local1 failing to list must not sweep its own rows"
        );
        assert_eq!(
            core.list_titles(ApiMediaKind::Show, 0, 10).unwrap().len(),
            before_shows,
            "a source that cannot be read must not sweep a Plex source's rows either"
        );
    }

    #[test]
    fn a_source_whose_root_lists_empty_after_being_indexed_keeps_every_other_sources_rows() {
        let TwoSourceLibrary {
            core,
            root,
            _media,
            _cache,
            _server,
        } = library_with_two_sources();
        let before_movies = core.list_titles(ApiMediaKind::Movie, 0, 10).unwrap().len();
        let before_shows = core.list_titles(ApiMediaKind::Show, 0, 10).unwrap().len();
        assert!(before_movies > 0 && before_shows > 0);

        // the root directory itself is still there and still lists fine, the
        // way a mount point does once whatever was mounted on it is gone:
        // this is "I saw nothing", never mapped to a NotFound, so it must be
        // told apart from a genuine deletion some other way
        fs::remove_dir_all(root.join("Movies")).unwrap();

        let second = core.scan_all(false).unwrap();
        assert_eq!(second.sources_failed, 1);
        let local = second.per_source.iter().find(|s| s.id == "local1").unwrap();
        assert_eq!(local.files_removed, 0);
        assert_eq!(
            core.list_titles(ApiMediaKind::Movie, 0, 10).unwrap().len(),
            before_movies,
            "a root that suddenly lists empty must not sweep local1's own rows"
        );
        assert_eq!(
            core.list_titles(ApiMediaKind::Show, 0, 10).unwrap().len(),
            before_shows,
            "a root that suddenly lists empty must not sweep a Plex source's rows either"
        );
    }

    #[test]
    fn a_plex_server_that_refuses_after_being_synced_keeps_the_local_sources_rows() {
        let TwoSourceLibrary {
            core,
            _media,
            _cache,
            _server,
            ..
        } = library_with_two_sources();
        let before_movies = core.list_titles(ApiMediaKind::Movie, 0, 10).unwrap().len();
        let before_shows = core.list_titles(ApiMediaKind::Show, 0, 10).unwrap().len();
        assert!(before_movies > 0 && before_shows > 0);

        // plex1's address now points nowhere: the server refuses every request
        core.add_or_replace(
            PlexModule.id(),
            "plex1".into(),
            std::collections::BTreeMap::from([
                ("base_url".to_string(), "http://127.0.0.1:1".into()),
                ("token".to_string(), "tok".into()),
            ]),
        )
        .unwrap();

        let second = core.scan_all(false).unwrap();
        assert_eq!(second.sources_failed, 1);
        let plex = second.per_source.iter().find(|s| s.id == "plex1").unwrap();
        assert_eq!(plex.files_removed, 0);
        assert_eq!(
            core.list_titles(ApiMediaKind::Show, 0, 10).unwrap().len(),
            before_shows,
            "plex1 refusing every request must not sweep its own rows"
        );
        assert_eq!(
            core.list_titles(ApiMediaKind::Movie, 0, 10).unwrap().len(),
            before_movies,
            "a server that refuses must not sweep the local source's rows either"
        );
    }

    #[test]
    fn a_scan_where_every_source_fails_still_names_every_one_of_them() {
        let cache = tempfile::tempdir().unwrap();
        let store = Arc::new(MemStore::default());
        let core =
            LexisCore::new(cache.path().to_string_lossy().into_owned(), store.clone()).unwrap();
        core.add_or_replace(
            LocalModule.id(),
            "broken".into(),
            std::collections::BTreeMap::from([(
                "root".to_string(),
                "/nonexistent/lexis-root".into(),
            )]),
        )
        .unwrap();
        core.add_or_replace(
            LocalModule.id(),
            "alsobroken".into(),
            std::collections::BTreeMap::from([(
                "root".to_string(),
                "/nonexistent/lexis-root-2".into(),
            )]),
        )
        .unwrap();

        let report = core.scan_all(false).unwrap();
        assert_eq!(report.sources_failed, 2);
        assert_eq!(report.per_source.len(), 2);
        assert!(report.per_source.iter().all(|s| s.error.is_some()));
        for id in ["broken", "alsobroken"] {
            let row = report.per_source.iter().find(|s| s.id == id).unwrap();
            let error = row.error.as_ref().unwrap();
            assert!(!error.is_empty(), "{row:?}");
            // the row names the source; the message must not name it again
            assert!(!error.contains(id), "{row:?}");
        }
        assert_eq!(report.files_upserted, 0);

        // no sources at all is not a failure
        let empty = LexisCore::new(
            cache.path().to_string_lossy().into_owned(),
            Arc::new(MemStore::default()),
        )
        .unwrap();
        assert_eq!(empty.scan_all(false).unwrap().sources_failed, 0);
    }

    #[test]
    fn no_failure_message_ever_carries_the_token() {
        let media = media_dir();
        let cache = tempfile::tempdir().unwrap();
        let store = Arc::new(MemStore::default());
        let core =
            LexisCore::new(cache.path().to_string_lossy().into_owned(), store.clone()).unwrap();
        // nothing listens on port 1, so the sync fails on transport
        core.add_or_replace(
            PlexModule.id(),
            "plex1".into(),
            std::collections::BTreeMap::from([
                ("base_url".to_string(), "http://127.0.0.1:1".into()),
                ("token".to_string(), "s3cr3t".into()),
            ]),
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

        // the per-source error is the failure text that crosses the FFI
        let report = core.scan_all(false).unwrap();
        let plex = report.per_source.iter().find(|s| s.id == "plex1").unwrap();
        assert!(!plex.error.as_ref().unwrap().contains("s3cr3t"), "{plex:?}");
    }

    #[test]
    fn plex_and_local_sources_share_one_report() {
        use crate::plex::fake::library;

        let server = library();
        let media = media_dir();
        let cache = tempfile::tempdir().unwrap();
        let store = Arc::new(MemStore::default());
        let core =
            LexisCore::new(cache.path().to_string_lossy().into_owned(), store.clone()).unwrap();
        core.add_or_replace(
            LocalModule.id(),
            "local1".into(),
            std::collections::BTreeMap::from([(
                "root".to_string(),
                media.path().to_string_lossy().into_owned(),
            )]),
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

        let report = core.scan_all(false).unwrap();
        assert_eq!(report.files_upserted, 4); // 1 local + 3 plex
        assert_eq!(report.sources_failed, 0);
        // a synced Plex source fills its row from the sync stats, like a walked one
        let plex = report.per_source.iter().find(|s| s.id == "plex1").unwrap();
        assert_eq!(plex.files_seen, 3);
        assert_eq!(plex.files_upserted, 3);
        assert_eq!(plex.files_removed, 0);
        assert!(plex.error.is_none());
        let local = report.per_source.iter().find(|s| s.id == "local1").unwrap();
        assert_eq!(local.files_upserted, 1);
        // both sources hold Dune (2021), which is one title with two files
        let movies = core.list_titles(ApiMediaKind::Movie, 0, 10).unwrap();
        assert_eq!(movies.len(), 1);
        assert_eq!(movies[0].name, "Dune");
        assert_eq!(movies[0].file_count, 2);
        assert_eq!(
            core.list_titles(ApiMediaKind::Show, 0, 10).unwrap().len(),
            1
        );

        // a rescan of both sources rewrites every row and drops none: the
        // shared title must not lose one of its two files
        let again = core.scan_all(false).unwrap();
        assert_eq!(again.files_removed, 0);
        assert_eq!(again.files_upserted, 4);
        assert_eq!(again.sources_failed, 0);
        let movies = core.list_titles(ApiMediaKind::Movie, 0, 10).unwrap();
        assert_eq!(movies.len(), 1);
        assert_eq!(movies[0].file_count, 2);
    }

    #[test]
    fn a_rejected_token_is_flagged_on_its_own_row_and_no_other() {
        use crate::plex::fake::{FakeServer, Reply};

        let server = FakeServer::start(|_req| Reply::status(401));
        let media = media_dir();
        let cache = tempfile::tempdir().unwrap();
        let store = Arc::new(MemStore::default());
        let core =
            LexisCore::new(cache.path().to_string_lossy().into_owned(), store.clone()).unwrap();
        core.add_or_replace(
            PlexModule.id(),
            "plex1".into(),
            std::collections::BTreeMap::from([
                ("base_url".to_string(), server.base_url.clone()),
                ("token".to_string(), "stale".into()),
            ]),
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

        let report = core.scan_all(false).unwrap();
        assert_eq!(report.sources_failed, 1);
        // the app offers a new token on this row alone, so the flag must be
        // the error's variant and not "the scan failed somehow"
        let plex = report.per_source.iter().find(|s| s.id == "plex1").unwrap();
        assert!(plex.unauthorized, "{plex:?}");
        assert!(plex.error.is_some(), "{plex:?}");
        let local = report.per_source.iter().find(|s| s.id == "local1").unwrap();
        assert!(!local.unauthorized, "{local:?}");
        assert!(local.error.is_none(), "{local:?}");

        // an unreachable server is not a rejected one: retrying is the fix
        let cache2 = tempfile::tempdir().unwrap();
        let core2 = LexisCore::new(
            cache2.path().to_string_lossy().into_owned(),
            Arc::new(MemStore::default()),
        )
        .unwrap();
        core2
            .add_or_replace(
                PlexModule.id(),
                "down".into(),
                std::collections::BTreeMap::from([
                    ("base_url".to_string(), "http://127.0.0.1:1".into()),
                    ("token".to_string(), "tok".into()),
                ]),
            )
            .unwrap();
        let report = core2.scan_all(false).unwrap();
        let down = report.per_source.iter().find(|s| s.id == "down").unwrap();
        assert!(!down.unauthorized, "{down:?}");
    }

    #[test]
    fn an_unreachable_plex_server_does_not_stop_the_local_scan() {
        let media = media_dir();
        let cache = tempfile::tempdir().unwrap();
        let store = Arc::new(MemStore::default());
        let core =
            LexisCore::new(cache.path().to_string_lossy().into_owned(), store.clone()).unwrap();
        // nothing listens on port 1
        core.add_or_replace(
            PlexModule.id(),
            "plex1".into(),
            std::collections::BTreeMap::from([
                ("base_url".to_string(), "http://127.0.0.1:1".into()),
                ("token".to_string(), "tok".into()),
            ]),
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

        let report = core.scan_all(false).unwrap();
        assert_eq!(report.sources_failed, 1);
        assert_eq!(report.files_upserted, 1);
    }

    #[test]
    fn a_report_breaks_down_by_source_and_names_the_one_that_failed() {
        let media = media_dir();
        let cache = tempfile::tempdir().unwrap();
        let store = Arc::new(MemStore::default());
        let core =
            LexisCore::new(cache.path().to_string_lossy().into_owned(), store.clone()).unwrap();
        core.add_or_replace(
            LocalModule.id(),
            "good".into(),
            std::collections::BTreeMap::from([(
                "root".to_string(),
                media.path().to_string_lossy().into_owned(),
            )]),
        )
        .unwrap();
        core.add_or_replace(
            PlexModule.id(),
            "plex1".into(),
            std::collections::BTreeMap::from([
                ("base_url".to_string(), "http://127.0.0.1:1".into()),
                ("token".to_string(), "tok".into()),
            ]),
        )
        .unwrap();

        let report = core.scan_all(false).unwrap();
        assert_eq!(report.files_upserted, 1);
        assert_eq!(report.sources_failed, 1);
        assert_eq!(report.per_source.len(), 2);

        let good = &report.per_source[0];
        assert_eq!(good.id, "good");
        assert_eq!(good.files_seen, 1);
        assert_eq!(good.files_upserted, 1);
        assert_eq!(good.files_removed, 0);
        assert!(good.error.is_none());

        let bad = &report.per_source[1];
        assert_eq!(bad.id, "plex1");
        assert_eq!(bad.files_upserted, 0);
        // the id is the row's, not the message's
        assert!(!bad.error.as_ref().unwrap().contains("plex1"), "{bad:?}");
        // the aggregates still hold, so a caller that ignores per_source is fine
        assert_eq!(
            report.files_upserted,
            report
                .per_source
                .iter()
                .map(|s| s.files_upserted)
                .sum::<u32>()
        );
    }

    /// A source pointed at a server slow enough that a synchronous scan would
    /// visibly hold the caller: every request costs `delay_ms` before it
    /// answers, the way a real Plex round trip does.
    fn slow_plex_core(delay_ms: u64) -> (Arc<LexisCore>, crate::plex::fake::FakeServer) {
        use crate::plex::fake::{FakeServer, Reply, SECTIONS_JSON};
        let server = FakeServer::start(move |req| {
            std::thread::sleep(std::time::Duration::from_millis(delay_ms));
            if req.url == "/library/sections" {
                return Reply::json(SECTIONS_JSON);
            }
            Reply::json(r#"{"MediaContainer":{"size":0,"totalSize":0}}"#)
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
                ("token".to_string(), "tok".into()),
            ]),
        )
        .unwrap();
        (core, server)
    }

    #[test]
    fn a_scan_runs_on_a_thread_of_its_own_and_resolves_with_its_report() {
        let (core, _server) = slow_plex_core(200);

        let start = std::time::Instant::now();
        let scan = started(core.clone().scan(false));
        assert!(
            start.elapsed() < std::time::Duration::from_millis(100),
            "the first poll waited on the scan itself: {:?}",
            start.elapsed()
        );
        // the total is there before the thread has reached a source
        assert_eq!(core.current_scan().unwrap().sources_total, 1);

        let report = wait(scan).unwrap();
        assert_eq!(report.sources_failed, 0);
        assert!(core.current_scan().is_none());
    }

    #[test]
    fn current_scan_answers_none_while_nothing_is_running() {
        let cache = tempfile::tempdir().unwrap();
        let core = LexisCore::new(
            cache.path().to_string_lossy().into_owned(),
            Arc::new(MemStore::default()),
        )
        .unwrap();
        assert!(core.current_scan().is_none());
    }

    #[test]
    fn a_scan_nobody_waits_on_any_more_still_finishes() {
        let (core, _server) = slow_plex_core(50);
        drop(started(core.clone().scan(false)));

        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(5);
        while core.current_scan().is_some() {
            assert!(
                std::time::Instant::now() < deadline,
                "the scan never finished"
            );
            std::thread::sleep(std::time::Duration::from_millis(10));
        }
        // and the next caller starts a scan of its own rather than joining
        // the one that ended
        assert_eq!(wait(core.clone().scan(false)).unwrap().sources_failed, 0);
    }

    #[test]
    fn a_scan_asked_for_while_one_runs_waits_on_that_one() {
        let (core, server) = slow_plex_core(200);
        let first = started(core.clone().scan(false));
        let second = started(core.clone().scan(false));

        assert_eq!(wait(first).unwrap().sources_failed, 0);
        assert_eq!(wait(second).unwrap().sources_failed, 0);
        let pulls = server
            .requests()
            .iter()
            .filter(|r| r.url == "/library/sections")
            .count();
        assert_eq!(pulls, 1, "the second caller started a scan of its own");
    }

    #[test]
    fn a_full_scan_asked_for_during_a_sweep_runs_once_the_sweep_ends() {
        let (core, server) = slow_plex_core(50);
        let sweep = started(core.clone().scan(false));
        let full = started(core.clone().scan(true));

        wait(sweep).unwrap();
        wait(full).unwrap();
        let pulls = server
            .requests()
            .iter()
            .filter(|r| r.url == "/library/sections")
            .count();
        assert_eq!(pulls, 2, "the full scan owed after the sweep never ran");
    }

    #[test]
    fn a_background_scan_reports_the_same_counts_a_synchronous_one_would() {
        use crate::plex::fake::library;

        let sync_server = library();
        let cache = tempfile::tempdir().unwrap();
        let sync_core = LexisCore::new(
            cache.path().to_string_lossy().into_owned(),
            Arc::new(MemStore::default()),
        )
        .unwrap();
        sync_core
            .add_or_replace(
                PlexModule.id(),
                "plex1".into(),
                std::collections::BTreeMap::from([
                    ("base_url".to_string(), sync_server.base_url.clone()),
                    ("token".to_string(), "tok".into()),
                ]),
            )
            .unwrap();
        let synchronous = sync_core.scan_all(false).unwrap();

        let bg_server = library();
        let cache2 = tempfile::tempdir().unwrap();
        let bg_core = LexisCore::new(
            cache2.path().to_string_lossy().into_owned(),
            Arc::new(MemStore::default()),
        )
        .unwrap();
        bg_core
            .add_or_replace(
                PlexModule.id(),
                "plex1".into(),
                std::collections::BTreeMap::from([
                    ("base_url".to_string(), bg_server.base_url.clone()),
                    ("token".to_string(), "tok".into()),
                ]),
            )
            .unwrap();
        let backgrounded = wait(bg_core.clone().scan(false)).unwrap();

        assert_eq!(backgrounded.files_seen, synchronous.files_seen);
        assert_eq!(backgrounded.files_upserted, synchronous.files_upserted);
        assert_eq!(backgrounded.sources_failed, synchronous.sources_failed);
    }

    /// A flag a fake server parks its first request on, so a test can hold a
    /// scan inside one source and let it out again. The wait gives up after a
    /// while, so a test this would otherwise hang fails instead.
    #[derive(Default)]
    struct Gate {
        open: Mutex<bool>,
        opened: Condvar,
    }

    impl Gate {
        fn open(&self) {
            *self.open.lock() = true;
            self.opened.notify_all();
        }

        /// True if the gate was opened, false if the wait gave up on it.
        fn wait(&self) -> bool {
            let mut open = self.open.lock();
            while !*open {
                if self
                    .opened
                    .wait_for(&mut open, Duration::from_secs(2))
                    .timed_out()
                {
                    return *open;
                }
            }
            true
        }
    }

    /// A Plex server holding an empty library, parking its first request on
    /// `gate`: a scan that reaches this source stays inside it until the gate
    /// opens. The flag returned answers whether the gate opened or the wait
    /// gave up on it.
    fn parked_plex(gate: Arc<Gate>) -> (crate::plex::fake::FakeServer, Arc<AtomicBool>) {
        use crate::plex::fake::{FakeServer, Reply, SECTIONS_JSON};
        let let_through = Arc::new(AtomicBool::new(false));
        let flag = let_through.clone();
        let first = AtomicBool::new(true);
        let server = FakeServer::start(move |req| {
            if first.swap(false, Ordering::SeqCst) {
                flag.store(gate.wait(), Ordering::SeqCst);
            }
            if req.url == "/library/sections" {
                return Reply::json(SECTIONS_JSON);
            }
            Reply::json(r#"{"MediaContainer":{"size":0,"totalSize":0}}"#)
        });
        (server, let_through)
    }

    /// A scan takes the index one source at a time: a playback report landing
    /// while a slow source is being scanned gets in as soon as that source is
    /// through, instead of waiting out every source that follows it. Today
    /// every source is local or on the LAN; an SMB or SFTP source away on a
    /// slow mount turns the same hold into a frozen interface.
    #[test]
    fn a_playback_report_gets_at_the_index_between_two_sources() {
        let media = media_dir();
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
        // the file the report is about, indexed before the scan under test
        core.scan_all(false).unwrap();
        let movie = core.list_titles(ApiMediaKind::Movie, 0, 10).unwrap()[0].id;
        let file_id = core.read_db.lock().title_file_refs(movie).unwrap()[0].id;

        let parked = Arc::new(Gate::default());
        let reported = Arc::new(Gate::default());
        let (slow, _) = parked_plex(parked.clone());
        let (last, report_landed_first) = parked_plex(reported.clone());
        for (id, server) in [("plex-slow", &slow), ("plex-last", &last)] {
            core.add_or_replace(
                PlexModule.id(),
                id.into(),
                std::collections::BTreeMap::from([
                    ("base_url".to_string(), server.base_url.clone()),
                    ("token".to_string(), "tok".into()),
                ]),
            )
            .unwrap();
        }

        let scan = started(core.clone().scan(false));
        let deadline = std::time::Instant::now() + Duration::from_secs(5);
        while slow.requests().is_empty() {
            assert!(
                std::time::Instant::now() < deadline,
                "the scan never reached the slow source"
            );
            std::thread::sleep(Duration::from_millis(5));
        }

        let reporter = {
            let core = core.clone();
            let reported = reported.clone();
            std::thread::spawn(move || {
                let sent = core.report_playback(file_id, 30.0, 600.0, PlaybackState::Playing);
                reported.open();
                sent
            })
        };
        // long enough that the report is waiting on the index rather than
        // still on its way there
        std::thread::sleep(Duration::from_millis(100));
        parked.open();

        reporter.join().unwrap().unwrap();
        wait(scan).unwrap();
        assert!(
            report_landed_first.load(Ordering::SeqCst),
            "the report waited out the whole scan, not just the source it landed in"
        );
    }
}
