use super::library::{to_item, ApiMediaKind, TitleItem};
use super::{unix_now, CoreError, LexisCore};
use crate::index::rows::{browse_rows, record_shown, Reason};
use std::collections::HashSet;

/// Where the step-aside row's reach is kept, the same key `rows` reads.
const STEP_ASIDE_REACH: &str = "step_aside.reach";

/// Why this row is on the screen. It is what the row is named from: the app
/// renders it out of its own catalogs, in the viewer's language, so no row
/// carries prose the core made up in English. It is also what the UI styles
/// and orders by, without ever matching on a name.
#[derive(Debug, Clone, uniffi::Enum)]
pub enum HomeReason {
    /// `seed_id` is what `mute_taste` takes to contest the row.
    BecauseYouWatched {
        seed: String,
        seed_id: i64,
    },
    /// `leader_id` is what `mute_taste` takes to contest the row.
    TasteFacet {
        leader: String,
        leader_id: i64,
    },
    /// The next title of each saga begun; each card's place is in `places`.
    Sagas,
    WithActor {
        name: String,
    },
    ByDirector {
        name: String,
    },
    /// `decade` is the first year of it: 1990, 2010.
    GenreEra {
        genre: String,
        decade: u16,
    },
    /// Films and series together, newest first.
    RecentlyAdded,
    LongAgo,
    Rediscovery,
    /// Deliberately a step aside from every taste.
    StepAside,
    /// A dated row: `window` is "oct", "dec" or "summer".
    Season {
        window: String,
    },
    /// Titles added long ago and never played; `seed` explains the first.
    ForgottenGem {
        seed: String,
    },
    /// A cycle through one taste, `done` of `total` watched.
    Thread {
        leader: String,
        done: u32,
        total: u32,
    },
    /// A mood asked for in one press: `key` is one of the keys `moods` lists.
    Mood {
        key: String,
    },
    /// What this day of the year brings back.
    OnThisDay {
        kind: DayKind,
    },
    /// All of one director's work, in order, for a week after one was finished.
    Retrospective {
        name: String,
    },
    /// The taste this month of the year leans to; `month` is 1 to 12.
    ThisMonth {
        month: u8,
        leader: String,
    },
    /// The week's theme, until `ends_at` (unix seconds).
    CineClub {
        theme: ClubTheme,
        ends_at: i64,
    },
    /// What the viewer is in the middle of, as `queue` answers it.
    UpNext,
    /// The evening's picks and the ideas after them.
    Tonight,
    /// Filmed stage shows not yet seen, apart from the films.
    StageShows,
    /// What the viewer put aside for later.
    Watchlist,
    /// The library's share of what TMDB says the world watches this week.
    Popular {
        series: bool,
    },
}

/// Which date an "on this day" row keeps.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum DayKind {
    /// Released `years` ago, within three days.
    Anniversary { years: u16 },
    /// Finished a year ago, within three days.
    YearAgo,
}

/// What the week's club is about.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum ClubTheme {
    Keyword { word: String },
    Composer { name: String },
    Writer { name: String },
}

impl From<Reason> for HomeReason {
    fn from(reason: Reason) -> Self {
        use crate::index::rows::{ClubTheme as Theme, DayKind as Day};
        match reason {
            Reason::BecauseYouWatched { seed, seed_id } => {
                HomeReason::BecauseYouWatched { seed, seed_id }
            }
            Reason::TasteFacet { leader, leader_id } => {
                HomeReason::TasteFacet { leader, leader_id }
            }
            Reason::Sagas => HomeReason::Sagas,
            Reason::WithActor { name } => HomeReason::WithActor { name },
            Reason::ByDirector { name } => HomeReason::ByDirector { name },
            Reason::GenreEra { genre, decade } => HomeReason::GenreEra { genre, decade },
            Reason::RecentlyAdded => HomeReason::RecentlyAdded,
            Reason::StepAside => HomeReason::StepAside,
            Reason::Season { window } => HomeReason::Season { window },
            Reason::Mood { key } => HomeReason::Mood { key },
            Reason::ForgottenGem { seed } => HomeReason::ForgottenGem { seed },
            Reason::Thread {
                leader,
                done,
                total,
            } => HomeReason::Thread {
                leader,
                done,
                total,
            },
            Reason::LongAgo => HomeReason::LongAgo,
            Reason::Rediscovery => HomeReason::Rediscovery,
            Reason::OnThisDay { kind } => HomeReason::OnThisDay {
                kind: match kind {
                    Day::Anniversary { years } => DayKind::Anniversary { years },
                    Day::YearAgo => DayKind::YearAgo,
                },
            },
            Reason::Retrospective { name } => HomeReason::Retrospective { name },
            Reason::ThisMonth { month, leader } => HomeReason::ThisMonth { month, leader },
            Reason::CineClub { theme, ends_at } => HomeReason::CineClub {
                theme: match theme {
                    Theme::Keyword { word } => ClubTheme::Keyword { word },
                    Theme::Composer { name } => ClubTheme::Composer { name },
                    Theme::Writer { name } => ClubTheme::Writer { name },
                },
                ends_at,
            },
            Reason::UpNext => HomeReason::UpNext,
            Reason::Tonight => HomeReason::Tonight,
            Reason::StageShows => HomeReason::StageShows,
            Reason::Watchlist => HomeReason::Watchlist,
            Reason::Popular { series } => HomeReason::Popular { series },
        }
    }
}

/// One home row. `items` is the same record the library screen renders; in a
/// continue-watching or next-up row, `first_file_id` is the file that plays.
#[derive(Debug, uniffi::Record)]
pub struct HomeRow {
    pub reason: HomeReason,
    pub items: Vec<TitleItem>,
    /// Whether the row opened holds more than these.
    pub more: bool,
    /// Where each of `items` stands in its saga, in the same order; empty on
    /// every row but `Sagas`.
    pub places: Vec<SagaPlace>,
}

/// A title's place in its saga: the `position`th of `size`, `watched` seen.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct SagaPlace {
    /// The saga's name, without the word its source filed it under.
    pub name: String,
    pub position: u32,
    pub size: u32,
    pub watched: u32,
}

impl From<HomeReason> for Reason {
    fn from(reason: HomeReason) -> Self {
        use crate::index::rows::{ClubTheme as Theme, DayKind as Day};
        match reason {
            HomeReason::BecauseYouWatched { seed, seed_id } => {
                Reason::BecauseYouWatched { seed, seed_id }
            }
            HomeReason::TasteFacet { leader, leader_id } => {
                Reason::TasteFacet { leader, leader_id }
            }
            HomeReason::Sagas => Reason::Sagas,
            HomeReason::WithActor { name } => Reason::WithActor { name },
            HomeReason::ByDirector { name } => Reason::ByDirector { name },
            HomeReason::GenreEra { genre, decade } => Reason::GenreEra { genre, decade },
            HomeReason::RecentlyAdded => Reason::RecentlyAdded,
            HomeReason::LongAgo => Reason::LongAgo,
            HomeReason::Rediscovery => Reason::Rediscovery,
            HomeReason::StepAside => Reason::StepAside,
            HomeReason::Season { window } => Reason::Season { window },
            HomeReason::Mood { key } => Reason::Mood { key },
            HomeReason::ForgottenGem { seed } => Reason::ForgottenGem { seed },
            HomeReason::Thread {
                leader,
                done,
                total,
            } => Reason::Thread {
                leader,
                done,
                total,
            },
            HomeReason::OnThisDay { kind } => Reason::OnThisDay {
                kind: match kind {
                    DayKind::Anniversary { years } => Day::Anniversary { years },
                    DayKind::YearAgo => Day::YearAgo,
                },
            },
            HomeReason::Retrospective { name } => Reason::Retrospective { name },
            HomeReason::ThisMonth { month, leader } => Reason::ThisMonth { month, leader },
            HomeReason::CineClub { theme, ends_at } => Reason::CineClub {
                theme: match theme {
                    ClubTheme::Keyword { word } => Theme::Keyword { word },
                    ClubTheme::Composer { name } => Theme::Composer { name },
                    ClubTheme::Writer { name } => Theme::Writer { name },
                },
                ends_at,
            },
            HomeReason::UpNext => Reason::UpNext,
            HomeReason::Tonight => Reason::Tonight,
            HomeReason::StageShows => Reason::StageShows,
            HomeReason::Watchlist => Reason::Watchlist,
            HomeReason::Popular { series } => Reason::Popular { series },
        }
    }
}

/// One entry of the queue. A resume file means the card wears a progress
/// bar; its absence means the title was only ever wanted.
#[derive(Debug, uniffi::Record)]
pub struct QueueItem {
    pub item: TitleItem,
    pub resume_file_id: Option<i64>,
    pub position_secs: f64,
    pub duration_secs: f64,
    /// Which episode the resume file is. Both absent on a film, and on an
    /// episode nothing numbered.
    pub season: Option<u16>,
    pub episode: Option<u16>,
}

/// A mood worth a press, and the first titles behind it.
#[derive(Debug, uniffi::Record)]
pub struct MoodShelf {
    pub key: String,
    pub title_ids: Vec<i64>,
}

#[uniffi::export]
impl LexisCore {
    /// One shelf's suggested rows, from the local tables alone: no request is
    /// made here, so a tab never waits on a network (spec: Instant UI). What
    /// it joins against was fetched by `fetch_similar`. Rows the library
    /// cannot fill are absent, never empty.
    pub fn browse_rows(
        &self,
        kind: Option<ApiMediaKind>,
        tz_offset_secs: i32,
    ) -> Result<Vec<HomeRow>, CoreError> {
        // the heaviest lot in the app: a dozen-plus indexed queries per call.
        // On the heavy connection so a browse never queues behind it.
        let db = self.heavy_db.lock();
        let now = unix_now();
        // one snapshot for the whole lot: a sync committing midway would
        // otherwise show a title in one row and its absence in the next
        let snapshot = db
            .conn()
            .unchecked_transaction()
            .map_err(crate::index::db::IndexError::from)?;
        // the home carries the evening's lane and the queue above its rows;
        // a shelf tab carries nothing else
        let shown = match kind {
            None => db.on_home(crate::index::tonight::session_of(now, tz_offset_secs))?,
            Some(_) => HashSet::new(),
        };
        let rows = browse_rows(&db, kind.map(Into::into), now, tz_offset_secs, &shown)?;
        snapshot
            .commit()
            .map_err(crate::index::db::IndexError::from)?;
        drop(db);
        // counted once a day, so a browse that finds a scan writing, or a write
        // that fails, skips it rather than failing: the next one that day
        // counts it
        if let Some(db) = self.db.try_lock() {
            if let Err(e) = record_shown(&db, &rows, now, tz_offset_secs) {
                eprintln!("[lexis-core] row exposure not recorded: {e}");
            }
        }
        Ok(rows
            .into_iter()
            .map(|r| HomeRow {
                reason: r.reason.into(),
                items: r.items.into_iter().map(to_item).collect(),
                more: r.more,
                places: r
                    .places
                    .into_iter()
                    .map(|p| SagaPlace {
                        name: p.name,
                        position: p.position,
                        size: p.size,
                        watched: p.watched,
                    })
                    .collect(),
            })
            .collect())
    }

    /// How far aside the step-aside row is asked to reach.
    pub fn step_aside_reach(&self) -> Result<String, CoreError> {
        let db = self.read_db.lock();
        Ok(db
            .setting(STEP_ASIDE_REACH)?
            .unwrap_or_else(|| "default".to_string()))
    }

    pub fn set_step_aside_reach(&self, reach: String) -> Result<(), CoreError> {
        if !matches!(reach.as_str(), "close" | "default" | "far") {
            return Err(CoreError::Storage {
                msg: format!("unknown step-aside reach {reach}"),
            });
        }
        let db = self.db.lock();
        db.set_setting(STEP_ASIDE_REACH, &reach)?;
        Ok(())
    }

    /// Puts a title aside to watch later, or takes it back off the list.
    ///
    /// The viewer's own list, kept here and nowhere else: Plex has a watchlist
    /// of its own, about its own catalogue rather than about this library, and
    /// the two answer different questions.
    pub fn set_watchlist(&self, title_id: i64, on: bool) -> Result<(), CoreError> {
        let db = self.db.lock();
        db.set_watchlisted(title_id, on, unix_now())?;
        Ok(())
    }

    /// The moods worth offering, as the keys `row_items` opens with
    /// `HomeReason::Mood`: those with a shelf of unseen titles behind them,
    /// each with the first of those titles. Empty until a taste pass has
    /// ranked the library against them.
    pub fn moods(&self) -> Result<Vec<MoodShelf>, CoreError> {
        let db = self.read_db.lock();
        Ok(crate::index::rows::moods(&db)?
            .into_iter()
            .map(|(key, title_ids)| MoodShelf {
                key: key.to_string(),
                title_ids,
            })
            .collect())
    }

    /// Everything one row of a shelf holds, for the screen a row opens into.
    /// A rail draws six of its twenty; this answers with what the row is
    /// actually made of, so a row can be a place rather than a glimpse.
    pub fn row_items(
        &self,
        reason: HomeReason,
        tz_offset_secs: i32,
    ) -> Result<Vec<TitleItem>, CoreError> {
        let db = self.heavy_db.lock();
        let rows = crate::index::rows::row_items(&db, &reason.into(), unix_now(), tz_offset_secs)?;
        Ok(rows.into_iter().map(to_item).collect())
    }

    /// What the viewer is in the middle of, likeliest first (see
    /// `queries::up_next`).
    pub fn queue(&self, limit: u32) -> Result<Vec<QueueItem>, CoreError> {
        use rusqlite::OptionalExtension;
        let db = self.read_db.lock();
        let mut numbers = db
            .conn()
            .prepare_cached("SELECT season, episode FROM files WHERE id = ?1")
            .map_err(crate::index::db::IndexError::from)?;
        crate::index::queries::up_next(&db, limit, unix_now())?
            .into_iter()
            .map(|q| {
                let (season, episode) = match q.resume_file_id {
                    Some(id) => numbers
                        .query_row([id], |r| Ok((r.get(0)?, r.get(1)?)))
                        .optional()
                        .map_err(crate::index::db::IndexError::from)?
                        .unwrap_or((None, None)),
                    None => (None, None),
                };
                Ok(QueueItem {
                    item: to_item(q.title),
                    resume_file_id: q.resume_file_id,
                    position_secs: q.position_secs,
                    duration_secs: q.duration_secs,
                    season,
                    episode,
                })
            })
            .collect()
    }
}

#[cfg(test)]
impl LexisCore {
    /// The list, newest first. Titles whose files have all gone are left out:
    /// a rail that opens something unplayable is a promise broken.
    pub fn watchlist(&self, limit: u32) -> Result<Vec<TitleItem>, CoreError> {
        let db = self.read_db.lock();
        Ok(crate::index::queries::watchlist(&db, limit)?
            .into_iter()
            .map(to_item)
            .collect())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::api::testing::*;
    use crate::source::local::LocalModule;
    use crate::source::module::SourceModule;
    use crate::source::plex::PlexModule;
    use std::fs;
    use std::sync::Arc;

    #[test]
    fn the_watchlist_keeps_what_was_put_aside_newest_first() {
        use crate::index::db::{Db, FileMedia, FileRecord};
        use crate::index::MediaKind;

        let cache = tempfile::tempdir().unwrap();
        let store = Arc::new(MemStore::default());
        let core = LexisCore::new(cache.path().to_string_lossy().into_owned(), store).unwrap();
        let db = Db::open(&cache.path().join("index.sqlite")).unwrap();
        let film = |name: &str| -> i64 {
            let id = db.upsert_title(MediaKind::Movie, name, None).unwrap();
            db.upsert_file(&FileRecord {
                source_id: "s1".into(),
                dir: "Movies".into(),
                path: format!("Movies/{name}.mkv"),
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
            id
        };
        let first = film("Le Convoi");
        let second = film("La Traversee");
        let gone = film("Sans Fichier");

        // Written straight, so the two carry dates a second apart rather than
        // the same second the two API calls would share.
        db.set_watchlisted(first, true, 100).unwrap();
        db.set_watchlisted(second, true, 200).unwrap();
        db.set_watchlisted(gone, true, 300).unwrap();
        db.conn()
            .execute("DELETE FROM files WHERE title_id = ?1", [gone])
            .unwrap();

        let names: Vec<String> = core
            .watchlist(10)
            .unwrap()
            .into_iter()
            .map(|t| t.name)
            .collect();
        // newest first, and the one with nothing left to play is not offered
        assert_eq!(names, ["La Traversee", "Le Convoi"]);
        assert!(core.title_detail(second).unwrap().in_watchlist);

        // A second press does not walk a title back to the front of the rail.
        db.set_watchlisted(first, true, 400).unwrap();
        let names: Vec<String> = core
            .watchlist(10)
            .unwrap()
            .into_iter()
            .map(|t| t.name)
            .collect();
        assert_eq!(names, ["La Traversee", "Le Convoi"]);

        core.set_watchlist(second, false).unwrap();
        let names: Vec<String> = core
            .watchlist(10)
            .unwrap()
            .into_iter()
            .map(|t| t.name)
            .collect();
        assert_eq!(names, ["Le Convoi"]);
        assert!(!core.title_detail(second).unwrap().in_watchlist);
    }

    /// Counting what the taste rows showed is bookkeeping: when the write
    /// fails, the rows still come back.
    #[test]
    fn a_browse_whose_exposure_write_fails_still_returns_its_rows() {
        use crate::index::db::{Db, FileMedia, FileRecord, TastePassOutput, TastePick};
        use crate::index::MediaKind;

        let cache = tempfile::tempdir().unwrap();
        let store = Arc::new(MemStore::default());
        let core = LexisCore::new(cache.path().to_string_lossy().into_owned(), store).unwrap();
        let db = Db::open(&cache.path().join("index.sqlite")).unwrap();
        let heat = db.upsert_title(MediaKind::Movie, "Heat", None).unwrap();
        let picks = (0..5)
            .map(|n| {
                let id = db
                    .upsert_title(MediaKind::Movie, &format!("Pick {n}"), None)
                    .unwrap();
                db.upsert_file(&FileRecord {
                    source_id: "s1".into(),
                    dir: "Movies".into(),
                    path: format!("Movies/pick{n}.mkv"),
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
                TastePick {
                    title_id: id,
                    facet: 0,
                    leader: heat,
                }
            })
            .collect();
        db.replace_taste(&TastePassOutput {
            picks,
            ..Default::default()
        })
        .unwrap();
        db.conn()
            .execute_batch(
                "CREATE TRIGGER refuse BEFORE INSERT ON row_exposure
                 BEGIN SELECT RAISE(ABORT, 'refused'); END;",
            )
            .unwrap();

        let rows = core.browse_rows(None, 0).unwrap();
        assert!(rows
            .iter()
            .any(|r| matches!(r.reason, HomeReason::TasteFacet { .. })));
    }

    #[test]
    fn the_home_rows_are_what_the_library_and_the_history_can_fill() {
        use crate::plex::fake::library;

        // a Plex server whose movie was left in progress and whose second
        // episode was played to the end, plus a local movie nobody has touched
        let server = library();
        let media = tempfile::tempdir().unwrap();
        fs::create_dir_all(media.path().join("Movies")).unwrap();
        fs::write(media.path().join("Movies/Alien (1979).mkv"), b"x").unwrap();
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

        // ordered by the server's own lastViewedAt, and the episode left
        // running is newer than the film
        let queue = core.queue(20).unwrap();
        let names: Vec<&str> = queue.iter().map(|q| q.item.name.as_str()).collect();
        assert_eq!(names, ["The Expanse", "Dune"]);
        // what the UI plays for a show is the episode that was left running
        let expanse = &queue[0].item;
        assert_eq!(expanse.file_count, 2);
        assert!(queue[0].resume_file_id.is_some());
        // and it says which one, where a film says none
        assert_eq!(queue[0].season, Some(1));
        assert!(queue[0].episode.is_some());
        assert_eq!((queue[1].season, queue[1].episode), (None, None));

        // three titles are not a shelf of what arrived: the row waits for five
        let rows = core.browse_rows(None, 0).unwrap();
        assert!(!rows
            .iter()
            .any(|r| matches!(r.reason, HomeReason::RecentlyAdded)));

        // and the row the queue opens into holds the queue
        let opened = core.row_items(HomeReason::UpNext, 0).unwrap();
        let names: Vec<&str> = opened.iter().map(|t| t.name.as_str()).collect();
        assert_eq!(names, ["The Expanse", "Dune"]);
    }

    #[test]
    fn an_empty_library_has_no_rows_and_asks_tmdb_nothing() {
        let cache = tempfile::tempdir().unwrap();
        let store = Arc::new(MemStore::default());
        let core =
            LexisCore::new(cache.path().to_string_lossy().into_owned(), store.clone()).unwrap();
        assert!(core
            .browse_rows(Some(ApiMediaKind::Movie), 0)
            .unwrap()
            .is_empty());

        // without a key, fetching similar links reports zero instead of failing
        let report = core.fetch_similar(50).unwrap();
        assert_eq!(report.attempted, 0);
        assert_eq!(report.linked, 0);
        assert_eq!(report.failed, 0);
    }
}
