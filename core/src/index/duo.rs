//! An evening of two: a deck of titles the guest says yes or no to, and what
//! both of them would watch.
//!
//! The ranking is Masthoff's average without misery: a title is worth the
//! lesser of the two tastes, and one either of them would sit through
//! unhappily is not offered at all, however much the other loves it.

use super::db::{Db, IndexError};
use super::queries::{row_to_title, TitleRow};
use super::taste::DISLIKE_PULL;
use super::tonight::{runtime_of, turn, Window, RUNTIME};
use super::MediaKind;
use crate::embed::pass::MAX_VECTORS;
use crate::embed::space::Space;
use crate::embed::Encoder;
use rusqlite::{params, OptionalExtension};
use std::collections::{HashMap, HashSet};
use std::sync::LazyLock;

/// Below this, for either of the two, a title is out: the guest's centred
/// cosine to their taste, or the owner's affinity (`title_taste`).
pub const VETO: f32 = 0.15;

/// How many titles the guest is asked about.
pub const DECK: usize = 12;

/// How many titles the proposal holds.
pub const DUO_PICKS: usize = 20;

/// How many of the deck are the owner's discoveries; the facet leaders come
/// first and the best connected titles fill the rest.
const DECK_DISCOVERIES: usize = 4;

/// How deep into the discovery band and the connection ranking the day's
/// deal reaches: twice the deck, so a day changes the titles and not only
/// their order.
const DECK_REACH: usize = 2 * DECK;

/// One title as a deck card, if it still has a file.
const DECK_ROW: &str = "SELECT t.id, t.kind, t.name, t.year,
    (SELECT COUNT(*) FROM files c WHERE c.title_id = t.id) AS file_count,
    (SELECT c.id FROM files c WHERE c.title_id = t.id ORDER BY c.quality DESC, c.id LIMIT 1) AS first_file_id
  FROM titles t
  WHERE t.id = ?1 AND EXISTS (SELECT 1 FROM files c WHERE c.title_id = t.id)";

/// One title as a proposal, with what one sitting of it costs, if nothing has
/// played it and the owner has said nothing about it.
static UNSEEN: LazyLock<String> = LazyLock::new(|| {
    format!(
        "SELECT t.id, t.kind, t.name, t.year,
    (SELECT COUNT(*) FROM files c WHERE c.title_id = t.id) AS file_count,
    (SELECT c.id FROM files c WHERE c.title_id = t.id ORDER BY c.quality DESC, c.id LIMIT 1) AS first_file_id,
    {RUNTIME} AS durations
  FROM titles t
  WHERE t.id = ?1
    AND EXISTS (SELECT 1 FROM files c WHERE c.title_id = t.id)
    AND NOT EXISTS (SELECT 1 FROM watch_state w JOIN files c ON c.id = w.file_id
                    WHERE c.title_id = t.id)
    AND NOT EXISTS (SELECT 1 FROM title_verdict v WHERE v.title_id = t.id)"
    )
});

/// Twelve titles for the guest to say yes or no to, dealt anew each day: the
/// owner's facet leaders, a few discoveries and the library's best connected
/// titles, none the guest already judged. Empty on a library the taste pass
/// has not reached.
pub fn deck(
    db: &Db,
    now: i64,
    tz_offset_secs: i32,
    guest: Option<i64>,
) -> Result<Vec<TitleRow>, IndexError> {
    let day = (now + i64::from(tz_offset_secs)).div_euclid(86_400);
    let judged: HashSet<i64> = match guest {
        Some(guest) => db
            .guest_verdicts(guest)?
            .into_iter()
            .map(|(id, _)| id)
            .collect(),
        None => HashSet::new(),
    };
    let dealt = |mut ids: Vec<i64>| {
        ids.retain(|id| !judged.contains(id));
        ids.truncate(DECK_REACH);
        ids.sort_by_key(|&id| turn(id, day));
        ids
    };
    let leaders: Vec<i64> = db.taste_facets()?.into_iter().map(|f| f.leader).collect();
    let discoveries = dealt(db.discovery_titles()?);
    let connected = dealt(db.best_connected(DECK_REACH as u32 + judged.len() as u32)?);

    let mut stmt = db.conn().prepare_cached(DECK_ROW)?;
    let mut out: Vec<TitleRow> = Vec::with_capacity(DECK);
    let mut taken: HashSet<i64> = HashSet::new();
    let mut discovered = 0;
    for (from_discovery, id) in leaders
        .into_iter()
        .filter(|id| !judged.contains(id))
        .map(|id| (false, id))
        .chain(discoveries.into_iter().map(|id| (true, id)))
        .chain(connected.into_iter().map(|id| (false, id)))
    {
        if out.len() == DECK {
            break;
        }
        if (from_discovery && discovered == DECK_DISCOVERIES) || !taken.insert(id) {
            continue;
        }
        if let Some(row) = stmt.query_row(params![id], row_to_title).optional()? {
            discovered += usize::from(from_discovery);
            out.push(row);
        }
    }
    out.sort_by_key(|row| turn(row.id, day));
    Ok(out)
}

/// What `rank` found: the proposal, and the guest's taste as each unseen
/// title's affinity to it past the veto, on the owner's 0 to 1 scale, which the caller stores for a named
/// guest so the trio can read it.
pub struct Ranked {
    pub titles: Vec<TitleRow>,
    pub taste: Vec<(i64, f32)>,
}

/// What both would watch, best first: unseen by the owner, unjudged by the
/// guest, past the veto for both, and short enough for what is left of the
/// session. The guest's votes are their stored ones plus `liked` and
/// `disliked`, which win. An owner the taste pass has no affinity for yet
/// leaves the guest to choose alone. Reads only.
///
/// The guest's taste is the centred mean of what they liked, and what they
/// turned down is taken off each title's score as the part the taste does
/// not already explain, the rule the owner's own row uses.
pub fn rank(
    db: &Db,
    now: i64,
    tz_offset_secs: i32,
    guest: Option<i64>,
    liked: &[i64],
    disliked: &[i64],
) -> Result<Ranked, IndexError> {
    let mut votes: HashMap<i64, bool> = match guest {
        Some(guest) => db.guest_verdicts(guest)?.into_iter().collect(),
        None => HashMap::new(),
    };
    votes.extend(liked.iter().map(|&id| (id, true)));
    votes.extend(disliked.iter().map(|&id| (id, false)));

    let version = Encoder::chosen(db)?.version();
    let vectors = db.vectors(version, MAX_VECTORS)?;
    let space = Space::of(&vectors);
    let dims = vectors.first().map_or(0, |v| v.vector.len());
    let mut centre = vec![0.0f32; dims];
    let mut liked: Vec<Vec<f32>> = Vec::new();
    let mut rejected: Vec<(usize, Vec<f32>)> = Vec::new();
    for (i, v) in vectors.iter().enumerate() {
        match votes.get(&v.title_id) {
            Some(_) if !space.placed(i) || v.vector.len() != dims => {}
            Some(true) => {
                let unit = space.unit(i, v);
                for (c, u) in centre.iter_mut().zip(&unit) {
                    *c += u;
                }
                liked.push(unit);
            }
            Some(false) => rejected.push((i, space.unit(i, v))),
            None => {}
        }
    }
    let norm = centre.iter().map(|c| c * c).sum::<f32>().sqrt();
    let mut cosines: Vec<(i64, f32)> = Vec::new();
    if norm > 0.0 {
        for c in centre.iter_mut() {
            *c /= norm;
        }
        let along = space.along_mean(&centre);
        let explained: Vec<f32> = rejected
            .iter()
            .map(|(_, unit)| unit.iter().zip(&centre).map(|(a, b)| a * b).sum())
            .collect();
        for (i, v) in vectors.iter().enumerate() {
            if votes.contains_key(&v.title_id) || !space.placed(i) || v.vector.len() != dims {
                continue;
            }
            let dot: f32 = v
                .vector
                .iter()
                .zip(&centre)
                .map(|(a, b)| f32::from(*a) * b)
                .sum();
            let cos = space.cos_to(i, dot, along);
            let mut shared = 0.0f32;
            for ((d, _), explained) in rejected.iter().zip(&explained) {
                let raw: i32 = v
                    .vector
                    .iter()
                    .zip(&vectors[*d].vector)
                    .map(|(a, b)| i32::from(*a) * i32::from(*b))
                    .sum();
                shared =
                    shared.max(DISLIKE_PULL * (space.cos(i, *d, raw as f32) - explained * cos));
            }
            cosines.push((v.title_id, cos - shared));
        }
        // the owner's affinity is placed between the library's background and
        // the facet's own members, and the guest's score is put on the same
        // scale, or the lower of the two would always be the guest's cosine
        let inner = liked
            .iter()
            .map(|u| u.iter().zip(&centre).map(|(a, b)| a * b).sum::<f32>())
            .sum::<f32>()
            / liked.len() as f32;
        let background = cosines.iter().map(|(_, s)| s).sum::<f32>() / cosines.len().max(1) as f32;
        let span = (inner - background).max(f32::EPSILON);
        for (_, score) in cosines.iter_mut() {
            *score = ((*score - background) / span).clamp(0.0, 1.0);
        }
        cosines.retain(|(_, score)| *score >= VETO);
    }
    let owner: HashMap<i64, f32> = db.title_affinities()?.into_iter().collect();
    let mut both: Vec<(i64, f32)> = cosines
        .iter()
        .filter_map(|&(id, cos)| {
            if owner.is_empty() {
                return Some((id, cos));
            }
            let affinity = owner.get(&id).copied().unwrap_or(0.0);
            (affinity >= VETO).then_some((id, cos.min(affinity)))
        })
        .collect();
    both.sort_by(|a, b| b.1.total_cmp(&a.1).then(a.0.cmp(&b.0)));

    let window = Window::of(db, now, tz_offset_secs, None)?;
    let mut stmt = db.conn().prepare_cached(&UNSEEN)?;
    let mut out = Vec::with_capacity(DUO_PICKS);
    for (id, _) in both {
        let found = stmt
            .query_row(params![id], |r| {
                let row = row_to_title(r)?;
                let episode = row.kind == MediaKind::Show;
                Ok((row, runtime_of(r.get(6)?, episode)))
            })
            .optional()?;
        let Some((row, runtime)) = found else {
            continue;
        };
        if window.as_ref().is_some_and(|w| !w.fits(runtime)) {
            continue;
        }
        out.push(row);
        if out.len() == DUO_PICKS {
            break;
        }
    }
    Ok(Ranked {
        titles: out,
        taste: cosines,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::index::db::{
        DiscoveryPick, EmbeddingRecord, FileMedia, FileRecord, TasteFacetMeta, TastePassOutput,
        TitleTasteRow, WatchAuthority, WatchRecord,
    };
    use crate::index::MediaKind;

    const WIDTH: usize = 40;
    const GUEST_AXIS: usize = 1;
    const OWNER_AXIS: usize = 5;
    /// A Thursday, 12:00: outside every session, so no window cuts anything.
    const NOON: i64 = 20_685 * 86_400 + 12 * 3_600;

    fn film(db: &Db, name: &str, axes: &[(usize, i8)]) -> i64 {
        let mut vector = vec![0i8; WIDTH];
        vector[0] = 80;
        for (axis, value) in axes {
            vector[*axis] = *value;
        }
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
        db.upsert_embedding(&EmbeddingRecord {
            title_id: id,
            model_version: crate::embed::Encoder::Small.version(),
            source_hash: 0,
            vector,
            computed_at: 1,
        })
        .unwrap();
        id
    }

    fn watched(db: &Db, title_id: i64) {
        let file_id = db
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
                updated_at: 1,
            },
            WatchAuthority::Report,
        )
        .unwrap();
    }

    struct Shelf {
        db: Db,
        /// What the guest liked: two titles on their axis.
        liked: [i64; 2],
        /// On the guest's axis and near the owner's taste.
        shared: i64,
        /// The owner's favourite, nowhere near the guest.
        adored: i64,
        /// On the guest's axis and nowhere near the owner.
        stranger: i64,
    }

    fn shelf() -> Shelf {
        let db = Db::open_in_memory().unwrap();
        let liked = [
            film(&db, "Liked One", &[(GUEST_AXIS, 100)]),
            film(&db, "Liked Two", &[(GUEST_AXIS, 100), (2, 10)]),
        ];
        let shared = film(&db, "Shared", &[(GUEST_AXIS, 90), (3, 20)]);
        let adored = film(&db, "Adored", &[(OWNER_AXIS, 100)]);
        let stranger = film(&db, "Stranger", &[(GUEST_AXIS, 90), (4, 20)]);
        let leader = film(&db, "Owner Leader", &[(OWNER_AXIS, 100), (6, 10)]);
        watched(&db, leader);
        for k in 7..WIDTH {
            film(&db, &format!("Single {k}"), &[(k, 100)]);
        }
        let taste = |title_id, affinity| TitleTasteRow {
            title_id,
            facet: 0,
            affinity,
            rejected: String::new(),
        };
        db.replace_taste(&TastePassOutput {
            facets: vec![TasteFacetMeta {
                facet: 0,
                weight: 1.0,
                leader,
                cos_to_top: 1.0,
            }],
            title_taste: vec![taste(adored, 0.95), taste(shared, 0.5)],
            discovery: vec![DiscoveryPick {
                title_id: stranger,
                closeness: 0.5,
            }],
            ..Default::default()
        })
        .unwrap();
        Shelf {
            db,
            liked,
            shared,
            adored,
            stranger,
        }
    }

    fn ids(rows: Vec<TitleRow>) -> Vec<i64> {
        rows.into_iter().map(|r| r.id).collect()
    }

    fn ranked(r: Ranked) -> Vec<i64> {
        ids(r.titles)
    }

    #[test]
    fn a_title_the_owner_adores_is_dropped_when_the_guest_vetoes_it() {
        let s = shelf();
        let ranked = ranked(rank(&s.db, NOON, 0, None, &s.liked, &[]).unwrap());
        assert_eq!(ranked.first(), Some(&s.shared), "{ranked:?}");
        assert!(!ranked.contains(&s.adored), "{ranked:?}");
        // the other way round too: the guest's taste alone is not enough
        assert!(!ranked.contains(&s.stranger), "{ranked:?}");
        // never a title the guest just judged
        assert!(!ranked.contains(&s.liked[0]), "{ranked:?}");
    }

    #[test]
    fn among_titles_the_guest_likes_alike_the_owner_s_stronger_affinity_leads() {
        let db = Db::open_in_memory().unwrap();
        // two likes far apart: the guest's taste is broad, and its centre
        // sits closer to a title that has both than to either of them
        let liked = [
            film(&db, "Liked One", &[(GUEST_AXIS, 100)]),
            film(&db, "Liked Two", &[(2, 100)]),
        ];
        let nearer = film(&db, "Nearer", &[(GUEST_AXIS, 100), (2, 100)]);
        let owners = film(&db, "Owner's", &[(GUEST_AXIS, 100), (2, 100), (3, 40)]);
        for k in 7..WIDTH {
            film(&db, &format!("Single {k}"), &[(k, 100)]);
        }
        let taste = |title_id, affinity| TitleTasteRow {
            title_id,
            facet: 0,
            affinity,
            rejected: String::new(),
        };
        db.replace_taste(&TastePassOutput {
            title_taste: vec![taste(nearer, 0.97), taste(owners, 1.0)],
            ..Default::default()
        })
        .unwrap();
        // both are as close to the guest's taste as anything they liked: a
        // hair nearer is no reason to pass over what the owner would rather watch
        let ranked = ranked(rank(&db, NOON, 0, None, &liked, &[]).unwrap());
        assert_eq!(ranked, vec![owners, nearer]);
    }

    #[test]
    fn an_owner_with_no_taste_yet_leaves_the_guest_to_choose_alone() {
        let s = shelf();
        s.db.replace_taste(&TastePassOutput::default()).unwrap();
        let ranked = ranked(rank(&s.db, NOON, 0, None, &s.liked, &[]).unwrap());
        assert!(
            ranked.contains(&s.shared) && ranked.contains(&s.stranger),
            "{ranked:?}"
        );
        // the guest's veto still holds
        assert!(!ranked.contains(&s.adored), "{ranked:?}");
    }

    #[test]
    fn a_guest_who_liked_nothing_or_a_library_without_vectors_ranks_nothing() {
        let s = shelf();
        assert!(rank(&s.db, NOON, 0, None, &[], &[s.shared])
            .unwrap()
            .titles
            .is_empty());
        let empty = Db::open_in_memory().unwrap();
        assert!(rank(&empty, NOON, 0, None, &[1, 2], &[])
            .unwrap()
            .titles
            .is_empty());
        assert!(deck(&empty, NOON, 0, None).unwrap().is_empty());
    }

    #[test]
    fn a_stored_guest_s_votes_rank_without_being_repeated_and_leave_their_taste_behind() {
        let s = shelf();
        let guest = s.db.add_guest("Sam", NOON).unwrap();
        for id in s.liked {
            s.db.set_guest_verdict(guest, id, true, NOON).unwrap();
        }
        let answer = rank(&s.db, NOON, 0, Some(guest), &[], &[]).unwrap();
        let taste: Vec<i64> = answer.taste.iter().map(|(id, _)| *id).collect();
        assert_eq!(ranked(answer).first(), Some(&s.shared));
        assert!(
            taste.contains(&s.shared) && taste.contains(&s.stranger),
            "{taste:?}"
        );
        assert!(!taste.contains(&s.adored), "{taste:?}");
        assert!(!taste.contains(&s.liked[0]), "{taste:?}");
    }

    #[test]
    fn a_title_the_guest_turned_down_pulls_its_twin_under_the_veto() {
        let s = shelf();
        // two titles the guest's taste only half explains: what they share
        // beyond it is what a rejection of one says about the other
        let odd = film(&s.db, "Odd", &[(GUEST_AXIS, 60), (3, 100)]);
        let twin = film(&s.db, "Odd Twin", &[(GUEST_AXIS, 60), (3, 100), (4, 5)]);
        let taste = |title_id| TitleTasteRow {
            title_id,
            facet: 0,
            affinity: 0.5,
            rejected: String::new(),
        };
        s.db.replace_taste(&TastePassOutput {
            title_taste: vec![taste(s.shared), taste(odd), taste(twin)],
            ..Default::default()
        })
        .unwrap();
        let before = ranked(rank(&s.db, NOON, 0, None, &s.liked, &[]).unwrap());
        assert!(before.contains(&twin), "{before:?}");
        let after = ranked(rank(&s.db, NOON, 0, None, &s.liked, &[odd]).unwrap());
        assert!(!after.contains(&twin), "{after:?}");
        // what is the taste itself loses nothing to it
        assert!(after.contains(&s.shared), "{after:?}");
    }

    #[test]
    fn the_deck_mixes_leaders_discoveries_and_connected_titles_and_skips_what_the_guest_judged() {
        let s = shelf();
        // the singles are each other's neighbours, some more than others
        let singles: Vec<i64> =
            s.db.conn()
                .prepare("SELECT id FROM titles WHERE name LIKE 'Single %' ORDER BY id")
                .unwrap()
                .query_map([], |r| r.get(0))
                .unwrap()
                .collect::<Result<_, _>>()
                .unwrap();
        let links: Vec<(i64, Vec<(i64, i32)>)> = singles
            .iter()
            .map(|&id| {
                (
                    id,
                    singles
                        .iter()
                        .take(14)
                        .filter(|&&o| o != id)
                        .map(|&o| (o, 5000))
                        .collect(),
                )
            })
            .collect();
        s.db.upsert_semantic(&links, crate::embed::Encoder::Small.version(), 1)
            .unwrap();
        let guest = s.db.add_guest("Sam", NOON).unwrap();
        s.db.set_guest_verdict(guest, singles[0], true, NOON)
            .unwrap();

        let dealt = ids(deck(&s.db, NOON, 0, Some(guest)).unwrap());
        assert_eq!(dealt.len(), DECK, "{dealt:?}");
        let leader: i64 =
            s.db.conn()
                .query_row("SELECT leader FROM taste_facet", [], |r| r.get(0))
                .unwrap();
        assert!(dealt.contains(&leader), "{dealt:?}");
        assert!(dealt.contains(&s.stranger), "{dealt:?}");
        assert!(!dealt.contains(&singles[0]), "{dealt:?}");
        let mut unique = dealt.clone();
        unique.sort_unstable();
        unique.dedup();
        assert_eq!(unique.len(), DECK);
        // the same day deals the same deck, another day another order
        assert_eq!(ids(deck(&s.db, NOON, 0, Some(guest)).unwrap()), dealt);
        assert_ne!(
            ids(deck(&s.db, NOON + 86_400, 0, Some(guest)).unwrap()),
            dealt
        );
    }

    #[test]
    fn removing_a_guest_takes_their_votes_and_their_taste() {
        let s = shelf();
        let guest = s.db.add_guest("Sam", NOON).unwrap();
        assert_eq!(s.db.add_guest("Sam", NOON + 1).unwrap(), guest);
        s.db.set_guest_verdict(guest, s.liked[0], true, NOON)
            .unwrap();
        s.db.replace_guest_taste(guest, &[(s.shared, 0.5)]).unwrap();
        s.db.set_evening_state(
            1,
            &crate::index::db::EveningAnswers {
                guest_id: Some(guest),
                ..Default::default()
            },
        )
        .unwrap();
        s.db.remove_guest(guest).unwrap();
        let count = |table: &str| -> i64 {
            s.db.conn()
                .query_row(&format!("SELECT COUNT(*) FROM {table}"), [], |r| r.get(0))
                .unwrap()
        };
        assert_eq!(count("guest"), 0);
        assert_eq!(count("guest_verdict"), 0);
        assert_eq!(count("guest_taste"), 0);
        assert_eq!(s.db.evening_state(1).unwrap().guest_id, None);
        // a title that leaves the library takes a guest's vote on it
        let other = s.db.add_guest("Alex", NOON).unwrap();
        s.db.set_guest_verdict(other, s.shared, false, NOON)
            .unwrap();
        s.db.conn()
            .execute("DELETE FROM files WHERE title_id = ?1", [s.shared])
            .unwrap();
        s.db.conn()
            .execute("DELETE FROM titles WHERE id = ?1", [s.shared])
            .unwrap();
        assert!(s.db.guest_verdicts(other).unwrap().is_empty());
    }
}
