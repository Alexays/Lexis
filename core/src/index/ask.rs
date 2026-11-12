//! Asking in words: "un truc drôle de moins de 1h40 pas vu". A handful of
//! rules read what they can (a length, a kind, a decade, a person, a mood,
//! seen or not) and hand what is left to the encoder, if the device has one.

use super::db::{Db, IndexError};
use super::queries::{row_to_title, TitleRow};
use super::tonight::{runtime_of, Window, RUNTIME};
use super::MediaKind;
use crate::embed::pass::MAX_VECTORS;
use crate::embed::space::Space;
use crate::embed::Encoder;
use crate::metadata::enrich::normalize;
use rusqlite::types::Value;
use std::collections::HashMap;
use unicode_normalization::char::is_combining_mark;

/// What the rules understood, and the words they left.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct AskFilters {
    pub max_minutes: Option<u32>,
    pub kind: Option<MediaKind>,
    /// Never played and never judged.
    pub unseen: bool,
    /// Watched to the end at least once.
    pub rewatch: bool,
    /// The first year of a decade: 1980 for the eighties.
    pub decade: Option<u16>,
    /// People credited on the title, as the library names them.
    pub people: Vec<String>,
    /// A key of `taste::MOODS`.
    pub mood: Option<String>,
    /// Fits what is left of this evening.
    pub tonight: bool,
    /// What no rule read, for the encoder.
    pub text: String,
}

/// What "court" or "short" asks of a length: an hour forty, past which a
/// film is an evening rather than a gap in one.
pub const SHORT_MINUTES: u32 = 100;

/// How much the taste weighs beside the words: a third of a cosine, enough
/// to order titles the words place alike and never to outrank the words.
pub const ASK_TASTE: f32 = 0.3;

/// How many titles one question answers with: two screens of posters.
pub const ASK_LIMIT: usize = 40;

/// The words each mood answers to, folded, French and English.
const MOOD_WORDS: [(&str, &[&str]); 7] = [
    (
        "light",
        &[
            "drole",
            "droles",
            "marrant",
            "marrants",
            "rigolo",
            "rigolos",
            "leger",
            "legere",
            "legers",
            "comedie",
            "funny",
            "light",
            "fun",
            "hilarious",
            "comedy",
        ],
    ),
    (
        "gripping",
        &[
            "haletant",
            "haletante",
            "suspense",
            "tendu",
            "tendue",
            "thriller",
            "palpitant",
            "gripping",
            "tense",
            "thrilling",
        ],
    ),
    (
        "moving",
        &[
            "emouvant",
            "emouvante",
            "touchant",
            "touchante",
            "triste",
            "pleurer",
            "moving",
            "sad",
            "touching",
            "poignant",
        ],
    ),
    (
        "chills",
        &[
            "flippant",
            "flippante",
            "peur",
            "effrayant",
            "effrayante",
            "horreur",
            "angoissant",
            "scary",
            "creepy",
            "horror",
            "frightening",
        ],
    ),
    (
        "escape",
        &[
            "aventure",
            "evasion",
            "epique",
            "depaysant",
            "adventure",
            "epic",
            "escape",
        ],
    ),
    (
        "mind",
        &[
            "cerebral",
            "intrigant",
            "intrigante",
            "reflechir",
            "intelligent",
            "enigme",
            "clever",
            "twisty",
            "puzzling",
            "mind",
        ],
    ),
    (
        "cosy",
        &[
            "doux",
            "douce",
            "reconfortant",
            "chaleureux",
            "chaleureuse",
            "mignon",
            "cosy",
            "cozy",
            "comforting",
            "wholesome",
            "feelgood",
            "warm",
        ],
    ),
];

/// Words that say nothing about what to watch, dropped before the encoder
/// reads what is left.
const STOP: &[&str] = &[
    "un",
    "une",
    "des",
    "du",
    "de",
    "d",
    "le",
    "la",
    "les",
    "l",
    "au",
    "aux",
    "en",
    "et",
    "ou",
    "a",
    "an",
    "the",
    "of",
    "for",
    "and",
    "or",
    "with",
    "by",
    "from",
    "to",
    "in",
    "on",
    "some",
    "something",
    "thing",
    "truc",
    "trucs",
    "quelque",
    "chose",
    "qui",
    "que",
    "quoi",
    "pour",
    "avec",
    "par",
    "je",
    "j",
    "veux",
    "voudrais",
    "envie",
    "i",
    "want",
    "me",
    "moi",
    "on",
    "regarder",
    "voir",
    "watch",
    "genre",
    "style",
    "type",
    "tv",
    "s",
    "ce",
    "cette",
    "c",
    "est",
    "is",
    "it",
    "that",
    "this",
    "please",
    "stp",
    "plutot",
    "bien",
    "bon",
    "good",
    "one",
];

/// Words that introduce a person: "avec Belmondo", "de Godard".
const PERSON_CUES: &[&str] = &["avec", "with", "starring", "de", "par", "by"];

fn seen_word(w: &str) -> bool {
    matches!(w, "vu" | "vue" | "vus" | "vues" | "seen")
}

/// A length at the head of `ws`: "1h40", "2h", "90 min", "2 heures",
/// "1 h 30", "1 hour 30 minutes". `bare` accepts a number with no unit,
/// which only a cue ("moins de") makes a length. How many words it took, and
/// the minutes.
fn length(ws: &[&str], bare: bool) -> Option<(usize, u32)> {
    let w = *ws.first()?;
    let minute = |x: Option<&&str>| matches!(x, Some(&("min" | "mn" | "minute" | "minutes")));
    let hour = |x: Option<&&str>| {
        matches!(
            x,
            Some(&("h" | "heure" | "heures" | "hour" | "hours" | "hr" | "hrs"))
        )
    };
    if let Some((h, m)) = w.split_once('h') {
        if let Ok(hours) = h.parse::<u32>() {
            let m = m.trim_end_matches("min").trim_end_matches("mn");
            let minutes: u32 = match m {
                "" | "r" | "rs" | "eure" | "eures" | "our" | "ours" => 0,
                m => m.parse().ok()?,
            };
            return Some((1 + usize::from(minute(ws.get(1))), hours * 60 + minutes));
        }
    }
    for suffix in ["minutes", "min", "mn"] {
        if let Some(n) = w.strip_suffix(suffix).and_then(|n| n.parse().ok()) {
            return Some((1, n));
        }
    }
    let n: u32 = w.parse().ok()?;
    if hour(ws.get(1)) {
        let (more, minutes) = match ws.get(2).and_then(|m| m.parse::<u32>().ok()) {
            Some(m) => (1 + usize::from(minute(ws.get(3))), m),
            None => (0, 0),
        };
        return Some((2 + more, n * 60 + minutes));
    }
    let with_unit = minute(ws.get(1));
    (bare || with_unit).then_some((1 + usize::from(with_unit), n))
}

/// A decade at the head of `ws`: "annees 80", "80s", "1980s", "annees 2000".
fn decade(ws: &[&str]) -> Option<(usize, u16)> {
    let (taken, digits) = match ws {
        [cue, y, ..] if matches!(*cue, "annees" | "annee") => (2, *y),
        [y, ..] => (1, y.strip_suffix('s')?),
        [] => return None,
    };
    let year: u16 = match digits.len() {
        2 => {
            let yy: u16 = digits.parse().ok()?;
            if yy < 30 {
                2000 + yy
            } else {
                1900 + yy
            }
        }
        4 => digits.parse().ok()?,
        _ => return None,
    };
    Some((taken, year / 10 * 10))
}

/// Reads what the rules can out of a question, in any case and with or
/// without accents, and leaves the rest in `text`. A person is found by any
/// run of their name's last words ("belmondo", "de niro"), the most credited
/// first when two share it.
pub fn parse(
    db: &Db,
    query: &str,
    now: i64,
    tz_offset_secs: i32,
) -> Result<AskFilters, IndexError> {
    let folded = normalize(query);
    let words: Vec<&str> = folded.split(' ').filter(|w| !w.is_empty()).collect();
    let mut used = vec![false; words.len()];
    let mut f = AskFilters::default();
    let mut i = 0;
    while i < words.len() {
        let rest = &words[i..];
        let taken = if let Some((cue, (n, minutes))) = [
            &["moins", "de"][..],
            &["under"],
            &["less", "than"],
            &["max"],
            &["maximum"],
        ]
        .iter()
        .find(|cue| rest.starts_with(cue))
        .and_then(|cue| Some((cue.len(), length(&rest[cue.len()..], true)?)))
        {
            f.max_minutes = Some(minutes);
            cue + n
        } else if let Some((n, minutes)) = length(rest, false) {
            f.max_minutes = Some(minutes);
            n
        } else if let Some((n, year)) = decade(rest) {
            f.decade = Some(year);
            n
        } else if matches!(rest, [not, w, ..] if matches!(*not, "pas" | "jamais" | "not" | "never") && seen_word(w))
        {
            f.unseen = true;
            2
        } else if matches!(rest, ["pas", "encore", w, ..] if seen_word(w)) {
            f.unseen = true;
            3
        } else if matches!(rest, [already, w, ..] if matches!(*already, "deja" | "already") && seen_word(w))
        {
            f.rewatch = true;
            2
        } else if matches!(rest, ["ce", "soir", ..]) {
            f.tonight = true;
            2
        } else {
            let w = rest[0];
            match w {
                "unseen" => f.unseen = true,
                "rewatch" | "revoir" => f.rewatch = true,
                "tonight" => f.tonight = true,
                "film" | "films" | "movie" | "movies" => f.kind = Some(MediaKind::Movie),
                "serie" | "series" | "show" | "shows" => f.kind = Some(MediaKind::Show),
                "court" | "courte" | "courts" | "courtes" | "short" => {
                    f.max_minutes = Some(
                        f.max_minutes
                            .map_or(SHORT_MINUTES, |m| m.min(SHORT_MINUTES)),
                    )
                }
                _ => match MOOD_WORDS.iter().find(|(_, list)| list.contains(&w)) {
                    Some((key, _)) => {
                        f.mood.get_or_insert_with(|| (*key).to_string());
                    }
                    None => {
                        i += 1;
                        continue;
                    }
                },
            }
            1
        };
        used[i..i + taken].fill(true);
        i += taken;
    }

    // people last, so a cue only reaches the words nothing else claimed
    let cued = (0..words.len()).any(|i| !used[i] && PERSON_CUES.contains(&words[i]));
    if cued {
        let mut named = db
            .conn()
            .prepare_cached("SELECT name FROM people WHERE last_word = ?1")?;
        let mut credits = db.conn().prepare_cached(
            "SELECT COUNT(*) FROM title_tags WHERE kind IN ('cast', 'director') AND value = ?1",
        )?;
        let mut directed = db.conn().prepare_cached(
            "SELECT COUNT(*) FROM title_tags WHERE kind = 'director' AND value = ?1",
        )?;
        let mut i = 0;
        while i < words.len() {
            if used[i] || !PERSON_CUES.contains(&words[i]) {
                i += 1;
                continue;
            }
            // "de", "par" and "by" also introduce a subject ("un film de
            // noel"): after them a lone surname is only ever a director's
            let authored = matches!(words[i], "de" | "par" | "by");
            let free = words[i + 1..]
                .iter()
                .zip(&used[i + 1..])
                .take_while(|(_, u)| !**u)
                .count();
            let mut found = None;
            for n in (1..=free.min(3)).rev() {
                let wanted = &words[i + 1..i + 1 + n];
                let names = named
                    .query_map([wanted[n - 1]], |r| r.get::<_, String>(0))?
                    .collect::<Result<Vec<_>, _>>()?;
                let mut best: Option<(i64, String, bool)> = None;
                for name in names {
                    let folded = normalize(&name);
                    let parts: Vec<&str> = folded.split(' ').collect();
                    if parts.len() < n || parts[parts.len() - n..] != *wanted {
                        continue;
                    }
                    let lone = n == 1 && parts.len() > 1;
                    let counted = if lone && authored {
                        &mut directed
                    } else {
                        &mut credits
                    };
                    let count: i64 = counted.query_row([&name], |r| r.get(0))?;
                    if count > 0 && best.as_ref().is_none_or(|(b, _, _)| count > *b) {
                        best = Some((count, name, lone));
                    }
                }
                // a lone surname ("james", "noel") is as often a word as a
                // person: it is the person only if they answer the question
                if let Some((_, name, lone)) = best {
                    if lone {
                        let mut trial = f.clone();
                        trial.people.push(name.clone());
                        if ask(db, &trial, None, now, tz_offset_secs)?.is_empty() {
                            continue;
                        }
                    }
                    found = Some((n, name));
                    break;
                }
            }
            match found {
                Some((n, name)) => {
                    used[i..=i + n].fill(true);
                    f.people.push(name);
                    i += n + 1;
                }
                None => i += 1,
            }
        }
    }

    // the encoder reads the words as they were typed: accents and case are
    // pieces of its vocabulary, and the folded form is only for the rules
    let typed: Vec<&str> = query
        .split(|c: char| !c.is_alphanumeric() && !is_combining_mark(c))
        .filter(|w| !w.is_empty())
        .collect();
    let typed = if typed.len() == words.len() {
        typed
    } else {
        words.clone()
    };
    f.text = typed
        .iter()
        .zip(&words)
        .zip(&used)
        .filter(|((_, w), u)| !**u && !STOP.contains(*w))
        .map(|((t, _), _)| *t)
        .collect::<Vec<_>>()
        .join(" ");
    Ok(f)
}

/// The library under the filters, best first. With `query`, the encoder's
/// vector of the words left over, each title ranks on its centred cosine to
/// it plus `ASK_TASTE` of the owner's affinity; without, a mood ranks first
/// and the taste after it. No model, no vectors, no taste pass: the filters
/// alone answer, never an error.
pub fn ask(
    db: &Db,
    filters: &AskFilters,
    query: Option<&[i8]>,
    now: i64,
    tz_offset_secs: i32,
) -> Result<Vec<TitleRow>, IndexError> {
    let mut sql = format!(
        "SELECT t.id, t.kind, t.name, t.year,
    (SELECT COUNT(*) FROM files c WHERE c.title_id = t.id) AS file_count,
    (SELECT c.id FROM files c WHERE c.title_id = t.id ORDER BY c.quality DESC, c.id LIMIT 1) AS first_file_id,
    {RUNTIME} AS durations, COALESCE(tt.affinity, 0)
  FROM titles t
  LEFT JOIN title_taste tt ON tt.title_id = t.id
  WHERE EXISTS (SELECT 1 FROM files c WHERE c.title_id = t.id)"
    );
    let mut params: Vec<Value> = Vec::new();
    if let Some(kind) = filters.kind {
        params.push(Value::Text(kind.as_str().to_string()));
        sql.push_str(&format!(" AND t.kind = ?{}", params.len()));
    }
    if filters.unseen {
        sql.push_str(
            " AND NOT EXISTS (SELECT 1 FROM watch_state w JOIN files c ON c.id = w.file_id
                              WHERE c.title_id = t.id)
              AND NOT EXISTS (SELECT 1 FROM title_verdict v WHERE v.title_id = t.id)",
        );
    }
    if filters.rewatch {
        sql.push_str(
            " AND EXISTS (SELECT 1 FROM watch_state w JOIN files c ON c.id = w.file_id
                          WHERE c.title_id = t.id AND w.watched = 1)",
        );
    }
    if let Some(decade) = filters.decade {
        params.push(Value::Integer(i64::from(decade)));
        sql.push_str(&format!(
            " AND t.year BETWEEN ?{0} AND ?{0} + 9",
            params.len()
        ));
    }
    for person in &filters.people {
        params.push(Value::Text(person.clone()));
        sql.push_str(&format!(
            " AND EXISTS (SELECT 1 FROM title_tags g WHERE g.title_id = t.id
                          AND g.kind IN ('cast', 'director') AND g.value = ?{})",
            params.len()
        ));
    }
    let window = if filters.tonight {
        Window::of(db, now, tz_offset_secs, None)?
    } else {
        None
    };
    let mut found: Vec<(TitleRow, f32)> = {
        let mut stmt = db.conn().prepare(&sql)?;
        let rows = stmt.query_map(rusqlite::params_from_iter(params), |r| {
            let row = row_to_title(r)?;
            let runtime = runtime_of(r.get(6)?, row.kind == MediaKind::Show);
            Ok((row, runtime, r.get::<_, f64>(7)? as f32))
        })?;
        let mut out = Vec::new();
        for row in rows {
            let (row, runtime, affinity) = row?;
            let minutes = (runtime / 60.0).ceil() as u32;
            if filters
                .max_minutes
                .is_some_and(|max| runtime <= 0.0 || minutes > max)
            {
                continue;
            }
            if window.as_ref().is_some_and(|w| !w.fits(runtime)) {
                continue;
            }
            out.push((row, affinity));
        }
        out
    };

    let by_words = match query {
        Some(query) if !filters.text.is_empty() => {
            let version = Encoder::chosen(db)?.version();
            let vectors = db.vectors(version, MAX_VECTORS)?;
            let space = Space::of(&vectors);
            // a mood said beside other words was taken out of them, and
            // weighs as much as they do through its anchor
            let mood = match &filters.mood {
                Some(key) => db
                    .anchor_vector(key, version)?
                    .and_then(|a| space.direction_of(&a)),
                None => None,
            }
            .map(|direction| {
                let along = space.along_mean(&direction);
                (direction, along)
            });
            space.direction_of(query).map(|direction| {
                let along = space.along_mean(&direction);
                vectors
                    .iter()
                    .enumerate()
                    .filter(|(i, v)| space.placed(*i) && v.vector.len() == direction.len())
                    .map(|(i, v)| {
                        let cos = |direction: &[f32], along: f32| {
                            let dot: f32 = v
                                .vector
                                .iter()
                                .zip(direction)
                                .map(|(a, b)| f32::from(*a) * b)
                                .sum();
                            space.cos_to(i, dot, along)
                        };
                        let mooded = mood.as_ref().map_or(0.0, |(d, along)| cos(d, *along));
                        (v.title_id, cos(&direction, along) + mooded)
                    })
                    .collect::<HashMap<i64, f32>>()
            })
        }
        _ => None,
    };
    match by_words {
        Some(cosines) => {
            // a title with no vector says nothing to the words, and follows
            // every one that does
            let score = |(row, affinity): &(TitleRow, f32)| {
                cosines
                    .get(&row.id)
                    .map_or(f32::MIN, |cos| cos + ASK_TASTE * affinity)
            };
            found.sort_by(|a, b| {
                score(b)
                    .total_cmp(&score(a))
                    .then(b.1.total_cmp(&a.1))
                    .then(a.0.id.cmp(&b.0.id))
            });
        }
        None => {
            let listed: HashMap<i64, usize> = match &filters.mood {
                Some(mood) => {
                    let mut ids = db.seasonal_titles(mood)?;
                    ids.extend(db.seasonal_titles(&format!("seen:{mood}"))?);
                    ids.into_iter()
                        .enumerate()
                        .map(|(at, id)| (id, at))
                        .rev()
                        .collect()
                }
                None => HashMap::new(),
            };
            found.sort_by(|a, b| {
                let at = |row: &TitleRow| listed.get(&row.id).copied().unwrap_or(usize::MAX);
                at(&a.0)
                    .cmp(&at(&b.0))
                    .then(b.1.total_cmp(&a.1))
                    .then(a.0.name.cmp(&b.0.name))
            });
        }
    }
    found.truncate(ASK_LIMIT);
    Ok(found.into_iter().map(|(row, _)| row).collect())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::index::db::{
        EmbeddingRecord, FileMedia, FileRecord, TastePassOutput, TitleTasteRow,
    };

    const WIDTH: usize = 16;
    /// A Thursday, 12:00: outside every session.
    const NOON: i64 = 20_685 * 86_400 + 12 * 3_600;

    fn title(db: &Db, kind: MediaKind, name: &str, year: u16, minutes: f64) -> i64 {
        let id = db.upsert_title(kind, name, Some(year)).unwrap();
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
        db.conn()
            .execute(
                "UPDATE files SET duration_secs = ?1 WHERE title_id = ?2",
                rusqlite::params![minutes * 60.0, id],
            )
            .unwrap();
        id
    }

    fn credit(db: &Db, title_id: i64, kind: &str, name: &str) {
        db.conn()
            .execute(
                "INSERT INTO title_tags (title_id, kind, value) VALUES (?1, ?2, ?3)",
                rusqlite::params![title_id, kind, name],
            )
            .unwrap();
        db.conn()
            .execute(
                "INSERT OR IGNORE INTO people (name, last_word) VALUES (?1, ?2)",
                rusqlite::params![name, normalize(name).rsplit(' ').next()],
            )
            .unwrap();
    }

    fn vector(db: &Db, title_id: i64, axis: usize) {
        let mut v = vec![0i8; WIDTH];
        v[0] = 80;
        v[axis] = 100;
        db.upsert_embedding(&EmbeddingRecord {
            title_id,
            model_version: crate::embed::Encoder::Small.version(),
            source_hash: 0,
            vector: v,
            computed_at: 1,
        })
        .unwrap();
    }

    fn names(rows: &[TitleRow]) -> Vec<&str> {
        rows.iter().map(|r| r.name.as_str()).collect()
    }

    #[test]
    fn a_length_a_mood_and_unseen_are_read_off_one_french_sentence() {
        let db = Db::open_in_memory().unwrap();
        let f = parse(&db, "un truc drôle de moins de 1h40 pas vu", NOON, 0).unwrap();
        assert_eq!(f.max_minutes, Some(100));
        assert!(f.unseen);
        assert!(!f.rewatch);
        assert_eq!(f.mood.as_deref(), Some("light"));
        assert!(f.people.is_empty());
        assert_eq!(f.text, "");
    }

    #[test]
    fn english_kinds_decades_and_lengths_read_the_same() {
        let db = Db::open_in_memory().unwrap();
        let f = parse(
            &db,
            "A SCARY movie from the 80s, under 90 min, rewatch",
            NOON,
            0,
        )
        .unwrap();
        assert_eq!(f.kind, Some(MediaKind::Movie));
        assert_eq!(f.decade, Some(1980));
        assert_eq!(f.max_minutes, Some(90));
        assert_eq!(f.mood.as_deref(), Some("chills"));
        assert!(f.rewatch);
        for (asked, minutes) in [
            ("moins de 2 heures", 120),
            ("under 2 hours", 120),
            ("moins de 1 h 30", 90),
            ("un film de 1 heure 30 minutes", 90),
            ("max 2 hrs", 120),
            ("1h40", 100),
            ("under 90", 90),
        ] {
            assert_eq!(
                parse(&db, asked, NOON, 0).unwrap().max_minutes,
                Some(minutes),
                "{asked}"
            );
        }
        let f = parse(&db, "une série courte des années 2000 déjà vue", NOON, 0).unwrap();
        assert_eq!(f.kind, Some(MediaKind::Show));
        assert_eq!(f.decade, Some(2000));
        assert!(f.max_minutes.is_some());
        assert!(f.rewatch);
        let f = parse(&db, "un film pour ce soir avec des robots géants", NOON, 0).unwrap();
        assert!(f.tonight);
        assert_eq!(f.text, "robots géants");
    }

    #[test]
    fn a_person_is_found_by_their_surname_whatever_the_case_and_the_accents() {
        let db = Db::open_in_memory().unwrap();
        let breathless = title(&db, MediaKind::Movie, "A bout de souffle", 1960, 90.0);
        let heat = title(&db, MediaKind::Movie, "Heat", 1995, 170.0);
        credit(&db, breathless, "cast", "Jean-Paul Belmondo");
        credit(&db, breathless, "director", "Jean-Luc Godard");
        credit(&db, heat, "director", "Michael Mann");
        credit(&db, heat, "cast", "Robert De Niro");

        let f = parse(&db, "avec BELMONDO", NOON, 0).unwrap();
        assert_eq!(f.people, vec!["Jean-Paul Belmondo".to_string()]);
        assert_eq!(f.text, "");
        let rows = ask(&db, &f, None, NOON, 0).unwrap();
        assert_eq!(names(&rows), vec!["A bout de souffle"]);

        let f = parse(&db, "un film de godard", NOON, 0).unwrap();
        assert_eq!(f.people, vec!["Jean-Luc Godard".to_string()]);
        // a "de" that names nobody is only a word
        let f = parse(&db, "avec de niro", NOON, 0).unwrap();
        assert_eq!(f.people, vec!["Robert De Niro".to_string()]);
        let f = parse(&db, "de la neige", NOON, 0).unwrap();
        assert!(f.people.is_empty());
        assert_eq!(f.text, "neige");
    }

    #[test]
    fn a_lone_surname_is_a_filter_only_when_something_answers_it() {
        let db = Db::open_in_memory().unwrap();
        let cinderella = title(&db, MediaKind::Movie, "Cinderella", 2015, 110.0);
        credit(&db, cinderella, "cast", "Lily James");
        title(&db, MediaKind::Show, "Dark", 2017, 50.0);

        let f = parse(&db, "un film avec james", NOON, 0).unwrap();
        assert_eq!(f.people, vec!["Lily James".to_string()]);
        assert_eq!(f.text, "");
        // no series of hers: the word was not her, and stays a word
        let f = parse(&db, "une série de james", NOON, 0).unwrap();
        assert!(f.people.is_empty(), "{f:?}");
        assert_eq!(f.text, "james");
        assert_eq!(names(&ask(&db, &f, None, NOON, 0).unwrap()), vec!["Dark"]);
        // a whole name is hers whatever it leaves
        let f = parse(&db, "une série avec lily james", NOON, 0).unwrap();
        assert_eq!(f.people, vec!["Lily James".to_string()]);
    }

    #[test]
    fn after_de_a_lone_surname_is_a_director_and_never_a_face_in_the_cast() {
        let db = Db::open_in_memory().unwrap();
        let film = title(&db, MediaKind::Movie, "Les Mains d'Orlac", 1960, 105.0);
        credit(&db, film, "cast", "Magali Noël");
        let irreversible = title(&db, MediaKind::Movie, "Irréversible", 2002, 97.0);
        credit(&db, irreversible, "director", "Gaspar Noé");

        // Christmas, not her filmography
        let f = parse(&db, "un film de Noël", NOON, 0).unwrap();
        assert!(f.people.is_empty(), "{f:?}");
        assert_eq!(f.text, "Noël");
        let f = parse(&db, "un film avec noel", NOON, 0).unwrap();
        assert_eq!(f.people, vec!["Magali Noël".to_string()]);
        let f = parse(&db, "un film de noé", NOON, 0).unwrap();
        assert_eq!(f.people, vec!["Gaspar Noé".to_string()]);
    }

    #[test]
    fn the_encoder_reads_the_words_as_they_were_typed() {
        let db = Db::open_in_memory().unwrap();
        let f = parse(
            &db,
            "un film pour ce soir avec des Robots géants, d'après Asimov",
            NOON,
            0,
        )
        .unwrap();
        assert!(f.tonight);
        assert_eq!(f.text, "Robots géants après Asimov");
    }

    #[test]
    fn a_mood_said_beside_other_words_still_weighs_on_the_ranking() {
        let db = Db::open_in_memory().unwrap();
        let robots = title(&db, MediaKind::Movie, "Robots", 2000, 100.0);
        let scary = title(&db, MediaKind::Movie, "Scary Robots", 2000, 100.0);
        vector(&db, robots, 1);
        let mut v = vec![0i8; WIDTH];
        v[0] = 80;
        v[1] = 70;
        v[2] = 70;
        db.upsert_embedding(&EmbeddingRecord {
            title_id: scary,
            model_version: crate::embed::Encoder::Small.version(),
            source_hash: 0,
            vector: v,
            computed_at: 1,
        })
        .unwrap();
        for axis in 3..WIDTH {
            let id = title(
                &db,
                MediaKind::Movie,
                &format!("Single {axis}"),
                1990,
                100.0,
            );
            vector(&db, id, axis);
        }
        let mut chills = vec![0i8; WIDTH];
        chills[0] = 80;
        chills[2] = 100;
        db.put_anchor_vector("chills", crate::embed::Encoder::Small.version(), &chills)
            .unwrap();
        let mut query = vec![0i8; WIDTH];
        query[0] = 80;
        query[1] = 100;

        let f = parse(&db, "des robots qui font peur", NOON, 0).unwrap();
        assert_eq!(f.mood.as_deref(), Some("chills"));
        assert_eq!(f.text, "robots font");
        let rows = ask(&db, &f, Some(&query), NOON, 0).unwrap();
        assert_eq!(rows[0].id, scary, "{:?}", names(&rows));
        // the same words without the mood: the closest to them leads
        let plain = AskFilters { mood: None, ..f };
        assert_eq!(
            ask(&db, &plain, Some(&query), NOON, 0).unwrap()[0].id,
            robots
        );
    }

    #[test]
    fn without_a_model_the_filters_alone_answer_ranked_by_taste() {
        let db = Db::open_in_memory().unwrap();
        let short = title(&db, MediaKind::Movie, "Short One", 1985, 85.0);
        let liked = title(&db, MediaKind::Movie, "Short Liked", 1987, 95.0);
        title(&db, MediaKind::Movie, "Long One", 1986, 150.0);
        title(&db, MediaKind::Show, "A Show", 1984, 30.0);
        let seen = title(&db, MediaKind::Movie, "Short Seen", 1988, 80.0);
        db.set_verdict(seen, Some(crate::index::Verdict::Up), 1)
            .unwrap();
        db.replace_taste(&TastePassOutput {
            title_taste: vec![TitleTasteRow {
                title_id: liked,
                facet: 0,
                affinity: 0.8,
                rejected: String::new(),
            }],
            ..Default::default()
        })
        .unwrap();

        let f = parse(
            &db,
            "un film drôle des années 80 de moins de 1h40 pas vu",
            NOON,
            0,
        )
        .unwrap();
        let rows = ask(&db, &f, None, NOON, 0).unwrap();
        assert_eq!(names(&rows), vec!["Short Liked", "Short One"]);
        assert!(rows.iter().any(|r| r.id == short));
    }

    #[test]
    fn words_left_over_rank_by_their_closeness_to_each_title_plus_a_share_of_the_taste() {
        let db = Db::open_in_memory().unwrap();
        let robots = title(&db, MediaKind::Movie, "Robots", 2000, 100.0);
        let whales = title(&db, MediaKind::Movie, "Whales", 2000, 100.0);
        let loved = title(&db, MediaKind::Movie, "Loved", 2000, 100.0);
        vector(&db, robots, 1);
        vector(&db, whales, 2);
        vector(&db, loved, 3);
        for axis in 4..WIDTH {
            let id = title(
                &db,
                MediaKind::Movie,
                &format!("Single {axis}"),
                1990,
                100.0,
            );
            vector(&db, id, axis);
        }
        db.replace_taste(&TastePassOutput {
            title_taste: vec![TitleTasteRow {
                title_id: loved,
                facet: 0,
                affinity: 1.0,
                rejected: String::new(),
            }],
            ..Default::default()
        })
        .unwrap();
        let mut query = vec![0i8; WIDTH];
        query[0] = 80;
        query[1] = 100;
        let f = AskFilters {
            text: "robots".into(),
            ..Default::default()
        };
        let rows = ask(&db, &f, Some(&query), NOON, 0).unwrap();
        assert_eq!(rows[0].id, robots, "{:?}", names(&rows));
        // the taste weighs a third of a cosine: enough to lead the rest
        assert_eq!(rows[1].id, loved, "{:?}", names(&rows));
    }
}
