//! The taste in words: for each facet, what sets its titles apart from the
//! library around them. The core names the genres, the keywords, the
//! directors, the decades and the tones; the screen writes the sentence.

use super::db::{Db, IndexError};
use std::collections::HashMap;

/// How many of each a facet is described by.
pub const PROFILE_GENRES: usize = 3;
pub const PROFILE_KEYWORDS: usize = 3;
pub const PROFILE_DIRECTORS: usize = 2;
pub const PROFILE_TONES: usize = 2;
pub const AVOID_GENRES: usize = 3;

/// How many titles of a facet must carry a value before it describes the
/// facet: one title is an anecdote, however rare its genre is elsewhere.
const MIN_CARRIERS: usize = 2;

/// One facet, described against the library.
#[derive(Debug, Clone, PartialEq)]
pub struct ProfileFacet {
    pub leader_id: i64,
    pub leader: String,
    /// The facet's part of the whole taste, nought to one.
    pub share: f32,
    pub genres: Vec<String>,
    pub keywords: Vec<String>,
    pub directors: Vec<String>,
    /// The first years of the decades the middle half of its titles span:
    /// (1960, 1970) for the sixties and seventies. (0, 0) when none is dated.
    pub decades: (u16, u16),
    /// Keys of `taste::MOODS`.
    pub tones: Vec<String>,
}

#[derive(Debug, Clone, Default, PartialEq)]
pub struct TasteProfile {
    pub facets: Vec<ProfileFacet>,
    /// The genres the titles the viewer turned down share more than the
    /// library does.
    pub avoid: Vec<String>,
}

/// Each facet of the taste, strongest first, described by what its titles
/// (the watched ones the facet claims) carry more often than the library's
/// titles do: the values with the highest ratio of the two shares, among
/// those at least `MIN_CARRIERS` of its titles carry. No facet, no profile.
pub fn taste_profile(db: &Db) -> Result<TasteProfile, IndexError> {
    let facets = db.taste_facets()?;
    let total: usize =
        db.conn()
            .query_row("SELECT COUNT(*) FROM titles", [], |r| r.get::<_, i64>(0))? as usize;
    let genres = values(
        db,
        "SELECT title_id, value FROM title_tags WHERE kind = 'genre'",
    )?;
    let avoid = {
        let mut stmt = db
            .conn()
            .prepare_cached("SELECT title_id FROM title_verdict WHERE verdict < 0")?;
        let rejected = stmt
            .query_map([], |r| r.get(0))?
            .collect::<Result<Vec<i64>, _>>()?;
        over(&rejected, &genres, &counts(&genres), total, AVOID_GENRES)
    };
    if facets.is_empty() {
        return Ok(TasteProfile {
            facets: Vec::new(),
            avoid,
        });
    }
    let directors = values(
        db,
        "SELECT title_id, value FROM title_tags WHERE kind = 'director'",
    )?;
    let tones = values(db, "SELECT title_id, mood FROM title_tone")?;
    let mut keywords: HashMap<i64, Vec<String>> = HashMap::new();
    {
        let mut stmt = db
            .conn()
            .prepare_cached("SELECT title_id, keywords FROM metadata WHERE keywords <> ''")?;
        let mut rows = stmt.query([])?;
        while let Some(r) = rows.next()? {
            let words: String = r.get(1)?;
            keywords.insert(
                r.get(0)?,
                words
                    .split(',')
                    .map(str::trim)
                    .filter(|w| !w.is_empty())
                    .map(String::from)
                    .collect(),
            );
        }
    }
    let mut members: HashMap<u32, Vec<(i64, u16)>> = HashMap::new();
    {
        let mut stmt = db.conn().prepare_cached(
            "SELECT wf.facet, wf.title_id, t.year FROM watched_facet wf
             CROSS JOIN titles t ON t.id = wf.title_id",
        )?;
        let mut rows = stmt.query([])?;
        while let Some(r) = rows.next()? {
            members
                .entry(r.get(0)?)
                .or_default()
                .push((r.get(1)?, r.get(2)?));
        }
    }
    let library = [&genres, &keywords, &directors, &tones].map(counts);
    let weight: f32 = facets.iter().map(|f| f.weight).sum();
    let mut out = Vec::with_capacity(facets.len());
    for facet in facets {
        let Some((_, leader, _)) = db.title_key(facet.leader)? else {
            continue;
        };
        let own = members.remove(&facet.facet).unwrap_or_default();
        let ids: Vec<i64> = own.iter().map(|(id, _)| *id).collect();
        let mut years: Vec<u16> = own.iter().map(|(_, y)| *y).filter(|y| *y > 0).collect();
        years.sort_unstable();
        let decades = match years.len() {
            0 => (0, 0),
            n => (
                years[(n - 1) / 4] / 10 * 10,
                years[3 * (n - 1) / 4] / 10 * 10,
            ),
        };
        out.push(ProfileFacet {
            leader_id: facet.leader,
            leader,
            share: if weight > 0.0 {
                facet.weight / weight
            } else {
                0.0
            },
            genres: over(&ids, &genres, &library[0], total, PROFILE_GENRES),
            keywords: over(&ids, &keywords, &library[1], total, PROFILE_KEYWORDS),
            directors: over(&ids, &directors, &library[2], total, PROFILE_DIRECTORS),
            decades,
            tones: over(&ids, &tones, &library[3], total, PROFILE_TONES),
        });
    }
    Ok(TasteProfile { facets: out, avoid })
}

/// Every title's values off a two-column query.
fn values(db: &Db, sql: &str) -> Result<HashMap<i64, Vec<String>>, IndexError> {
    let mut out: HashMap<i64, Vec<String>> = HashMap::new();
    let mut stmt = db.conn().prepare_cached(sql)?;
    let mut rows = stmt.query([])?;
    while let Some(r) = rows.next()? {
        out.entry(r.get(0)?).or_default().push(r.get(1)?);
    }
    Ok(out)
}

/// How many titles carry each value.
fn counts(by_title: &HashMap<i64, Vec<String>>) -> HashMap<&str, usize> {
    let mut out: HashMap<&str, usize> = HashMap::new();
    for values in by_title.values() {
        for v in values {
            *out.entry(v.as_str()).or_insert(0) += 1;
        }
    }
    out
}

/// The `n` values `ids` carry most over their share of the library's
/// `total` titles (`library` counts them), among those carried more there
/// than in the library and by at least `MIN_CARRIERS` of `ids` (all of
/// them, when fewer).
fn over(
    ids: &[i64],
    by_title: &HashMap<i64, Vec<String>>,
    library: &HashMap<&str, usize>,
    total: usize,
    n: usize,
) -> Vec<String> {
    if ids.is_empty() || total == 0 {
        return Vec::new();
    }
    let mut carried: HashMap<&str, usize> = HashMap::new();
    for id in ids {
        for v in by_title.get(id).into_iter().flatten() {
            *carried.entry(v.as_str()).or_insert(0) += 1;
        }
    }
    let least = MIN_CARRIERS.min(ids.len());
    let mut ranked: Vec<(&str, f64, usize)> = carried
        .into_iter()
        .filter(|(_, count)| *count >= least)
        .map(|(v, count)| {
            let here = count as f64 / ids.len() as f64;
            let there = library.get(v).copied().unwrap_or(count) as f64 / total as f64;
            (v, here / there, count)
        })
        .filter(|(_, ratio, _)| *ratio > 1.0)
        .collect();
    ranked.sort_by(|a, b| b.1.total_cmp(&a.1).then(b.2.cmp(&a.2)).then(a.0.cmp(b.0)));
    ranked
        .into_iter()
        .take(n)
        .map(|(v, _, _)| v.to_string())
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::index::db::{TasteFacetMeta, TastePassOutput};
    use crate::index::{MediaKind, Verdict};

    fn title(db: &Db, name: &str, year: u16, genres: &[&str]) -> i64 {
        let id = db.upsert_title(MediaKind::Movie, name, Some(year)).unwrap();
        tag(db, id, "genre", genres);
        id
    }

    fn tag(db: &Db, id: i64, kind: &str, values: &[&str]) {
        for value in values {
            db.conn()
                .execute(
                    "INSERT INTO title_tags (title_id, kind, value) VALUES (?1, ?2, ?3)",
                    rusqlite::params![id, kind, value],
                )
                .unwrap();
        }
    }

    fn keywords(db: &Db, id: i64, words: &str) {
        db.conn()
            .execute(
                "INSERT INTO metadata (title_id, source, fetched_at, keywords) VALUES (?1, 'tmdb', 0, ?2)",
                rusqlite::params![id, words],
            )
            .unwrap();
    }

    #[test]
    fn a_facet_of_westerns_is_described_by_the_western_first() {
        let db = Db::open_in_memory().unwrap();
        let westerns = [
            title(
                &db,
                "Once Upon a Time in the West",
                1968,
                &["Western", "Drama"],
            ),
            title(&db, "The Good, the Bad and the Ugly", 1966, &["Western"]),
            title(&db, "Rio Bravo", 1959, &["Western", "Drama"]),
            title(&db, "Unforgiven", 1992, &["Western"]),
        ];
        tag(&db, westerns[0], "director", &["Sergio Leone"]);
        tag(&db, westerns[1], "director", &["Sergio Leone"]);
        tag(&db, westerns[2], "director", &["Howard Hawks"]);
        keywords(&db, westerns[0], "duel, revenge");
        keywords(&db, westerns[1], "duel, gold");
        keywords(&db, westerns[3], "revenge");
        let comedies = [
            title(&db, "Some Like It Hot", 1959, &["Comedy"]),
            title(&db, "Airplane!", 1980, &["Comedy"]),
        ];
        for k in 0..10 {
            let id = title(&db, &format!("Drama {k}"), 2000, &["Drama"]);
            keywords(&db, id, "family");
        }
        title(&db, "Another Western", 2010, &["Western"]);
        let horror = [
            title(&db, "Scream", 1996, &["Horror"]),
            title(&db, "Saw", 2004, &["Horror", "Thriller"]),
        ];
        for id in horror {
            db.set_verdict(id, Some(Verdict::Down), 1).unwrap();
        }
        let facet = |facet, weight, leader| TasteFacetMeta {
            facet,
            weight,
            leader,
            cos_to_top: 1.0,
        };
        db.replace_taste(&TastePassOutput {
            facets: vec![facet(0, 3.0, westerns[0]), facet(1, 1.0, comedies[0])],
            watched_facet: westerns
                .iter()
                .map(|&id| (id, 0))
                .chain(comedies.iter().map(|&id| (id, 1)))
                .collect(),
            tones: vec![
                (westerns[0], "gripping", 0.1),
                (westerns[1], "gripping", 0.2),
            ],
            ..Default::default()
        })
        .unwrap();

        let profile = taste_profile(&db).unwrap();
        assert_eq!(profile.facets.len(), 2);
        let west = &profile.facets[0];
        assert_eq!(west.leader, "Once Upon a Time in the West");
        assert_eq!(west.leader_id, westerns[0]);
        assert!((west.share - 0.75).abs() < 1e-6, "{}", west.share);
        assert_eq!(
            west.genres.first().map(String::as_str),
            Some("Western"),
            "{west:?}"
        );
        // one title's genre is an anecdote, not a description
        assert!(!west.genres.contains(&"Comedy".to_string()));
        assert_eq!(west.directors, vec!["Sergio Leone".to_string()]);
        assert_eq!(west.keywords.len(), 2, "{west:?}");
        assert!(west.keywords.contains(&"duel".to_string()));
        assert!(west.keywords.contains(&"revenge".to_string()));
        assert_eq!(west.decades, (1950, 1960));
        assert_eq!(west.tones, vec!["gripping".to_string()]);
        assert_eq!(profile.facets[1].genres, vec!["Comedy".to_string()]);
        assert_eq!(profile.avoid, vec!["Horror".to_string()]);
    }

    #[test]
    fn a_first_launch_has_no_profile_and_no_division_by_nothing() {
        let db = Db::open_in_memory().unwrap();
        assert_eq!(taste_profile(&db).unwrap(), TasteProfile::default());
    }
}
