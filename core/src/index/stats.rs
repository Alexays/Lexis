//! How the propositions fare: what was launched from where, what of it was
//! finished, and how often the evening's trio was taken up.
//!
//! Read on demand by a diagnostic screen, never by the home: every figure is
//! one indexed query over the launch journal and the evening's own tables.

use rusqlite::params;

use super::db::{Db, IndexError, TASTE_DEFERRED, TASTE_FINISHED};
use super::tonight::{AFTERNOON_LEN_MIN, AFTERNOON_START_MIN, EVENING_LEN_MIN, EVENING_START_MIN};

/// How far back the journal's companions are kept, and so the longest window
/// the stats can answer for.
pub const STATS_REACH_DAYS: i64 = 90;

/// A launch counts as finished when its title crosses the end (the ledger's
/// finished event, not the watched flag, which a rewatch already carries)
/// within this long after it: a film left for the next day still counts, a
/// title met again next week is another decision.
const FINISHED_WITHIN_SECS: i64 = 3 * 86_400;

/// A launch this long after the home opened was not decided there: the
/// viewer left, or the screen was left on.
const DECISION_WITHIN_SECS: i64 = 30 * 60;

#[derive(Debug, Clone, Default, PartialEq)]
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

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SurfaceStat {
    pub surface: String,
    pub detail: String,
    pub launched: u32,
    pub finished: u32,
}

/// The stats over the last `days` days, capped at `STATS_REACH_DAYS`. An
/// evening belongs to the window when it starts inside it.
pub fn reco_stats(
    db: &Db,
    now: i64,
    tz_offset_secs: i32,
    days: u32,
) -> Result<RecoStats, IndexError> {
    let from = now - i64::from(days).min(STATS_REACH_DAYS) * 86_400;
    let conn = db.conn();
    let mut stats = RecoStats::default();

    let mut by_surface = conn.prepare_cached(
        "SELECT surface, detail, COUNT(*), SUM(finished) FROM (
           SELECT l.surface, l.detail, EXISTS (
             SELECT 1 FROM taste_event e
             WHERE e.at >= l.at AND e.at < l.at + ?2
               AND e.kind = ?3 AND e.title_id = l.title_id
           ) AS finished
           FROM launch l WHERE l.at >= ?1
         )
         GROUP BY surface, detail
         ORDER BY COUNT(*) DESC, surface, detail",
    )?;
    let rows = by_surface.query_map(params![from, FINISHED_WITHIN_SECS, TASTE_FINISHED], |r| {
        Ok(SurfaceStat {
            surface: r.get(0)?,
            detail: r.get(1)?,
            launched: r.get(2)?,
            finished: r.get(3)?,
        })
    })?;
    for row in rows {
        let row = row?;
        stats.launches += row.launched;
        stats.finished += row.finished;
        stats.surfaces.push(row);
    }

    // A session is an evening, or a weekend afternoon under its own key (see
    // `tonight::session_of`); both show a trio, and both count here. Its span
    // starts on its local day at the session's hour, read back through the
    // offset.
    let tz = i64::from(tz_offset_secs);
    (stats.trio_evenings, stats.trio_accepted) = conn
        .prepare_cached(
            "SELECT COUNT(*), COALESCE(SUM(EXISTS (
               SELECT 1 FROM tonight_shown s JOIN launch l ON l.title_id = s.title_id
               WHERE s.evening = e.evening AND l.at >= e.start AND l.at < e.start + e.len
             )), 0)
             FROM (SELECT evening,
                          CASE WHEN evening >= 0 THEN evening * 86400 + ?2
                               ELSE (-evening - 1) * 86400 + ?3 END AS start,
                          CASE WHEN evening >= 0 THEN ?4 ELSE ?5 END AS len
                     FROM (SELECT DISTINCT evening FROM tonight_shown)) e
             WHERE e.start >= ?1",
        )?
        .query_row(
            params![
                from,
                i64::from(EVENING_START_MIN) * 60 - tz,
                i64::from(AFTERNOON_START_MIN) * 60 - tz,
                i64::from(EVENING_LEN_MIN) * 60,
                i64::from(AFTERNOON_LEN_MIN) * 60
            ],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )?;

    let deferrals: u32 = conn
        .prepare_cached("SELECT COUNT(*) FROM taste_event WHERE kind = ?1 AND at >= ?2")?
        .query_row(params![TASTE_DEFERRED, from], |r| r.get(0))?;
    if stats.trio_evenings > 0 {
        stats.deferrals_per_evening = deferrals as f32 / stats.trio_evenings as f32;
    }

    // A launch is timed from the earliest opening since the launch before
    // it: a return from a title page opens the home again mid-decision, and
    // a second film the same sitting has no opening of its own.
    let mut waits: Vec<i64> = conn
        .prepare_cached(
            "SELECT wait FROM (
               SELECT l.at - (
                 SELECT MIN(h.at) FROM home_open h
                 WHERE h.at <= l.at AND h.at >= l.at - ?2
                   AND h.at > COALESCE((SELECT MAX(p.at) FROM launch p WHERE p.at < l.at), -1)
               ) AS wait
               FROM launch l WHERE l.at >= ?1
             ) WHERE wait IS NOT NULL",
        )?
        .query_map(params![from, DECISION_WITHIN_SECS], |r| r.get(0))?
        .collect::<Result<_, _>>()?;
    if !waits.is_empty() {
        waits.sort_unstable();
        let mid = waits.len() / 2;
        let median = if waits.len().is_multiple_of(2) {
            (waits[mid - 1] + waits[mid]) / 2
        } else {
            waits[mid]
        };
        stats.median_decision_secs = Some(median as u32);
    }
    Ok(stats)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::index::db::{FileMedia, FileRecord, WatchAuthority, WatchRecord};
    use crate::index::tonight::{ROLE_GAMBLE, ROLE_SAFE};
    use crate::index::MediaKind;

    const DAY: i64 = 86_400;
    /// A Thursday.
    const EVENING: i64 = 20_685;
    /// 21:00 that Thursday, read at tz 0.
    const NOW: i64 = EVENING * DAY + 21 * 3_600;

    fn film(db: &Db, name: &str) -> i64 {
        let id = db.upsert_title(MediaKind::Movie, name, None).unwrap();
        db.upsert_file(&FileRecord {
            source_id: "s1".into(),
            dir: "Media".into(),
            path: format!("Media/{name}.mkv"),
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
    }

    fn watched(db: &Db, title_id: i64, at: i64) {
        let file_id: i64 = db
            .conn()
            .query_row(
                "SELECT id FROM files WHERE title_id = ?1",
                [title_id],
                |r| r.get(0),
            )
            .unwrap();
        db.upsert_watch_state(
            &WatchRecord {
                file_id,
                position_secs: 6000.0,
                duration_secs: 6000.0,
                watched: true,
                plays: 0,
                updated_at: at,
            },
            WatchAuthority::Report,
        )
        .unwrap();
    }

    #[test]
    fn an_evening_that_launched_one_of_its_cards_counts_as_accepted() {
        let db = Db::open_in_memory().unwrap();
        let safe = film(&db, "Safe");
        let gamble = film(&db, "Gamble");
        let yesterday = film(&db, "Yesterday");
        let old = film(&db, "Old");
        db.record_tonight_exposure(EVENING - 1, &[(ROLE_SAFE, yesterday)], &[], 30)
            .unwrap();
        db.record_tonight_exposure(
            EVENING,
            &[(ROLE_SAFE, safe), (ROLE_GAMBLE, gamble)],
            &[],
            30,
        )
        .unwrap();
        db.record_launch(safe, NOW, "tonight.safe", "").unwrap();
        watched(&db, safe, NOW + 2 * 3_600);
        // yesterday's card, launched tonight from search: it answers neither evening
        db.record_launch(yesterday, NOW + 60, "search", "").unwrap();
        // outside the week asked for
        db.record_launch(old, NOW - 10 * DAY, "library", "")
            .unwrap();
        db.defer_tonight(gamble, NOW).unwrap();

        let stats = reco_stats(&db, NOW + 3 * 3_600, 0, 7).unwrap();
        assert_eq!(stats.launches, 2);
        assert_eq!(stats.finished, 1);
        assert_eq!(
            stats.surfaces,
            [
                SurfaceStat {
                    surface: "search".into(),
                    detail: String::new(),
                    launched: 1,
                    finished: 0
                },
                SurfaceStat {
                    surface: "tonight.safe".into(),
                    detail: String::new(),
                    launched: 1,
                    finished: 1
                },
            ]
        );
        assert_eq!((stats.trio_evenings, stats.trio_accepted), (2, 1));
        assert_eq!(stats.deferrals_per_evening, 0.5);
    }

    /// A weekend afternoon shows a trio under a key of its own, and counts as
    /// a session beside the evenings: a launch in its hours accepts it, and
    /// the evening's write keeps it rather than reading its key as ancient.
    #[test]
    fn a_weekend_afternoon_counts_as_a_session_of_its_own() {
        let db = Db::open_in_memory().unwrap();
        let noon = film(&db, "Noon");
        let night = film(&db, "Night");
        let saturday = EVENING + 2;
        db.record_tonight_exposure(-saturday - 1, &[(ROLE_SAFE, noon)], &[], 30)
            .unwrap();
        db.record_tonight_exposure(saturday, &[(ROLE_SAFE, night)], &[], 30)
            .unwrap();
        db.record_launch(noon, saturday * DAY + 15 * 3_600, "tonight.safe", "")
            .unwrap();
        // the evening's card, launched the next day at noon: past its span
        db.record_launch(night, (saturday + 1) * DAY + 12 * 3_600, "detail", "")
            .unwrap();

        let stats = reco_stats(&db, (saturday + 1) * DAY + 13 * 3_600, 0, 7).unwrap();
        assert_eq!((stats.trio_evenings, stats.trio_accepted), (2, 1));
    }

    #[test]
    fn a_finish_days_after_the_launch_is_another_decision() {
        let db = Db::open_in_memory().unwrap();
        let slow = film(&db, "Slow");
        db.record_launch(slow, NOW, "detail", "").unwrap();
        watched(&db, slow, NOW + 4 * DAY);
        let stats = reco_stats(&db, NOW + 5 * DAY, 0, 30).unwrap();
        assert_eq!((stats.launches, stats.finished), (1, 0));
    }

    #[test]
    fn a_launch_forty_minutes_after_the_home_opened_stays_out_of_the_median() {
        let db = Db::open_in_memory().unwrap();
        let film_id = film(&db, "Any");
        db.record_home_open(NOW).unwrap();
        db.record_launch(film_id, NOW + 40 * 60, "row", "taste_facet")
            .unwrap();
        assert_eq!(
            reco_stats(&db, NOW + DAY, 0, 7)
                .unwrap()
                .median_decision_secs,
            None
        );

        // the first launch after an opening is the decision, the next is not
        let later = NOW + 3 * 3_600;
        db.record_home_open(later).unwrap();
        db.record_launch(film_id, later + 300, "tonight.safe", "")
            .unwrap();
        db.record_launch(film_id, later + 600, "queue", "").unwrap();
        let again = later + 3_600;
        db.record_home_open(again).unwrap();
        db.record_launch(film_id, again + 100, "queue", "").unwrap();
        assert_eq!(
            reco_stats(&db, NOW + DAY, 0, 7)
                .unwrap()
                .median_decision_secs,
            Some(200)
        );
    }

    fn reported(db: &Db, title_id: i64, position_secs: f64, at: i64) {
        let file_id: i64 = db
            .conn()
            .query_row(
                "SELECT id FROM files WHERE title_id = ?1",
                [title_id],
                |r| r.get(0),
            )
            .unwrap();
        db.upsert_watch_state(
            &WatchRecord {
                file_id,
                position_secs,
                duration_secs: 6000.0,
                watched: false,
                plays: 0,
                updated_at: at,
            },
            WatchAuthority::Report,
        )
        .unwrap();
    }

    #[test]
    fn a_rewatch_is_finished_by_crossing_the_end_again_and_not_by_its_old_flag() {
        let db = Db::open_in_memory().unwrap();
        let seen = film(&db, "Seen");
        watched(&db, seen, NOW - 30 * DAY);
        db.record_launch(seen, NOW, "tonight.familiar", "").unwrap();
        reported(&db, seen, 0.0, NOW);
        reported(&db, seen, 300.0, NOW + 300);
        let stats = reco_stats(&db, NOW + 3_600, 0, 7).unwrap();
        assert_eq!((stats.launches, stats.finished), (1, 0));

        reported(&db, seen, 5_900.0, NOW + 2 * 3_600);
        let stats = reco_stats(&db, NOW + 3 * 3_600, 0, 7).unwrap();
        assert_eq!((stats.launches, stats.finished), (1, 1));
    }

    #[test]
    fn a_return_to_the_home_does_not_restart_the_decision() {
        let db = Db::open_in_memory().unwrap();
        let film_id = film(&db, "Any");
        db.record_home_open(NOW).unwrap();
        // back from a title page: the home appears again, the choosing goes on
        db.record_home_open(NOW + 120).unwrap();
        db.record_launch(film_id, NOW + 200, "row", "saga").unwrap();
        assert_eq!(
            reco_stats(&db, NOW + DAY, 0, 7)
                .unwrap()
                .median_decision_secs,
            Some(200)
        );
    }

    #[test]
    fn no_history_gives_zeros_and_no_median() {
        let db = Db::open_in_memory().unwrap();
        assert_eq!(reco_stats(&db, NOW, 0, 90).unwrap(), RecoStats::default());
    }
}
