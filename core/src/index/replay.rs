//! The replay: past evenings asked again, to score the engine offline.
//!
//! An evening counts when it started a title nothing had started before, and
//! that title is what the engine should have offered. Each one is replayed
//! on an in-memory copy cut back to the start of that evening: the taste pass
//! runs as it would have then, the trio is asked `at_minutes` into the
//! evening, and the report says how often the title was on screen.
//!
//! The history is approximate: `watch_state` keeps only the latest update per
//! file, so a title watched again later vanishes from every evening before
//! it. The approximation is the same from one revision to the next, which is
//! all a comparison of two variants needs. Likewise a title never watched
//! whose file was replaced after the evening drops out of that evening.

use super::db::Db;
use super::{rows, taste, tonight};
use crate::embed::model::EmbedModel;
use crate::embed::pass::{embed_pending, semantic_pending};
use crate::embed::{Encoder, ENCODER_SETTING};
use crate::slice::Slice;
use parking_lot::Mutex;
use std::collections::{BTreeMap, HashSet};
use std::error::Error;
use std::path::{Path, PathBuf};

pub struct ReplayOptions {
    pub evenings: usize,
    pub tz_offset_secs: i32,
    pub at_minutes: u32,
    /// An encoder and the cache directory holding its files: the copy is
    /// re-embedded with it before any evening is replayed.
    pub reembed: Option<(Encoder, PathBuf)>,
}

/// Each count is of evenings, and each includes the one before it: a card is
/// also in the lane, and the lane is also in the first 20 picks.
#[derive(Debug, Default, PartialEq)]
pub struct ReplayReport {
    pub evenings: usize,
    /// The title started that evening was a card.
    pub trio_hits: usize,
    /// Or in the lane under the trio.
    pub more_hits: usize,
    /// Or in the first 20 taste picks.
    pub taste_hits_20: usize,
    pub taste_hits_60: usize,
    /// Mean reciprocal rank in `taste_pick`, 0 when absent.
    pub mrr_taste: f64,
    /// Apart from the trio and its lane: the title was on a home row where
    /// the rail shows it before any scroll, and anywhere in a home row.
    pub row_hits_head: usize,
    pub row_hits: usize,
    /// Mean reciprocal of the best place a home row gave the title, 0 when
    /// none did.
    pub mrr_rows: f64,
}

/// When each title was first started, as far as `watch_state` still tells.
const FIRST_STARTS: &str = "SELECT f.title_id, MIN(w.updated_at)
  FROM watch_state w CROSS JOIN files f ON f.id = w.file_id
  WHERE w.watched = 1 OR w.position_secs > 0
  GROUP BY f.title_id";

/// Titles not on the shelf yet when the trio is asked (`?1`), files first:
/// `files.title_id` does not cascade. A title with any play stays, which keeps
/// the evening's targets and an old title whose file was replaced since.
const NOT_YET_SHELVED: [&str; 2] = [
    "DELETE FROM files WHERE title_id IN (SELECT t.id FROM titles t
       WHERE t.added_at > ?1
         AND NOT EXISTS (SELECT 1 FROM watch_state w CROSS JOIN files f ON f.id = w.file_id
                         WHERE f.title_id = t.id))",
    "DELETE FROM titles WHERE added_at > ?1
       AND NOT EXISTS (SELECT 1 FROM files f WHERE f.title_id = titles.id)",
];

/// What happened from the cutoff on, removed so the copy is the database as
/// it stood when the evening began.
const AFTER_CUTOFF: [&str; 8] = [
    "DELETE FROM watch_state WHERE updated_at >= ?1",
    "DELETE FROM title_verdict WHERE stated_at >= ?1",
    "DELETE FROM taste_event WHERE at >= ?1",
    "DELETE FROM watchlist WHERE added_at >= ?1",
    "DELETE FROM launch WHERE at >= ?1",
    "DELETE FROM home_open WHERE at >= ?1",
    "DELETE FROM row_kind_shown WHERE day >= ?1 / 86400",
    "DELETE FROM row_subject_shown WHERE day >= ?1 / 86400",
];

/// Replays the latest `opts.evenings` evenings of the database at `source`,
/// which is only ever read.
pub fn run(source: &Path, opts: &ReplayOptions) -> Result<ReplayReport, Box<dyn Error>> {
    // one read of the file: every evening is cut from the same snapshot
    let mut base = Db::open_read_only(source)?.copy_in_memory()?;
    if let Some((encoder, dir)) = &opts.reembed {
        base = reembed(base, *encoder, dir)?;
    }
    let mut targets: BTreeMap<i64, Vec<i64>> = BTreeMap::new();
    {
        let mut stmt = base.conn().prepare(FIRST_STARTS)?;
        let rows = stmt.query_map([], |r| Ok((r.get::<_, i64>(0)?, r.get::<_, i64>(1)?)))?;
        for row in rows {
            let (title_id, at) = row?;
            if let Some(evening) = tonight::evening_of(at, opts.tz_offset_secs) {
                targets.entry(evening).or_default().push(title_id);
            }
        }
    }

    let mut report = ReplayReport::default();
    let mut reciprocal = 0.0;
    let mut row_reciprocal = 0.0;
    for (&evening, titles) in targets.iter().rev().take(opts.evenings) {
        let (cutoff, _) = tonight::session_span(evening, opts.tz_offset_secs);
        let at = cutoff + i64::from(opts.at_minutes) * 60;
        let db = base.copy_in_memory()?;
        // before the plays are cut: they are what spares a title
        for sql in NOT_YET_SHELVED {
            db.conn().execute(sql, [at])?;
        }
        for sql in AFTER_CUTOFF {
            db.conn().execute(sql, [cutoff])?;
        }
        db.conn()
            .execute("DELETE FROM tonight_shown WHERE evening >= ?1", [evening])?;
        // a mute keeps no date it was said on: today's would bend past evenings
        db.conn().execute_batch(
            "DELETE FROM tonight_pick;
             DELETE FROM tonight_deferred;
             DELETE FROM tonight_exposure;
             DELETE FROM evening_state;
             DELETE FROM tonight_queued;
             DELETE FROM taste_mute;
             DELETE FROM row_exposure;
             DELETE FROM subject_rest;",
        )?;

        taste::refresh(&db, cutoff)?;
        let trio = tonight::tonight(&db, at, opts.tz_offset_secs, None)?;
        let picks: Vec<i64> = {
            let mut stmt = db
                .conn()
                .prepare("SELECT title_id FROM taste_pick ORDER BY rank LIMIT 60")?;
            let rows = stmt.query_map([], |r| r.get(0))?;
            rows.collect::<Result<_, _>>()?
        };

        let card = trio
            .as_ref()
            .is_some_and(|t| t.cards.iter().any(|c| titles.contains(&c.title.id)));
        let lane = card
            || trio
                .as_ref()
                .is_some_and(|t| t.more.iter().any(|m| titles.contains(&m.id)));
        let rank = picks.iter().position(|id| titles.contains(id));
        let shown: HashSet<i64> = trio
            .as_ref()
            .map(|t| {
                t.cards
                    .iter()
                    .map(|c| c.title.id)
                    .chain(t.more.iter().map(|m| m.id))
                    .collect()
            })
            .unwrap_or_default();
        let rows = rows::browse_rows(&db, None, at, opts.tz_offset_secs, &shown)?;
        let head = rows.iter().any(|r| {
            r.items
                .iter()
                .take(rows::ROW_VISIBLE)
                .any(|t| titles.contains(&t.id))
        });
        let best = rows
            .iter()
            .filter_map(|r| r.items.iter().position(|t| titles.contains(&t.id)))
            .min();
        let row = best.is_some();
        row_reciprocal += best.map_or(0.0, |p| 1.0 / (p + 1) as f64);
        report.row_hits_head += usize::from(head);
        report.row_hits += usize::from(row);
        report.evenings += 1;
        report.trio_hits += usize::from(card);
        report.more_hits += usize::from(lane);
        report.taste_hits_20 += usize::from(lane || rank.is_some_and(|r| r < 20));
        report.taste_hits_60 += usize::from(lane || rank.is_some());
        reciprocal += rank.map_or(0.0, |r| 1.0 / (r + 1) as f64);
    }
    if report.evenings > 0 {
        report.mrr_taste = reciprocal / report.evenings as f64;
        report.mrr_rows = row_reciprocal / report.evenings as f64;
    }
    Ok(report)
}

/// The copy with every title and anchor embedded again by `encoder`, whose
/// files are looked for where the app caches them under `dir`, and the
/// neighbours swept again from those vectors.
fn reembed(db: Db, encoder: Encoder, dir: &Path) -> Result<Db, Box<dyn Error>> {
    let artifact = encoder.source().artifact(dir);
    let Some(model) = EmbedModel::load(&artifact)? else {
        return Err(format!(
            "no {} encoder in {}: expected {} and its tokenizer and config beside it",
            encoder.key(),
            dir.display(),
            artifact.weights.display()
        )
        .into());
    };
    db.set_setting(ENCODER_SETTING, encoder.key())?;
    let db = Mutex::new(db);
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)?
        .as_secs() as i64;
    while embed_pending(&db, &model, 200, now, &Slice::open())?.attempted > 0 {}
    let held = Mutex::new(None);
    while semantic_pending(&db, &held, encoder.version(), 500, now, &Slice::open())?.attempted > 0 {
    }
    Ok(db.into_inner())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::index::db::{
        Db, EmbeddingRecord, FileMedia, FileRecord, WatchAuthority, WatchRecord,
    };
    use crate::index::{MediaKind, Verdict};

    const DAY: i64 = 86_400;
    const TZ: i32 = 7_200;
    /// Three weeknights a week apart, as local day numbers.
    const EVENINGS: [i64; 3] = [20_600, 20_607, 20_614];

    /// Unix seconds for `hour` local time on local day `day`.
    fn local(day: i64, hour: i64) -> i64 {
        day * DAY + hour * 3_600 - i64::from(TZ)
    }

    /// A 100-minute film, with a vector when `vector` says what sets it apart
    /// from the rest of the library (the first dimension is what they share).
    fn film(db: &Db, name: &str, vector: Option<&[i8]>) -> i64 {
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
        db.conn()
            .execute(
                "UPDATE files SET duration_secs = 6000 WHERE title_id = ?1",
                [id],
            )
            .unwrap();
        if let Some(vector) = vector {
            db.upsert_embedding(&EmbeddingRecord {
                title_id: id,
                model_version: crate::embed::Encoder::Small.version(),
                source_hash: 0,
                vector: std::iter::once(80).chain(vector.iter().copied()).collect(),
                computed_at: 1,
            })
            .unwrap();
        }
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
                plays: 1,
                updated_at: at,
            },
            WatchAuthority::Owner,
        )
        .unwrap();
    }

    /// Two tastes watched in afternoons, which start no evening. The three
    /// evenings each start one new title, and only the third is one the taste
    /// could have named: the safe bet it leads with.
    fn library(path: &Path) {
        let db = Db::open(path).unwrap();
        for (name, v) in [
            ("Horror One", [100, 6, 0, 0]),
            ("Horror Two", [98, 0, 9, 0]),
            ("Horror Three", [99, 0, 0, 7]),
            ("Small Bear", [6, 100, 0, 0]),
            ("Small Fox", [0, 98, 9, 0]),
        ] {
            let id = film(&db, name, Some(&v));
            watched(&db, id, local(EVENINGS[0] - 120, 15));
        }
        film(&db, "Horror Unseen", Some(&[97, 0, 0, 0]));
        let quiet = film(&db, "Quiet", None);
        let loud = film(&db, "Loud", None);
        let target = film(&db, "Small Unseen", Some(&[0, 97, 0, 0]));
        watched(&db, quiet, local(EVENINGS[0], 20));
        watched(&db, loud, local(EVENINGS[1], 21));
        watched(&db, target, local(EVENINGS[2], 20));
        // what the viewer did about it afterwards is not what they knew that evening
        db.set_verdict(target, Some(Verdict::Loved), local(EVENINGS[2] + 1, 12))
            .unwrap();
        db.set_watchlisted(target, true, local(EVENINGS[2] + 2, 12))
            .unwrap();
        // nearer the leading taste than the target, but on the shelf only
        // after the third evening; the target's own file is replaced then too
        let newcomer = film(&db, "Small Newcomer", Some(&[3, 99, 5, 0]));
        for id in [newcomer, target] {
            db.conn()
                .execute(
                    "UPDATE files SET mtime = ?1 WHERE title_id = ?2",
                    [local(EVENINGS[2] + 3, 12), id],
                )
                .unwrap();
        }
    }

    #[test]
    fn replay_counts_the_evening_whose_new_title_was_the_safe_bet() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("index.sqlite");
        library(&path);
        let before = std::fs::read(&path).unwrap();
        let opts = ReplayOptions {
            evenings: 60,
            tz_offset_secs: TZ,
            at_minutes: 180,
            reembed: None,
        };
        let report = run(&path, &opts).unwrap();
        assert_eq!(report.evenings, 3, "{report:?}");
        assert_eq!(report.trio_hits, 1, "{report:?}");
        assert_eq!(report.more_hits, 1, "{report:?}");
        assert_eq!(report.taste_hits_20, 1, "{report:?}");
        assert_eq!(report.taste_hits_60, 1, "{report:?}");
        assert!((report.mrr_taste - 1.0 / 3.0).abs() < 1e-9, "{report:?}");
        assert_eq!(
            std::fs::read(&path).unwrap(),
            before,
            "the source was written to"
        );

        // the latest evenings are the ones replayed
        let last = run(
            &path,
            &ReplayOptions {
                evenings: 1,
                ..opts
            },
        )
        .unwrap();
        assert_eq!((last.evenings, last.trio_hits), (1, 1), "{last:?}");
    }

    /// A taste contested today was not contested on the evenings replayed.
    #[test]
    fn replay_ignores_today_s_contested_tastes() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("index.sqlite");
        library(&path);
        {
            let db = Db::open(&path).unwrap();
            for name in ["Small Bear", "Small Fox"] {
                let id: i64 = db
                    .conn()
                    .query_row("SELECT id FROM titles WHERE name = ?1", [name], |r| {
                        r.get(0)
                    })
                    .unwrap();
                db.mute_taste(id, local(EVENINGS[2] + 400, 12)).unwrap();
            }
        }
        let report = run(
            &path,
            &ReplayOptions {
                evenings: 60,
                tz_offset_secs: TZ,
                at_minutes: 180,
                reembed: None,
            },
        )
        .unwrap();
        assert_eq!(report.trio_hits, 1, "{report:?}");
    }

    #[test]
    fn replay_of_an_empty_history_is_an_empty_report() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("index.sqlite");
        drop(Db::open(&path).unwrap());
        let report = run(
            &path,
            &ReplayOptions {
                evenings: 60,
                tz_offset_secs: TZ,
                at_minutes: 180,
                reembed: None,
            },
        )
        .unwrap();
        assert_eq!(report, ReplayReport::default());
    }

    #[test]
    fn replay_with_an_encoder_nobody_installed_says_where_it_looked() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("index.sqlite");
        library(&path);
        let empty = tempfile::tempdir().unwrap();
        let err = run(
            &path,
            &ReplayOptions {
                evenings: 60,
                tz_offset_secs: TZ,
                at_minutes: 180,
                reembed: Some((Encoder::Base, empty.path().to_path_buf())),
            },
        )
        .unwrap_err()
        .to_string();
        assert!(err.contains("no base encoder"), "{err}");
        assert!(err.contains(&empty.path().display().to_string()), "{err}");
    }

    #[test]
    fn replay_re_embeds_the_copy_and_never_the_source() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("index.sqlite");
        library(&path);
        {
            let db = Db::open(&path).unwrap();
            db.conn()
                .execute_batch(
                    "INSERT INTO metadata (title_id, genres, cast_names, overview_fr, fetched_at, source)
                     SELECT id, 'science,fiction', '', 'dune desert epice', 1, 'tmdb' FROM titles",
                )
                .unwrap();
        }
        let before = std::fs::read(&path).unwrap();
        // the hand-written encoder, where the app would cache the base one
        let models = tempfile::tempdir().unwrap();
        let small = crate::embed::fixture::write_model(models.path());
        let base = Encoder::Base.source().artifact(models.path());
        for (from, to) in [
            (&small.weights, &base.weights),
            (&small.tokenizer, &base.tokenizer),
            (&small.config, &base.config),
        ] {
            std::fs::rename(from, to).unwrap();
        }
        let report = run(
            &path,
            &ReplayOptions {
                evenings: 60,
                tz_offset_secs: TZ,
                at_minutes: 180,
                reembed: Some((Encoder::Base, models.path().to_path_buf())),
            },
        )
        .unwrap();
        assert_eq!(report.evenings, 3, "{report:?}");
        assert_eq!(
            std::fs::read(&path).unwrap(),
            before,
            "the source was written to"
        );

        // what the evenings are replayed against: the encoder's vectors, as
        // wide as it writes them, and none of the five-wide ones on disk
        let copy = Db::open_read_only(&path).unwrap().copy_in_memory().unwrap();
        let copy = reembed(copy, Encoder::Base, models.path()).unwrap();
        assert_eq!(Encoder::chosen(&copy).unwrap(), Encoder::Base);
        let vectors = copy.vectors(Encoder::Base.version(), 100).unwrap();
        assert!(!vectors.is_empty());
        assert!(vectors
            .iter()
            .all(|v| v.vector.len() == crate::embed::fixture::DIMS));
    }
}
