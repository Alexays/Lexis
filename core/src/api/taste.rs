use super::library::{to_item, TitleItem};
use super::{unix_now, CoreError, LexisCore};
use parking_lot::Mutex;

/// Recomputes the taste rows off whatever thread pressed the button. One
/// lazy worker sleeps on a channel of kicks: a kick costs one send, presses
/// during a run coalesce into the next one, and the worker ends when the
/// core, dropping the sending end, closes the channel.
#[derive(Default)]
pub(super) struct TasteWorker {
    /// The worker's wake line, created with it on the first kick.
    kick: Mutex<Option<std::sync::mpsc::Sender<()>>>,
    /// Refreshes completed, so a test can wait for its own kick to land.
    completed: std::sync::atomic::AtomicU64,
}

impl LexisCore {
    pub(super) fn kick_taste_refresh(&self) {
        let mut kick = self.taste_refresh.kick.lock();
        let sender = kick.get_or_insert_with(|| {
            let (sender, kicks) = std::sync::mpsc::channel();
            let core = self.self_ref.clone();
            std::thread::Builder::new()
                .name("lexis.taste".into())
                .spawn(move || {
                    crate::lower_thread_qos();
                    taste_worker(core, kicks)
                })
                .expect("spawn a thread");
            sender
        });
        // the worker only stops once the core is gone, and this is the core
        let _ = sender.send(());
    }

    /// How many refreshes have landed so far.
    #[cfg(test)]
    pub(crate) fn taste_runs(&self) -> u64 {
        self.taste_refresh
            .completed
            .load(std::sync::atomic::Ordering::SeqCst)
    }

    /// Waits until the refresh count passes `previous`. Tests only; production
    /// callers never need the recompute synchronously.
    #[cfg(test)]
    pub(crate) fn wait_for_taste(&self, previous: u64, timeout: std::time::Duration) -> bool {
        let deadline = std::time::Instant::now() + timeout;
        while self
            .taste_refresh
            .completed
            .load(std::sync::atomic::Ordering::SeqCst)
            <= previous
        {
            if std::time::Instant::now() >= deadline {
                return false;
            }
            std::thread::sleep(std::time::Duration::from_millis(5));
        }
        true
    }
}

fn taste_worker(core: std::sync::Weak<LexisCore>, kicks: std::sync::mpsc::Receiver<()>) {
    // no strong reference is held while waiting, so the core can drop, and
    // its sender with it, which ends the wait
    while kicks.recv().is_ok() {
        // every kick queued so far is served by this one refresh
        while kicks.try_recv().is_ok() {}
        let Some(this) = core.upgrade() else {
            return;
        };
        let now = unix_now();
        if let Err(e) = crate::index::taste::refresh(&this.db.lock(), now) {
            eprintln!("[lexis.taste] refresh failed: {e}");
        }
        this.taste_refresh
            .completed
            .fetch_add(1, std::sync::atomic::Ordering::SeqCst);
    }
}

/// One facet of the taste, described against the library. `leader_id` is
/// the title the facet is named after; the decades are the first years of
/// those its middle half of titles span, 0 when none is dated.
#[derive(Debug, uniffi::Record)]
pub struct ProfileFacet {
    pub leader_id: i64,
    pub leader: String,
    /// Its part of the whole taste, nought to one.
    pub share: f32,
    pub genres: Vec<String>,
    pub keywords: Vec<String>,
    pub directors: Vec<String>,
    pub decade_from: u16,
    pub decade_to: u16,
    /// Mood keys.
    pub tones: Vec<String>,
}

#[derive(Debug, uniffi::Record)]
pub struct TasteProfile {
    pub facets: Vec<ProfileFacet>,
    /// The genres the titles the viewer turned down share.
    pub avoid: Vec<String>,
}

/// What the fingerprint says about one title, in the words the detail screen
/// renders: the taste that claims it, how strongly (0..1), and the rejected
/// title holding it back, empty when none does.
#[derive(Debug, uniffi::Record)]
pub struct TitleTasteInfo {
    pub leader_id: i64,
    pub leader: String,
    pub affinity: f32,
    pub rejected: String,
}

/// One taste on the screen that shows the taste moving: the title that names
/// it, its share of the history, and how much of that share it has gained or
/// lost over the span asked for. `shift` is absent when the taste is younger
/// than the span, which reads as unchanged and not as nought.
#[derive(Debug, uniffi::Record)]
pub struct ApiTasteFacet {
    /// The title the facet is named after, which `taste_profile` names too.
    pub leader_id: i64,
    pub leader: String,
    pub weight: f32,
    /// Whether the viewer contested this taste and the contest still holds.
    pub muted: bool,
    pub shift: Option<f32>,
}

/// One entry of the ledger: when, what happened, and to which title. The core
/// hands over the kind and the name; the words around them are the app's.
#[derive(Debug, uniffi::Record)]
pub struct ApiTasteEvent {
    pub at: i64,
    pub kind: ApiTasteEventKind,
    pub title: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum ApiTasteEventKind {
    Finished,
    Verdict,
    Deferred,
    Queued,
}

#[uniffi::export]
impl LexisCore {
    /// What the fingerprint has to say about one title, for the screen that
    /// shows the title itself. Nothing for a title no pass has placed, or one
    /// already watched: this explains what is being offered, and a title the
    /// viewer has seen is not being offered.
    pub fn title_taste(&self, title_id: i64) -> Result<Option<TitleTasteInfo>, CoreError> {
        let db = self.read_db.lock();
        let Some(row) = db.title_taste(title_id)? else {
            return Ok(None);
        };
        let facets = db.taste_facets()?;
        let Some(facet) = facets.iter().find(|f| f.facet == row.facet) else {
            return Ok(None);
        };
        let Some((_, leader, _)) = db.title_key(facet.leader)? else {
            return Ok(None);
        };
        Ok(Some(TitleTasteInfo {
            leader_id: facet.leader,
            leader,
            affinity: row.affinity,
            rejected: row.rejected,
        }))
    }

    /// The tastes the fingerprint holds, strongest first, each with how much
    /// it has moved over the last `since_secs`. A facet whose leader is no
    /// longer in the library is left out: the row is named after it.
    pub fn taste_facets(&self, since_secs: i64) -> Result<Vec<ApiTasteFacet>, CoreError> {
        let db = self.read_db.lock();
        let now = unix_now();
        let muted = db.muted_tastes(now)?;
        let mut out = Vec::new();
        for f in db.taste_facet_shifts(now - since_secs)? {
            let Some((_, leader, _)) = db.title_key(f.leader)? else {
                continue;
            };
            out.push(ApiTasteFacet {
                leader_id: f.leader,
                leader,
                weight: f.weight,
                muted: muted.contains(&f.leader),
                shift: f.was.map(|was| f.weight - was),
            });
        }
        Ok(out)
    }

    /// "Not because of this": the taste led by this title, or the row seeded
    /// by it, steps back for 30 days. The fingerprint is recomputed behind
    /// the press, as for a verdict.
    pub fn mute_taste(&self, leader_title_id: i64) -> Result<(), CoreError> {
        {
            let db = self.db.lock();
            db.mute_taste(leader_title_id, unix_now() + crate::index::taste::MUTE_SECS)?;
        }
        self.kick_taste_refresh();
        Ok(())
    }

    pub fn unmute_taste(&self, leader_title_id: i64) -> Result<(), CoreError> {
        {
            let db = self.db.lock();
            db.unmute_taste(leader_title_id)?;
        }
        self.kick_taste_refresh();
        Ok(())
    }

    /// What the last evening finished and nobody has judged yet, offered
    /// from 06:00 until the next evening starts. Empty otherwise.
    pub fn evening_review(&self, tz_offset_secs: i32) -> Result<Vec<TitleItem>, CoreError> {
        let db = self.read_db.lock();
        Ok(
            crate::index::queries::evening_review(&db, unix_now(), tz_offset_secs)?
                .into_iter()
                .map(to_item)
                .collect(),
        )
    }

    /// "Later": puts the last evening's review aside for good.
    pub fn dismiss_review(&self) -> Result<(), CoreError> {
        let db = self.db.lock();
        crate::index::queries::dismiss_review(&db, unix_now())?;
        Ok(())
    }

    /// The taste in words: each facet strongest first, with what sets its
    /// titles apart from the library, and the genres the viewer turns down.
    /// The screen composes the sentences.
    pub fn taste_profile(&self) -> Result<TasteProfile, CoreError> {
        let db = self.heavy_db.lock();
        let profile = crate::index::profile::taste_profile(&db)?;
        Ok(TasteProfile {
            facets: profile
                .facets
                .into_iter()
                .map(|f| ProfileFacet {
                    leader_id: f.leader_id,
                    leader: f.leader,
                    share: f.share,
                    genres: f.genres,
                    keywords: f.keywords,
                    directors: f.directors,
                    decade_from: f.decades.0,
                    decade_to: f.decades.1,
                    tones: f.tones,
                })
                .collect(),
            avoid: profile.avoid,
        })
    }

    /// What has moved the taste, newest first.
    pub fn taste_ledger(&self, limit: u32) -> Result<Vec<ApiTasteEvent>, CoreError> {
        let db = self.read_db.lock();
        Ok(db
            .taste_ledger(limit)?
            .into_iter()
            .map(|e| ApiTasteEvent {
                at: e.at,
                kind: match e.kind {
                    crate::index::db::TASTE_FINISHED => ApiTasteEventKind::Finished,
                    crate::index::db::TASTE_VERDICT => ApiTasteEventKind::Verdict,
                    crate::index::db::TASTE_DEFERRED => ApiTasteEventKind::Deferred,
                    _ => ApiTasteEventKind::Queued,
                },
                title: e.title,
            })
            .collect())
    }
}

#[cfg(test)]
mod tests {
    use crate::api::testing::*;
    use crate::source::PlaybackState;

    #[test]
    fn a_play_through_to_the_credits_retrains_the_taste_and_a_report_short_of_it_does_not() {
        let media = show_dir();
        let cache = tempfile::tempdir().unwrap();
        let (core, show) = scanned_show(&media, &cache);
        let first = core.up_next(show).unwrap().unwrap();
        let before = core.taste_runs();
        core.report_playback(first.file_id, 300.0, 1000.0, PlaybackState::Playing)
            .unwrap();
        assert_eq!(core.taste_runs(), before);
        core.report_playback(first.file_id, 950.0, 1000.0, PlaybackState::Playing)
            .unwrap();
        assert!(core.wait_for_taste(before, std::time::Duration::from_secs(5)));
        // a later report past the mark is the same play, and says nothing new
        let after = core.taste_runs();
        core.report_playback(first.file_id, 990.0, 1000.0, PlaybackState::Playing)
            .unwrap();
        std::thread::sleep(std::time::Duration::from_millis(50));
        assert_eq!(core.taste_runs(), after);
    }
}
