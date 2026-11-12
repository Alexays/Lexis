use super::{unix_now, CoreError, LexisCore, TMDB_KEY};
use crate::embed::download::{discard_damaged, model_files};
use crate::embed::model::EmbedModel;
use crate::embed::pass::semantic_pending;
use crate::embed::EmbedError;
use crate::embed::Encoder;
use crate::index::MediaKind;
use crate::metadata::client::TmdbClient;
use crate::metadata::enrich::{backfill_keywords, enrich_pending, EnrichError};
use crate::metadata::similar::{fetch_similar_pending, SimilarError};
use crate::slice::Slice;
use parking_lot::{Condvar, Mutex};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Weak};
use std::time::{Duration, Instant};

/// How old the stored trending may be before a pass asks again: TMDB moves
/// its week every day.
const TRENDING_EVERY_SECS: i64 = 86_400;
/// Pages of twenty asked for each kind: a library holds only a few of any
/// hundred titles the world is watching.
const TRENDING_PAGES: u32 = 10;

/// How long one batch of any of the four queues may hold the pass thread
/// before it looks at the world again. This, and not a count of titles, is
/// what a pause waits for: an item is an HTTP request on two of these queues,
/// a forward pass through an encoder on the third and a query on the fourth,
/// so no one count of them means the same thing twice. What it costs to make
/// it short is one queue query per slice, which every queue here dwarfs with a
/// single item.
const PASS_SLICE: Duration = Duration::from_millis(200);
/// How often a running pass says where it got to. A queue that takes twenty
/// minutes and one that is wedged look the same from outside a silent pass,
/// and this is what tells them apart without making a log of it.
const PASS_REPORT: Duration = Duration::from_secs(10);
/// Titles one metadata queue query reads ahead. Each one is a search and up to
/// three more requests to TMDB, so the slice above almost always ends the
/// batch first; this only keeps the read from being larger than a batch could
/// ever use.
const BATCH: u32 = 5;
/// Titles one embedding queue query reads ahead. Embedding a title is a
/// forward pass through the encoder, which is milliseconds on a Mac and more
/// on a television: the slice decides how many of these a batch does, and this
/// is the ceiling on rows read to find them.
const EMBED_BATCH: u32 = 32;
/// Seeds one semantic-neighbour query reads ahead. Measured: a full sweep of
/// the owner's 3785-vector library took 109 ms in a release build on an Apple
/// M4 Pro, and tvOS hardware is slower. The slice above is what answers that
/// now, by ending a batch at a seed rather than at a count.
///
/// Raising it would amortise the whole-table read every batch makes before its
/// first seed, but it also decides the size of the one transaction that writes
/// the batch back, and that transaction holds the write connection a playback
/// report queues behind. Neither end of that is measured on the device, so the
/// number stays where it was.
const SEMANTIC_BATCH: u32 = 50;
/// Consecutive failing embedding batches before the pass leaves the queue for
/// the next one. A scan pruning a title mid-batch fails this batch and no
/// other; a broken model would fail all of them, and the rows work without
/// vectors.
const EMBED_TRIES: u32 = 3;
/// Consecutive metadata batches in which every title asked about failed,
/// before the pass gives up on TMDB for this run. A batch is a slice of time
/// and can be a single request, so this is the count that carries the meaning
/// a five-title batch used to carry on its own: one failure is a title, five
/// in a row is TMDB.
const TMDB_TRIES: u32 = 5;
/// How long the pass thread waits before looking again at a queue it may not
/// work yet because a tile is still waiting for its poster.
const PASS_IDLE: Duration = Duration::from_millis(50);

#[derive(Debug, Default)]
pub struct EnrichReport {
    pub attempted: u32,
    pub matched: u32,
    pub failed: u32,
    /// How long TMDB asked to be left alone for, 0 when it did not ask. The
    /// batch stopped there with its queue intact, so a caller that waits this
    /// out and calls again resumes rather than starting over.
    pub retry_after_secs: u32,
}

/// The background pass's own three totals against the library's size, read at
/// rest: whether or not a pass is running right now, this is what the index
/// actually holds.
#[derive(Debug, Default, uniffi::Record)]
pub struct PassProgress {
    pub total: u32,
    pub described: u32,
    pub linked: u32,
    pub embedded: u32,
}

#[derive(Debug, Default)]
pub struct SimilarReport {
    pub attempted: u32,
    pub linked: u32,
    pub failed: u32,
    /// How long TMDB asked to be left alone for, 0 when it did not ask, read
    /// exactly like `EnrichReport::retry_after_secs`.
    pub retry_after_secs: u32,
}

/// What one embedding batch did. `ready` is false when there is no model on
/// the device and none could be fetched, which is not an error: the rows fall
/// back to the links TMDB gave (spec: Errors and degraded modes).
#[derive(Debug, Default)]
pub struct EmbedReport {
    /// Read by the tests' batch drivers; the pass reads its own stats.
    #[cfg_attr(not(test), allow(dead_code))]
    pub attempted: u32,
    pub embedded: u32,
    pub ready: bool,
}

/// What one semantic-neighbour batch did, out of the titles whose vector is
/// new since their row was last written. `empty` is titles the floor in
/// `nearest` left with no neighbour, not a failure of the batch.
#[derive(Debug, Default)]
pub struct SemanticReport {
    /// Read by the tests' batch drivers; the pass reads its own stats.
    #[cfg_attr(not(test), allow(dead_code))]
    pub attempted: u32,
    pub linked: u32,
    pub empty: u32,
}

/// Which of the four queues the pass is on. They run in this order because
/// each reads what the one before it wrote: the links need the ids enrichment
/// found, the vectors need the descriptions, the sweep needs the vectors.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, uniffi::Enum)]
pub enum PassPhase {
    /// Nothing has started one yet.
    #[default]
    Idle,
    Describing,
    Linking,
    Embedding,
    /// The neighbour sweep over the whole library (spec: Recommendations).
    Semantic,
    /// Every queue is drained, or one of them cannot go on. `note` says which.
    Done,
}

/// Why a pass is saying something, for whoever draws it to put in its own
/// words. Only the detail of the last two is in the core's words, and that
/// detail is whatever sqlite or an HTTP client said.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum PassNote {
    /// There is no model on this device and none could be fetched, which is
    /// not a failure: the rows fall back to the links TMDB gave (spec: Errors
    /// and degraded modes).
    NoModel,
    /// Every title of a batch failed. TMDB is not answering, and the queue is
    /// ordered by id, so the next batch would block on the same titles.
    TmdbSilent,
    /// The model this device holds is not the pinned one, and no batch will
    /// change that.
    ModelUnusable { msg: String },
    /// The phase stopped on something else worth reading.
    Failed { msg: String },
}

/// What the pass in the core is doing and what it has done since it started.
/// Read by whoever draws progress, as often as it likes: answering costs a
/// mutex, never a batch.
#[derive(Debug, Clone, Default, PartialEq, Eq, uniffi::Record)]
pub struct PassRun {
    pub phase: PassPhase,
    pub described: u32,
    pub linked: u32,
    pub embedded: u32,
    pub semantic: u32,
    pub note: Option<PassNote>,
}

/// The pass's own state, and the thread running it.
#[derive(Default)]
struct PassWork {
    run: PassRun,
    /// Whether a thread is alive to run the batches.
    working: bool,
    /// A scan landed during the metadata phases, which only move forward: the
    /// titles it indexed carry no metadata row, so the phase in flight hands
    /// the pass back to the start rather than leaving them undescribed.
    rescan: bool,
    /// Consecutive failing embedding batches, and zero on entry to every pass.
    embed_tries: u32,
    /// Consecutive metadata batches every title of which failed, zero on entry
    /// to every pass and on every batch TMDB answered.
    tmdb_fails: u32,
    /// When TMDB asked to be left alone until. The batch stopped with its
    /// queue intact, so waiting is what resumes it, where asking again now
    /// would spend the next batch collecting the same 429.
    resume_at: Option<Instant>,
}

#[derive(Default)]
pub(super) struct PassQueue {
    work: Mutex<PassWork>,
    woken: Condvar,
    /// Set while a film plays: the player owns the network and the cores. It
    /// sits outside the mutex because the batch in flight reads it between
    /// items, which is the whole of how quickly a pass stands aside.
    paused: AtomicBool,
}

#[uniffi::export]
impl LexisCore {
    /// Asks TMDB for the week's trending, films and shows, when what the
    /// index holds is a day old or was never fetched: what the popular rows
    /// are drawn from. Returns at once: the fetch has a thread of its own, and
    /// never runs twice at once.
    pub fn refresh_trending(&self) {
        // the reading connection: a scan can hold the writing one for minutes
        let fresh = self
            .read_db
            .lock()
            .trending_fetched_at()
            .ok()
            .flatten()
            .is_some_and(|at| unix_now() - at < TRENDING_EVERY_SECS);
        if fresh || self.tmdb_key().is_none() || self.trending.swap(true, Ordering::SeqCst) {
            return;
        }
        let Some(this) = self.self_ref.upgrade() else {
            self.trending.store(false, Ordering::SeqCst);
            return;
        };
        std::thread::Builder::new()
            .name("lexis.trending".into())
            .spawn(move || {
                crate::lower_thread_qos();
                if let Some(key) = this.tmdb_key() {
                    let client = this.tmdb_client(&key);
                    for kind in [MediaKind::Movie, MediaKind::Show] {
                        let mut ids = Vec::new();
                        for page in 1..=TRENDING_PAGES {
                            match client.trending(kind, page) {
                                Ok(found) => ids.extend(found),
                                Err(e) => {
                                    eprintln!("[lexis-core] trending {}: {e}", kind.as_str());
                                    break;
                                }
                            }
                        }
                        // nothing at all is a failure, asked again at the next pass
                        if !ids.is_empty() {
                            let stored = this.db.lock().replace_trending(kind, &ids, unix_now());
                            if let Err(e) = stored {
                                eprintln!("[lexis-core] trending {}: {e}", kind.as_str());
                            }
                        }
                    }
                }
                this.trending.store(false, Ordering::SeqCst);
            })
            .expect("spawn a thread");
    }

    /// Runs the four queues, in order, on a thread of the core's own: the
    /// call itself only wakes that thread. Called at launch and after every
    /// scan; a pass already on the metadata queues is sent back to the first
    /// one rather than doubled, since the titles a scan just indexed carry no
    /// metadata row.
    ///
    /// Nothing here waits for a batch. `pass_now` is how a caller finds out
    /// what happened.
    pub fn start_pass(&self) {
        let mut work = self.passes.work.lock();
        if matches!(work.run.phase, PassPhase::Describing | PassPhase::Linking) {
            // 'embedding' is deliberately not here: it takes the reset below,
            // which is the only thing that clears embed_tries.
            work.rescan = true;
            return;
        }
        work.run = PassRun {
            phase: PassPhase::Describing,
            ..PassRun::default()
        };
        work.rescan = false;
        work.embed_tries = 0;
        work.tmdb_fails = 0;
        work.resume_at = None;
        if !work.working {
            // None only while the core itself is being dropped, which cannot
            // be happening: this is running on a live instance
            if let Some(this) = self.self_ref.upgrade() {
                work.working = true;
                std::thread::Builder::new()
                    .name("lexis.pass".into())
                    .spawn(move || {
                        crate::lower_thread_qos();
                        run_pass(Arc::downgrade(&this))
                    })
                    .expect("spawn a thread");
            }
        }
        drop(work);
        self.passes.woken.notify_all();
    }

    /// Where the pass has got to. Costs a mutex, so a caller drawing progress
    /// may ask on every frame.
    pub fn pass_now(&self) -> PassRun {
        self.passes.work.lock().run.clone()
    }

    /// Holds the pass while something else owns the device, playback above
    /// all. The batch in flight stops at its next item, one TMDB round trip or
    /// one forward pass away; what is queued stays queued, and resuming picks
    /// the queue up where it stopped.
    ///
    /// The flag is set under the same lock the pass thread waits on, so a
    /// resume can never be lost between the two.
    pub fn pause_pass(&self, paused: bool) {
        {
            let _waiting = self.passes.work.lock();
            self.passes.paused.store(paused, Ordering::Relaxed);
        }
        self.passes.woken.notify_all();
    }
}

impl LexisCore {
    /// One batch of whichever queue the pass is on, and what it did to the
    /// phase. Runs on the pass thread, holding no lock across the batch: what
    /// it reads and writes is the snapshot `pass_now` answers from.
    fn pass_batch(&self, slice: &Slice) {
        let phase = self.passes.work.lock().run.phase;
        match phase {
            PassPhase::Describing | PassPhase::Linking => {
                let describing = phase == PassPhase::Describing;
                // the two TMDB phases differ only in their batch, their
                // counter and the phase after them
                let (outcome, next) = if describing {
                    let outcome = self.enrich_batch(BATCH, slice);
                    let outcome =
                        outcome.map(|r| (r.attempted, r.failed, r.retry_after_secs, r.matched));
                    (outcome, PassPhase::Linking)
                } else {
                    let outcome = self.similar_batch(BATCH, slice);
                    let outcome =
                        outcome.map(|r| (r.attempted, r.failed, r.retry_after_secs, r.linked));
                    (outcome, PassPhase::Embedding)
                };
                let mut work = self.passes.work.lock();
                match outcome {
                    Ok((attempted, failed, retry_after_secs, done)) => {
                        let stalled = tmdb_silent(&mut work, attempted, failed);
                        if retry_after_secs > 0 {
                            work.resume_at = Some(
                                Instant::now() + Duration::from_secs(u64::from(retry_after_secs)),
                            );
                        }
                        if describing {
                            work.run.described += done;
                        } else {
                            work.run.linked += done;
                        }
                        // a rate-limited batch stopped on a queue it did not
                        // empty, and so did one the slice cut short: an
                        // attempted of zero is the end of the phase only when
                        // neither of those is what held it back
                        let drained = attempted == 0 && !slice.expired();
                        if work.resume_at.is_none() && (drained || stalled) {
                            work.run.phase = next;
                            work.tmdb_fails = 0;
                        }
                        if stalled {
                            work.run.note = Some(PassNote::TmdbSilent);
                        }
                    }
                    // quietly: a library works without TMDB (spec: Errors and
                    // degraded modes). TMDB itself is what failed, not one
                    // title's row, so this phase cannot make more progress
                    // this pass - but the next one can, and is asked for
                    // regardless.
                    Err(e) => {
                        work.run.note = Some(PassNote::Failed { msg: e.to_string() });
                        work.run.phase = next;
                        work.tmdb_fails = 0;
                    }
                }
            }
            PassPhase::Embedding => {
                let outcome = self.embed_batch(EMBED_BATCH, slice);
                let mut work = self.passes.work.lock();
                match outcome {
                    Ok((report, drained)) => {
                        work.embed_tries = 0;
                        work.run.embedded += report.embedded;
                        // no model on the device is not a failure to report
                        // either: there is no key to ask anyone for. It is the
                        // one silent case worth naming, since an empty queue
                        // ends the phase the same way and needs no
                        // explanation. Either way the sweep still runs: it
                        // reads vectors already on disk and needs no model.
                        if !report.ready {
                            work.run.note = Some(PassNote::NoModel);
                        }
                        if drained || !report.ready {
                            work.run.phase = PassPhase::Semantic;
                        }
                    }
                    // the artifact on this device is not the pinned one, and
                    // no batch will change that: the pass ends here, and the
                    // reason ends up where it can be read rather than nowhere
                    Err(CoreError::EmbedModelUnusable { msg }) => {
                        work.run.note = Some(PassNote::ModelUnusable { msg });
                        work.run.phase = PassPhase::Done;
                    }
                    // routine (a scan pruned a title mid-batch), not a reason
                    // to alarm the viewer: the next pass tries the queue again
                    // on its own, and the sweep still has whatever vectors
                    // already embedded to reach
                    Err(_) => {
                        work.embed_tries += 1;
                        if work.embed_tries >= EMBED_TRIES {
                            work.run.phase = PassPhase::Semantic;
                        }
                    }
                }
            }
            PassPhase::Semantic => {
                let outcome = self.semantic_batch(SEMANTIC_BATCH, slice);
                let mut work = self.passes.work.lock();
                match outcome {
                    Ok((report, drained)) => {
                        work.run.semantic += report.linked + report.empty;
                        if drained {
                            work.run.phase = PassPhase::Done;
                        }
                    }
                    // a scan pruning a title mid-read, the same routine case
                    // embedding tolerates above; there is nothing after this
                    // phase to hand off to, so the pass simply ends
                    Err(e) => {
                        work.run.note = Some(PassNote::Failed { msg: e.to_string() });
                        work.run.phase = PassPhase::Done;
                    }
                }
            }
            PassPhase::Idle | PassPhase::Done => {}
        }
        let mut work = self.passes.work.lock();
        if work.rescan {
            work.rescan = false;
            work.run.phase = PassPhase::Describing;
        }
        if work.run.phase != phase {
            let run = &work.run;
            eprintln!(
                "[lexis-core] pass: {phase:?} -> {:?} (described {}, linked {}, embedded {}, \
                 semantic {}, note {:?})",
                run.phase, run.described, run.linked, run.embedded, run.semantic, run.note
            );
        }
    }
}

/// Whether TMDB has stopped answering, from one metadata batch's tally. A
/// batch is a slice of time and routinely holds a single request, so the
/// verdict is `TMDB_TRIES` batches that failed outright in a row rather than
/// any one of them: a title nobody could reach is a title, and the queue is
/// ordered by id, so the batch after a run of those would block on the same
/// ones.
fn tmdb_silent(work: &mut PassWork, attempted: u32, failed: u32) -> bool {
    if attempted == 0 {
        return false;
    }
    if failed == attempted {
        work.tmdb_fails += 1;
    } else {
        work.tmdb_fails = 0;
    }
    work.tmdb_fails >= TMDB_TRIES
}

/// The pass thread: one slice at a time, for as long as a queue has anything
/// in it. It holds no reference to the core between batches, so a core
/// dropped while this runs takes the thread with it at the next one.
fn run_pass(core: Weak<LexisCore>) {
    let mut said = Instant::now();
    loop {
        let Some(this) = core.upgrade() else {
            return;
        };
        {
            let mut work = this.passes.work.lock();
            loop {
                if matches!(work.run.phase, PassPhase::Idle | PassPhase::Done) {
                    // every queue is drained: the next pass is a launch or a
                    // scan away, and start_pass starts a thread again
                    work.working = false;
                    return;
                }
                let waiting = match work.resume_at {
                    Some(at) => at.checked_duration_since(Instant::now()),
                    None => None,
                };
                if waiting.is_none() {
                    work.resume_at = None;
                }
                let paused = this.passes.paused.load(Ordering::Relaxed);
                // artwork is what the viewer is looking at and a batch is not
                if !paused && waiting.is_none() && !this.artwork.busy() {
                    break;
                }
                if paused {
                    // the encoder's heap tensors go back to the system for the
                    // length of the film; the next batch reads them off the
                    // mapping again. Absent and Broken stay: they are answers.
                    let mut model = this.model.lock();
                    if matches!(*model, Some(ModelState::Ready(_))) {
                        *model = None;
                    }
                    drop(model);
                    // no timeout: pause_pass(false) notifies under this lock
                    this.passes.woken.wait(&mut work);
                } else {
                    this.passes
                        .woken
                        .wait_for(&mut work, waiting.unwrap_or(PASS_IDLE));
                }
            }
        }
        this.pass_batch(&Slice::of(PASS_SLICE, &this.passes.paused));
        // on the clock rather than every batch: a batch is a fifth of a second
        // and this has to be readable by whoever is watching a long queue move
        if said.elapsed() >= PASS_REPORT {
            said = Instant::now();
            let run = this.pass_now();
            eprintln!(
                "[lexis-core] pass: {:?} (described {}, linked {}, embedded {}, semantic {})",
                run.phase, run.described, run.linked, run.embedded, run.semantic
            );
        }
    }
}

/// How long the encoder stays in memory after the last question asked in
/// words, when the pass is not using it: long enough for a viewer rewording
/// a question, short of holding its tensors through the film it found.
const ASK_IDLE: Duration = if cfg!(test) {
    Duration::from_millis(300)
} else {
    Duration::from_secs(60)
};

/// What the first batch found the embedding model to be. Every batch after it
/// reads this instead of the cache directory.
#[derive(Clone)]
pub(super) enum ModelState {
    Ready(Arc<EmbedModel>),
    /// Nothing pinned, nothing installed, or nothing that could be fetched:
    /// the feature is off, which is not a failure (spec: Errors and degraded
    /// modes).
    Absent,
    /// Pinned, and what came back is not it.
    Broken(String),
    /// The download stood aside for playback. Never memoized: the next batch
    /// resumes it.
    Deferred,
}

#[uniffi::export]
impl LexisCore {
    /// The user's own TMDB token, from the same account page as the v3 key.
    /// Only the v4 "API Read Access Token" works as a Bearer credential, so a
    /// pasted v3 key is refused here rather than 401ing on every enrichment.
    pub fn set_tmdb_key(&self, key: String) -> Result<(), CoreError> {
        let key = key.trim();
        if key.is_empty() {
            return Err(CoreError::InvalidConfig {
                msg: "the TMDB token must not be empty".to_string(),
            });
        }
        if key.len() == 32 && key.chars().all(|c| c.is_ascii_hexdigit()) {
            return Err(CoreError::InvalidConfig {
                msg: "that is the TMDB API Key (v3); Lexis needs the API Read Access Token \
                      from the same page"
                    .to_string(),
            });
        }
        self.store
            .set(TMDB_KEY.to_string(), key.as_bytes().to_vec());
        Ok(())
    }

    pub fn has_tmdb_key(&self) -> bool {
        self.tmdb_key().is_some()
    }

    /// Forgets the stored token: the way back from one the user revoked, and
    /// the way to stop asking TMDB at all. Enrichment falls back to reporting
    /// zero, the same as before a key was ever set.
    pub fn clear_tmdb_key(&self) {
        self.store.set(TMDB_KEY.to_string(), Vec::new());
    }

    /// What the background pass has done, at any time: the library's size and
    /// how much of it is described, linked and vectorized. Diagnostics reads
    /// this on its own, apart from the pass itself, so the counts hold even
    /// when nothing has ticked since launch.
    pub fn pass_progress(&self) -> Result<PassProgress, CoreError> {
        let counts = {
            let db = self.read_db.lock();
            Encoder::chosen(&db).and_then(|e| db.pass_counts(e.version()))
        }
        .map_err(|e| CoreError::Storage { msg: e.to_string() })?;
        Ok(PassProgress {
            total: counts.total,
            described: counts.described,
            linked: counts.linked,
            embedded: counts.embedded,
        })
    }

    /// The encoder this device runs, as a key: "small" unless somebody chose
    /// "base" on the diagnostic screen.
    pub fn encoder(&self) -> Result<String, CoreError> {
        let db = self.read_db.lock();
        Ok(Encoder::chosen(&db)?.key().to_string())
    }

    /// Switches the encoder. Every vector the other one wrote is then owed a
    /// recompute by the next pass (`start_pass`), so the model in memory is let
    /// go: the rows keep what the old vectors linked until the new ones
    /// replace them, and the two encoders' vectors are never compared.
    /// The taste is read off the chosen encoder's vectors alone, so it stays
    /// empty until the pass has re-embedded the library (and, for "base",
    /// downloaded the model): no safe bet from the taste and no taste rows
    /// until then. The diagnostic screen says so beside the toggle.
    pub fn set_encoder(&self, model: String) -> Result<(), CoreError> {
        let Some(encoder) = Encoder::from_key(&model) else {
            return Err(CoreError::Storage {
                msg: format!("unknown encoder {model}"),
            });
        };
        self.db
            .lock()
            .set_setting(crate::embed::ENCODER_SETTING, encoder.key())?;
        let source = encoder.source();
        #[cfg(test)]
        let source = source.offline();
        *self.model_source.lock() = source;
        *self.model.lock() = None;
        *self.semantic_library.lock() = None;
        Ok(())
    }
}

#[cfg(test)]
impl LexisCore {
    /// Describes up to `limit` titles nothing has described yet. Without a key
    /// it is a no-op reporting zero, never an error: the library works without
    /// TMDB (spec: Errors and degraded modes). Call it again to continue.
    /// A rejected key fails as `Unauthorized` on the pseudo-source id "tmdb".
    pub fn enrich_pending(&self, limit: u32) -> Result<EnrichReport, CoreError> {
        self.enrich_batch(limit, &Slice::open())
    }

    /// Fetches the TMDB "similar" links for up to `limit` matched titles that
    /// have none, so the rows have something to join against. Without a key it
    /// is a no-op reporting zero, never an error, exactly like
    /// `enrich_pending`; a rejected key fails as `Unauthorized` on the
    /// pseudo-source id "tmdb". Call it again to continue.
    pub fn fetch_similar(&self, limit: u32) -> Result<SimilarReport, CoreError> {
        self.similar_batch(limit, &Slice::open())
    }

    /// Embeds up to `limit` titles that are owed a vector. Never an error when
    /// the model is missing: it reports `ready: false` and the rows keep the
    /// behaviour they had. Call it again to continue.
    ///
    /// `EmbedModelUnusable` is the one failure a caller must not retry: the
    /// model this device holds is not the pinned one and no batch will change
    /// that. `Storage` is the retryable one, a title pruned by a scan mid-pass.
    pub fn embed_pending(&self, limit: u32) -> Result<EmbedReport, CoreError> {
        self.embed_batch(limit, &Slice::open())
            .map(|(report, _)| report)
    }

    /// Links up to `limit` titles whose vector is new since their neighbours
    /// were last computed, or that have never been looked at: the incremental
    /// half of the full-library sweep (spec: Recommendations). A
    /// title stays linked across calls once reached, so a sweep stopped after
    /// any batch has already banked that many titles and the next one resumes
    /// rather than starting over. Call it again until `attempted` is zero.
    pub fn link_semantic(&self, limit: u32) -> Result<SemanticReport, CoreError> {
        self.semantic_batch(limit, &Slice::open())
            .map(|(report, _)| report)
    }
}

impl LexisCore {
    /// The same, for as long as `slice` lasts: what the pass calls, and the
    /// only difference between a caller waiting for an answer and a background
    /// queue that must give the thread back.
    fn enrich_batch(&self, limit: u32, slice: &Slice) -> Result<EnrichReport, CoreError> {
        let Some(key) = self.tmdb_key() else {
            return Ok(EnrichReport::default());
        };
        let now = unix_now();
        let client = self.tmdb_client(&key);
        let tmdb = |e| match e {
            EnrichError::Index(e) => CoreError::Storage { msg: e.to_string() },
            EnrichError::Unauthorized => CoreError::Unauthorized {
                source_id: "tmdb".to_string(),
            },
        };
        let mut stats = enrich_pending(&self.db, &client, limit, now, slice).map_err(tmdb)?;
        // what is left of the batch goes to the keywords, so the phase only
        // ends once every placed title has been asked for them too
        if stats.retry_after_secs == 0 && stats.attempted < limit && !slice.expired() {
            let left = limit - stats.attempted;
            backfill_keywords(&self.db, &client, left, now, slice, &mut stats).map_err(tmdb)?;
        }
        Ok(EnrichReport {
            attempted: stats.attempted,
            matched: stats.matched,
            failed: stats.failed,
            retry_after_secs: stats.retry_after_secs,
        })
    }

    /// The same, for as long as `slice` lasts: what the pass calls.
    fn similar_batch(&self, limit: u32, slice: &Slice) -> Result<SimilarReport, CoreError> {
        let Some(key) = self.tmdb_key() else {
            return Ok(SimilarReport::default());
        };
        let client = self.tmdb_client(&key);
        let stats =
            fetch_similar_pending(&self.db, &client, limit, slice).map_err(|e| match e {
                SimilarError::Index(e) => CoreError::Storage { msg: e.to_string() },
                SimilarError::Unauthorized => CoreError::Unauthorized {
                    source_id: "tmdb".to_string(),
                },
            })?;
        Ok(SimilarReport {
            attempted: stats.attempted,
            linked: stats.linked,
            failed: stats.failed,
            retry_after_secs: stats.retry_after_secs,
        })
    }

    /// The same, for as long as `slice` lasts: what the pass calls.
    /// One batch, and whether it found the queue empty: read once, here, so
    /// letting the model go and ending the phase follow the same reading of a
    /// slice that can expire between two.
    fn embed_batch(&self, limit: u32, slice: &Slice) -> Result<(EmbedReport, bool), CoreError> {
        let version = Encoder::chosen(&self.db.lock())
            .map_err(|e| CoreError::Storage { msg: e.to_string() })?
            .version();
        let owed = crate::embed::pass::embedding_owed(&self.db, version)
            .map_err(|e| CoreError::Storage { msg: e.to_string() })?;
        if !owed {
            // nothing to embed: the model is not read for it, and one an
            // earlier batch held is let go
            *self.model.lock() = None;
            let report = EmbedReport {
                ready: true,
                ..EmbedReport::default()
            };
            return Ok((report, true));
        }
        let model = match self.embed_model() {
            ModelState::Ready(model) => model,
            ModelState::Absent => return Ok((EmbedReport::default(), false)),
            ModelState::Broken(msg) => return Err(CoreError::EmbedModelUnusable { msg }),
            // ready as far as the phase is concerned: it stays on this queue
            ModelState::Deferred => {
                let report = EmbedReport {
                    ready: true,
                    ..EmbedReport::default()
                };
                return Ok((report, false));
            }
        };
        let batch = crate::embed::pass::embed_pending(&self.db, &model, limit, unix_now(), slice);
        let stats = batch.map_err(|e| match e {
            // a title a scan pruned between the queue query and the write:
            // the next batch walks past it
            EmbedError::Index(msg) => CoreError::Storage { msg },
            // a forward pass that will not run is this model on this
            // device, and no batch will change that
            other => CoreError::EmbedModelUnusable {
                msg: other.to_string(),
            },
        })?;
        // never for a batch the slice cut to nothing: that queue is not empty,
        // and dropping the model there would buy a fresh read of the artifact
        // every time a viewer pressed play
        let drained = stats.attempted == 0 && !slice.expired();
        if drained {
            // the batch that finds the queue empty is the last one of the pass,
            // and the next pass is a launch or a scan away: the encoder's
            // tensors and its 449 MiB mapping are not worth holding for it,
            // least of all behind a film. What it costs is one read of the
            // artifact per pass instead of one per process, which is why this
            // is the empty queue rather than the end of every batch.
            *self.model.lock() = None;
        }
        let report = EmbedReport {
            attempted: stats.attempted,
            embedded: stats.embedded,
            ready: true,
        };
        Ok((report, drained))
    }

    /// The same, for as long as `slice` lasts: what the pass calls.
    fn semantic_batch(
        &self,
        limit: u32,
        slice: &Slice,
    ) -> Result<(SemanticReport, bool), CoreError> {
        let now = unix_now();
        let version = Encoder::chosen(&self.db.lock())
            .map_err(|e| CoreError::Storage { msg: e.to_string() })?
            .version();
        let stats = semantic_pending(&self.db, &self.semantic_library, version, limit, now, slice)
            .map_err(|e| CoreError::Storage { msg: e.to_string() })?;
        // the same reading as the empty embedding queue: a slice that ran out
        // before the first seed has swept nothing
        let drained = stats.attempted == 0 && !slice.expired();
        if drained {
            // the sweep is done, so every vector the fingerprint reads is the
            // current one: this is where the taste row is worth recomputing,
            // and it costs less than the batch that came before it. Off this
            // thread's lock now: the worker takes what it needs itself.
            self.kick_taste_refresh();
        }
        let report = SemanticReport {
            attempted: stats.attempted,
            linked: stats.linked,
            empty: stats.empty,
        };
        Ok((report, drained))
    }

    /// The model, downloading it once if the cache does not hold it, and then
    /// answered from memory: `embed_pending` runs on every tick of the
    /// background pass, and reading 83 MiB of tensors or making a fresh
    /// connect per call is what this spares it. A device that comes online after this answered installs
    /// the model on the next launch rather than on the next tick.
    ///
    /// The memo holds for a pass, not for the process: the batch that empties
    /// the queue clears it, so what is memoized here is a model something is
    /// still being embedded against. `Absent` and `Broken` are the answer
    /// until the cache is purged, and neither is ever cleared.
    ///
    /// Only the memo is locked, and never across the download: two calls
    /// racing here install the same bytes twice at worst, and no batch waits
    /// behind another's fetch.
    fn embed_model(&self) -> ModelState {
        if let Some(resolved) = self.model.lock().as_ref() {
            return resolved.clone();
        }
        // the resolve URL answers with a 302 to a signed CDN URL, so this is
        // the one client here that follows redirects: the request carries no
        // header and the digest pins what comes back, so the host that ends up
        // serving the bytes decides nothing.
        //
        // The read timeout is generous because the weights are 449 MiB: a
        // household line that takes minutes over them is slow, not broken.
        let agent = ureq::AgentBuilder::new()
            .timeout_connect(std::time::Duration::from_secs(10))
            .timeout_read(std::time::Duration::from_secs(900))
            .redirects(5)
            .build();
        let source = self.model_source.lock().clone();
        let state = match model_files(&agent, &self.cache_dir, &source, &self.passes.paused) {
            Err(EmbedError::Paused) => return ModelState::Deferred,
            // bytes that are not the pinned artifact, and a launch that fetches
            // them again gets the same ones: a mispasted digest, a mispasted
            // URL, or a host serving something else. None of the three is worth
            // half a gigabyte of download per call to rediscover.
            Err(e @ (EmbedError::Checksum | EmbedError::Format(_) | EmbedError::TooLarge)) => {
                ModelState::Broken(e.to_string())
            }
            fetched => {
                let artifact = match fetched {
                    Ok(Some(artifact)) => artifact,
                    // nothing pinned to fetch, or a fetch the network may
                    // answer another day: whatever the cache holds for this pin
                    _ => source.artifact(&self.cache_dir),
                };
                match EmbedModel::load(&artifact) {
                    Ok(Some(model)) => ModelState::Ready(Arc::new(model)),
                    Ok(None) => ModelState::Absent,
                    // the answer for this process; a cached file whose bytes
                    // have rotted is dropped so the next launch fetches it again
                    Err(e) => {
                        discard_damaged(&self.cache_dir, &source);
                        ModelState::Broken(e.to_string())
                    }
                }
            }
        };
        // once per process, the first time embed_pending asks: nothing else
        // here says why the vectors never move, and this is the only line
        // that can, over a console attached to the process
        match &state {
            ModelState::Ready(m) => {
                eprintln!(
                    "[lexis-core] embedding model: ready ({} dims, {} layers)",
                    m.dims(),
                    m.layers()
                );
            }
            ModelState::Absent if !source.is_pinned() => {
                eprintln!("[lexis-core] embedding model: absent, no artifact pinned");
            }
            ModelState::Absent => {
                eprintln!("[lexis-core] embedding model: absent, pinned artifact not fetched yet");
            }
            ModelState::Broken(msg) => eprintln!("[lexis-core] embedding model: broken: {msg}"),
            ModelState::Deferred => {}
        }
        *self.model.lock() = Some(state.clone());
        state
    }

    /// The encoder for a question asked in words: the one the pass holds, or
    /// read off the cache into the same memo, never fetched. None when the
    /// device has none. It is let go `ASK_IDLE` after the last question,
    /// unless the pass is embedding and will let it go when its queue empties.
    pub(super) fn ask_model(&self) -> Option<Arc<EmbedModel>> {
        let held = match self.model.lock().as_ref() {
            Some(ModelState::Ready(model)) => Some(model.clone()),
            Some(ModelState::Absent | ModelState::Broken(_)) => return None,
            Some(ModelState::Deferred) | None => None,
        };
        let model = match held {
            Some(model) => model,
            None => {
                let artifact = self.model_source.lock().artifact(&self.cache_dir);
                let model = Arc::new(EmbedModel::load(&artifact).ok().flatten()?);
                // whoever resolved the memo first is the one instance kept
                match self
                    .model
                    .lock()
                    .get_or_insert_with(|| ModelState::Ready(model))
                {
                    ModelState::Ready(model) => model.clone(),
                    _ => return None,
                }
            }
        };
        let mut used = self.ask_used.lock();
        let waiting = used.is_some();
        *used = Some(Instant::now());
        drop(used);
        if !waiting {
            let core = self.self_ref.clone();
            std::thread::spawn(move || loop {
                let Some(this) = core.upgrade() else {
                    return;
                };
                let idle = {
                    let mut used = this.ask_used.lock();
                    let idle = used.map_or(ASK_IDLE, |at| at.elapsed());
                    if idle >= ASK_IDLE {
                        *used = None;
                        if this.passes.work.lock().run.phase != PassPhase::Embedding {
                            let mut model = this.model.lock();
                            if matches!(*model, Some(ModelState::Ready(_))) {
                                *model = None;
                            }
                        }
                        return;
                    }
                    idle
                };
                drop(this);
                std::thread::sleep(ASK_IDLE - idle);
            });
        }
        Some(model)
    }

    pub(super) fn tmdb_key(&self) -> Option<String> {
        let bytes = self.store.get(TMDB_KEY.to_string())?;
        let key = String::from_utf8(bytes).ok()?;
        Some(key).filter(|k| !k.is_empty())
    }

    /// A TMDB client over the one API connection pool this core keeps. Every
    /// caller here goes through this: a client of its own is a pool of its
    /// own, thrown away with it, and the describe and link passes make one
    /// per batch of twenty titles.
    pub(super) fn tmdb_client(&self, key: &str) -> TmdbClient {
        TmdbClient::with_agent(
            self.tmdb_api_agent
                .get_or_init(TmdbClient::api_agent)
                .clone(),
            &self.tmdb_base.lock(),
            key,
        )
    }
}

/// The acknowledgement TMDB's terms require wherever their data is shown
/// (spec: Metadata). It is a function, not a UI string, so every platform's
/// settings screen shows the same sentence.
#[uniffi::export]
pub fn tmdb_attribution() -> String {
    "This product uses the TMDB API but is not endorsed or certified by TMDB.".to_string()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::api::library::ApiMediaKind;
    use crate::api::rows::HomeReason;
    use crate::api::testing::*;
    use crate::api::HostStore;
    use crate::embed::download::{ModelSource, Pin, CONFIG_FILE, TOKENIZER_FILE, WEIGHTS_FILE};
    use crate::index::db::{MetadataSource, WatchAuthority, WatchRecord};
    use crate::index::MediaKind;
    use crate::source::local::LocalModule;
    use crate::source::module::SourceModule;
    use std::fs;

    /// A digest no host in a test serves: what a mispasted pin, or an upstream
    /// file that moved, looks like from the device.
    const A_PIN_NOTHING_ANSWERS: &str =
        "d6ca3fd0c3a3b462ff2b83d0c5bd5b1e2b6a0b2c6c1a3a7f5e4d3c2b1a098765";

    /// A source pointing both files at `base`, pinned to a digest and a length
    /// the bytes there will not answer.
    fn source_at(base: &str, len: u64) -> ModelSource {
        ModelSource {
            encoder: Encoder::Small,
            weights: Pin {
                name: WEIGHTS_FILE,
                url: format!("{base}/model.safetensors"),
                sha256: A_PIN_NOTHING_ANSWERS.to_string(),
                len,
            },
            tokenizer: Pin {
                name: TOKENIZER_FILE,
                url: format!("{base}/tokenizer.json"),
                sha256: A_PIN_NOTHING_ANSWERS.to_string(),
                len,
            },
            config: Pin {
                name: CONFIG_FILE,
                url: format!("{base}/config.json"),
                sha256: A_PIN_NOTHING_ANSWERS.to_string(),
                len,
            },
        }
    }

    /// `count` films for a local source to index, each one a title of its own.
    fn shelf(count: usize) -> tempfile::TempDir {
        let tmp = tempfile::tempdir().unwrap();
        fs::create_dir_all(tmp.path().join("Movies")).unwrap();
        for i in 0..count {
            fs::write(
                tmp.path()
                    .join(format!("Movies/A Film {i:03} ({}).mkv", 1980 + i)),
                b"x",
            )
            .unwrap();
        }
        tmp
    }

    /// A TMDB that knows none of them, `delay_ms` after being asked. What is
    /// under test is never the match: it is who waits for the round trip.
    fn slow_tmdb(delay_ms: u64) -> crate::plex::fake::FakeServer {
        use crate::plex::fake::{FakeServer, Reply};
        FakeServer::start(move |_| {
            std::thread::sleep(Duration::from_millis(delay_ms));
            Reply::json(r#"{"page":1,"results":[],"total_results":0}"#)
        })
    }

    /// A core with `count` local films indexed and its TMDB pointed at `base`.
    fn library_of(
        count: usize,
        base: &str,
    ) -> (Arc<LexisCore>, tempfile::TempDir, tempfile::TempDir) {
        let media = shelf(count);
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
        base.clone_into(&mut core.tmdb_base.lock());
        core.set_tmdb_key("eyJhbGciOiJIUzI1NiJ9.token".into())
            .unwrap();
        // the encoder already on the device, at the shipped pin's own paths:
        // a pass that reaches its embedding phase must find it in the cache,
        // because the alternative is a test fetching 449 MiB from Hugging Face
        crate::embed::fixture::write_model(cache.path());
        (core, media, cache)
    }

    #[test]
    fn a_metadata_batch_leaves_the_write_connection_free_between_titles() {
        // a batch is several seconds of somebody else's network; a viewer
        // marking a title watched, or a player reporting where it got to, must
        // not queue behind the whole of it
        let server = slow_tmdb(300);
        let (core, _media, _cache) = library_of(4, &server.base_url);
        let id = core.list_titles(ApiMediaKind::Movie, 0, 10).unwrap()[0].id;

        let batch = {
            let core = Arc::clone(&core);
            std::thread::spawn(move || core.enrich_pending(4).unwrap())
        };
        // the first title answered and the second in flight: the batch is in
        // the middle of its titles
        until(5, "the batch reaches its second title", || {
            server.requests().len() >= 2
        });
        let start = Instant::now();
        core.mark_watched(id, true).unwrap();
        let waited = start.elapsed();
        assert!(
            waited < Duration::from_millis(150),
            "the write connection was held across the batch: {waited:?}"
        );
        assert_eq!(batch.join().unwrap().attempted, 4);
    }

    #[test]
    fn a_question_in_words_borrows_the_encoder_and_lets_it_go_once_idle() {
        let cache = tempfile::tempdir().unwrap();
        let core = LexisCore::new(
            cache.path().to_string_lossy().into_owned(),
            Arc::new(MemStore::default()),
        )
        .unwrap();
        // no encoder on the device: the words stay words, and nothing fails
        let bare = core.ask("dune desert".into(), 0).unwrap();
        assert_eq!(bare.filters.text, "dune desert");
        assert!(core.model.lock().is_none());

        crate::embed::fixture::write_model(cache.path());
        core.ask("dune desert".into(), 0).unwrap();
        assert!(matches!(*core.model.lock(), Some(ModelState::Ready(_))));
        // a question the rules read whole needs no encoder, and does not
        // keep it: the idle clock runs from the last question that used it
        core.ask("un film pas vu".into(), 0).unwrap();
        until(5, "the encoder let go after the last question", || {
            core.model.lock().is_none()
        });

        // a pass past its embedding has no use for the encoder, and nothing
        // else would drop it: the question's clock still does
        let phase = |phase| {
            let mut work = core.passes.work.lock();
            work.working = phase != PassPhase::Idle;
            work.run.phase = phase;
        };
        phase(PassPhase::Semantic);
        core.ask("dune desert".into(), 0).unwrap();
        assert!(matches!(*core.model.lock(), Some(ModelState::Ready(_))));
        until(5, "the encoder let go during the neighbour sweep", || {
            core.model.lock().is_none()
        });
        // one embedding is the pass's to drop when its queue empties
        phase(PassPhase::Embedding);
        core.ask("dune desert".into(), 0).unwrap();
        std::thread::sleep(ASK_IDLE * 3);
        assert!(matches!(*core.model.lock(), Some(ModelState::Ready(_))));
        phase(PassPhase::Idle);
    }

    /// Waits for `want` to hold, or fails: what the pass does happens on its
    /// own thread, so every assertion about it is an assertion about time.
    fn until(secs: u64, what: &str, want: impl Fn() -> bool) {
        let deadline = Instant::now() + Duration::from_secs(secs);
        while !want() {
            assert!(Instant::now() < deadline, "never happened: {what}");
            std::thread::sleep(Duration::from_millis(20));
        }
    }

    /// A TMDB that places every title `shelf` writes, answering a search in
    /// `search_ms` and a similar list in `similar_ms`. The two are apart
    /// because a test that has to watch one phase needs the other to be over.
    fn matching_tmdb(search_ms: u64, similar_ms: u64) -> crate::plex::fake::FakeServer {
        use crate::plex::fake::{FakeServer, Reply};
        FakeServer::start(move |req| {
            let url = req.url.clone();
            if let Some(rest) = url.strip_prefix("/movie/") {
                let id: i64 = rest
                    .split(['/', '?'])
                    .next()
                    .and_then(|n| n.parse().ok())
                    .unwrap_or(0);
                if rest.contains("/recommendations") {
                    std::thread::sleep(Duration::from_millis(similar_ms));
                    return Reply::json(&format!(
                        r#"{{"page":1,"results":[{{"id":{}}}],"total_pages":1}}"#,
                        id + 1
                    ));
                }
                return Reply::json(&format!(
                    r#"{{"id":{id},"overview":"Un film que le faux serveur a invente.",
                        "poster_path":"/p.jpg","backdrop_path":null,"genres":[]}}"#
                ));
            }
            std::thread::sleep(Duration::from_millis(search_ms));
            // "A Film 007 (1987).mkv" is indexed as "A Film 007", year 1987:
            // the number in the name is the id, and the year the query carries
            // is the one it is answered with
            let query = query_of(&url);
            let n: i64 = query
                .rsplit(' ')
                .next()
                .and_then(|n| n.parse().ok())
                .unwrap_or(0);
            let year = param_of(&url, "year=").unwrap_or_else(|| "1980".to_string());
            Reply::json(&format!(
                r#"{{"page":1,"results":[{{"id":{n},"title":"{query}",
                    "release_date":"{year}-01-01"}}]}}"#
            ))
        })
    }

    fn param_of(url: &str, name: &str) -> Option<String> {
        let at = url.find(name)? + name.len();
        Some(url[at..].split('&').next().unwrap_or("").to_string())
    }

    /// The search query as it was typed, out of the percent-encoding ureq put
    /// it in.
    fn query_of(url: &str) -> String {
        let raw = param_of(url, "query=").unwrap_or_default();
        let bytes = raw.replace('+', " ").into_bytes();
        let mut out = Vec::with_capacity(bytes.len());
        let mut i = 0;
        while i < bytes.len() {
            if bytes[i] == b'%' && i + 2 < bytes.len() {
                let hex = std::str::from_utf8(&bytes[i + 1..i + 3]).unwrap_or("20");
                out.push(u8::from_str_radix(hex, 16).unwrap_or(b' '));
                i += 3;
            } else {
                out.push(bytes[i]);
                i += 1;
            }
        }
        String::from_utf8_lossy(&out).into_owned()
    }

    #[test]
    fn a_pass_runs_its_batches_on_a_thread_of_its_own() {
        // 500 ms is a title over somebody's network. Starting the pass, and
        // asking how far it got, have to cost a mutex whatever TMDB is doing,
        // or the thread that also answers the remote answers it that late.
        let server = slow_tmdb(500);
        let (core, _media, _cache) = library_of(6, &server.base_url);

        let start = Instant::now();
        core.start_pass();
        let started = start.elapsed();
        assert!(
            started < Duration::from_millis(50),
            "start_pass waited for a batch: {started:?}"
        );

        // and once it is running, which is when a screen draws progress
        until(5, "the first title is asked about", || {
            !server.requests().is_empty()
        });
        let start = Instant::now();
        let run = core.pass_now();
        let asked = start.elapsed();
        assert!(
            asked < Duration::from_millis(50),
            "pass_now waited for a batch: {asked:?}"
        );
        assert_eq!(run.phase, PassPhase::Describing);

        // the batches happen anyway, without anyone having blocked for them
        until(60, "every title is described", || {
            core.pass_progress().unwrap().described == 6
        });
    }

    #[test]
    fn a_rate_limited_batch_keeps_its_queue_and_the_pass_waits_the_delay_out() {
        use crate::plex::fake::{FakeServer, Reply};
        use std::sync::atomic::{AtomicUsize, Ordering};
        let asked = Arc::new(AtomicUsize::new(0));
        let counted = Arc::clone(&asked);
        // the first title collects a 429 asking to be left alone for a second;
        // everything after it is answered
        let server = FakeServer::start(move |_| {
            if counted.fetch_add(1, Ordering::SeqCst) == 0 {
                return Reply {
                    status: 429,
                    headers: vec![("Retry-After".to_string(), "1".to_string())],
                    body: Vec::new(),
                };
            }
            Reply::json(r#"{"page":1,"results":[],"total_results":0}"#)
        });
        let (core, _media, _cache) = library_of(4, &server.base_url);

        core.start_pass();
        until(5, "the rate limit is collected", || {
            asked.load(Ordering::SeqCst) > 0
        });
        // the batch stopped where it stood: nothing written, and nothing asked
        // again while TMDB wants to be left alone
        std::thread::sleep(Duration::from_millis(500));
        assert_eq!(asked.load(Ordering::SeqCst), 1);
        assert_eq!(core.pass_now().phase, PassPhase::Describing);
        assert_eq!(core.pass_progress().unwrap().described, 0);

        // and the queue is still four titles deep when the wait is over
        until(20, "the pass resumes on its own", || {
            core.pass_progress().unwrap().described == 4
        });
    }

    #[test]
    fn a_film_stops_the_pass_between_batches_and_it_resumes_where_it_stopped() {
        // heavy work stands aside while a film plays: the batch in flight
        // finishes, and nothing after it starts until the film is over
        let server = slow_tmdb(20);
        let (core, _media, _cache) = library_of(24, &server.base_url);

        core.start_pass();
        until(20, "the pass gets going", || {
            core.pass_progress().unwrap().described >= 5
        });
        core.pause_pass(true);
        // at most the title in flight, which is two requests, then nothing;
        // held for a moment, since a request already sent can still be on
        // its way to the server when the counts first agree
        until(5, "the title in flight lands", || {
            let asked = server.requests().len();
            std::thread::sleep(Duration::from_millis(100));
            asked == server.requests().len()
                && asked == 2 * core.pass_progress().unwrap().described as usize
        });
        let stopped_at = server.requests().len();
        let described = core.pass_progress().unwrap().described;
        std::thread::sleep(Duration::from_millis(500));
        assert_eq!(
            server.requests().len(),
            stopped_at,
            "the pass kept asking while a film was playing"
        );
        assert!(described < 24, "the pass had already drained its queue");

        core.pause_pass(false);
        until(20, "the pass picks its queue up again", || {
            core.pass_progress().unwrap().described == 24
        });
        // resumed where it stopped, not started over: a title already
        // described is not asked about twice
        assert_eq!(server.requests().len(), 48);
    }

    #[test]
    fn a_film_waits_on_the_item_in_flight_and_never_on_the_batch_around_it() {
        // the twenty seconds the owner waited, in the shape a test can measure
        // to the millisecond: one title here is two requests of a fifth of a
        // second each, and the queue reads several titles ahead of itself. A
        // pass that reads its flag between batches rather than between items
        // holds the line for every one of them, and how long that is depends
        // on a device nobody here is holding.
        //
        // So what is asserted is not how many titles a batch is. It is how
        // long the pass went on working after the viewer pressed play.
        let server = slow_tmdb(200);
        let (core, _media, _cache) = library_of(24, &server.base_url);

        core.start_pass();
        // the first request has landed, so the pass is near the start of a
        // batch: the most a batch can still have left to hold
        until(30, "the pass gets going", || !server.requests().is_empty());

        core.pause_pass(true);
        let pressed = Instant::now();

        // when the last request reached TMDB, watched for long enough that a
        // batch that ran on would be seen doing it
        let mut asked = server.requests().len();
        let mut latest = pressed;
        while pressed.elapsed() < Duration::from_millis(1500) {
            let now = server.requests().len();
            if now != asked {
                asked = now;
                latest = Instant::now();
            }
            std::thread::sleep(Duration::from_millis(10));
        }
        let held = latest.duration_since(pressed);
        assert!(
            held < Duration::from_millis(500),
            "the pass went on asking TMDB for {held:?} after the film started"
        );
        // and it stopped because it was asked to, not because it ran out of
        // work: there is still a queue behind what it did
        assert!(
            core.pass_progress().unwrap().described < 24,
            "the queue drained before the pause had anything to stop"
        );
    }

    #[test]
    fn a_tmdb_that_answers_nothing_is_given_up_on_rather_than_asked_forever() {
        // a batch is a slice of time and can hold a single request, so one
        // failed title says nothing about TMDB. What says TMDB has stopped
        // answering is a run of batches that failed outright: the queue is
        // ordered by id, so the batch after those would block on the same
        // titles.
        let server =
            crate::plex::fake::FakeServer::start(|_| crate::plex::fake::Reply::status(500));
        let (core, _media, _cache) = library_of(12, &server.base_url);

        core.start_pass();
        until(30, "the pass gives up on TMDB", || {
            core.pass_now().note == Some(PassNote::TmdbSilent)
        });
        until(30, "the pass ends", || {
            core.pass_now().phase == PassPhase::Done
        });
        // nothing was described, and the pass is not still trying
        assert_eq!(core.pass_progress().unwrap().described, 0);
        let asked = server.requests().len();
        std::thread::sleep(Duration::from_millis(200));
        assert_eq!(
            server.requests().len(),
            asked,
            "the pass is still asking a TMDB it has given up on"
        );
    }

    #[test]
    fn a_scan_during_the_links_hands_the_pass_back_instead_of_starting_it_over() {
        // the phase only moves forward, so a scan landing during the links
        // would leave the titles it indexed undescribed. The pass in flight is
        // handed back to the first queue, tally and all, rather than reset on
        // top of the batch that is running.
        let server = matching_tmdb(10, 300);
        let (core, _media, _cache) = library_of(12, &server.base_url);

        core.start_pass();
        until(30, "the pass reaches the links", || {
            core.pass_now().phase == PassPhase::Linking
        });
        core.pause_pass(true);
        // the batch in flight finishes: five similar lists at most, each one
        // counted once it lands
        let similar = || {
            server
                .requests()
                .iter()
                .filter(|r| r.url.contains("/recommendations"))
                .count()
        };
        until(10, "the batch in flight lands", || {
            core.pass_now().linked as usize == similar()
        });
        let before = core.pass_now();
        assert_eq!(before.phase, PassPhase::Linking);
        assert_eq!(before.described, 12);

        core.start_pass();
        assert_eq!(
            core.pass_now(),
            before,
            "a scan mid-pass reset a pass that was still running"
        );
        core.pause_pass(false);
        until(30, "the pass ends", || {
            core.pass_now().phase == PassPhase::Done
        });
        // the hand-back put it back over the metadata before it ended
        assert_eq!(core.pass_now().described, 12);
    }

    #[test]
    fn the_tmdb_key_is_the_read_access_token_and_nothing_else() {
        let cache = tempfile::tempdir().unwrap();
        let store = Arc::new(MemStore::default());
        let core =
            LexisCore::new(cache.path().to_string_lossy().into_owned(), store.clone()).unwrap();

        assert!(!core.has_tmdb_key());
        // the v3 API key from the same TMDB page is not a Bearer credential
        assert!(matches!(
            core.set_tmdb_key("0123456789abcdef0123456789abcdef".into()),
            Err(CoreError::InvalidConfig { .. })
        ));
        assert!(matches!(
            core.set_tmdb_key("   ".into()),
            Err(CoreError::InvalidConfig { .. })
        ));
        assert!(!core.has_tmdb_key());

        core.set_tmdb_key("  eyJhbGciOiJIUzI1NiJ9.token  ".into())
            .unwrap();
        assert!(core.has_tmdb_key());
        assert_eq!(
            store.get(TMDB_KEY.to_string()),
            Some(b"eyJhbGciOiJIUzI1NiJ9.token".to_vec())
        );

        // the key survives a cache purge: it lives in the host store
        let cache2 = tempfile::tempdir().unwrap();
        let purged = LexisCore::new(cache2.path().to_string_lossy().into_owned(), store).unwrap();
        assert!(purged.has_tmdb_key());
    }

    #[test]
    fn a_cleared_key_is_forgotten_and_enrichment_goes_quiet_again() {
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

        core.set_tmdb_key("eyJhbGciOiJIUzI1NiJ9.token".into())
            .unwrap();
        assert!(core.has_tmdb_key());

        core.clear_tmdb_key();
        assert!(!core.has_tmdb_key());
        // what a host reads back is what it may report as absent itself
        assert_eq!(store.get(TMDB_KEY.to_string()), Some(Vec::new()));

        // a title is pending, so a key still in place would mean a request:
        // the zero report is the proof nothing was asked
        assert!(!core
            .list_titles(ApiMediaKind::Movie, 0, 10)
            .unwrap()
            .is_empty());
        let report = core.enrich_pending(50).unwrap();
        assert_eq!(report.attempted, 0);
        assert_eq!(report.matched, 0);
        assert_eq!(report.failed, 0);
    }

    #[test]
    fn without_a_key_enrichment_reports_zero_instead_of_failing() {
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

        let report = core.enrich_pending(50).unwrap();
        assert_eq!(report.attempted, 0);
        assert_eq!(report.matched, 0);
        assert_eq!(report.failed, 0);

        // the title is still there, with nothing said about it
        let id = core.list_titles(ApiMediaKind::Movie, 0, 10).unwrap()[0].id;
        let detail = core.title_detail(id).unwrap();
        assert_eq!(detail.overview, None);
        assert!(detail.genres.is_empty());
        assert!(detail.cast.is_empty());
        assert!(!detail.has_poster);
        assert_eq!(detail.tmdb_id, None);
        assert_eq!(core.poster_file(id).unwrap(), None);
    }

    #[test]
    fn the_tmdb_attribution_is_the_wording_tmdb_asks_for() {
        let text = tmdb_attribution();
        assert!(text.contains("TMDB"), "{text}");
        assert!(text.contains("not endorsed or certified"), "{text}");
    }

    #[test]
    fn with_no_model_published_the_pass_is_a_quiet_no_op() {
        use crate::plex::fake::{FakeServer, Reply};

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
        core.scan_all(false).unwrap();
        // the shipped pin, and a host of our own where the release asset is:
        // no test may reach it, whatever the pin becomes
        let server = FakeServer::start(|_req| Reply::status(404));
        *core.model_source.lock() = ModelSource {
            weights: Pin {
                sha256: String::new(),
                ..source_at(&server.base_url, 16).weights
            },
            ..source_at(&server.base_url, 16)
        };

        // nothing pinned is the feature switched off: no download, no error,
        // and no vectors
        let report = core.embed_pending(10).unwrap();
        assert!(!report.ready);
        assert_eq!(report.attempted, 0);
        assert_eq!(report.embedded, 0);
        let vectors: i64 = core
            .read_db
            .lock()
            .conn()
            .query_row("SELECT COUNT(*) FROM embeddings", [], |r| r.get(0))
            .unwrap();
        assert_eq!(vectors, 0);

        // and the home rows are the ones the library can fill without it
        let rows = core.browse_rows(Some(ApiMediaKind::Movie), 0).unwrap();
        assert!(!rows
            .iter()
            .any(|r| matches!(r.reason, HomeReason::TasteFacet { .. })));

        // the dark-ship invariant: nothing is pinned, so nothing is asked of
        // anyone. A pinned digest is another world, and the assertions above
        // are the ones that hold in it, against a host that has no artifact.
        if !ModelSource::default().is_pinned() {
            assert!(server.requests().is_empty());
        }
    }

    #[test]
    fn the_sweep_that_ends_leaves_the_home_screen_a_fingerprint_row() {
        let media = tempfile::tempdir().unwrap();
        fs::create_dir_all(media.path().join("Movies")).unwrap();
        for n in 0..12 {
            fs::write(
                media.path().join(format!("Movies/Film {n} (2000).mkv")),
                b"x",
            )
            .unwrap();
        }
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

        // what an embedding pass would have left behind, and a history: two
        // films watched, seven more pointing the same way, three that do not
        let ids = core.db.lock().list_title_ids_for_test().unwrap();
        {
            let db = core.db.lock();
            for (n, id) in ids.iter().enumerate() {
                // the two that are watched point exactly the same way, so the
                // fingerprint is one taste rather than one per film; the last
                // three point elsewhere, so that being near this taste is
                // something other than being in this library
                let vector = if n < 2 {
                    vec![100, 0, 0, 0]
                } else if n < 9 {
                    vec![100, n as i8, 0, 0]
                } else {
                    vec![0, 0, 100, n as i8]
                };
                db.upsert_embedding(&crate::index::db::EmbeddingRecord {
                    title_id: *id,
                    model_version: Encoder::Small.version(),
                    source_hash: 0,
                    vector,
                    computed_at: 1,
                })
                .unwrap();
            }
            for id in &ids[..2] {
                let file_id: i64 = db
                    .conn()
                    .query_row("SELECT id FROM files WHERE title_id = ?1", [id], |r| {
                        r.get(0)
                    })
                    .unwrap();
                db.upsert_watch_state(
                    &WatchRecord {
                        file_id,
                        position_secs: 0.0,
                        duration_secs: 7000.0,
                        watched: true,
                        plays: 0,
                        updated_at: unix_now(),
                    },
                    WatchAuthority::Report,
                )
                .unwrap();
            }
        }
        // nothing has computed the row yet, so there is none to show
        assert!(!core
            .browse_rows(Some(ApiMediaKind::Movie), 0)
            .unwrap()
            .iter()
            .any(|r| matches!(r.reason, HomeReason::TasteFacet { .. })));

        // the pass runs to the end of its sweep, which is where the taste is
        // recomputed: every vector it reads is current by then. The recompute
        // itself rides the worker now, so the rows are read only once it has
        // landed.
        let refreshes_before = core.taste_runs();
        while core.link_semantic(50).unwrap().attempted > 0 {}
        assert!(core.wait_for_taste(refreshes_before, std::time::Duration::from_secs(5)));
        let rows = core.browse_rows(Some(ApiMediaKind::Movie), 0).unwrap();
        let picked = rows
            .iter()
            .find(|r| matches!(r.reason, HomeReason::TasteFacet { .. }))
            .expect("the sweep that ends recomputes the fingerprint");
        assert_eq!(picked.items.len(), 7);
        // and the row names itself after a film the viewer actually watched,
        // which is what the pass wrote beside the picks
        let HomeReason::TasteFacet { leader, .. } = &picked.reason else {
            panic!()
        };
        assert!(leader.starts_with("Film "), "{leader}");
    }

    #[test]
    fn unpinning_the_model_puts_the_rows_back_where_they_were() {
        // the rollback lever: emptying MODEL_SHA256 has to give a device that
        // already installed the model the rows it had before it, and nothing
        // else ever empties the link table
        let media = tempfile::tempdir().unwrap();
        fs::create_dir_all(media.path().join("Movies")).unwrap();
        fs::write(media.path().join("Movies/Dune (2021).mkv"), b"x").unwrap();
        // a shelf's worth of neighbours to name below: a recommendation row
        // shorter than that is left out, so fewer would make the comparison
        // vacuous whatever the links said
        for n in 0..6 {
            fs::write(
                media.path().join(format!("Movies/Film {n} (2000).mkv")),
                b"x",
            )
            .unwrap();
        }
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

        let shape = |core: &LexisCore| -> Vec<(String, Vec<String>)> {
            core.browse_rows(Some(ApiMediaKind::Movie), 0)
                .unwrap()
                .into_iter()
                .map(|r| {
                    (
                        format!("{:?}", r.reason),
                        r.items.into_iter().map(|t| t.name).collect(),
                    )
                })
                .collect()
        };
        // the taste row only fuses a watched title's own neighbours, and
        // watched state outlives an unpinned model same as everything else the
        // library holds: marking it before `before` is captured is what keeps
        // that part of the comparison honest across the reopen below.
        let ids = core.db.lock().list_title_ids_for_test().unwrap();
        {
            let db = core.db.lock();
            let file_id: i64 = db
                .conn()
                .query_row("SELECT id FROM files WHERE title_id = ?1", [ids[0]], |r| {
                    r.get(0)
                })
                .unwrap();
            db.upsert_watch_state(
                &WatchRecord {
                    file_id,
                    position_secs: 0.0,
                    duration_secs: 7000.0,
                    watched: true,
                    plays: 0,
                    updated_at: 1,
                },
                WatchAuthority::Report,
            )
            .unwrap();
        }
        let before = shape(&core);

        // what a withdrawn model leaves behind: one title's neighbours
        let near: Vec<(i64, i32)> = ids[1..7].iter().map(|id| (*id, 100)).collect();
        {
            let db = core.db.lock();
            db.upsert_semantic(&[(ids[0], near)], Encoder::Small.version(), 1)
                .unwrap();
        }
        // and they do reach the rows, so what follows is not vacuous
        assert_ne!(shape(&core), before);

        drop(core);
        let core =
            LexisCore::new(cache.path().to_string_lossy().into_owned(), store.clone()).unwrap();
        let links: i64 = core
            .read_db
            .lock()
            .conn()
            .query_row("SELECT COUNT(*) FROM similar_semantic", [], |r| r.get(0))
            .unwrap();
        if !ModelSource::default().is_pinned() {
            // no model is pinned: the links are a withdrawn one's, and the rows
            // are the ones the library gave before it
            assert_eq!(links, 0);
            assert_eq!(shape(&core), before);
        } else {
            // a model is pinned: they are the live one's and outlive a launch.
            // Six rows: a title with neighbours carries no sentinel, only an
            // empty answer does.
            assert_eq!(links, 6);
        }
    }

    #[test]
    fn an_install_that_cannot_work_is_said_once_and_never_fetched_again() {
        use crate::plex::fake::{FakeServer, Reply};

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
        core.scan_all(false).unwrap();
        // a digest, and a host answering with something that is not it: what a
        // mispasted pin looks like from the device
        let server = FakeServer::start(|_req| Reply {
            status: 200,
            headers: Vec::new(),
            body: b"a release page, or the wrong asset".to_vec(),
        });
        *core.model_source.lock() = source_at(&server.base_url, 34);

        // `msg` is what crosses the FFI on its own, so this is the line the app
        // shows: the CoreError prefix around it never leaves this side
        match core.embed_pending(10).unwrap_err() {
            CoreError::EmbedModelUnusable { msg } => {
                assert_eq!(msg, "the model file is not the one that was pinned");
            }
            e => panic!("{e}"),
        }
        // and the next tick is told the same thing without asking the host
        // again: a batch every 40 ms would otherwise fetch 465 MiB every time
        let err = core.embed_pending(10).unwrap_err();
        assert!(matches!(err, CoreError::EmbedModelUnusable { .. }));
        assert_eq!(server.requests().len(), 1);
    }

    #[test]
    fn a_url_pointing_at_something_far_too_large_is_not_downloaded_twice() {
        use crate::plex::fake::{FakeServer, Reply};

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
        core.scan_all(false).unwrap();
        // a URL whose file has moved answers with something that is not the
        // artifact: the length is pinned as well as the digest so the read
        // stops at the first byte past it, rather than pulling a body of any
        // size over a TV's network on every call
        let server = FakeServer::start(|_req| Reply {
            status: 200,
            headers: Vec::new(),
            body: vec![7u8; 4096],
        });
        // the pin says 512 bytes and the host answers with four kilobytes: the
        // body is not the file, and the read stops rather than taking all of it
        *core.model_source.lock() = source_at(&server.base_url, 512);

        // the line a maintainer reads in Settings when the URL is the wrong one
        match core.embed_pending(10).unwrap_err() {
            CoreError::EmbedModelUnusable { msg } => {
                assert_eq!(
                    msg,
                    "the file at the pinned URL is longer than the artifact"
                );
            }
            e => panic!("{e}"),
        }
        // and the host is asked once for the process, not once per tick
        let err = core.embed_pending(10).unwrap_err();
        assert!(matches!(err, CoreError::EmbedModelUnusable { .. }));
        assert_eq!(server.requests().len(), 1);
    }

    #[test]
    fn a_cached_artifact_that_will_not_read_is_not_a_missing_model() {
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
        core.scan_all(false).unwrap();
        // the cached file is never verified again, so this is what every launch
        // reads: quietly reporting no model would leave it there forever
        let artifact = ModelSource::default().artifact(cache.path());
        std::fs::create_dir_all(artifact.weights.parent().unwrap()).unwrap();
        std::fs::write(&artifact.weights, b"not a model").unwrap();
        std::fs::write(&artifact.tokenizer, b"{}").unwrap();
        std::fs::write(&artifact.config, crate::embed::fixture::config_bytes()).unwrap();

        let err = core.embed_pending(10).unwrap_err();
        assert!(matches!(err, CoreError::EmbedModelUnusable { .. }));
        // none of them hashes to its pin: the next launch fetches them again
        assert!(!artifact.weights.exists());
        assert!(!artifact.tokenizer.exists());
    }

    #[test]
    fn a_pinned_artifact_that_will_not_read_is_kept_rather_than_fetched_every_launch() {
        use sha2::{Digest, Sha256};

        let cache = tempfile::tempdir().unwrap();
        let core = LexisCore::new(
            cache.path().to_string_lossy().into_owned(),
            Arc::new(MemStore::default()),
        )
        .unwrap();
        let hex = |bytes: &[u8]| -> String {
            Sha256::digest(bytes)
                .iter()
                .map(|b| format!("{b:02x}"))
                .collect()
        };
        let (weights, tokenizer, config) = (
            b"not a model".to_vec(),
            b"{}".to_vec(),
            crate::embed::fixture::config_bytes(),
        );
        let mut source = source_at("http://127.0.0.1:9", 1 << 20);
        source.weights.sha256 = hex(&weights);
        source.tokenizer.sha256 = hex(&tokenizer);
        source.config.sha256 = hex(&config);
        let artifact = source.artifact(cache.path());
        std::fs::create_dir_all(artifact.weights.parent().unwrap()).unwrap();
        std::fs::write(&artifact.weights, &weights).unwrap();
        std::fs::write(&artifact.tokenizer, &tokenizer).unwrap();
        std::fs::write(&artifact.config, &config).unwrap();
        *core.model_source.lock() = source;

        let err = core.embed_pending(10).unwrap_err();
        assert!(matches!(err, CoreError::EmbedModelUnusable { .. }));
        assert!(artifact.weights.exists() && artifact.tokenizer.exists());
    }

    #[test]
    fn a_host_that_has_no_artifact_leaves_the_feature_off_and_is_asked_once() {
        use crate::plex::fake::{FakeServer, Reply};

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
        core.scan_all(false).unwrap();
        let gone = FakeServer::start(|_req| Reply::status(404));
        *core.model_source.lock() = source_at(&gone.base_url, 16);

        // a device that cannot install it recommends without it, and pays one
        // connect for the whole process rather than one per call
        let report = core.embed_pending(10).unwrap();
        assert!(!report.ready);
        assert!(!core.embed_pending(10).unwrap().ready);
        assert_eq!(gone.requests().len(), 1);
    }

    #[test]
    fn a_model_in_the_cache_is_used_and_link_semantic_sweeps_what_it_embedded() {
        use crate::embed::fixture;
        use crate::index::db::MetadataRecord;

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
        core.scan_all(false).unwrap();
        // a title the fixture model has words for, described by hand: nothing
        // in a test may reach TMDB
        {
            let db = core.db.lock();
            let id = db.list_title_ids_for_test().unwrap()[0];
            db.upsert_metadata(&MetadataRecord {
                title_id: id,
                tmdb_id: Some(1),
                overview_fr: Some("dune desert epice".into()),
                overview_en: None,
                poster_path: None,
                backdrop_path: None,
                genres: "science,fiction".into(),
                cast_names: "epice".into(),
                collections: String::new(),
                director_names: String::new(),
                writer_names: String::new(),
                composer_names: String::new(),
                source: MetadataSource::Tmdb,
                fetched_at: 1,
                critics: None,
                audience: None,
                release_date: None,
            })
            .unwrap();
        }
        let model = fixture::write_model(cache.path());

        let report = core.embed_pending(10).unwrap();
        assert!(report.ready);
        assert_eq!(report.attempted, 1);
        assert_eq!(report.embedded, 1);

        // the artifact is read once and the batches share it: the pass calls
        // this every 40 ms, and the pinned weights are 449 MiB
        std::fs::remove_file(&model.weights).unwrap();
        std::fs::remove_file(&model.tokenizer).unwrap();

        // the queue is empty: found so without reading the model, which the
        // batch lets go, and said once for the model and the phase alike
        let (report, drained) = core.embed_batch(10, &Slice::open()).unwrap();
        assert_eq!(report.attempted, 0);
        assert!(report.ready);
        assert!(drained);
        assert!(core.model.lock().is_none());

        // the title just embedded is the only vectorised one in this library,
        // so the sweep reaches it and it has nothing to compare itself against
        let semantic = core.link_semantic(10).unwrap();
        assert_eq!(semantic.attempted, 1);
        assert_eq!(semantic.linked, 0);
        assert_eq!(semantic.empty, 1);
    }

    #[test]
    fn the_batch_that_empties_the_queue_lets_the_model_go() {
        use crate::embed::fixture;
        use crate::index::db::MetadataRecord;

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
        core.scan_all(false).unwrap();
        fixture::write_model(cache.path());

        let describe = |fetched_at: i64| {
            let db = core.db.lock();
            let id = db.list_title_ids_for_test().unwrap()[0];
            db.upsert_metadata(&MetadataRecord {
                title_id: id,
                tmdb_id: Some(1),
                overview_fr: Some(format!("dune desert epice {fetched_at}")),
                overview_en: None,
                poster_path: None,
                backdrop_path: None,
                genres: "science,fiction".into(),
                cast_names: "epice".into(),
                collections: String::new(),
                director_names: String::new(),
                writer_names: String::new(),
                composer_names: String::new(),
                source: MetadataSource::Tmdb,
                fetched_at,
                critics: None,
                audience: None,
                release_date: None,
            })
            .unwrap();
        };

        describe(1);
        assert_eq!(core.embed_pending(10).unwrap().embedded, 1);
        // held while there is still a queue to embed against: every batch of a
        // pass reads the same rows rather than the artifact again
        assert!(matches!(
            core.model.lock().as_ref(),
            Some(ModelState::Ready(_))
        ));

        let report = core.embed_pending(10).unwrap();
        assert_eq!(report.attempted, 0);
        // and let go of the moment there is not: tensors and a mapping that
        // nothing will read again until the next scan
        assert!(core.model.lock().is_none());

        // a title described after that is still embedded, off a fresh read
        describe(unix_now() + 100);
        let report = core.embed_pending(10).unwrap();
        assert!(report.ready);
        assert_eq!(report.embedded, 1);
    }

    #[test]
    fn pass_progress_reads_the_index_whether_or_not_a_pass_is_running() {
        use crate::index::db::{EmbeddingRecord, MetadataRecord};

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
        core.scan_all(false).unwrap();

        // a scan alone describes nothing: local files carry no metadata of
        // their own, so the counts sit at the library's size and no further
        let progress = core.pass_progress().unwrap();
        assert_eq!(progress.total, 1);
        assert_eq!(progress.described, 0);
        assert_eq!(progress.linked, 0);
        assert_eq!(progress.embedded, 0);

        // no pass ever ticks in this test: every row below is written by hand,
        // and the numbers still move, because they are read from the index
        // itself and not from a session's own counters
        let db = core.db.lock();
        let id = db.list_title_ids_for_test().unwrap()[0];
        db.upsert_metadata(&MetadataRecord {
            title_id: id,
            tmdb_id: Some(438631),
            overview_fr: None,
            overview_en: Some("A far future.".into()),
            poster_path: None,
            backdrop_path: None,
            genres: String::new(),
            cast_names: String::new(),
            collections: String::new(),
            director_names: String::new(),
            writer_names: String::new(),
            composer_names: String::new(),
            source: MetadataSource::Tmdb,
            fetched_at: 1,
            critics: None,
            audience: None,
            release_date: None,
        })
        .unwrap();
        db.upsert_similar(438631, MediaKind::Movie, &[78]).unwrap();
        db.upsert_embedding(&EmbeddingRecord {
            title_id: id,
            model_version: Encoder::Small.version(),
            source_hash: 1,
            vector: vec![1, 2, 3],
            computed_at: 1,
        })
        .unwrap();
        drop(db);

        let progress = core.pass_progress().unwrap();
        assert_eq!(progress.total, 1);
        assert_eq!(progress.described, 1);
        assert_eq!(progress.linked, 1);
        assert_eq!(progress.embedded, 1);
    }

    #[test]
    fn choosing_the_other_encoder_owes_every_title_a_vector_and_survives_a_relaunch() {
        let cache = tempfile::tempdir().unwrap();
        let open = || {
            LexisCore::new(
                cache.path().to_string_lossy().into_owned(),
                Arc::new(MemStore::default()),
            )
            .unwrap()
        };
        let core = open();
        assert_eq!(core.encoder().unwrap(), "small");
        {
            let db = core.db.lock();
            let id = db
                .upsert_title(crate::index::MediaKind::Movie, "Dune", None)
                .unwrap();
            db.upsert_embedding(&crate::index::db::EmbeddingRecord {
                title_id: id,
                model_version: Encoder::Small.version(),
                source_hash: 0,
                vector: vec![1; 8],
                computed_at: 1,
            })
            .unwrap();
        }
        assert_eq!(core.pass_progress().unwrap().embedded, 1);

        core.set_encoder("base".into()).unwrap();
        assert_eq!(core.encoder().unwrap(), "base");
        assert_eq!(core.model_source.lock().encoder, Encoder::Base);
        // the small vector counts for nothing against the base encoder
        assert_eq!(core.pass_progress().unwrap().embedded, 0);
        assert!(core.set_encoder("large".into()).is_err());
        drop(core);

        let again = open();
        assert_eq!(again.encoder().unwrap(), "base");
        assert_eq!(again.model_source.lock().encoder, Encoder::Base);
    }
}
