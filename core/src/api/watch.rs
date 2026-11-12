use super::{
    unix_now, CoreError, HostStore, LexisCore, LIVE_WATCH_KEY, MAX_QUEUE_ENTRIES,
    MAX_WATCH_ENTRIES, QUEUE_KEY, QUEUE_MAX_AGE_SECS, WATCH_KEY,
};
use crate::index::db::{in_progress, FileRef, WatchAuthority, WatchRecord};
use crate::source::{PlaybackState, Source, SourceError, WatchSync};
use parking_lot::Mutex;
use serde::{Deserialize, Serialize};
use std::collections::VecDeque;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Arc, Weak};
use std::time::Duration;

/// One file's watch state as the durable copy stores it. Keyed by source and
/// path, never by file id: a purge rebuilds the index and hands out new ids,
/// while the same scan finds the same paths. The field names are short because
/// every byte counts against the store's budget.
#[derive(Serialize, Deserialize, Clone, Debug)]
pub(super) struct WatchEntry {
    s: String,
    p: String,
    #[serde(default)]
    pos: f64,
    #[serde(default)]
    dur: f64,
    #[serde(default)]
    w: bool,
    /// How many times the file was played through. Absent from entries an
    /// older build wrote, which the migration already credited on the row.
    #[serde(default)]
    n: u32,
    t: i64,
}

/// One Plex writeback the server has not taken yet. Keyed by source and
/// ratingKey, the item the write is about; `p` is the part path that names the
/// file row in the index, so the local truth can be put back after a sync
/// mirrors older server state over it.
///
/// `pos` absent is an entry that carries no position: `mark_watched` knows
/// none. `w` absent is an entry that owes no flag: a plain position report.
/// The field names are short because every byte counts against the budget.
///
/// `wl` is which of the two happened last, and is set only while the entry owes
/// both: true is a flag raised after the position, false a position reported
/// after the flag. The drain sends the older one first, because a scrobble
/// clears the offset a timeline set and a timeline after a scrobble sets it
/// back, which is what the online path would have left on the server. `enqueue`
/// owns it: a write handed in carries `wl: None` and is told its order there.
#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
pub(super) struct QueuedWrite {
    s: String,
    k: String,
    p: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pos: Option<f64>,
    #[serde(default)]
    dur: f64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    w: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    wl: Option<bool>,
    t: i64,
}

/// Whether a refused write is worth keeping until the server comes back. A
/// transport failure and a rejected credential are the server, or the user's
/// access to it, being away; a refusal the server understood and meant (an
/// item it no longer has, a malformed request) fails the same way forever,
/// and queueing it would only delay the same error.
fn is_queueable(e: &SourceError) -> bool {
    matches!(e, SourceError::Io(_) | SourceError::Unauthorized)
}

/// One server round trip the reporting thread does not want to wait out.
/// The source comes resolved (`writeback_target`, DB reads only), so the
/// worker touches no index lock on its way to the network.
pub(super) enum WritebackJob {
    Position {
        source: Arc<dyn Source>,
        rating_key: String,
        path: String,
        pos: f64,
        dur: f64,
        state: PlaybackState,
        finished_now: bool,
    },
    Watched {
        source: Arc<dyn Source>,
        rating_key: String,
        path: String,
        watched: bool,
    },
}

/// Why a hand-set flag failed, kept in a form the outcome map can hold:
/// `SourceError` is neither `Clone` nor `Send`-trivial, and the distinction
/// matters to the caller (a rejected credential wants a new token, not a
/// retry).
#[derive(Clone, Debug)]
pub(super) enum MarkFailure {
    Unauthorized,
    Server(String),
}

/// The FIFO of outstanding writebacks and the one thread draining it. Jobs
/// keep server order: two reports pushed back to back reach Plex in the order
/// they were made. The worker stands down after a short idle and a later job
/// restarts it, the way the warming thread comes and goes with the core.
#[derive(Default)]
pub(super) struct WritebackMailbox {
    jobs: Mutex<VecDeque<WritebackJob>>,
    /// True while a worker thread is alive. Flipped under the jobs lock when
    /// it stands down, so a producer either sees it true or spawns a fresh
    /// worker itself; no job can be lost in between.
    running: AtomicBool,
    /// Jobs handed over but not yet settled: `wait_for_writeback_idle` spins
    /// on this, which only tests ever do.
    pending: AtomicUsize,
}

/// How long `mark_watched` lets the worker settle a season before answering
/// with whatever came back. Unbounded before; bounded now because the caller
/// is a screen showing a spinner, and a server that owes thirty round trips
/// answers most of them well inside this.
const MARK_WATCHED_WAIT: Duration = Duration::from_secs(120);

fn mark_outcome_key(source_id: &str, rating_key: &str) -> String {
    format!("{source_id}/{rating_key}")
}

/// The network half of a writeback, run on the mailbox worker. Mirrors the
/// online path that used to sit inline in `report_playback` and
/// `mark_watched`: send, supersede what the server just took, queue what it
/// refused and might take later.
fn run_writeback(core: &LexisCore, job: WritebackJob) {
    match job {
        WritebackJob::Position {
            source,
            rating_key,
            path,
            pos,
            dur,
            state,
            finished_now,
        } => {
            let ws = source.watch_sync().unwrap();
            let sent = ws.timeline(&rating_key, state, pos, dur).and_then(|()| {
                // scrobbling marks the item played and clears the offset the
                // timeline above just set, so it goes out on the report that
                // finishes the file and on no other
                if finished_now {
                    ws.scrobble(&rating_key)
                } else {
                    Ok(())
                }
            });
            match sent {
                // the server is here and it may have missed writes while it
                // was not: this is the cheapest moment to find out
                Ok(()) => {
                    core.supersede_queued(source.id(), &rating_key);
                    core.drain_queue(source.id(), unix_now());
                    core.writeback_outcomes
                        .lock()
                        .insert(mark_outcome_key(source.id(), &rating_key), None);
                }
                Err(e) => {
                    if is_queueable(&e) {
                        core.enqueue(QueuedWrite {
                            s: source.id().to_string(),
                            k: rating_key.clone(),
                            p: path,
                            pos: Some(pos),
                            dur,
                            // the flag rides along on the report that
                            // finished the file and on no other, exactly as
                            // it does above: a scrobble clears the offset
                            // the timeline just sent
                            w: if finished_now { Some(true) } else { None },
                            wl: None,
                            t: unix_now(),
                        });
                    }
                    let failure = match e {
                        SourceError::Unauthorized => MarkFailure::Unauthorized,
                        e => MarkFailure::Server(e.to_string()),
                    };
                    core.writeback_outcomes.lock().insert(
                        mark_outcome_key(source.id(), &rating_key),
                        Some((source.id().to_string(), failure)),
                    );
                }
            }
        }
        WritebackJob::Watched {
            source,
            rating_key,
            path,
            watched,
        } => {
            let ws = source.watch_sync().unwrap();
            let sent = if watched {
                ws.scrobble(&rating_key)
            } else {
                ws.unscrobble(&rating_key)
            };
            let key = mark_outcome_key(source.id(), &rating_key);
            match sent {
                Err(e) => {
                    // one episode the server refused must not leave the rest
                    // of a season unwritten
                    if is_queueable(&e) {
                        core.enqueue(QueuedWrite {
                            s: source.id().to_string(),
                            k: rating_key,
                            p: path,
                            // by hand, with no position and no runtime: the
                            // flag is the whole intent
                            pos: None,
                            dur: 0.0,
                            w: Some(watched),
                            wl: None,
                            t: unix_now(),
                        });
                    }
                    let failure = match e {
                        SourceError::Unauthorized => MarkFailure::Unauthorized,
                        e => MarkFailure::Server(e.to_string()),
                    };
                    core.writeback_outcomes
                        .lock()
                        .insert(key, Some((source.id().to_string(), failure)));
                }
                Ok(()) => {
                    // this call zeroed the position and the server took the
                    // flag, so anything queued for the item is older than
                    // what it now holds
                    core.supersede_queued(source.id(), &rating_key);
                    core.writeback_outcomes.lock().insert(key, None);
                }
            }
        }
    }
}

/// Drains the mailbox until it runs dry, then stands down. Woken by nothing:
/// a 50 ms poll costs nothing next to the seconds each job spends on the
/// network, and a condvar protocol would buy latency nobody asked for.
fn writeback_worker(core: Weak<LexisCore>) {
    const IDLE_ROUNDS_BEFORE_STANDDOWN: u32 = 4;
    let mut idle_rounds: u32 = 0;
    loop {
        let Some(core) = core.upgrade() else {
            return;
        };
        let job = core.writeback.jobs.lock().pop_front();
        match job {
            Some(job) => {
                idle_rounds = 0;
                run_writeback(&core, job);
                core.writeback.pending.fetch_sub(1, Ordering::SeqCst);
            }
            None => {
                idle_rounds += 1;
                if idle_rounds < IDLE_ROUNDS_BEFORE_STANDDOWN {
                    drop(core);
                    std::thread::sleep(Duration::from_millis(50));
                    continue;
                }
                // still empty under the lock, so no producer can be mid-push:
                // flipping running here is race-free against spawn decisions
                let jobs = core.writeback.jobs.lock();
                if jobs.front().is_some() {
                    idle_rounds = 0;
                    continue;
                }
                core.writeback
                    .running
                    .store(false, std::sync::atomic::Ordering::SeqCst);
                return;
            }
        }
    }
}

/// Folds a pending live record into the durable list at load and pays for one
/// whole-list write now, so the process never carries two copies of the truth.
/// An unreadable record costs its one position, same rule as every other
/// stored payload: cleared, never a failed launch.
pub(super) fn take_live_watch(store: &dyn HostStore, watch: &mut Vec<WatchEntry>) {
    let Some(bytes) = store
        .get(LIVE_WATCH_KEY.to_string())
        .filter(|bytes| !bytes.is_empty())
    else {
        return;
    };
    match serde_json::from_slice::<WatchEntry>(&bytes) {
        Ok(entry) => {
            match watch.iter_mut().find(|e| e.s == entry.s && e.p == entry.p) {
                Some(slot) => *slot = entry,
                None => watch.push(entry),
            }
            // left alone on a serialize failure: both keys stay, and the next
            // launch retries the fold instead of losing the position
            if let Ok(bytes) = serde_json::to_vec(&*watch) {
                store.set(WATCH_KEY.to_string(), bytes);
                store.set(LIVE_WATCH_KEY.to_string(), Vec::new());
            }
        }
        Err(_) => store.set(LIVE_WATCH_KEY.to_string(), Vec::new()),
    }
}

#[uniffi::export]
impl LexisCore {
    /// Records where playback got to. The app calls this every few seconds and
    /// once more when the player goes away.
    ///
    /// The state is written twice: into the index, which the home rows are
    /// queried from, and to whoever owns it durably. For a Plex file that is
    /// the Plex server, so other Plex clients resume at the same point (spec:
    /// Storage model); for anything else it is the host store, which survives a
    /// cache purge. A server that refuses the write fails *after* the local row
    /// is written: the position is not lost, and the caller may say that
    /// history is not syncing.
    pub fn report_playback(
        &self,
        file_id: i64,
        position_secs: f64,
        duration_secs: f64,
        state: PlaybackState,
    ) -> Result<(), CoreError> {
        if !position_secs.is_finite()
            || position_secs < 0.0
            || !duration_secs.is_finite()
            || duration_secs < 0.0
        {
            return Err(CoreError::InvalidConfig {
                msg: "a playback position is a positive number of seconds".to_string(),
            });
        }
        let file = {
            let db = self.read_db.lock();
            db.file_ref(file_id)?
        };
        let Some(file) = file else {
            return Err(CoreError::NotFound {
                msg: format!("no file with id {file_id} in the index"),
            });
        };
        let now = unix_now();
        let (watched, plays, finished_now, crossed) = {
            let db = self.db.lock();
            let before = db.watch_state(file_id)?;
            let was_watched = before.as_ref().is_some_and(|w| w.watched);
            let was_plays = before.map_or(0, |w| w.plays);
            db.upsert_watch_state(
                &WatchRecord {
                    file_id,
                    position_secs,
                    duration_secs,
                    watched: false,
                    // the write counts the crossing; a report asserts nothing
                    plays: 0,
                    updated_at: now,
                },
                WatchAuthority::Report,
            )?;
            // the 90% rule lives in the write itself, so this reads back what
            // was stored instead of deciding the same thing a second time
            let row = db.watch_state(file_id)?;
            let watched = row.as_ref().is_some_and(|w| w.watched);
            let plays = row.map_or(0, |w| w.plays);
            (watched, plays, watched && !was_watched, plays > was_plays)
        };
        // a play through to the credits is the strongest thing the taste
        // hears, a rewatch included, and the home should have heard it by the
        // time the viewer is back on it
        if crossed {
            self.kick_taste_refresh();
        }
        // The local truth is durable above. The server round trip belongs to
        // the writeback worker: a Plex server away or slow would otherwise
        // hold the caller, every few seconds of a film, for its whole connect
        // and read timeout.
        match self.writeback_target(&file) {
            Some((source, rating_key)) => {
                self.enqueue_writeback(WritebackJob::Position {
                    source,
                    rating_key,
                    path: file.path,
                    pos: position_secs,
                    dur: duration_secs,
                    state,
                    finished_now,
                });
                Ok(())
            }
            None => self.store_watch(&[WatchEntry {
                s: file.source_id,
                p: file.path,
                pos: position_secs,
                dur: duration_secs,
                w: watched,
                n: plays,
                t: now,
            }]),
        }
    }

    /// Marks every file of a title watched, or unwatched, by hand. The position
    /// goes back to zero either way: a title marked watched leaves the resume
    /// row, and one marked unwatched starts over.
    pub fn mark_watched(&self, title_id: i64, watched: bool) -> Result<(), CoreError> {
        let files = {
            let db = self.read_db.lock();
            db.title_file_refs(title_id)?
        };
        self.mark_files_watched(&files, watched)
    }

    /// Marks these episodes watched, or unwatched, by hand: the one a row was
    /// held on, or every one up to it. As for a title, the position goes back
    /// to zero either way. An id the index no longer has is passed over.
    pub fn mark_episodes_watched(
        &self,
        file_ids: Vec<i64>,
        watched: bool,
    ) -> Result<(), CoreError> {
        let files = {
            let db = self.read_db.lock();
            let mut files = Vec::with_capacity(file_ids.len());
            for id in file_ids {
                if let Some(file) = db.file_ref(id)? {
                    files.push(file);
                }
            }
            files
        };
        self.mark_files_watched(&files, watched)
    }

    /// How many Plex writes are waiting for a server to come back. Settings
    /// shows it; zero is the normal state.
    pub fn queued_writes(&self) -> u32 {
        self.queue.lock().len() as u32
    }
}

impl LexisCore {
    /// The writes behind a hand-marked title or episodes: each file's state,
    /// then its server or the local store, and the first failure the servers
    /// answered with.
    fn mark_files_watched(&self, files: &[FileRef], watched: bool) -> Result<(), CoreError> {
        let now = unix_now();
        // set_watched leaves the count alone, so it is read back beside the
        // write rather than under a lock taken again per file
        let plays = {
            let db = self.db.lock();
            let mut plays = Vec::with_capacity(files.len());
            for file in files {
                db.set_watched(file.id, watched, now)?;
                plays.push(db.watch_state(file.id)?.map_or(0, |w| w.plays));
            }
            plays
        };
        let mut entries = Vec::new();
        let mut owed: Vec<(String, String)> = Vec::new();
        for (file, plays) in files.iter().zip(plays) {
            match self.writeback_target(file) {
                Some((source, rating_key)) => {
                    owed.push((source.id().to_string(), rating_key.clone()));
                    self.enqueue_writeback(WritebackJob::Watched {
                        source,
                        rating_key,
                        path: file.path.clone(),
                        watched,
                    });
                }
                None => entries.push(WatchEntry {
                    s: file.source_id.clone(),
                    p: file.path.clone(),
                    pos: 0.0,
                    dur: 0.0,
                    w: watched,
                    n: plays,
                    t: now,
                }),
            }
        }
        self.store_watch(&entries)?;
        self.kick_taste_refresh();
        // The contract stays synchronous, because the caller shows what
        // failed; the round trips happen on the worker either way, so an away
        // server costs this thread one idle window instead of one timeout per
        // episode on top of its own.
        self.wait_for_writeback_idle(MARK_WATCHED_WAIT);
        let mut failure = None;
        let mut answered: Option<String> = None;
        {
            let outcomes = self.writeback_outcomes.lock();
            for (source_id, rating_key) in &owed {
                match outcomes.get(&mark_outcome_key(source_id, rating_key)) {
                    Some(None) if answered.is_none() => answered = Some(source_id.clone()),
                    Some(None) => {}
                    Some(Some((failed_source, kind))) => {
                        failure = Some(match kind {
                            MarkFailure::Unauthorized => CoreError::Unauthorized {
                                source_id: failed_source.clone(),
                            },
                            MarkFailure::Server(msg) => CoreError::SourceUnavailable {
                                source_id: failed_source.clone(),
                                msg: msg.clone(),
                            },
                        });
                    }
                    None => {}
                }
            }
        }
        // a server that just took a write is a server that can take the ones it
        // refused before
        if let Some(source_id) = answered {
            self.drain_queue(&source_id, now);
        }
        match failure {
            Some(e) => Err(e),
            None => Ok(()),
        }
    }

    /// Hands a job to the mailbox, starting the worker if none is alive. The
    /// running flip and the push both sit under the jobs lock on the worker's
    /// stand-down side, so exactly one of the two of us ends up responsible
    /// for every job in the queue.
    fn enqueue_writeback(&self, job: WritebackJob) {
        self.writeback.jobs.lock().push_back(job);
        self.writeback.pending.fetch_add(1, Ordering::SeqCst);
        if !self.writeback.running.swap(true, Ordering::SeqCst) {
            let core = self.self_ref.clone();
            std::thread::Builder::new()
                .name("lexis.writeback".into())
                .spawn(move || {
                    crate::lower_thread_qos();
                    writeback_worker(core)
                })
                .expect("spawn a thread");
        }
    }

    /// Settles every job already handed over, or gives up after `timeout`.
    /// Tests use this to make the worker's outcomes observable; production
    /// callers never wait except `mark_watched`, whose contract is an answer.
    pub(crate) fn wait_for_writeback_idle(&self, timeout: Duration) -> bool {
        let deadline = std::time::Instant::now() + timeout;
        while self.writeback.pending.load(Ordering::SeqCst) > 0 {
            if std::time::Instant::now() >= deadline {
                return false;
            }
            std::thread::sleep(Duration::from_millis(5));
        }
        true
    }

    /// The source to report a file's state to, when its own server holds
    /// watch state: a ratingKey and a source whose `watch_sync` answers.
    fn writeback_target(&self, file: &FileRef) -> Option<(Arc<dyn Source>, String)> {
        let rating_key = file.rating_key.clone()?;
        let source = self.built_source(&file.source_id)?;
        source.watch_sync()?;
        Some((source, rating_key))
    }

    /// Keeps a write the server refused, so the next scan can send it. One
    /// entry per item, latest wins: a report every few seconds would otherwise
    /// fill the store with a history nobody reads.
    ///
    /// A field the new write knows nothing about is kept from the old one: a
    /// title marked watched carries no position, and a position carries no
    /// flag, and both are owed once both have happened. Which of the two is the
    /// newer is recorded in `wl`, so the drain can replay them in the order
    /// they were made.
    fn enqueue(&self, write: QueuedWrite) {
        // whatever this write brought is the newer of the two, and a write that
        // brings a flag brought it after the position of that same report
        let flag_is_newer = write.w.is_some();
        let bytes = {
            let mut queue = self.queue.lock();
            // by index, not by `iter_mut`: the not-found case pushes onto the
            // very vector the search would still be borrowing
            let at = match queue.iter().position(|e| e.s == write.s && e.k == write.k) {
                Some(at) => {
                    let entry = &mut queue[at];
                    *entry = QueuedWrite {
                        pos: write.pos.or(entry.pos),
                        dur: if write.dur == 0.0 {
                            entry.dur
                        } else {
                            write.dur
                        },
                        w: write.w.or(entry.w),
                        ..write
                    };
                    at
                }
                None => {
                    queue.push(write);
                    queue.len() - 1
                }
            };
            let entry = &mut queue[at];
            entry.wl = (entry.pos.is_some() && entry.w.is_some()).then_some(flag_is_newer);
            if queue.len() > MAX_QUEUE_ENTRIES {
                // the discard order: a position sample before a flag the user
                // set by hand, then the oldest, so a season marked watched
                // cannot be evicted by an evening of playback
                queue.sort_by_key(|e| (e.w.is_none(), std::cmp::Reverse(e.t)));
                queue.truncate(MAX_QUEUE_ENTRIES);
            }
            serde_json::to_vec(&*queue).ok()
        };
        // a value that will not serialize is not worth failing a playback
        // report for: the local row is already written
        if let Some(bytes) = bytes {
            self.store.set(QUEUE_KEY.to_string(), bytes);
        }
    }

    /// Forgets the queued entry a direct write just made obsolete. What the
    /// server took is newer than both halves queued for that item, and neither
    /// can be replayed behind it: a scrobble or an unscrobble clears the offset
    /// that write delivered, and the next mirror would then write the loss into
    /// the local row for good. A flag set offline loses to the playback that
    /// followed it, the way the index resolves any two writes.
    fn supersede_queued(&self, source_id: &str, rating_key: &str) {
        let bytes = {
            let mut queue = self.queue.lock();
            let Some(at) = queue
                .iter()
                .position(|e| e.s == source_id && e.k == rating_key)
            else {
                return;
            };
            queue.remove(at);
            serde_json::to_vec(&*queue).ok()
        };
        if let Some(bytes) = bytes {
            self.store.set(QUEUE_KEY.to_string(), bytes);
        }
    }

    /// Sends what this source owes, oldest first, and stops at the first
    /// refusal a retry could fix: a server that is still away must cost one
    /// request per scan, not one per entry. Returns the entries the server
    /// took, and only those: an entry too old to send and one the server will
    /// refuse forever leave the queue too, but they never reached it.
    ///
    /// No guard is held while it talks. The batch is copied under the queue
    /// lock, sent with nothing held, and only entries that left it unchanged
    /// are taken back out: a report that failed mid-drain queued a newer entry
    /// under the same key, and that one is still owed.
    pub(super) fn drain_queue(&self, source_id: &str, now: i64) -> Vec<QueuedWrite> {
        let mut batch: Vec<QueuedWrite> = {
            let queue = self.queue.lock();
            if queue.iter().all(|e| e.s != source_id) {
                return Vec::new();
            }
            queue.iter().filter(|e| e.s == source_id).cloned().collect()
        };
        batch.sort_by_key(|e| e.t);
        // a source no longer configured, or one whose module keeps no watch
        // state, has nowhere to send; remove_source already took its entries
        // out
        let Some(source) = self.built_source(source_id) else {
            return Vec::new();
        };
        let Some(ws) = source.watch_sync() else {
            return Vec::new();
        };
        let mut sent: Vec<QueuedWrite> = Vec::new();
        let mut abandoned: Vec<QueuedWrite> = Vec::new();
        for entry in batch {
            // an entry nothing delivered for a month is dropped, not sent
            if now.saturating_sub(entry.t) > QUEUE_MAX_AGE_SECS {
                abandoned.push(entry);
                continue;
            }
            match self.send_queued(ws, &entry) {
                Ok(()) => sent.push(entry),
                // a refusal that will not change, on the same rule the direct
                // path queues by: an item the server no longer has must not sit
                // at the head of the queue holding back every newer write. It
                // goes the way a direct write of it would have, unrecorded.
                Err(e) if !is_queueable(&e) => abandoned.push(entry),
                Err(_) => break,
            }
        }
        if sent.is_empty() && abandoned.is_empty() {
            return sent;
        }
        let bytes = {
            let mut queue = self.queue.lock();
            queue.retain(|e| !sent.contains(e) && !abandoned.contains(e));
            serde_json::to_vec(&*queue).ok()
        };
        if let Some(bytes) = bytes {
            self.store.set(QUEUE_KEY.to_string(), bytes);
        }
        sent
    }

    /// One queued entry on the wire, replaying the order the two writes were
    /// made in: a scrobble clears the offset a timeline sets, and a timeline
    /// after a scrobble sets it back, so the older of the two goes first and
    /// the server is left where the online path would have left it.
    fn send_queued(&self, ws: &dyn WatchSync, entry: &QueuedWrite) -> Result<(), SourceError> {
        let timeline = || match entry.pos {
            // Stopped, whatever the report was made in: this is a write the
            // server refused hours or days ago being replayed. It owes a
            // resume point, and opening a session for a film nobody is
            // watching would put a ghost on the dashboard.
            Some(pos) => ws.timeline(&entry.k, PlaybackState::Stopped, pos, entry.dur),
            None => Ok(()),
        };
        let flag = || match entry.w {
            Some(true) => ws.scrobble(&entry.k),
            Some(false) => ws.unscrobble(&entry.k),
            None => Ok(()),
        };
        // `wl` is set only while the entry owes both; false is a position
        // reported after the flag, so that flag is the one that goes first
        if entry.wl == Some(false) {
            flag()?;
            timeline()
        } else {
            timeline()?;
            flag()
        }
    }

    /// Drops what a source owed, and says how many writes that was. Its writes
    /// have nowhere to go once it is gone, and its ratingKeys mean nothing on
    /// whatever server takes its id next.
    pub(super) fn forget_queue(&self, source_id: &str) -> usize {
        let (forgotten, bytes) = {
            let mut queue = self.queue.lock();
            let before = queue.len();
            queue.retain(|e| e.s != source_id);
            let forgotten = before - queue.len();
            if forgotten == 0 {
                return 0;
            }
            (forgotten, serde_json::to_vec(&*queue).ok())
        };
        if let Some(bytes) = bytes {
            self.store.set(QUEUE_KEY.to_string(), bytes);
        }
        forgotten
    }

    /// Merges what the files below need remembered into the durable copy, and
    /// writes the whole value back once: a season marked watched costs one
    /// store write, not one per episode.
    ///
    /// A change to membership or to the watched flag is structural and
    /// rewrites the whole list. A position or duration alone moves one record,
    /// which rides out on the one-entry live key instead: the whole list used
    /// to be re-serialized on every playback report, hundreds of KB encoded
    /// and base64'd on the calling thread for a value nothing but this file
    /// reads back. The live record is folded into the list at load
    /// (`take_live_watch`), so nothing is lost between sessions or on a crash.
    ///
    /// A report that moves nothing a viewer would see writes nothing. The
    /// index row is written either way.
    fn store_watch(&self, updates: &[WatchEntry]) -> Result<(), CoreError> {
        if updates.is_empty() {
            return Ok(());
        }
        let mut structural = false;
        let mut changed = false;
        let mut live: Option<WatchEntry> = None;
        let whole = {
            let mut watch = self.watch.lock();
            for update in updates {
                match watch
                    .iter_mut()
                    .find(|e| e.s == update.s && e.p == update.p)
                {
                    Some(entry) => {
                        // marking a title watched knows no runtime, and the
                        // table keeps the one it has: the copy must too
                        let dur = if update.dur == 0.0 {
                            entry.dur
                        } else {
                            update.dur
                        };
                        if entry.w == update.w
                            && entry.n == update.n
                            && entry.dur == dur
                            && entry.pos.round() == update.pos.round()
                        {
                            continue;
                        }
                        if entry.w != update.w {
                            structural = true;
                        }
                        *entry = WatchEntry {
                            dur,
                            ..update.clone()
                        };
                        changed = true;
                        live = Some(entry.clone());
                    }
                    None => {
                        watch.push(update.clone());
                        structural = true;
                        changed = true;
                        live = Some(update.clone());
                    }
                }
            }
            if !changed {
                return Ok(());
            }
            if structural && watch.len() > MAX_WATCH_ENTRIES {
                // the discard order: what is watched with nothing left to
                // resume goes first, then the oldest, so a season marked
                // watched cannot evict the film someone is halfway through
                watch.sort_by_key(|e| (e.w && !in_progress(e.pos, e.dur), std::cmp::Reverse(e.t)));
                watch.truncate(MAX_WATCH_ENTRIES);
            }
            structural.then(|| {
                serde_json::to_vec(&*watch).map_err(|e| CoreError::Storage { msg: e.to_string() })
            })
        };
        match whole {
            Some(bytes) => {
                self.store.set(WATCH_KEY.to_string(), bytes?);
                self.store.set(LIVE_WATCH_KEY.to_string(), Vec::new());
            }
            None => {
                let bytes = serde_json::to_vec(&live.unwrap())
                    .map_err(|e| CoreError::Storage { msg: e.to_string() })?;
                self.store.set(LIVE_WATCH_KEY.to_string(), bytes);
            }
        }
        Ok(())
    }

    /// Mirrors the durable copies back into the index, without overwriting
    /// anything fresher a Plex sync just wrote.
    ///
    /// The queue is a durable copy too, and so is what the drain just sent: a
    /// server takes a write and answers the sync that follows with whatever it
    /// has made of it, which may be older state or none. Every restore is
    /// stale-guarded on `updated_at`, so a mirror that carried the newer state
    /// wins and one that carried older state is put back.
    ///
    /// A queued entry answers only for the halves it owes: a position reported
    /// offline says nothing about the flag, and asserting a `false` there would
    /// clear one this device and the server both hold.
    pub(super) fn restore_watch_state(
        &self,
        db: &crate::index::db::Db,
        settled: &[QueuedWrite],
    ) -> Result<(), CoreError> {
        let entries: Vec<WatchEntry> = self.watch.lock().clone();
        let mut owed: Vec<QueuedWrite> = self.queue.lock().clone();
        owed.extend_from_slice(settled);
        if entries.is_empty() && owed.is_empty() {
            return Ok(());
        }
        for entry in &entries {
            // a file that is not in the index has nothing to restore onto: the
            // entry stays in the copy until the budget drops it
            let Some(file_id) = db.file_id(&entry.s, &entry.p)? else {
                continue;
            };
            // the copy's flag is the one read back off the row it describes,
            // never a default, so it answers for it
            db.restore_watch_state(
                &WatchRecord {
                    file_id,
                    position_secs: entry.pos,
                    duration_secs: entry.dur,
                    watched: entry.w,
                    plays: entry.n,
                    updated_at: entry.t,
                },
                true,
            )?;
        }
        for write in &owed {
            let Some(file_id) = db.file_id(&write.s, &write.p)? else {
                continue;
            };
            // an entry with no position owes a flag instead, and delivering
            // either half clears the offset: zero is what the row should hold
            db.restore_watch_state(
                &WatchRecord {
                    file_id,
                    position_secs: write.pos.unwrap_or(0.0),
                    duration_secs: write.dur,
                    watched: write.w.unwrap_or(false),
                    plays: 0,
                    updated_at: write.t,
                },
                write.w.is_some(),
            )?;
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::api::library::ApiMediaKind;
    use crate::api::sources::SourceConfig;
    use crate::api::testing::*;
    use crate::api::HostStore;
    use crate::plex::fake::{
        refusing_library, FakeServer, Reply, REFUSING_OFFSET_MS, REFUSING_VIEWED_AT,
    };
    use crate::source::local::LocalModule;
    use crate::source::module::SourceModule;
    use crate::source::plex::PlexModule;
    use std::sync::atomic::{AtomicBool, Ordering};

    /// A writeback is a job for the worker now, so a test that wants to look
    /// at what the server or the queue ended up with settles first.
    fn settle_report(core: &LexisCore, file_id: i64, pos: f64, dur: f64) {
        core.report_playback(file_id, pos, dur, PlaybackState::Playing)
            .unwrap();
        assert!(core.wait_for_writeback_idle(Duration::from_secs(10)));
    }

    /// Same, for the tests that assert on the failure the caller used to get
    /// inline. The worker keeps what the server said about the item.
    fn settle_report_err(core: &LexisCore, file_id: i64, pos: f64, dur: f64) -> CoreError {
        core.writeback_outcomes.lock().clear();
        core.report_playback(file_id, pos, dur, PlaybackState::Playing)
            .unwrap();
        assert!(core.wait_for_writeback_idle(Duration::from_secs(10)));
        let settled: Vec<_> = core.writeback_outcomes.lock().drain().collect();
        assert_eq!(settled.len(), 1, "one report, one settled job");
        match settled.into_iter().next().unwrap().1 {
            Some((source_id, MarkFailure::Unauthorized)) => CoreError::Unauthorized { source_id },
            Some((source_id, MarkFailure::Server(msg))) => {
                CoreError::SourceUnavailable { source_id, msg }
            }
            None => panic!("the server took a write the test expected refused"),
        }
    }

    /// The file the one indexed local movie plays from.
    fn only_file_id(core: &LexisCore) -> i64 {
        core.list_titles(ApiMediaKind::Movie, 0, 10).unwrap()[0]
            .first_file_id
            .expect("the listed title names a file")
    }

    #[test]
    fn progress_is_written_to_the_index_and_to_the_durable_copy() {
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
        let file_id = only_file_id(&core);

        settle_report(&core, file_id, 600.0, 7000.0);

        let row = core.read_db.lock().watch_state(file_id).unwrap().unwrap();
        assert_eq!(row.position_secs, 600.0);
        assert!(!row.watched);

        // the durable copy names the file by source and path, not by id
        let saved = String::from_utf8(store.get(WATCH_KEY.to_string()).unwrap()).unwrap();
        assert!(saved.contains(r#""s":"local1""#), "{saved}");
        assert!(saved.contains("Dune (2021).mkv"), "{saved}");

        // past 90% the row watches itself, and the copy says so too
        settle_report(&core, file_id, 6900.0, 7000.0);
        assert!(
            core.read_db
                .lock()
                .watch_state(file_id)
                .unwrap()
                .unwrap()
                .watched
        );
        let saved = String::from_utf8(store.get(WATCH_KEY.to_string()).unwrap()).unwrap();
        assert!(saved.contains(r#""w":true"#), "{saved}");

        // one file played twice is one entry, not a growing log
        assert_eq!(saved.matches(r#""p":"#).count(), 1, "{saved}");
    }

    #[test]
    fn a_detail_says_where_to_resume_and_whether_it_was_seen() {
        let media = media_dir();
        let cache = tempfile::tempdir().unwrap();
        let store = Arc::new(MemStore::default());
        let core = LexisCore::new(cache.path().to_string_lossy().into_owned(), store).unwrap();
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
        let title = &core.list_titles(ApiMediaKind::Movie, 0, 10).unwrap()[0];
        let title_id = title.id;
        let file_id = title.first_file_id.unwrap();

        // nothing played: no resume, not seen
        let detail = core.title_detail(title_id).unwrap();
        assert!(!detail.watched);
        assert_eq!(detail.resume_file_id, None);
        assert_eq!(detail.resume_position_secs, 0.0);
        assert_eq!(detail.resume_duration_secs, 0.0);

        settle_report(&core, file_id, 930.0, 7000.0);
        let detail = core.title_detail(title_id).unwrap();
        assert!(!detail.watched);
        assert_eq!(detail.resume_file_id, Some(file_id));
        assert_eq!(detail.resume_position_secs, 930.0);
        assert_eq!(detail.resume_duration_secs, 7000.0);

        // marked by hand: seen, and nothing to resume from
        core.mark_watched(title_id, true).unwrap();
        let detail = core.title_detail(title_id).unwrap();
        assert!(detail.watched);
        assert_eq!(detail.resume_file_id, None);
        assert_eq!(detail.resume_position_secs, 0.0);

        // and back: unwatched, still nothing to resume, because the position
        // went with the flag
        core.mark_watched(title_id, false).unwrap();
        let detail = core.title_detail(title_id).unwrap();
        assert!(!detail.watched);
        assert_eq!(detail.resume_file_id, None);
    }

    #[test]
    fn a_position_in_the_last_seconds_of_a_file_is_not_a_resume_point() {
        let media = media_dir();
        let cache = tempfile::tempdir().unwrap();
        let store = Arc::new(MemStore::default());
        let core = LexisCore::new(cache.path().to_string_lossy().into_owned(), store).unwrap();
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
        let title = &core.list_titles(ApiMediaKind::Movie, 0, 10).unwrap()[0];
        let (title_id, file_id) = (title.id, title.first_file_id.unwrap());

        // 87% of a short file: under the 90% rule, so not watched, but inside
        // the last thirty seconds. Seeking there leaves the player with
        // nothing to read, so the detail offers a start instead.
        settle_report(&core, file_id, 175.0, 200.0);
        let detail = core.title_detail(title_id).unwrap();
        assert!(!detail.watched);
        assert_eq!(detail.resume_file_id, None);
        assert_eq!(detail.resume_position_secs, 0.0);

        // a minute earlier is a resume point again
        settle_report(&core, file_id, 120.0, 200.0);
        let detail = core.title_detail(title_id).unwrap();
        assert_eq!(detail.resume_file_id, Some(file_id));
        assert_eq!(detail.resume_position_secs, 120.0);
    }

    #[test]
    fn a_purge_gets_the_play_count_back_from_the_durable_copy() {
        let media = media_dir();
        let cache = tempfile::tempdir().unwrap();
        let store = Arc::new(MemStore::default());
        {
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
            let file_id = only_file_id(&core);
            // watched through twice, which only a count can remember
            settle_report(&core, file_id, 600.0, 7000.0);
            settle_report(&core, file_id, 6500.0, 7000.0);
            settle_report(&core, file_id, 30.0, 7000.0);
            settle_report(&core, file_id, 6500.0, 7000.0);
            assert_eq!(row(&core, file_id).plays, 2);
        }

        let cache2 = tempfile::tempdir().unwrap();
        let core = LexisCore::new(cache2.path().to_string_lossy().into_owned(), store).unwrap();
        core.scan_all(false).unwrap();
        let file_id = only_file_id(&core);
        assert_eq!(row(&core, file_id).plays, 2);
    }

    #[test]
    fn a_purge_gets_the_position_back_from_the_durable_copy() {
        let media = media_dir();
        let cache = tempfile::tempdir().unwrap();
        let store = Arc::new(MemStore::default());
        {
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
            settle_report(&core, only_file_id(&core), 600.0, 7000.0);
        }

        // the purge: a brand new cache dir, only the host store survives
        let cache2 = tempfile::tempdir().unwrap();
        let core = LexisCore::new(cache2.path().to_string_lossy().into_owned(), store).unwrap();
        // nothing to restore onto yet: the scan is what recreates the file rows
        core.scan_all(false).unwrap();
        let file_id = only_file_id(&core);
        let row = core
            .read_db
            .lock()
            .watch_state(file_id)
            .unwrap()
            .expect("the position came back from the durable copy");
        assert_eq!(row.position_secs, 600.0);
        assert_eq!(row.duration_secs, 7000.0);
    }

    #[test]
    fn a_plex_file_reports_to_its_server_and_not_to_the_host_store() {
        use crate::plex::fake::library;

        let server = library();
        let cache = tempfile::tempdir().unwrap();
        let store = Arc::new(MemStore::default());
        let core =
            LexisCore::new(cache.path().to_string_lossy().into_owned(), store.clone()).unwrap();
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
        let file_id = only_file_id(&core);

        settle_report(&core, file_id, 6900.0, 7000.0);

        let timeline = server
            .requests()
            .into_iter()
            .find(|r| r.url.starts_with("/:/timeline"))
            .expect("the position went to the Plex server");
        assert!(timeline.url.contains("ratingKey=101"), "{}", timeline.url);
        assert!(timeline.url.contains("time=6900000"), "{}", timeline.url);
        assert!(
            timeline.url.contains("duration=7000000"),
            "{}",
            timeline.url
        );
        assert_eq!(timeline.header("X-Plex-Token"), Some("s3cr3t"));
        assert!(!timeline.url.contains("s3cr3t"), "{}", timeline.url);
        // past 90% the server is told the item is played, not just positioned
        assert!(server
            .requests()
            .iter()
            .any(|r| r.url.starts_with("/:/scrobble")));

        // the server is the durable owner here: the host store is left alone
        assert_eq!(store.get(WATCH_KEY.to_string()), None);
        // and the local row is there to be queried
        assert!(
            core.read_db
                .lock()
                .watch_state(file_id)
                .unwrap()
                .unwrap()
                .watched
        );
    }

    #[test]
    fn a_server_that_refuses_the_writeback_still_keeps_the_position() {
        use crate::plex::fake::{FakeServer, Reply, EPISODES_JSON, MOVIES_JSON, SECTIONS_JSON};

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
            // the token was good enough to browse and is stale by now
            Reply::status(401)
        });
        let cache = tempfile::tempdir().unwrap();
        let store = Arc::new(MemStore::default());
        let core =
            LexisCore::new(cache.path().to_string_lossy().into_owned(), store.clone()).unwrap();
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
        let file_id = only_file_id(&core);

        let err = settle_report_err(&core, file_id, 600.0, 7000.0);
        // by reference: the message is read again below, and a match by value
        // would have moved it
        assert!(matches!(&err, CoreError::Unauthorized { source_id } if source_id == "plex1"));
        assert!(!err.to_string().contains("s3cr3t"), "{err}");
        // the position is not what was lost
        assert_eq!(
            core.read_db
                .lock()
                .watch_state(file_id)
                .unwrap()
                .unwrap()
                .position_secs,
            600.0
        );
    }

    #[test]
    fn marking_one_episode_watched_leaves_the_others() {
        use crate::plex::fake::library;

        let server = library();
        let cache = tempfile::tempdir().unwrap();
        let store = Arc::new(MemStore::default());
        let core =
            LexisCore::new(cache.path().to_string_lossy().into_owned(), store.clone()).unwrap();
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
        let show = core.list_titles(ApiMediaKind::Show, 0, 10).unwrap()[0].id;
        let episodes = core.episodes(show).unwrap();
        let (first, second) = (episodes[0].file_id, episodes[1].file_id);

        let watched = |id: i64| {
            let db = core.read_db.lock();
            db.watch_state(id).unwrap().is_some_and(|w| w.watched)
        };
        let second_before = watched(second);
        // an id the index never had is passed over, not an error
        core.mark_episodes_watched(vec![first, -7], true).unwrap();
        assert!(watched(first));
        assert_eq!(watched(second), second_before);
        let scrobbles = server
            .requests()
            .into_iter()
            .filter(|r| r.url.starts_with("/:/scrobble"))
            .count();
        assert_eq!(scrobbles, 1);

        core.mark_episodes_watched(vec![first], false).unwrap();
        assert!(!watched(first));
        assert!(server
            .requests()
            .iter()
            .any(|r| r.url.starts_with("/:/unscrobble")));
    }

    #[test]
    fn marking_a_title_watched_covers_every_file_it_has() {
        use crate::plex::fake::library;

        let server = library();
        let cache = tempfile::tempdir().unwrap();
        let store = Arc::new(MemStore::default());
        let core =
            LexisCore::new(cache.path().to_string_lossy().into_owned(), store.clone()).unwrap();
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
        let show = core.list_titles(ApiMediaKind::Show, 0, 10).unwrap()[0].id;

        core.mark_watched(show, true).unwrap();
        {
            let db = core.read_db.lock();
            for file in db.title_file_refs(show).unwrap() {
                let row = db.watch_state(file.id).unwrap().unwrap();
                assert!(row.watched, "{file:?}");
                assert_eq!(row.position_secs, 0.0);
            }
        }
        // both episodes were scrobbled, by their own ratingKey
        let scrobbles: Vec<String> = server
            .requests()
            .into_iter()
            .filter(|r| r.url.starts_with("/:/scrobble"))
            .map(|r| r.url)
            .collect();
        assert_eq!(scrobbles.len(), 2, "{scrobbles:?}");
        assert!(
            scrobbles.iter().any(|u| u.contains("key=201")),
            "{scrobbles:?}"
        );
        assert!(
            scrobbles.iter().any(|u| u.contains("key=202")),
            "{scrobbles:?}"
        );

        core.mark_watched(show, false).unwrap();
        {
            // one guard, taken once: locking read_db inside its own lock would
            // deadlock the test on the spot
            let db = core.read_db.lock();
            let files = db.title_file_refs(show).unwrap();
            assert!(!db.watch_state(files[0].id).unwrap().unwrap().watched);
        }
        assert!(server
            .requests()
            .iter()
            .any(|r| r.url.starts_with("/:/unscrobble")));
    }

    #[test]
    fn a_position_that_is_not_a_number_is_refused_before_anything_is_stored() {
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
        let file_id = only_file_id(&core);

        for (position, duration) in [(f64::NAN, 7000.0), (-1.0, 7000.0), (10.0, f64::INFINITY)] {
            assert!(matches!(
                core.report_playback(file_id, position, duration, PlaybackState::Playing),
                Err(CoreError::InvalidConfig { .. })
            ));
        }
        assert_eq!(store.get(WATCH_KEY.to_string()), None);
        // a file id nothing has is an error, not a silent success
        assert!(matches!(
            core.report_playback(999_999, 10.0, 100.0, PlaybackState::Playing),
            Err(CoreError::NotFound { .. })
        ));
    }

    #[test]
    fn a_rewatch_from_the_start_does_not_undo_a_finished_title() {
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
        let title = core.list_titles(ApiMediaKind::Movie, 0, 10).unwrap()[0].id;
        let file_id = only_file_id(&core);
        settle_report(&core, file_id, 6900.0, 7000.0);
        core.mark_watched(title, true).unwrap();

        // the first seconds of a rewatch: a position never lowers the flag,
        // because for a local file no owner could hand it back
        settle_report(&core, file_id, 12.0, 7000.0);

        let row = core.read_db.lock().watch_state(file_id).unwrap().unwrap();
        assert!(row.watched);
        assert_eq!(row.position_secs, 12.0);
        let saved = String::from_utf8(store.get(WATCH_KEY.to_string()).unwrap()).unwrap();
        assert!(saved.contains(r#""w":true"#), "{saved}");
        // and the durable copy kept the runtime that mark_watched never knew
        assert!(saved.contains(r#""dur":7000.0"#), "{saved}");

        // the way back down is the one the user asks for
        core.mark_watched(title, false).unwrap();
        assert!(
            !core
                .read_db
                .lock()
                .watch_state(file_id)
                .unwrap()
                .unwrap()
                .watched
        );
        let saved = String::from_utf8(store.get(WATCH_KEY.to_string()).unwrap()).unwrap();
        assert!(saved.contains(r#""w":false"#), "{saved}");
    }

    #[test]
    fn the_server_is_told_a_file_is_played_once_and_not_on_every_tick() {
        use crate::plex::fake::library;

        let server = library();
        let cache = tempfile::tempdir().unwrap();
        let store = Arc::new(MemStore::default());
        let core =
            LexisCore::new(cache.path().to_string_lossy().into_owned(), store.clone()).unwrap();
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
        let file_id = only_file_id(&core);

        // the report that finishes it, then one more of the same playback, then
        // the first seconds of a rewatch
        settle_report(&core, file_id, 6900.0, 7000.0);
        settle_report(&core, file_id, 6950.0, 7000.0);
        settle_report(&core, file_id, 12.0, 7000.0);

        let count = |prefix: &str| {
            server
                .requests()
                .iter()
                .filter(|r| r.url.starts_with(prefix))
                .count()
        };
        // scrobbling clears the offset the timeline just set, so it must not
        // ride along with every position
        assert_eq!(count("/:/scrobble"), 1);
        assert_eq!(count("/:/timeline"), 3);
    }

    #[test]
    fn two_quick_reports_reach_the_server_in_the_order_they_were_made() {
        use crate::plex::fake::library;

        let server = library();
        let cache = tempfile::tempdir().unwrap();
        let store = Arc::new(MemStore::default());
        let core =
            LexisCore::new(cache.path().to_string_lossy().into_owned(), store.clone()).unwrap();
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
        let file_id = only_file_id(&core);

        // both jobs go into the mailbox back to back; the worker must drain
        // them FIFO, so the newer position never lands behind the older one
        settle_report(&core, file_id, 100.0, 7000.0);
        settle_report(&core, file_id, 200.0, 7000.0);

        let positions: Vec<String> = server
            .requests()
            .iter()
            .filter(|r| r.url.starts_with("/:/timeline"))
            .map(|r| r.url.clone())
            .collect();
        assert_eq!(positions.len(), 2);
        let older = positions.iter().position(|u| u.contains("time=100000"));
        let newer = positions.iter().position(|u| u.contains("time=200000"));
        assert!(older.is_some() && newer.is_some());
        assert!(older.unwrap() < newer.unwrap());
    }

    #[test]
    fn a_report_that_carries_no_runtime_keeps_the_one_the_sync_mirrored() {
        use crate::plex::fake::library;

        let server = library();
        let cache = tempfile::tempdir().unwrap();
        let store = Arc::new(MemStore::default());
        let core =
            LexisCore::new(cache.path().to_string_lossy().into_owned(), store.clone()).unwrap();
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
        let file_id = only_file_id(&core);
        let row = |c: &LexisCore| c.read_db.lock().watch_state(file_id).unwrap().unwrap();
        assert_eq!(row(&core).duration_secs, 9000.0);

        // the shape the app sends: it has no clock, so every tick carries a
        // position and a zero runtime
        settle_report(&core, file_id, 1500.0, 0.0);
        let after = row(&core);
        assert_eq!(after.position_secs, 1500.0);
        assert_eq!(after.duration_secs, 9000.0);
        assert!(!after.watched);

        // and the runtime it kept is what the 90% rule fires against
        settle_report(&core, file_id, 8200.0, 0.0);
        assert!(row(&core).watched);
    }

    #[test]
    fn a_new_token_reaches_the_next_report_the_client_is_kept_for() {
        use crate::plex::fake::library;

        let server = library();
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
        core.scan_all(false).unwrap();
        let file_id = only_file_id(&core);
        settle_report(&core, file_id, 600.0, 7000.0);

        // the client cached for the connection pool holds the old token, so
        // re-adding the source has to drop it
        core.add_or_replace(
            PlexModule.id(),
            "plex1".into(),
            std::collections::BTreeMap::from([
                ("base_url".to_string(), server.base_url.clone()),
                ("token".to_string(), "fresh".into()),
            ]),
        )
        .unwrap();
        settle_report(&core, file_id, 900.0, 7000.0);

        let tokens: Vec<String> = server
            .requests()
            .into_iter()
            .filter(|r| r.url.starts_with("/:/timeline"))
            .map(|r| r.header("X-Plex-Token").unwrap_or_default().to_string())
            .collect();
        assert_eq!(tokens, ["stale", "fresh"]);
    }

    #[test]
    fn a_report_that_moves_nothing_leaves_the_durable_copy_alone() {
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
        let file_id = only_file_id(&core);
        settle_report(&core, file_id, 600.0, 7000.0);

        let before = store.writes.load(Ordering::Relaxed);
        // a paused player still reports: within the same second nothing is
        // worth rewriting the whole value for
        settle_report(&core, file_id, 600.4, 7000.0);
        assert_eq!(store.writes.load(Ordering::Relaxed), before);
        // the index took it anyway, because that is what the rows are read from
        assert_eq!(
            core.read_db
                .lock()
                .watch_state(file_id)
                .unwrap()
                .unwrap()
                .position_secs,
            600.4
        );

        settle_report(&core, file_id, 630.0, 7000.0);
        assert_eq!(store.writes.load(Ordering::Relaxed), before + 1);
    }

    #[test]
    fn a_full_durable_copy_drops_what_is_finished_before_what_is_not() {
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
        // the film in progress, through the real path, and long ago
        settle_report(&core, only_file_id(&core), 600.0, 7000.0);
        core.watch.lock()[0].t = 1;
        // a film played to the end instead of marked: watched, and with a
        // position no one would ever resume from
        core.store_watch(&[WatchEntry {
            s: "local1".to_string(),
            p: "Movies/Alien (1979).mkv".to_string(),
            pos: 6990.0,
            dur: 7000.0,
            w: true,
            n: 0,
            t: 500,
        }])
        .unwrap();

        // and a short extra left in its credits: under the 90% mark, so only
        // the tail rule says there is nothing left of it to resume
        core.store_watch(&[WatchEntry {
            s: "local1".to_string(),
            p: "Movies/Big Adventure (short).mkv".to_string(),
            pos: 20.0,
            dur: 45.0,
            w: true,
            n: 0,
            t: 501,
        }])
        .unwrap();

        // the wave: a season marked watched, entry for entry as mark_watched
        // builds them. Indexing that many real files would prove nothing more.
        let wave: Vec<WatchEntry> = (0..MAX_WATCH_ENTRIES)
            .map(|i| WatchEntry {
                s: "local1".to_string(),
                p: format!("Shows/S01E{i:04}.mkv"),
                pos: 0.0,
                dur: 0.0,
                w: true,
                n: 0,
                t: 1000 + i as i64,
            })
            .collect();
        core.store_watch(&wave).unwrap();

        let watch = core.watch.lock();
        assert_eq!(watch.len(), MAX_WATCH_ENTRIES);
        // the film survives the season, whatever their dates say
        let film = watch.iter().find(|e| e.p.contains("Dune")).unwrap();
        assert_eq!(film.pos, 600.0);
        // the one played to the end had nothing left to resume, so it went
        // with the wave and before the film, though it is newer than the film
        assert!(!watch.iter().any(|e| e.p.contains("Alien")));
        // and so did the short one, on the same rule read the same way
        assert!(!watch.iter().any(|e| e.p.contains("Big Adventure")));
        // and the episode evicted is the oldest of them, not an arbitrary one
        assert!(!watch.iter().any(|e| e.p == "Shows/S01E0000.mkv"));
        assert!(watch.iter().any(|e| e.p == "Shows/S01E1999.mkv"));
    }

    /// A core with one Plex source, scanned once against a server that is
    /// answering: one movie, one file, and the position the server knows.
    fn queued_core(server: &FakeServer) -> (tempfile::TempDir, Arc<MemStore>, Arc<LexisCore>, i64) {
        let cache = tempfile::tempdir().unwrap();
        let store = Arc::new(MemStore::default());
        let core =
            LexisCore::new(cache.path().to_string_lossy().into_owned(), store.clone()).unwrap();
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
        let file_id = only_file_id(&core);
        (cache, store, core, file_id)
    }

    fn row(core: &LexisCore, file_id: i64) -> WatchRecord {
        core.read_db.lock().watch_state(file_id).unwrap().unwrap()
    }

    #[test]
    fn a_refused_writeback_is_kept_for_the_next_scan() {
        let refusing = Arc::new(AtomicBool::new(false));
        let server = refusing_library(refusing.clone(), 503, true);
        let (_cache, store, core, file_id) = queued_core(&server);
        assert_eq!(row(&core, file_id).position_secs, 1200.0);
        assert_eq!(row(&core, file_id).updated_at, REFUSING_VIEWED_AT);

        refusing.store(true, Ordering::SeqCst);
        let err = settle_report_err(&core, file_id, 3000.0, 9000.0);
        // the failure is still the caller's to see
        assert!(matches!(err, CoreError::SourceUnavailable { .. }));
        assert!(!err.to_string().contains("s3cr3t"), "{err}");
        // the position is not what was lost, and the write is owed
        assert_eq!(row(&core, file_id).position_secs, 3000.0);
        assert!(row(&core, file_id).updated_at > REFUSING_VIEWED_AT);
        assert_eq!(core.queued_writes(), 1);

        // the durable value, by name and by shape
        let saved = String::from_utf8(store.get(QUEUE_KEY.to_string()).unwrap()).unwrap();
        assert!(saved.contains(r#""s":"plex1""#), "{saved}");
        assert!(saved.contains(r#""k":"101""#), "{saved}");
        assert!(saved.contains(r#""pos":3000.0"#), "{saved}");
        // no credential, ever, in a stored value
        assert!(!saved.contains("s3cr3t"), "{saved}");
    }

    #[test]
    fn a_rejected_token_keeps_the_write_and_a_redirect_does_not() {
        // a token that went stale mid-session: the user re-enters one, and what
        // was watched in between is still owed
        let refusing = Arc::new(AtomicBool::new(false));
        let server = refusing_library(refusing.clone(), 401, true);
        let (_cache, _store, core, file_id) = queued_core(&server);
        refusing.store(true, Ordering::SeqCst);
        let err = settle_report_err(&core, file_id, 3000.0, 9000.0);
        assert!(matches!(err, CoreError::Unauthorized { .. }));
        assert!(!err.to_string().contains("s3cr3t"), "{err}");
        assert_eq!(core.queued_writes(), 1);

        // a Plex behind a proxy that redirects: the write is never recorded and
        // never will be, so it is reported and dropped
        let refusing = Arc::new(AtomicBool::new(false));
        let moved = refusing_library(refusing.clone(), 302, true);
        let (_cache, _store, core, file_id) = queued_core(&moved);
        refusing.store(true, Ordering::SeqCst);
        settle_report(&core, file_id, 3000.0, 9000.0);
        assert_eq!(core.queued_writes(), 0);
    }

    #[test]
    fn many_reports_of_one_item_are_one_queued_write() {
        let refusing = Arc::new(AtomicBool::new(false));
        let server = refusing_library(refusing.clone(), 503, true);
        let (_cache, _store, core, file_id) = queued_core(&server);
        refusing.store(true, Ordering::SeqCst);
        for pos in [100.0, 200.0, 300.0] {
            settle_report(&core, file_id, pos, 9000.0);
        }
        assert_eq!(core.queued_writes(), 1);

        // and a flag set by hand joins the position instead of replacing it
        let title = core.list_titles(ApiMediaKind::Movie, 0, 10).unwrap()[0].id;
        core.mark_watched(title, true).unwrap_err();
        assert_eq!(core.queued_writes(), 1);
        let queue = core.queue.lock();
        assert_eq!(queue[0].pos, Some(300.0));
        assert_eq!(queue[0].dur, 9000.0);
        assert_eq!(queue[0].w, Some(true));
    }

    #[test]
    fn a_queued_flag_and_a_queued_position_remember_which_came_last() {
        let refusing = Arc::new(AtomicBool::new(false));
        let server = refusing_library(refusing.clone(), 503, true);
        let (_cache, _store, core, file_id) = queued_core(&server);
        let title = core.list_titles(ApiMediaKind::Movie, 0, 10).unwrap()[0].id;
        refusing.store(true, Ordering::SeqCst);

        // the flag alone owes no order: there is nothing to order it against
        core.mark_watched(title, true).unwrap_err();
        assert_eq!(core.queue.lock()[0].wl, None);

        // then the film is restarted and stopped twice: the position is what
        // the server must end up with, so the drain sends the scrobble first
        settle_report(&core, file_id, 100.0, 9000.0);
        settle_report(&core, file_id, 200.0, 9000.0);
        {
            let queue = core.queue.lock();
            assert_eq!(queue.len(), 1);
            assert_eq!(queue[0].pos, Some(200.0));
            assert_eq!(queue[0].w, Some(true));
            assert_eq!(queue[0].wl, Some(false));
        }

        // and marked watched again by hand: the flag is the newer of the two
        // now, so the scrobble goes last and clears the offset, exactly as the
        // online order would have
        core.mark_watched(title, true).unwrap_err();
        assert_eq!(core.queue.lock()[0].wl, Some(true));

        // a report that finishes the file sends the timeline and then the
        // scrobble: one write, and the flag is still the newer
        let refusing = Arc::new(AtomicBool::new(false));
        let finished = refusing_library(refusing.clone(), 503, true);
        let (_cache, _store, core, file_id) = queued_core(&finished);
        refusing.store(true, Ordering::SeqCst);
        settle_report(&core, file_id, 8500.0, 9000.0);
        let queue = core.queue.lock();
        assert_eq!(queue[0].w, Some(true));
        assert_eq!(queue[0].wl, Some(true));
    }

    #[test]
    fn a_source_pointed_at_another_server_reports_no_stale_keys_either() {
        let refusing = Arc::new(AtomicBool::new(false));
        let server = refusing_library(refusing.clone(), 503, true);
        let (_cache, _store, core, file_id) = queued_core(&server);

        let elsewhere = refusing_library(Arc::new(AtomicBool::new(false)), 503, true);
        core.add_or_replace(
            PlexModule.id(),
            "plex1".into(),
            std::collections::BTreeMap::from([
                ("base_url".to_string(), elsewhere.base_url.clone()),
                ("token".to_string(), "fresh".into()),
            ]),
        )
        .unwrap();

        // the ratingKey the index holds was issued by the old server, so the
        // report has no item to name until the next sync re-keys the row
        settle_report(&core, file_id, 3000.0, 9000.0);
        assert!(elsewhere.requests().is_empty());
        assert_eq!(row(&core, file_id).position_secs, 3000.0);

        // the sync re-keys it, and the writeback resumes against the new server
        core.scan_all(false).unwrap();
        settle_report(&core, only_file_id(&core), 4000.0, 9000.0);
        assert!(elsewhere
            .requests()
            .iter()
            .any(|r| r.url.starts_with("/:/timeline?")));
    }

    #[test]
    fn a_full_queue_drops_a_position_before_a_flag() {
        let cache = tempfile::tempdir().unwrap();
        let store = Arc::new(MemStore::default());
        let core =
            LexisCore::new(cache.path().to_string_lossy().into_owned(), store.clone()).unwrap();
        for i in 0..(MAX_QUEUE_ENTRIES + 10) {
            core.enqueue(QueuedWrite {
                s: "plex1".to_string(),
                k: format!("{i}"),
                p: format!("/p/{i}"),
                pos: Some(i as f64),
                dur: 0.0,
                // the first ten are flags set by hand, and the oldest of all
                w: if i < 10 { Some(true) } else { None },
                wl: None,
                t: 1_800_000_000 + i as i64,
            });
        }
        assert_eq!(core.queued_writes(), MAX_QUEUE_ENTRIES as u32);
        let queue = core.queue.lock();
        assert_eq!(queue.iter().filter(|e| e.w.is_some()).count(), 10);
        // the newest position is kept and the oldest one went
        assert!(queue
            .iter()
            .any(|e| e.k == format!("{}", MAX_QUEUE_ENTRIES + 9)));
        assert!(!queue.iter().any(|e| e.k == "10"));
    }

    #[test]
    fn the_queue_outlives_the_process_that_wrote_it() {
        let refusing = Arc::new(AtomicBool::new(false));
        let server = refusing_library(refusing.clone(), 503, true);
        let (_cache, store, core, file_id) = queued_core(&server);
        refusing.store(true, Ordering::SeqCst);
        settle_report(&core, file_id, 3000.0, 9000.0);
        drop(core);

        // a new process on the same store, and a cache that was purged
        let purged = tempfile::tempdir().unwrap();
        let core = LexisCore::new(purged.path().to_string_lossy().into_owned(), store).unwrap();
        assert_eq!(core.queued_writes(), 1);
    }

    #[test]
    fn a_source_that_is_removed_owes_nothing() {
        let refusing = Arc::new(AtomicBool::new(false));
        let server = refusing_library(refusing.clone(), 503, true);
        let (_cache, _store, core, file_id) = queued_core(&server);
        refusing.store(true, Ordering::SeqCst);
        settle_report(&core, file_id, 3000.0, 9000.0);
        assert_eq!(core.queued_writes(), 1);

        core.remove_source("plex1".to_string()).unwrap();
        assert_eq!(core.queued_writes(), 0);
    }

    #[test]
    fn a_source_pointed_at_another_server_owes_nothing() {
        let refusing = Arc::new(AtomicBool::new(false));
        let server = refusing_library(refusing.clone(), 503, true);
        let (_cache, _store, core, file_id) = queued_core(&server);
        refusing.store(true, Ordering::SeqCst);
        settle_report(&core, file_id, 3000.0, 9000.0);

        // the same id, a new token: the ratingKeys still mean what they meant
        core.add_or_replace(
            PlexModule.id(),
            "plex1".into(),
            std::collections::BTreeMap::from([
                ("base_url".to_string(), server.base_url.clone()),
                ("token".to_string(), "fresh".into()),
            ]),
        )
        .unwrap();
        assert_eq!(core.queued_writes(), 1);

        // the same id, another server: they do not, and the history that goes
        // with them is said out loud, never dropped quietly
        let err = core
            .add_or_replace(
                PlexModule.id(),
                "plex1".into(),
                std::collections::BTreeMap::from([
                    ("base_url".to_string(), "http://127.0.0.1:1".into()),
                    ("token".to_string(), "fresh".into()),
                ]),
            )
            .unwrap_err();
        assert!(err.to_string().contains("1 write(s)"), "{err}");
        assert!(!err.to_string().contains("fresh"), "{err}");
        assert_eq!(core.queued_writes(), 0);
        // the source moved all the same: the message is what was lost doing it
        assert_eq!(core.list_sources()[0].detail, "http://127.0.0.1:1");
    }

    #[test]
    fn replace_source_at_the_same_address_keeps_the_queue_and_the_ratingkeys() {
        let refusing = Arc::new(AtomicBool::new(false));
        let server = refusing_library(refusing.clone(), 503, true);
        let (_cache, _store, core, file_id) = queued_core(&server);
        refusing.store(true, Ordering::SeqCst);
        settle_report(&core, file_id, 3000.0, 9000.0);
        assert_eq!(core.queued_writes(), 1);
        assert!(core
            .read_db
            .lock()
            .file_ref(file_id)
            .unwrap()
            .unwrap()
            .rating_key
            .is_some());

        // the same module, the same base_url, only the token changed: this is
        // a credential refresh, not a move to another server
        let dropped = core
            .replace_source(SourceConfig {
                module: PlexModule.id().to_string(),
                id: "plex1".to_string(),
                name: None,
                values: std::collections::BTreeMap::from([
                    ("base_url".to_string(), server.base_url.clone()),
                    ("token".to_string(), "fresh".to_string()),
                ]),
            })
            .unwrap();
        assert!(dropped.is_none());
        assert_eq!(core.queued_writes(), 1);
        assert!(core
            .read_db
            .lock()
            .file_ref(file_id)
            .unwrap()
            .unwrap()
            .rating_key
            .is_some());
    }

    #[test]
    fn replace_source_at_a_new_address_drops_the_queue_and_the_ratingkeys_and_says_so() {
        let refusing = Arc::new(AtomicBool::new(false));
        let server = refusing_library(refusing.clone(), 503, true);
        let (_cache, _store, core, file_id) = queued_core(&server);
        refusing.store(true, Ordering::SeqCst);
        settle_report(&core, file_id, 3000.0, 9000.0);
        assert_eq!(core.queued_writes(), 1);

        let err = core
            .replace_source(SourceConfig {
                module: PlexModule.id().to_string(),
                id: "plex1".to_string(),
                name: None,
                values: std::collections::BTreeMap::from([
                    ("base_url".to_string(), "http://127.0.0.1:1".to_string()),
                    ("token".to_string(), "fresh".to_string()),
                ]),
            })
            .unwrap()
            .unwrap();
        assert!(err.to_string().contains("1 write(s)"), "{err}");
        assert_eq!(core.queued_writes(), 0);
        assert!(core
            .read_db
            .lock()
            .file_ref(file_id)
            .unwrap()
            .unwrap()
            .rating_key
            .is_none());
    }

    #[test]
    fn the_next_scan_sends_what_the_server_refused_before_it_mirrors() {
        let refusing = Arc::new(AtomicBool::new(false));
        let server = refusing_library(refusing.clone(), 503, true);
        let (_cache, _store, core, file_id) = queued_core(&server);

        refusing.store(true, Ordering::SeqCst);
        settle_report(&core, file_id, 3000.0, 9000.0);
        let t1 = row(&core, file_id).updated_at;

        refusing.store(false, Ordering::SeqCst);
        let report = core.scan_all(false).unwrap();
        assert_eq!(report.queued_writes, 0);
        assert_eq!(core.queued_writes(), 0);

        let urls: Vec<String> = server.requests().into_iter().map(|r| r.url).collect();
        let drain = urls
            .iter()
            .position(|u| u.starts_with("/:/timeline") && u.contains("time=3000000"))
            .expect("the queued position reached the wire");
        let mirror = urls
            .iter()
            .enumerate()
            .find(|(i, u)| *i > drain && u.starts_with("/library/sections/1/all"))
            .map(|(i, _)| i)
            .expect("the sync read the library after the drain");
        // the server hears this device before it answers for the same item
        assert!(drain < mirror);
        assert_eq!(row(&core, file_id).position_secs, 3000.0);
        assert!(row(&core, file_id).updated_at >= t1);
        assert!(urls.iter().all(|u| !u.contains("s3cr3t")));
    }

    #[test]
    fn a_server_still_away_costs_one_request_and_keeps_the_rest() {
        use crate::plex::fake::{EPISODES_JSON, MOVIES_JSON, SECTIONS_JSON};
        use std::sync::atomic::AtomicU32;

        // the writes it will take before it goes away again
        let allowance = Arc::new(AtomicU32::new(0));
        let budget = allowance.clone();
        let server = FakeServer::start(move |req| {
            if req.url.starts_with("/:/") {
                if budget.load(Ordering::SeqCst) == 0 {
                    return Reply::status(503);
                }
                budget.fetch_sub(1, Ordering::SeqCst);
                return Reply::status(200);
            }
            if req.url == "/library/sections" {
                return Reply::json(SECTIONS_JSON);
            }
            if req.url.starts_with("/library/sections/1/all") {
                return Reply::json(MOVIES_JSON);
            }
            if req.url.starts_with("/library/sections/2/all") {
                return Reply::json(EPISODES_JSON);
            }
            Reply::status(404)
        });
        let cache = tempfile::tempdir().unwrap();
        let store = Arc::new(MemStore::default());
        let core =
            LexisCore::new(cache.path().to_string_lossy().into_owned(), store.clone()).unwrap();
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

        // three items, none of which the server takes
        let mut file_ids: Vec<i64> = Vec::new();
        for kind in [ApiMediaKind::Movie, ApiMediaKind::Show] {
            for title in core.list_titles(kind, 0, 10).unwrap() {
                let db = core.read_db.lock();
                for file in db.title_file_refs(title.id).unwrap() {
                    file_ids.push(file.id);
                }
            }
        }
        assert_eq!(file_ids.len(), 3);
        for (i, id) in file_ids.iter().enumerate() {
            settle_report(&core, *id, 100.0 + i as f64, 9000.0);
        }
        assert_eq!(core.queued_writes(), 3);

        // it comes back for exactly one write
        allowance.store(1, Ordering::SeqCst);
        let before = server.requests().len();
        let report = core.scan_all(false).unwrap();
        assert_eq!(report.queued_writes, 2);
        // one taken, one refused, and nothing tried after it
        let tried = server.requests()[before..]
            .iter()
            .filter(|r| r.url.starts_with("/:/"))
            .count();
        assert_eq!(tried, 2);
    }

    #[test]
    fn a_write_nothing_delivered_for_a_month_is_dropped() {
        let refusing = Arc::new(AtomicBool::new(false));
        let server = refusing_library(refusing.clone(), 503, true);
        let (_cache, _store, core, file_id) = queued_core(&server);
        refusing.store(true, Ordering::SeqCst);
        settle_report(&core, file_id, 3000.0, 9000.0);
        {
            let mut queue = core.queue.lock();
            queue[0].t = unix_now() - QUEUE_MAX_AGE_SECS - 1;
        }

        refusing.store(false, Ordering::SeqCst);
        let before = server.requests().len();
        core.scan_all(false).unwrap();
        assert_eq!(core.queued_writes(), 0);
        // dropped, not sent: the server has heard from other clients since
        assert!(!server.requests()[before..]
            .iter()
            .any(|r| r.url.starts_with("/:/")));
    }

    #[test]
    fn a_report_the_server_takes_carries_the_backlog_with_it() {
        let refusing = Arc::new(AtomicBool::new(false));
        let server = refusing_library(refusing.clone(), 503, true);
        let (_cache, _store, core, file_id) = queued_core(&server);
        refusing.store(true, Ordering::SeqCst);
        settle_report(&core, file_id, 3000.0, 9000.0);
        assert_eq!(core.queued_writes(), 1);

        // the next tick of the same playback goes through, and takes what was
        // owed with it: no scan needed
        refusing.store(false, Ordering::SeqCst);
        settle_report(&core, file_id, 3030.0, 9000.0);
        assert_eq!(core.queued_writes(), 0);
        let sent: Vec<String> = server
            .requests()
            .into_iter()
            .map(|r| r.url)
            .filter(|u| u.starts_with("/:/timeline"))
            .collect();
        assert!(sent.iter().any(|u| u.contains("time=3000000")), "{sent:?}");
        assert!(sent.iter().any(|u| u.contains("time=3030000")), "{sent:?}");
    }

    #[test]
    fn a_write_the_server_took_settles_the_older_one_it_queued() {
        let refusing = Arc::new(AtomicBool::new(false));
        let server = refusing_library(refusing.clone(), 503, true);
        let (_cache, _store, core, file_id) = queued_core(&server);
        refusing.store(true, Ordering::SeqCst);
        settle_report(&core, file_id, 3000.0, 9000.0);

        // the server comes back and takes the next tick of the same playback,
        // which is newer than what was queued for that item
        refusing.store(false, Ordering::SeqCst);
        let before = server.requests().len();
        settle_report(&core, file_id, 3030.0, 9000.0);
        assert_eq!(core.queued_writes(), 0);
        let sent: Vec<String> = server.requests()[before..]
            .iter()
            .map(|r| r.url.clone())
            .filter(|u| u.starts_with("/:/"))
            .collect();
        assert_eq!(sent.len(), 1, "{sent:?}");
        assert!(sent[0].contains("time=3030000"), "{sent:?}");

        // playback stopped there, so nothing corrects the server later: the
        // mirror must not bring the stale position back into the local row
        core.scan_all(false).unwrap();
        assert_eq!(row(&core, only_file_id(&core)).position_secs, 3030.0);
    }

    #[test]
    fn a_flag_the_server_took_settles_the_position_it_queued() {
        let refusing = Arc::new(AtomicBool::new(false));
        let server = refusing_library(refusing.clone(), 503, true);
        let (_cache, _store, core, file_id) = queued_core(&server);
        let title = core.list_titles(ApiMediaKind::Movie, 0, 10).unwrap()[0].id;
        refusing.store(true, Ordering::SeqCst);
        settle_report(&core, file_id, 3000.0, 9000.0);

        // the server comes back and the title is marked watched by hand, which
        // zeroes the position this device had been trying to send
        refusing.store(false, Ordering::SeqCst);
        let before = server.requests().len();
        core.mark_watched(title, true).unwrap();
        assert_eq!(core.queued_writes(), 0);
        let sent: Vec<String> = server.requests()[before..]
            .iter()
            .map(|r| r.url.clone())
            .filter(|u| u.starts_with("/:/"))
            .collect();
        assert_eq!(sent.len(), 1, "{sent:?}");
        assert!(sent[0].starts_with("/:/scrobble?"), "{sent:?}");

        // no stale position went out after the flag, so the mirror answers with
        // the server's own offset and not with one this device abandoned
        core.scan_all(false).unwrap();
        assert_eq!(row(&core, only_file_id(&core)).position_secs, 1200.0);
    }

    #[test]
    fn a_position_the_server_takes_settles_both_halves_queued_before_it() {
        let refusing = Arc::new(AtomicBool::new(false));
        let server = refusing_library(refusing.clone(), 503, true);
        let (_cache, _store, core, file_id) = queued_core(&server);
        let title = core.list_titles(ApiMediaKind::Movie, 0, 10).unwrap()[0].id;
        refusing.store(true, Ordering::SeqCst);

        // one entry owing both halves: a flag set by hand, then a rewatch
        core.mark_watched(title, true).unwrap_err();
        settle_report(&core, file_id, 3000.0, 9000.0);
        assert_eq!(core.queued_writes(), 1);

        // the next tick goes through, and it is newer than both halves: the
        // scrobble behind it would clear the offset it just delivered
        refusing.store(false, Ordering::SeqCst);
        let before = server.requests().len();
        settle_report(&core, file_id, 3030.0, 9000.0);
        assert_eq!(core.queued_writes(), 0);
        let sent: Vec<String> = server.requests()[before..]
            .iter()
            .map(|r| r.url.clone())
            .filter(|u| u.starts_with("/:/"))
            .collect();
        assert_eq!(sent.len(), 1, "{sent:?}");
        assert!(
            sent[0].starts_with("/:/timeline?") && sent[0].contains("time=3030000"),
            "{sent:?}"
        );
    }

    #[test]
    fn a_flag_queued_before_a_delivered_position_never_undoes_it() {
        // marked unwatched while the server was away, then watched for real
        // once it was back: the unscrobble would clear both halves of what the
        // report delivered, on the server and, at the next mirror, here
        let refusing = Arc::new(AtomicBool::new(false));
        let server = refusing_library(refusing.clone(), 503, true);
        let (_cache, _store, core, file_id) = queued_core(&server);
        let title = core.list_titles(ApiMediaKind::Movie, 0, 10).unwrap()[0].id;
        refusing.store(true, Ordering::SeqCst);
        core.mark_watched(title, false).unwrap_err();
        assert_eq!(core.queue.lock()[0].w, Some(false));

        refusing.store(false, Ordering::SeqCst);
        let before = server.requests().len();
        settle_report(&core, file_id, 3000.0, 9000.0);
        let sent: Vec<String> = server.requests()[before..]
            .iter()
            .map(|r| r.url.clone())
            .filter(|u| u.starts_with("/:/"))
            .collect();
        assert_eq!(sent.len(), 1, "{sent:?}");
        assert!(sent[0].contains("time=3000000"), "{sent:?}");
        assert_eq!(core.queued_writes(), 0);

        // the server kept what it was sent, and so does the row it mirrors into
        core.scan_all(false).unwrap();
        assert_eq!(row(&core, file_id).position_secs, 3000.0);
    }

    #[test]
    fn an_item_the_server_will_never_take_is_dropped_and_a_refusal_keeps_the_rest() {
        use crate::plex::fake::{EPISODES_JSON, MOVIES_JSON, SECTIONS_JSON};

        // the movie is deleted on the server partway through, while the two
        // episodes are only ever refused
        let deleted = Arc::new(AtomicBool::new(false));
        let refusing = Arc::new(AtomicBool::new(true));
        let (gone, away) = (deleted.clone(), refusing.clone());
        let server = FakeServer::start(move |req| {
            if req.url.starts_with("/:/") {
                if req.url.contains("ratingKey=101") {
                    return Reply::status(if gone.load(Ordering::SeqCst) {
                        404
                    } else {
                        503
                    });
                }
                return Reply::status(if away.load(Ordering::SeqCst) {
                    503
                } else {
                    200
                });
            }
            if req.url == "/library/sections" {
                return Reply::json(SECTIONS_JSON);
            }
            if req.url.starts_with("/library/sections/1/all") {
                return Reply::json(MOVIES_JSON);
            }
            if req.url.starts_with("/library/sections/2/all") {
                return Reply::json(EPISODES_JSON);
            }
            Reply::status(404)
        });
        let cache = tempfile::tempdir().unwrap();
        let store = Arc::new(MemStore::default());
        let core =
            LexisCore::new(cache.path().to_string_lossy().into_owned(), store.clone()).unwrap();
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
        let mut file_ids: Vec<i64> = Vec::new();
        for kind in [ApiMediaKind::Movie, ApiMediaKind::Show] {
            for title in core.list_titles(kind, 0, 10).unwrap() {
                let db = core.read_db.lock();
                for file in db.title_file_refs(title.id).unwrap() {
                    file_ids.push(file.id);
                }
            }
        }
        // the movie is the oldest of the three, so it is at the head of the
        // drain and can hold the other two back
        assert_eq!(file_ids.len(), 3);
        for (i, id) in file_ids.iter().enumerate() {
            settle_report(&core, *id, 100.0 + i as f64, 9000.0);
        }
        assert_eq!(core.queued_writes(), 3);

        deleted.store(true, Ordering::SeqCst);
        let before = server.requests().len();
        let report = core.scan_all(false).unwrap();
        // the movie is dropped without stopping the drain, and the episode
        // behind it still refuses, which does stop it
        assert_eq!(report.queued_writes, 2);
        let tried = server.requests()[before..]
            .iter()
            .filter(|r| r.url.starts_with("/:/"))
            .count();
        assert_eq!(tried, 2);

        // and what a retry could fix is still owed when the server takes it
        refusing.store(false, Ordering::SeqCst);
        assert_eq!(core.scan_all(false).unwrap().queued_writes, 0);
    }

    #[test]
    fn the_drain_replays_a_flag_and_a_position_in_the_order_they_were_made() {
        // the position is the newer of the two, so the scrobble that would
        // clear it goes out first
        let refusing = Arc::new(AtomicBool::new(false));
        let server = refusing_library(refusing.clone(), 503, true);
        let (_cache, _store, core, file_id) = queued_core(&server);
        let title = core.list_titles(ApiMediaKind::Movie, 0, 10).unwrap()[0].id;
        refusing.store(true, Ordering::SeqCst);
        core.mark_watched(title, true).unwrap_err();
        settle_report(&core, file_id, 200.0, 9000.0);
        assert_eq!(core.queue.lock()[0].wl, Some(false));

        refusing.store(false, Ordering::SeqCst);
        let before = server.requests().len();
        core.scan_all(false).unwrap();
        let sent: Vec<String> = server.requests()[before..]
            .iter()
            .map(|r| r.url.clone())
            .filter(|u| u.starts_with("/:/"))
            .collect();
        assert_eq!(sent.len(), 2, "{sent:?}");
        assert!(sent[0].starts_with("/:/scrobble?"), "{sent:?}");
        assert!(
            sent[1].starts_with("/:/timeline?") && sent[1].contains("time=200000"),
            "{sent:?}"
        );

        // and the other way round: the flag is the newer, so it goes last and
        // the offset it clears is the one the online path would have cleared
        let refusing = Arc::new(AtomicBool::new(false));
        let server = refusing_library(refusing.clone(), 503, true);
        let (_cache, _store, core, file_id) = queued_core(&server);
        let title = core.list_titles(ApiMediaKind::Movie, 0, 10).unwrap()[0].id;
        refusing.store(true, Ordering::SeqCst);
        settle_report(&core, file_id, 200.0, 9000.0);
        core.mark_watched(title, true).unwrap_err();
        assert_eq!(core.queue.lock()[0].wl, Some(true));

        refusing.store(false, Ordering::SeqCst);
        let before = server.requests().len();
        core.scan_all(false).unwrap();
        let sent: Vec<String> = server.requests()[before..]
            .iter()
            .map(|r| r.url.clone())
            .filter(|u| u.starts_with("/:/"))
            .collect();
        assert_eq!(sent.len(), 2, "{sent:?}");
        assert!(
            sent[0].starts_with("/:/timeline?") && sent[0].contains("time=200000"),
            "{sent:?}"
        );
        assert!(sent[1].starts_with("/:/scrobble?"), "{sent:?}");
    }

    #[test]
    fn a_mirror_of_older_server_state_does_not_undo_a_queued_write() {
        // a server that takes the write and still answers with what it had
        let refusing = Arc::new(AtomicBool::new(false));
        let server = refusing_library(refusing.clone(), 503, false);
        let (_cache, _store, core, file_id) = queued_core(&server);
        refusing.store(true, Ordering::SeqCst);
        settle_report(&core, file_id, 3000.0, 9000.0);
        let t1 = row(&core, file_id).updated_at;

        refusing.store(false, Ordering::SeqCst);
        core.scan_all(false).unwrap();

        // the drain sent 3000 at t1 and the mirror answered 1200 at t0
        assert_eq!(row(&core, file_id).position_secs, 3000.0);
        assert_eq!(row(&core, file_id).updated_at, t1);
        assert_eq!(core.queued_writes(), 0);
    }

    #[test]
    fn a_write_still_owed_survives_every_mirror_until_it_lands() {
        let refusing = Arc::new(AtomicBool::new(false));
        let server = refusing_library(refusing.clone(), 503, false);
        let (_cache, _store, core, file_id) = queued_core(&server);
        refusing.store(true, Ordering::SeqCst);
        settle_report(&core, file_id, 3000.0, 9000.0);
        let t1 = row(&core, file_id).updated_at;

        // the state endpoints are still refusing when the next scan runs
        let report = core.scan_all(false).unwrap();
        assert_eq!(report.queued_writes, 1);
        assert_eq!(row(&core, file_id).position_secs, 3000.0);
        assert_eq!(row(&core, file_id).updated_at, t1);
    }

    #[test]
    fn a_purge_and_a_restart_still_owe_the_server_the_same_write() {
        let refusing = Arc::new(AtomicBool::new(false));
        let server = refusing_library(refusing.clone(), 503, true);
        let cache = tempfile::tempdir().unwrap();
        let store = Arc::new(MemStore::default());
        let core =
            LexisCore::new(cache.path().to_string_lossy().into_owned(), store.clone()).unwrap();
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
        refusing.store(true, Ordering::SeqCst);
        settle_report(&core, only_file_id(&core), 3000.0, 9000.0);
        drop(core);

        // a new process, a purged cache, and a server that is back
        let purged = tempfile::tempdir().unwrap();
        let core =
            LexisCore::new(purged.path().to_string_lossy().into_owned(), store.clone()).unwrap();
        assert_eq!(core.queued_writes(), 1);
        refusing.store(false, Ordering::SeqCst);
        core.scan_all(false).unwrap();
        assert_eq!(core.queued_writes(), 0);
        assert_eq!(row(&core, only_file_id(&core)).position_secs, 3000.0);
    }

    #[test]
    fn a_title_played_before_resumes_without_telling_the_server_anything_new() {
        // the shape a rewatch has on the server: a viewCount from the time it
        // was finished, and a viewOffset from where the viewer is now. The row
        // is about the offset; the flag is the server's own and this device
        // has nothing new to say about it.
        let server = FakeServer::start(|req| {
            if req.url.starts_with("/:/") {
                return Reply::status(200);
            }
            if req.url == "/library/sections" {
                return Reply::json(
                    r#"{"MediaContainer":{"size":1,"Directory":[
  {"key":"1","type":"movie","title":"Movies"}
]}}"#,
                );
            }
            if req.url.starts_with("/library/sections/1/all") {
                return Reply::json(&format!(
                    r#"{{"MediaContainer":{{"size":1,"totalSize":1,"Metadata":[
  {{"ratingKey":"101","title":"Dune","year":2021,"viewCount":1,
   "viewOffset":{REFUSING_OFFSET_MS},"duration":9000000,
   "lastViewedAt":{REFUSING_VIEWED_AT},
   "Media":[{{"Part":[{{"id":501,"key":"/library/parts/501/1/Dune.mkv","size":42}}]}}]}}
]}}}}"#
                ));
            }
            Reply::status(404)
        });
        let (_cache, _store, core, file_id) = queued_core(&server);
        assert!(row(&core, file_id).watched);

        let title = core.list_titles(ApiMediaKind::Movie, 0, 10).unwrap()[0].id;
        assert!(
            core.queue(20)
                .unwrap()
                .iter()
                .any(|q| q.item.id == title && q.resume_file_id.is_some()),
            "a film the server holds a live offset for is one to continue"
        );

        settle_report(&core, file_id, 3000.0, 9000.0);
        let sent: Vec<String> = server
            .requests()
            .into_iter()
            .map(|r| r.url)
            .filter(|u| u.starts_with("/:/"))
            .collect();
        assert!(
            sent.iter().any(|u| u.starts_with("/:/timeline")),
            "{sent:?}"
        );
        assert!(
            !sent
                .iter()
                .any(|u| u.starts_with("/:/scrobble") || u.starts_with("/:/unscrobble")),
            "a rewatch must not write a flag the viewer never changed: {sent:?}"
        );

        // and the detail screen carries on from the report, flag untouched
        let detail = core.title_detail(title).unwrap();
        assert!(detail.watched);
        assert_eq!(detail.resume_position_secs, 3000.0);
    }

    #[test]
    fn a_re_assert_never_clears_a_flag_the_queued_entry_does_not_owe() {
        // the one-movie library again, with the item already watched on the
        // server: a rewatch owes it a position and no flag
        let refusing = Arc::new(AtomicBool::new(false));
        let away = refusing.clone();
        let server = FakeServer::start(move |req| {
            if req.url.starts_with("/:/") {
                return Reply::status(if away.load(Ordering::SeqCst) {
                    503
                } else {
                    200
                });
            }
            if req.url == "/library/sections" {
                return Reply::json(
                    r#"{"MediaContainer":{"size":1,"Directory":[
  {"key":"1","type":"movie","title":"Movies"}
]}}"#,
                );
            }
            if req.url.starts_with("/library/sections/1/all") {
                return Reply::json(&format!(
                    r#"{{"MediaContainer":{{"size":1,"totalSize":1,"Metadata":[
  {{"ratingKey":"101","title":"Dune","year":2021,"viewCount":1,
   "viewOffset":{REFUSING_OFFSET_MS},"duration":9000000,
   "lastViewedAt":{REFUSING_VIEWED_AT},
   "Media":[{{"Part":[{{"id":501,"key":"/library/parts/501/1/Dune.mkv","size":42}}]}}]}}
]}}}}"#
                ));
            }
            Reply::status(404)
        });
        let (_cache, _store, core, file_id) = queued_core(&server);
        assert!(row(&core, file_id).watched);

        refusing.store(true, Ordering::SeqCst);
        settle_report(&core, file_id, 3000.0, 9000.0);
        // the report never finished the file, so the entry owes the position
        // alone and the flag is nobody's to answer for but the row's
        assert_eq!(core.queue.lock()[0].w, None);
        assert!(row(&core, file_id).watched);

        refusing.store(false, Ordering::SeqCst);
        core.scan_all(false).unwrap();
        assert_eq!(core.queued_writes(), 0);
        assert_eq!(row(&core, file_id).position_secs, 3000.0);
        assert!(row(&core, file_id).watched);
    }

    #[test]
    fn a_re_assert_puts_back_the_flag_the_queued_entry_owes() {
        // the item is unplayed on the server, and it is the mirror of that
        // state that the entry has to answer for after every scan
        let refusing = Arc::new(AtomicBool::new(false));
        let server = refusing_library(refusing.clone(), 503, true);
        let (_cache, _store, core, file_id) = queued_core(&server);
        assert!(!row(&core, file_id).watched);
        let title = core.list_titles(ApiMediaKind::Movie, 0, 10).unwrap()[0].id;

        refusing.store(true, Ordering::SeqCst);
        core.mark_watched(title, true).unwrap_err();
        assert_eq!(core.queue.lock()[0].w, Some(true));

        // the mirror writes the server's unwatched row, dated before the mark:
        // the flag is still owed, so the entry asserts it back
        let report = core.scan_all(false).unwrap();
        assert_eq!(report.queued_writes, 1);
        assert!(row(&core, file_id).watched);
        assert_eq!(row(&core, file_id).position_secs, 0.0);
    }

    #[test]
    fn a_durable_copy_answers_for_the_flag_a_re_pointed_source_lost() {
        // the same library at another address: the re-point clears the rating
        // keys, so the mark has no server to go to and the copy holds it
        let here = refusing_library(Arc::new(AtomicBool::new(false)), 503, true);
        let there = refusing_library(Arc::new(AtomicBool::new(false)), 503, true);
        let (_cache, _store, core, file_id) = queued_core(&here);
        let title = core.list_titles(ApiMediaKind::Movie, 0, 10).unwrap()[0].id;
        core.add_or_replace(
            PlexModule.id(),
            "plex1".into(),
            std::collections::BTreeMap::from([
                ("base_url".to_string(), there.base_url.clone()),
                ("token".to_string(), "s3cr3t".into()),
            ]),
        )
        .unwrap();
        core.mark_watched(title, true).unwrap();
        assert!(core.watch.lock()[0].w);

        // the sync re-keys the file and mirrors the new server's row, dated
        // before the mark: the copy answers for the flag it read off that row
        core.scan_all(false).unwrap();
        assert!(row(&core, file_id).watched);
    }
}
