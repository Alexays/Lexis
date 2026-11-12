use crate::embed::download::ModelSource;
use crate::index::db::{Db, IndexError};
use crate::index::scan::ScanError;
use crate::source::{Source, SourceError};
use parking_lot::Mutex;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::sync::atomic::AtomicBool;
use std::sync::{Arc, OnceLock, Weak};

#[cfg(test)]
mod testing;

mod artwork;
mod ask;
mod detail;
mod duo;
mod episodes;
mod library;
mod passes;
mod rows;
mod scan;
mod shelf;
pub(crate) mod sources;
mod stats;
mod stream;
mod taste;
mod tonight;
mod verdicts;
mod watch;

use artwork::ArtworkQueue;
use passes::{ModelState, PassQueue};
use scan::RunningScan;
use sources::{LegacySourceConfig, LinkSession, SourceConfig};
use verdicts::{DismissEntry, VerdictEntry};
use watch::{QueuedWrite, WatchEntry};

const SOURCES_KEY: &str = "sources.v1";
/// This install's own id, generated once and never rotated. Presented to a
/// module's own account API that tells devices apart by it (Plex's
/// X-Plex-Client-Identifier); it names this install, not a user, and is not a
/// credential, but it still has no business in an error string.
const INSTALL_ID_KEY: &str = "install.id.v1";
/// The user's own TMDB API Read Access Token (spec: Metadata). The repo ships
/// no key of its own.
const TMDB_KEY: &str = "tmdb.key.v1";
/// Watch state for everything no Plex server owns (spec: Storage model). It is
/// the durable copy: the table in the index is a mirror a purge may take.
const WATCH_KEY: &str = "watchstate.v1";
/// Where the file currently playing parks its own record between full-list
/// writes: one entry, rewritten every report, folded into WATCH_KEY at load.
const LIVE_WATCH_KEY: &str = "watchstate.live.v1";
/// The whole host store has a 500 KB budget, shared with the source list, the
/// preferences and the queue below. Two thousand entries of about 110 bytes
/// fit, and a personal library does not resume more titles than that.
const MAX_WATCH_ENTRIES: usize = 2000;
/// The Plex writes this device still owes a server that refused them (spec:
/// Errors and degraded modes). One entry per item: what the server needs is the
/// last state, not the trail of reports that led to it.
const QUEUE_KEY: &str = "watchqueue.v1";
/// A queue this long is an offline session no viewer has: it is a bound on the
/// store's budget, not a target. Five hundred entries serialize to 77 KB at
/// their widest, beside the watch state's own 220 KB.
const MAX_QUEUE_ENTRIES: usize = 500;
/// A write nobody could deliver for a month is dropped instead of sent: other
/// clients have written to that server since, and an old position that wins
/// over them is worse than one that is lost.
const QUEUE_MAX_AGE_SECS: i64 = 30 * 24 * 3600;
/// The last scan's own answer for each source, so the pane can draw a card
/// without touching the network (spec: Instant UI). Small: one entry per
/// configured source, well inside the store's budget.
const SOURCE_STATUS_KEY: &str = "sources.status.v1";
/// The titles the viewer has taken out of the continue-watching row. Local to
/// this device and sent to nobody: it is the one piece of watch-adjacent state
/// no server owns, so the durable copy is the whole of it and the table in the
/// index is the mirror a purge may take.
const DISMISSED_KEY: &str = "resume.dismissed.v1";
/// The row itself holds twenty titles, and a dismissal stops mattering as soon
/// as the title is played again. A few hundred is years of pressing it and
/// about 25 KB of the store's 500 KB budget.
const MAX_DISMISSED: usize = 200;
/// What the viewer said about the titles they have an opinion about. Local to
/// this device and sent to nobody: Plex owns the watch history, and this is
/// the opinion about it, which is not the same thing and is not theirs to
/// carry. The durable copy is the whole of it and the index table is the
/// mirror a purge may take.
const VERDICTS_KEY: &str = "verdicts.v1";
/// Unlike a dismissal, a verdict is meant to last: nothing wears it off, so
/// the list only grows. Five hundred is more titles than a personal library
/// gets an opinion on and about 60 KB of the store's 500 KB budget; past it
/// the oldest opinion goes, which is the one whose title the viewer is least
/// likely to be shown again anyway.
const MAX_VERDICTS: usize = 500;

#[derive(Serialize, Deserialize, Clone, Default)]
struct SourceStatus {
    last_scan: i64,
    last_error: Option<String>,
}

/// The five things the UI does differently. Anything finer belongs in `msg`.
///
/// A message never names the source: `source_id` is a field of the variant, and
/// every consumer already knows which source it asked about, so a message that
/// repeated it would be printed next to the id twice.
///
/// One id names no configured source: "tmdb", raised by `enrich_pending`, by
/// `fetch_similar` and by the TMDB arm of `poster_file`. It never appears in
/// `list_sources`, so a consumer must special-case it: an `Unauthorized` on it
/// asks for a new TMDB key, not a new source token.
#[derive(Debug, Clone, thiserror::Error, uniffi::Error)]
pub enum CoreError {
    #[error("storage error: {msg}")]
    Storage { msg: String },
    #[error("{msg}")]
    SourceUnavailable { source_id: String, msg: String },
    #[error("invalid configuration: {msg}")]
    InvalidConfig { msg: String },
    #[error("the credentials were rejected")]
    Unauthorized { source_id: String },
    /// The pinned embedding model is on this device as something that is not
    /// it, and asking again gives the same answer: a mispasted digest, a host
    /// serving something else, or a cached file that will not read. The rows
    /// work without vectors, so a caller ends the pass on this rather than
    /// retrying it, and keeps the message where it can be read.
    #[error("the embedding model is unusable: {msg}")]
    EmbedModelUnusable { msg: String },
    /// An id that names nothing any more: a title or file a rescan replaced.
    #[error("{msg}")]
    NotFound { msg: String },
    /// The index on disk was written by a newer build. It is left untouched
    /// for that build, so the caller opens a cache directory of its own.
    #[error("{msg}")]
    SchemaTooNew { msg: String },
}

impl From<IndexError> for CoreError {
    fn from(e: IndexError) -> Self {
        match e {
            IndexError::SchemaTooNew { .. } => CoreError::SchemaTooNew { msg: e.to_string() },
            IndexError::Sqlite(_) => CoreError::Storage { msg: e.to_string() },
        }
    }
}

/// A failure from anything a `Source` or `WatchSync` returned. Never inspects
/// which module produced it.
fn source_error(source_id: &str, e: SourceError) -> CoreError {
    match e {
        // a rejected credential needs a new one, not a retry
        SourceError::Unauthorized => CoreError::Unauthorized {
            source_id: source_id.to_string(),
        },
        e => CoreError::SourceUnavailable {
            source_id: source_id.to_string(),
            msg: e.to_string(),
        },
    }
}

/// A scan failure carries no source id of its own; the caller is the only one
/// that knows which source it was scanning.
fn scan_error(source_id: &str, e: ScanError) -> CoreError {
    match e {
        ScanError::Index(e) => CoreError::Storage { msg: e.to_string() },
        ScanError::Source(e) => source_error(source_id, e),
    }
}

/// Runs `work` on a thread of its own and resolves with what it returns, so
/// an async export never holds the foreign caller on the index or the
/// network. A panic in `work` re-raises here, where UniFFI hands it to the
/// caller as an unexpected error.
async fn on_thread<T: Send + 'static>(work: impl FnOnce() -> T + Send + 'static) -> T {
    let (tx, rx) = futures_channel::oneshot::channel();
    std::thread::spawn(move || {
        // a waiter that went away drops the answer, and with it whatever the
        // answer owns
        let _ = tx.send(work());
    });
    rx.await.expect("the worker thread panicked")
}

/// Unix seconds, or 0 on a clock set before 1970. Every stored timestamp goes
/// through here so a test can reason about one shape of "now".
fn unix_now() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}

/// The durable store: UserDefaults on tvOS (spec: Storage model). `set` returns
/// nothing on purpose, because UserDefaults has no failure signal to report; a
/// host that can fail must retry or drop the write itself.
///
/// There is no `remove`: an empty value means absent, and the core reads one
/// back that way, so a host with no "absent" answer of its own may report an
/// empty value as `None` too.
#[uniffi::export(with_foreign)]
pub trait HostStore: Send + Sync {
    fn get(&self, key: String) -> Option<Vec<u8>>;
    fn set(&self, key: String, value: Vec<u8>);
}

#[derive(uniffi::Object)]
pub struct LexisCore {
    store: Arc<dyn HostStore>,
    /// Artwork lives beside the index, and is as disposable as it is.
    cache_dir: PathBuf,
    db: Mutex<Db>,
    /// Browsing must stay responsive while a scan holds the write connection.
    read_db: Mutex<Db>,
    /// A second readonly connection for the big lots - `home_rows`, shelf
    /// snapshots, anything that issues a dozen queries per call. Interactive
    /// short reads keep the first one and never queue behind a long lot.
    heavy_db: Mutex<Db>,
    configs: Mutex<Vec<SourceConfig>>,
    /// The durable copy of the watch state, mirrored into the index.
    watch: Mutex<Vec<WatchEntry>>,
    /// What a Plex server refused, waiting for it to come back.
    queue: Mutex<Vec<QueuedWrite>>,
    /// The titles taken out of the continue-watching row. No server owns this,
    /// so the copy here is the original and the index table is the mirror.
    dismissed: Mutex<Vec<DismissEntry>>,
    /// What the viewer said about the titles they have an opinion about. No
    /// server owns this either, and this one is never sent anywhere at all.
    verdicts: Mutex<Vec<VerdictEntry>>,
    /// The last scan's own answer for each source (spec: `SOURCE_STATUS_KEY`).
    status: Mutex<HashMap<String, SourceStatus>>,
    /// One built `Source` per configured source, kept for whatever connection
    /// pooling its module wants: a report every few seconds must not
    /// reconnect every time. Dropped whenever the source list changes.
    built_sources: Mutex<HashMap<String, Arc<dyn Source>>>,
    /// The titles waiting for an image, and what the thread fetching them
    /// found: `poster_now` reads this instead of the network.
    artwork: ArtworkQueue,
    /// Which titles a trailer is being asked TMDB about: `trailer_now` reads
    /// this rather than the network, the same way `poster_now` reads the one
    /// above.
    trailers: Mutex<artwork::TrailerWork>,
    /// The one agent every TMDB image goes through. An agent per fetch is a
    /// connection per fetch, and a connection to that CDN is a TLS handshake.
    tmdb_art_agent: OnceLock<ureq::Agent>,
    /// The same for the TMDB API itself, which the describe and link passes
    /// call a batch of titles at a time: a client per batch threw the pool
    /// away with it and reconnected for the next twenty.
    tmdb_api_agent: OnceLock<ureq::Agent>,
    /// How far the background pass has got, and the thread running it:
    /// `pass_now` reads this instead of running a batch.
    passes: PassQueue,
    /// The network half of playback writebacks, drained by one worker so a
    /// slow or away Plex server cannot hold the caller that reports every few
    /// seconds of a film.
    writeback: watch::WritebackMailbox,
    /// The taste recompute, off the verdict press and off the pass thread.
    taste_refresh: taste::TasteWorker,
    /// What the app last said about the weather, and when. Kept in memory
    /// only: it is stale in hours, and a restart asks the sky again.
    ambient: Mutex<Option<(crate::index::tonight::Ambient, i64)>>,
    /// Outcome per settled writeback job, keyed like the queue. None is the
    /// server taking it; Some carries the source and what it said. Read back
    /// by `mark_watched`, whose contract is an answer, and by tests.
    writeback_outcomes: Mutex<HashMap<String, Option<(String, watch::MarkFailure)>>>,
    /// The embedding model, once the first batch has decided what it is; None
    /// until then.
    model: Mutex<Option<ModelState>>,
    /// The vectors the semantic sweep measures its seeds against, centred once
    /// and kept for as long as the vector table stands still. Reading and
    /// centring the library costs more than a batch of seeds does, and every
    /// seed in the sweep wants the same answer.
    semantic_library: Mutex<Option<crate::embed::pass::Library>>,
    /// When the last question asked in words used the encoder, while a
    /// thread waits to let it go (see `ask_model`).
    ask_used: Mutex<Option<std::time::Instant>>,
    /// What the guest said on the duo's deck when no guest was chosen: kept
    /// for the session only, and forgotten when the next deck is dealt.
    duo_votes: Mutex<HashMap<i64, bool>>,
    /// Where the encoder's two files are fetched from and the digests that
    /// pin them: the upstream defaults, except in the tests, which must reach
    /// a server of their own rather than Hugging Face.
    model_source: Mutex<ModelSource>,
    /// Where the metadata passes ask about a title: API_BASE, except in the
    /// tests, which must reach a server of their own rather than TMDB.
    tmdb_base: Mutex<String>,
    /// Where TheIntroDB is asked, the same way.
    introdb_base: Mutex<String>,
    /// What `skip_marks` found for each file this process asked about.
    skip_marks: Mutex<HashMap<i64, Vec<episodes::SkipMark>>>,
    /// The titles whose Plex server was asked for faces this launch.
    faces_asked: Mutex<HashSet<i64>>,
    /// One link in progress, keyed by an opaque handle. Removed once
    /// `add_from_choice` stores the source, or by `link_cancel` when the
    /// viewer backs out first: either way the account token a session holds
    /// stops existing here rather than sitting until the process ends.
    link_sessions: Mutex<HashMap<String, LinkSession>>,
    link_seq: Mutex<u64>,
    /// The playback brake for scans, the same contract as the pass and
    /// artwork pauses: set from the app when a film starts, consulted between
    /// sources and between pages. A field of its own rather than part of a
    /// running scan so it can be set before, during or after one.
    scan_paused: crate::source::Pause,
    /// The scan running right now, if any. Two scans would write the same
    /// rows at once, so at most one ever runs: a caller of `scan` while one
    /// is going waits on that one. `current_scan` reads its progress here.
    running_scan: Mutex<Option<RunningScan>>,
    /// Whether a scan has changed the library since `take_library_changed`
    /// last read it.
    library_changed: AtomicBool,
    /// Whether `keep_sources_warm` already has its thread running, so that
    /// calling it again costs nothing and never starts a second one.
    warming: AtomicBool,
    /// Whether the week's trending is being asked TMDB about, so a second
    /// `start_pass` meanwhile starts no second fetch.
    trending: AtomicBool,
    /// This instance's own strong handle, recovered by a method whose
    /// background thread must keep the core alive for as long as it runs,
    /// whether or not the caller keeps its own reference around. Set once, by
    /// `new`, and never rewritten.
    self_ref: Weak<LexisCore>,
    /// This install's id (spec: `INSTALL_ID_KEY`). Read once at construction
    /// and never rewritten, so every plex.tv call in the process's life
    /// presents the same identity.
    install_id: String,
}

/// A fresh install id: the wall clock at nanosecond resolution, this
/// process's id, and the address of a stack variable (which moves with each
/// process's own ASLR base) hashed together, so no one of the three weak
/// inputs has to carry the whole id's uniqueness on its own. Called once per
/// install, ever, so this is the only place that needs the entropy at all.
fn fresh_install_id() -> String {
    let mut hasher = Sha256::new();
    hasher.update(
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap_or_default()
            .as_nanos()
            .to_le_bytes(),
    );
    hasher.update(std::process::id().to_le_bytes());
    let marker = 0u8;
    hasher.update((&marker as *const u8 as usize).to_le_bytes());
    hasher
        .finalize()
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect()
}

/// The JSON value the host store holds under `key`, or the default when it
/// holds none or one nothing can read.
fn load_json<T: serde::de::DeserializeOwned + Default>(store: &dyn HostStore, key: &str) -> T {
    store
        .get(key.to_string())
        .and_then(|bytes| serde_json::from_slice(&bytes).ok())
        .unwrap_or_default()
}

#[uniffi::export]
impl LexisCore {
    #[uniffi::constructor]
    pub fn new(cache_dir: String, store: Arc<dyn HostStore>) -> Result<Arc<Self>, CoreError> {
        // a tvOS cache purge removes the directory itself, not just its contents
        std::fs::create_dir_all(&cache_dir)
            .map_err(|e| CoreError::Storage { msg: e.to_string() })?;
        let db_path = Path::new(&cache_dir).join("index.sqlite");
        let db = Db::open(&db_path)?;
        // nothing pinned is the feature withdrawn as much as never shipped: the
        // links an installed model left would otherwise drive the rows for good,
        // since the pass that replaces them never runs again. Here rather than
        // in the pass, because the first home screen is drawn before the pass
        // reaches its vectors.
        if !ModelSource::default().is_pinned() {
            db.clear_semantic()?;
        }
        let encoder = crate::embed::Encoder::chosen(&db)?;
        // opened second: the writable open is what creates the file and schema
        let read_db = Db::open_read_only(&db_path)?;
        let heavy_db = Db::open_read_only(&db_path)?;
        // an unreadable value must not read as "no sources": the next
        // add_source would overwrite it and lose the user's setup
        let configs: Vec<SourceConfig> = match store.get(SOURCES_KEY.to_string()) {
            Some(bytes) => {
                let configs = serde_json::from_slice::<Vec<SourceConfig>>(&bytes)
                    .or_else(|_| {
                        serde_json::from_slice::<Vec<LegacySourceConfig>>(&bytes)
                            .map(|old| old.into_iter().map(SourceConfig::from).collect())
                    })
                    .map_err(|e| CoreError::InvalidConfig {
                        msg: format!(
                            "the stored source list is unreadable ({e}); reset_sources clears it"
                        ),
                    })?;
                for c in &configs {
                    if crate::source::module(&c.module).is_none() {
                        return Err(CoreError::InvalidConfig {
                            msg: format!(
                                "the source \"{}\" names a module this build does not have: \"{}\"",
                                c.id, c.module
                            ),
                        });
                    }
                }
                configs
            }
            None => Vec::new(),
        };
        // watch state must never keep the app from starting: an unreadable
        // value costs one history, not a library, and the next write replaces
        // it. The source list is the opposite case, and fails loudly above.
        let mut watch: Vec<WatchEntry> = load_json(store.as_ref(), WATCH_KEY);
        watch::take_live_watch(store.as_ref(), &mut watch);
        // same rule as the watch state: a payload nothing can read costs the
        // writes it held, never the launch
        let queue: Vec<QueuedWrite> = load_json(store.as_ref(), QUEUE_KEY);
        // same rule again: an unreadable list costs the presses it held, and
        // the row offers those titles once more rather than the app refusing
        // to start
        let dismissed: Vec<DismissEntry> = load_json(store.as_ref(), DISMISSED_KEY);
        // same rule again, and here it costs the most: an unreadable list is
        // every opinion the viewer ever stated. It still must not stop the app
        // starting, and the row it feeds works without it.
        let verdicts: Vec<VerdictEntry> = load_json(store.as_ref(), VERDICTS_KEY);
        // same rule again: an unreadable status costs the status, never the launch
        let status: HashMap<String, SourceStatus> = load_json(store.as_ref(), SOURCE_STATUS_KEY);
        // generated once, ever: every later launch reads the same value back
        // instead of taking this branch again
        let install_id = match store
            .get(INSTALL_ID_KEY.to_string())
            .and_then(|bytes| String::from_utf8(bytes).ok())
            .filter(|s| !s.is_empty())
        {
            Some(id) => id,
            None => {
                let id = fresh_install_id();
                store.set(INSTALL_ID_KEY.to_string(), id.as_bytes().to_vec());
                id
            }
        };
        Ok(Arc::new_cyclic(|weak| Self {
            store,
            cache_dir: PathBuf::from(&cache_dir),
            db: Mutex::new(db),
            read_db: Mutex::new(read_db),
            heavy_db: Mutex::new(heavy_db),
            configs: Mutex::new(configs),
            watch: Mutex::new(watch),
            queue: Mutex::new(queue),
            dismissed: Mutex::new(dismissed),
            verdicts: Mutex::new(verdicts),
            status: Mutex::new(status),
            built_sources: Mutex::new(HashMap::new()),
            artwork: ArtworkQueue::new(Path::new(&cache_dir).join("artwork")),
            trailers: Mutex::default(),
            tmdb_art_agent: OnceLock::new(),
            tmdb_api_agent: OnceLock::new(),
            passes: PassQueue::default(),
            model: Mutex::new(None),
            semantic_library: Mutex::new(None),
            ask_used: Mutex::new(None),
            duo_votes: Mutex::new(HashMap::new()),
            // a test core never reaches Hugging Face, from any thread it leaves
            #[cfg(test)]
            model_source: Mutex::new(encoder.source().offline()),
            #[cfg(not(test))]
            model_source: Mutex::new(encoder.source()),
            tmdb_base: Mutex::new(crate::metadata::client::API_BASE.to_string()),
            introdb_base: Mutex::new(crate::metadata::introdb::API_BASE.to_string()),
            skip_marks: Mutex::new(HashMap::new()),
            faces_asked: Mutex::new(HashSet::new()),
            link_sessions: Mutex::new(HashMap::new()),
            link_seq: Mutex::new(0),
            scan_paused: crate::source::Pause::new(),
            running_scan: Mutex::new(None),
            library_changed: AtomicBool::new(false),
            warming: AtomicBool::new(false),
            trending: AtomicBool::new(false),
            writeback: watch::WritebackMailbox::default(),
            taste_refresh: taste::TasteWorker::default(),
            ambient: Mutex::new(None),
            writeback_outcomes: Mutex::new(HashMap::new()),
            self_ref: weak.clone(),
            install_id,
        }))
    }
}

#[cfg(test)]
mod tests {
    use super::testing::*;
    use super::*;

    #[test]
    fn the_install_id_is_generated_once_and_survives_a_relaunch() {
        let cache = tempfile::tempdir().unwrap();
        let store = Arc::new(MemStore::default());
        let core =
            LexisCore::new(cache.path().to_string_lossy().into_owned(), store.clone()).unwrap();
        let id = core.install_id.clone();
        assert!(!id.is_empty());
        assert!(id.is_ascii());
        drop(core);

        // a cache purge does not touch the host store: the same id comes back
        let purged = tempfile::tempdir().unwrap();
        let relaunched =
            LexisCore::new(purged.path().to_string_lossy().into_owned(), store).unwrap();
        assert_eq!(relaunched.install_id, id);

        // a different install never lands on the same id, or plex.tv would
        // still see the two as one device
        let other = Arc::new(MemStore::default());
        let elsewhere = tempfile::tempdir().unwrap();
        let other_install =
            LexisCore::new(elsewhere.path().to_string_lossy().into_owned(), other).unwrap();
        assert_ne!(other_install.install_id, id);
    }

    #[test]
    fn failures_map_onto_the_error_the_app_can_act_on() {
        use crate::index::db::IndexError;
        use crate::index::scan::ScanError;
        use crate::source::SourceError;

        let storage = ScanError::Index(IndexError::Sqlite(rusqlite::Error::QueryReturnedNoRows));
        assert!(matches!(
            scan_error("local1", storage),
            CoreError::Storage { .. }
        ));
        let unavailable = scan_error(
            "local1",
            ScanError::Source(SourceError::NotFound("x".into())),
        );
        assert!(matches!(
            &unavailable,
            CoreError::SourceUnavailable { source_id, .. } if source_id == "local1"
        ));
        // the id is a field, not part of the message: whoever prints the
        // message has the id already and would print it twice
        assert!(!unavailable.to_string().contains("local1"), "{unavailable}");
        // a rejected credential is not "try again later": the UI must ask the
        // user for a new one, so it never shares a case with unavailability
        assert!(matches!(
            scan_error("local1", ScanError::Source(SourceError::Unauthorized)),
            CoreError::Unauthorized { source_id } if source_id == "local1"
        ));

        // scan_error and source_error agree: a catalogue source's pull and a
        // directory walk both fail through the same SourceError
        assert!(matches!(
            source_error("plex1", SourceError::Unauthorized),
            CoreError::Unauthorized { source_id } if source_id == "plex1"
        ));
        assert!(matches!(
            source_error("plex1", SourceError::Io(std::io::Error::other("down"))),
            CoreError::SourceUnavailable { .. }
        ));
        let empty = source_error(
            "plex1",
            SourceError::Refused("the plex library came back empty".to_string()),
        );
        assert!(matches!(empty, CoreError::SourceUnavailable { .. }));
        assert!(empty.to_string().contains("empty"), "{empty}");
    }
}
