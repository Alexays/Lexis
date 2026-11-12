use super::rows::HomeReason;
use super::{unix_now, CoreError, LexisCore};

/// A gesture that says a viewer leans towards a title without having watched
/// it: the fingerprint weighs it for a month, and the title stays on offer.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum InterestKind {
    /// The detail page stayed open more than eight seconds.
    DetailDwell,
    /// More than thirty seconds of a trailer.
    Trailer,
    Watchlist,
    /// Picked over another title when asked to choose.
    Chosen,
}

/// The surface a launch was proposed by. It is kept under a stable key, and
/// a home row under the kind of its reason: the stats count kinds of
/// proposition, never the names a row carries.
#[derive(Debug, Clone, uniffi::Enum)]
pub enum LaunchSurface {
    TonightSafe,
    TonightGamble,
    TonightFamiliar,
    /// The runners-up under the trio.
    TonightMore,
    Queue,
    HomeRow {
        reason: HomeReason,
    },
    Detail,
    Search,
    Person,
    Library,
    Duo,
    ThisOrThat,
    Surprise,
    Ask,
    Review,
    Other,
}

impl LaunchSurface {
    /// `(surface, detail)` as the launch journal stores them.
    fn key(&self) -> (&'static str, &'static str) {
        match self {
            LaunchSurface::TonightSafe => ("tonight.safe", ""),
            LaunchSurface::TonightGamble => ("tonight.gamble", ""),
            LaunchSurface::TonightFamiliar => ("tonight.familiar", ""),
            LaunchSurface::TonightMore => ("tonight.more", ""),
            LaunchSurface::Queue => ("queue", ""),
            LaunchSurface::HomeRow { reason } => (
                "row",
                crate::index::rows::launch_detail(&reason.clone().into()),
            ),
            LaunchSurface::Detail => ("detail", ""),
            LaunchSurface::Search => ("search", ""),
            LaunchSurface::Person => ("person", ""),
            LaunchSurface::Library => ("library", ""),
            LaunchSurface::Duo => ("duo", ""),
            LaunchSurface::ThisOrThat => ("this_or_that", ""),
            LaunchSurface::Surprise => ("surprise", ""),
            LaunchSurface::Ask => ("ask", ""),
            LaunchSurface::Review => ("review", ""),
            LaunchSurface::Other => ("other", ""),
        }
    }
}

/// How the propositions fare over a window, for the diagnostic screen.
/// `surface` and `detail` are the journal's keys; the app names them.
#[derive(Debug, uniffi::Record)]
pub struct RecoStats {
    pub launches: u32,
    pub finished: u32,
    /// Most launched first.
    pub surfaces: Vec<SurfaceStat>,
    /// Evenings with a trio shown, and how many of them launched one of its cards.
    pub trio_evenings: u32,
    pub trio_accepted: u32,
    /// Median seconds from a home open to the launch that followed it within 30 minutes.
    pub median_decision_secs: Option<u32>,
    pub deferrals_per_evening: f32,
}

#[derive(Debug, uniffi::Record)]
pub struct SurfaceStat {
    pub surface: String,
    pub detail: String,
    pub launched: u32,
    pub finished: u32,
}

#[uniffi::export]
impl LexisCore {
    /// One launch, and the surface that proposed it.
    pub fn record_launch(&self, title_id: i64, surface: LaunchSurface) -> Result<(), CoreError> {
        let (surface, detail) = surface.key();
        let db = self.db.lock();
        db.record_launch(title_id, unix_now(), surface, detail)?;
        Ok(())
    }

    /// A gesture of interest in a title. The watchlist's is the event
    /// `set_watchlist` already writes, so `Watchlist` records nothing here.
    pub fn record_interest(&self, title_id: i64, kind: InterestKind) -> Result<(), CoreError> {
        let kind = match kind {
            InterestKind::DetailDwell => crate::index::db::TASTE_DWELL,
            InterestKind::Trailer => crate::index::db::TASTE_TRAILER,
            InterestKind::Chosen => crate::index::db::TASTE_CHOSEN,
            InterestKind::Watchlist => return Ok(()),
        };
        let db = self.db.lock();
        db.record_interest(title_id, kind, unix_now())?;
        Ok(())
    }

    /// The home came on screen: where the time to a decision starts.
    pub fn record_home_open(&self) -> Result<(), CoreError> {
        let db = self.db.lock();
        db.record_home_open(unix_now())?;
        Ok(())
    }

    /// How the propositions fared over the last `days` days, 90 at most.
    pub fn reco_stats(&self, days: u32, tz_offset_secs: i32) -> Result<RecoStats, CoreError> {
        let db = self.read_db.lock();
        let stats = crate::index::stats::reco_stats(&db, unix_now(), tz_offset_secs, days)?;
        Ok(RecoStats {
            launches: stats.launches,
            finished: stats.finished,
            surfaces: stats
                .surfaces
                .into_iter()
                .map(|s| SurfaceStat {
                    surface: s.surface,
                    detail: s.detail,
                    launched: s.launched,
                    finished: s.finished,
                })
                .collect(),
            trio_evenings: stats.trio_evenings,
            trio_accepted: stats.trio_accepted,
            median_decision_secs: stats.median_decision_secs,
            deferrals_per_evening: stats.deferrals_per_evening,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::api::taste::ApiTasteEventKind;
    use crate::api::testing::*;
    use std::sync::Arc;

    /// A launch crosses the FFI as a surface and lands under its stable key:
    /// a home row by the kind of its reason, never by the name it carries.
    #[test]
    fn a_launch_is_counted_under_the_surface_that_proposed_it() {
        use crate::index::db::{Db, FileMedia, FileRecord};
        use crate::index::MediaKind;

        let cache = tempfile::tempdir().unwrap();
        let store = Arc::new(MemStore::default());
        let core = LexisCore::new(cache.path().to_string_lossy().into_owned(), store).unwrap();
        let db = Db::open(&cache.path().join("index.sqlite")).unwrap();
        let id = db
            .upsert_title(MediaKind::Movie, "Le Convoi", None)
            .unwrap();
        db.upsert_file(&FileRecord {
            source_id: "s1".into(),
            dir: "Movies".into(),
            path: "Movies/Le Convoi.mkv".into(),
            size: 1,
            mtime: 0,
            seen_gen: 1,
            title_id: id,
            season: None,
            episode: None,
            rating_key: None,
            media: FileMedia::default(),
        })
        .unwrap();

        core.record_home_open().unwrap();
        core.record_launch(
            id,
            LaunchSurface::HomeRow {
                reason: HomeReason::TasteFacet {
                    leader: "Heat".into(),
                    leader_id: id,
                },
            },
        )
        .unwrap();
        core.record_launch(id, LaunchSurface::TonightGamble)
            .unwrap();

        let stats = core.reco_stats(7, 0).unwrap();
        assert_eq!(stats.launches, 2);
        let keys: Vec<(String, String)> = stats
            .surfaces
            .into_iter()
            .map(|s| (s.surface, s.detail))
            .collect();
        assert_eq!(
            keys,
            [
                ("row".to_string(), "taste_facet".to_string()),
                ("tonight.gamble".to_string(), String::new()),
            ]
        );
        assert!(stats.median_decision_secs.is_some_and(|secs| secs < 60));
    }

    /// A page read is logged as interest, and kept off the ledger; the
    /// watchlist's own event is `set_watchlist`'s, so nothing is written twice.
    #[test]
    fn a_gesture_of_interest_is_logged_once_and_off_the_ledger() {
        use crate::index::db::{Db, TASTE_DWELL, TASTE_QUEUED};
        use crate::index::MediaKind;

        let cache = tempfile::tempdir().unwrap();
        let store = Arc::new(MemStore::default());
        let core = LexisCore::new(cache.path().to_string_lossy().into_owned(), store).unwrap();
        let db = Db::open(&cache.path().join("index.sqlite")).unwrap();
        let id = db
            .upsert_title(MediaKind::Movie, "Le Convoi", None)
            .unwrap();

        core.record_interest(id, InterestKind::DetailDwell).unwrap();
        core.set_watchlist(id, true).unwrap();
        core.record_interest(id, InterestKind::Watchlist).unwrap();
        let kinds: Vec<u32> = db
            .conn()
            .prepare("SELECT kind FROM taste_event ORDER BY rowid")
            .unwrap()
            .query_map([], |r| r.get(0))
            .unwrap()
            .collect::<Result<_, _>>()
            .unwrap();
        assert_eq!(kinds, [TASTE_DWELL, TASTE_QUEUED]);
        let ledger = core.taste_ledger(10).unwrap();
        assert_eq!(ledger.len(), 1);
        assert_eq!(ledger[0].kind, ApiTasteEventKind::Queued);
    }
}
