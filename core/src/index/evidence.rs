//! The one sentence worth saying about a title, to the viewer looking at it.
//!
//! A row carries its own reason in its name, but a title is in several rows,
//! and the hero speaks for the title alone. So each title gets the single
//! strongest piece of evidence the index holds about this viewer and it, in
//! a fixed order of strength: what they have started, who they follow, how
//! close it is to their taste, and only then what anybody else thinks.

use super::db::{Db, IndexError};
use rusqlite::{params, OptionalExtension};

/// Why this title, for this viewer. The app writes the sentence.
#[derive(Debug, Clone, PartialEq)]
pub enum Evidence {
    /// Part of a collection the viewer has already watched `done` titles of.
    Saga { name: String, done: u32 },
    /// Directed by someone the viewer has watched `seen` films of.
    Director { name: String, seen: u32 },
    /// Claimed by a taste `count` of whose titles were finished this month.
    Streak { leader: String, count: u32 },
    /// Scored or written by someone who also signed `loved`, a title the
    /// viewer gave a thumb up or loved.
    Crew {
        role: CrewRole,
        name: String,
        loved: String,
    },
    /// Close to one of the viewer's tastes, named after its leader.
    Vein { leader: String },
    /// With an actor the viewer has watched in `seen` titles.
    Actor { name: String, seen: u32 },
    /// Arrived in the library within the last fortnight.
    NewArrival,
    /// Scored this well, out of ten, by whoever the metadata names.
    Acclaimed { score: f32 },
    /// Already watched: `plays` times, the last at `last_watched_at`.
    Rewatch { plays: u32, last_watched_at: i64 },
}

/// Which credit a `Crew` piece of evidence rests on.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CrewRole {
    Composer,
    Writer,
}

/// How close to a taste a title has to sit before the kinship leads its
/// evidence. The hero's band calls this "dans la veine": below it the taste
/// is a weaker claim than an actor the viewer keeps returning to.
const STRONG_VEIN: f32 = 0.6;

/// The same floors the rows use: two films of a director is a return, three
/// of an actor is a habit (see `rows::DIRECTOR_FLOOR`, `rows::ACTOR_FLOOR`).
const DIRECTOR_SEEN: u32 = 2;
const ACTOR_SEEN: u32 = 3;

/// A run is three titles of one taste finished within a month: two is a
/// coincidence of the calendar, three is the viewer going back for more.
const STREAK: u32 = 3;
const STREAK_SECS: i64 = 30 * 86_400;

/// How many titles of one facet were finished since a moment.
const FACET_FINISHED: &str = "SELECT COUNT(DISTINCT wf.title_id)
  FROM watched_facet wf
  CROSS JOIN files f ON f.title_id = wf.title_id
  CROSS JOIN watch_state w ON w.file_id = f.id
  WHERE wf.facet = ?1 AND w.watched = 1 AND w.updated_at >= ?2";

/// A composer or writer of this title who also signed a title the viewer
/// judged well: composers before writers, loved before liked, then the most
/// recent opinion.
const CREW_LOVED: &str = "SELECT g.kind, g.value, t.name
  FROM title_tags g INDEXED BY idx_title_tags_title
  CROSS JOIN title_tags o ON o.kind = g.kind AND o.value = g.value AND o.title_id <> g.title_id
  CROSS JOIN title_verdict v ON v.title_id = o.title_id
  CROSS JOIN titles t ON t.id = o.title_id
  WHERE g.title_id = ?1 AND g.kind IN ('composer', 'writer') AND v.verdict > 0
  ORDER BY g.kind = 'writer', v.verdict DESC, v.stated_at DESC, o.title_id
  LIMIT 1";

/// A fortnight: long enough to still be news on the second weekend.
const NEW_SECS: i64 = 14 * 86_400;

/// What a score has to reach to be worth saying out loud.
const ACCLAIMED: f64 = 8.0;

/// For one tag kind, the value of this title's that the viewer has watched
/// the most other titles of, and how many. Only titles watched through count.
const MOST_WATCHED_TAG: &str = "SELECT g.value,
    (SELECT COUNT(DISTINCT o.title_id) FROM title_tags o
      WHERE o.kind = g.kind AND o.value = g.value AND o.title_id <> g.title_id
        AND EXISTS (SELECT 1 FROM files f JOIN watch_state w ON w.file_id = f.id
                    WHERE f.title_id = o.title_id AND w.watched = 1)) AS seen
  FROM title_tags g INDEXED BY idx_title_tags_title
  WHERE g.title_id = ?1 AND g.kind = ?2
  ORDER BY seen DESC, g.value
  LIMIT 1";

pub fn title_evidence(db: &Db, title_id: i64, now: i64) -> Result<Option<Evidence>, IndexError> {
    let conn = db.conn();
    let watched: Option<(u32, i64)> = conn
        .prepare_cached(
            "SELECT MAX(w.plays), MAX(w.updated_at) FROM files f
               JOIN watch_state w ON w.file_id = f.id
              WHERE f.title_id = ?1 AND w.watched = 1
             HAVING COUNT(*) > 0",
        )?
        .query_row(params![title_id], |r| Ok((r.get(0)?, r.get(1)?)))
        .ok();
    if let Some((plays, last_watched_at)) = watched {
        return Ok(Some(Evidence::Rewatch {
            plays: plays.max(1),
            last_watched_at,
        }));
    }

    let most_watched = |kind: &str| -> Result<Option<(String, u32)>, IndexError> {
        let mut stmt = conn.prepare_cached(MOST_WATCHED_TAG)?;
        let mut rows = stmt.query(params![title_id, kind])?;
        Ok(match rows.next()? {
            Some(r) => Some((r.get(0)?, r.get(1)?)),
            None => None,
        })
    };
    if let Some((name, done)) = most_watched("collection")? {
        if done > 0 {
            return Ok(Some(Evidence::Saga {
                name: super::rows::saga_name(&name),
                done,
            }));
        }
    }
    if let Some((name, seen)) = most_watched("director")? {
        if seen >= DIRECTOR_SEEN {
            return Ok(Some(Evidence::Director { name, seen }));
        }
    }
    let taste = db.title_taste(title_id)?;
    // the facet's leader, read once for both the run and the vein
    let mut leader = None;
    if let Some(row) = &taste {
        if let Some(facet) = db
            .taste_facets()?
            .into_iter()
            .find(|f| f.facet == row.facet)
        {
            leader = db.title_key(facet.leader)?.map(|(_, name, _)| name);
        }
        if let Some(leader) = &leader {
            let count: u32 = conn
                .prepare_cached(FACET_FINISHED)?
                .query_row(params![row.facet, now - STREAK_SECS], |r| r.get(0))?;
            if count >= STREAK {
                return Ok(Some(Evidence::Streak {
                    leader: leader.clone(),
                    count,
                }));
            }
        }
    }
    let crew: Option<(String, String, String)> = conn
        .prepare_cached(CREW_LOVED)?
        .query_row(params![title_id], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)))
        .optional()?;
    if let Some((kind, name, loved)) = crew {
        let role = if kind == "composer" {
            CrewRole::Composer
        } else {
            CrewRole::Writer
        };
        return Ok(Some(Evidence::Crew { role, name, loved }));
    }
    if let (Some(row), Some(leader)) = (&taste, leader) {
        if row.affinity >= STRONG_VEIN {
            return Ok(Some(Evidence::Vein { leader }));
        }
    }
    if let Some((name, seen)) = most_watched("cast")? {
        if seen >= ACTOR_SEEN {
            return Ok(Some(Evidence::Actor { name, seen }));
        }
    }
    let (added_at, score): (i64, Option<f64>) = conn
        .prepare_cached(
            "SELECT t.added_at,
                    (SELECT CASE WHEN m.audience_source <> '' THEN m.audience_rating
                                 WHEN m.critic_source <> '' THEN m.critic_rating END
                       FROM metadata m WHERE m.title_id = t.id)
               FROM titles t WHERE t.id = ?1",
        )?
        .query_row(params![title_id], |r| Ok((r.get(0)?, r.get(1)?)))?;
    if added_at > 0 && now - added_at <= NEW_SECS {
        return Ok(Some(Evidence::NewArrival));
    }
    if let Some(score) = score.filter(|s| *s >= ACCLAIMED) {
        return Ok(Some(Evidence::Acclaimed {
            score: score as f32,
        }));
    }
    Ok(None)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::index::db::{FileMedia, FileRecord, WatchAuthority, WatchRecord};
    use crate::index::{MediaKind, Verdict};

    const DAY: i64 = 86_400;
    const NOW: i64 = 20_000 * DAY;

    fn film(db: &Db, name: &str) -> i64 {
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
    }

    fn tag(db: &Db, title_id: i64, kind: &str, value: &str) {
        db.conn()
            .execute(
                "INSERT INTO title_tags (title_id, kind, value) VALUES (?1, ?2, ?3)",
                params![title_id, kind, value],
            )
            .unwrap();
    }

    fn watched(db: &Db, title_id: i64, plays: u32, at: i64) {
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
                position_secs: 0.0,
                duration_secs: 6000.0,
                watched: true,
                plays,
                updated_at: at,
            },
            WatchAuthority::Owner,
        )
        .unwrap();
    }

    #[test]
    fn a_director_followed_outranks_an_actor_and_a_score() {
        let db = Db::open_in_memory().unwrap();
        let unseen = film(&db, "Unseen");
        tag(&db, unseen, "director", "Villeneuve");
        tag(&db, unseen, "cast", "Oscar Isaac");
        for n in 0..3 {
            let seen = film(&db, &format!("Seen {n}"));
            tag(&db, seen, "director", "Villeneuve");
            tag(&db, seen, "cast", "Oscar Isaac");
            watched(&db, seen, 1, NOW - DAY);
        }
        assert_eq!(
            title_evidence(&db, unseen, NOW).unwrap(),
            Some(Evidence::Director {
                name: "Villeneuve".into(),
                seen: 3
            })
        );
    }

    #[test]
    fn one_film_of_a_director_is_not_a_return_and_the_actor_speaks_instead() {
        let db = Db::open_in_memory().unwrap();
        let unseen = film(&db, "Unseen");
        tag(&db, unseen, "director", "Once");
        tag(&db, unseen, "cast", "Habit");
        let once = film(&db, "Once");
        tag(&db, once, "director", "Once");
        watched(&db, once, 1, NOW - DAY);
        for n in 0..3 {
            let seen = film(&db, &format!("Habit {n}"));
            tag(&db, seen, "cast", "Habit");
            watched(&db, seen, 1, NOW - DAY);
        }
        assert_eq!(
            title_evidence(&db, unseen, NOW).unwrap(),
            Some(Evidence::Actor {
                name: "Habit".into(),
                seen: 3
            })
        );
    }

    #[test]
    fn a_title_already_watched_says_how_often_and_when() {
        let db = Db::open_in_memory().unwrap();
        let heat = film(&db, "Heat");
        watched(&db, heat, 3, NOW - 400 * DAY);
        assert_eq!(
            title_evidence(&db, heat, NOW).unwrap(),
            Some(Evidence::Rewatch {
                plays: 3,
                last_watched_at: NOW - 400 * DAY
            })
        );
    }

    #[test]
    fn with_nothing_personal_to_say_the_shelf_and_the_score_speak() {
        let db = Db::open_in_memory().unwrap();
        let fresh = film(&db, "Fresh");
        db.conn()
            .execute(
                "UPDATE titles SET added_at = ?1 WHERE id = ?2",
                params![NOW - DAY, fresh],
            )
            .unwrap();
        assert_eq!(
            title_evidence(&db, fresh, NOW).unwrap(),
            Some(Evidence::NewArrival)
        );
        let praised = film(&db, "Praised");
        db.conn()
            .execute(
                "INSERT INTO metadata (title_id, source, fetched_at, audience_rating, audience_source)
                 VALUES (?1, 'tmdb', 0, 8.4, 'themoviedb')",
                params![praised],
            )
            .unwrap();
        db.conn()
            .execute(
                "UPDATE titles SET added_at = ?1 WHERE id = ?2",
                params![NOW - 90 * DAY, praised],
            )
            .unwrap();
        assert_eq!(
            title_evidence(&db, praised, NOW).unwrap(),
            Some(Evidence::Acclaimed { score: 8.4 })
        );
        let plain = film(&db, "Plain");
        db.conn()
            .execute(
                "UPDATE titles SET added_at = ?1 WHERE id = ?2",
                params![NOW - 90 * DAY, plain],
            )
            .unwrap();
        assert_eq!(title_evidence(&db, plain, NOW).unwrap(), None);
    }

    /// One facet led by "Leader", claiming `unseen`, and `finished` films of
    /// it watched through within the month.
    fn facet_with_run(db: &Db, finished: usize) -> i64 {
        let leader = film(db, "Leader");
        db.conn()
            .execute(
                "INSERT INTO taste_facet (facet, weight, leader, cos_to_top) VALUES (0, 1.0, ?1, 1.0)",
                params![leader],
            )
            .unwrap();
        let unseen = film(db, "Unseen");
        db.conn()
            .execute(
                "INSERT INTO title_taste (title_id, facet, affinity, rejected) VALUES (?1, 0, 0.3, '')",
                params![unseen],
            )
            .unwrap();
        for n in 0..finished {
            let seen = film(db, &format!("Run {n}"));
            watched(db, seen, 1, NOW - (n as i64 + 1) * DAY);
            db.conn()
                .execute(
                    "INSERT INTO watched_facet (title_id, facet) VALUES (?1, 0)",
                    params![seen],
                )
                .unwrap();
        }
        // an old one of the same taste, outside the month: never part of a run
        let old = film(db, "Old");
        watched(db, old, 1, NOW - 40 * DAY);
        db.conn()
            .execute(
                "INSERT INTO watched_facet (title_id, facet) VALUES (?1, 0)",
                params![old],
            )
            .unwrap();
        unseen
    }

    #[test]
    fn three_titles_of_one_taste_finished_this_month_are_a_streak() {
        let db = Db::open_in_memory().unwrap();
        let unseen = facet_with_run(&db, 3);
        assert_eq!(
            title_evidence(&db, unseen, NOW).unwrap(),
            Some(Evidence::Streak {
                leader: "Leader".into(),
                count: 3
            })
        );
    }

    #[test]
    fn two_titles_of_one_taste_this_month_are_not_a_streak() {
        let db = Db::open_in_memory().unwrap();
        let unseen = facet_with_run(&db, 2);
        assert_eq!(title_evidence(&db, unseen, NOW).unwrap(), None);
    }

    #[test]
    fn the_composer_of_a_loved_film_is_evidence_and_a_merely_seen_one_is_not() {
        let db = Db::open_in_memory().unwrap();
        let unseen = film(&db, "Unseen");
        tag(&db, unseen, "composer", "Zimmer");
        tag(&db, unseen, "writer", "Nolan");
        let seen = film(&db, "Seen");
        tag(&db, seen, "composer", "Zimmer");
        watched(&db, seen, 1, NOW - DAY);
        assert_eq!(title_evidence(&db, unseen, NOW).unwrap(), None);

        let liked = film(&db, "Memento");
        tag(&db, liked, "writer", "Nolan");
        db.set_verdict(liked, Some(Verdict::Up), NOW - DAY).unwrap();
        let loved = film(&db, "Interstellar");
        tag(&db, loved, "composer", "Zimmer");
        db.set_verdict(loved, Some(Verdict::Loved), NOW - DAY)
            .unwrap();
        assert_eq!(
            title_evidence(&db, unseen, NOW).unwrap(),
            Some(Evidence::Crew {
                role: CrewRole::Composer,
                name: "Zimmer".into(),
                loved: "Interstellar".into()
            })
        );
    }
}
