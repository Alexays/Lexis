//! The home screen's rows, computed in SQL against the local tables. Nothing
//! here talks to the network: the scan wrote the files, the enrichment wrote
//! the genres and the similar links, and playback wrote the watch state.
//!
//! The screen is not a fixed list of rows. Every generator below proposes the
//! rows its own corner of the data can fill, each carrying the `Reason` it
//! exists for, and `select` picks and orders them for this viewer today. The
//! reason is what the row is built from, not a label put on afterwards: the
//! catalogs render it, so every row on screen can say why it is there and be
//! disagreed with.

use super::db::{Db, IndexError};
use super::queries::{row_to_title, TitleRow};
use super::MediaKind;
use rusqlite::params;
use std::collections::{HashMap, HashSet};
use std::sync::LazyLock;

/// How many titles one row carries. A 10-foot row shows five or six at a time,
/// and nothing past twenty is still a recommendation.
pub const ROW_LIMIT: u32 = 20;

/// How many titles a person's page carries per role. A row is a
/// recommendation and is cut where one stops being useful; this is the whole
/// of what a library holds of somebody's work, and cutting it would be
/// answering "what else is he in" with "some of it". The most-credited name
/// in a 3798-title library reaches forty, so this is a guard against a
/// pathological tag rather than a limit anyone meets.
pub const PERSON_LIMIT: u32 = 200;

/// The fewest titles a row is worth showing with. Below a screenful a shelf
/// reads as broken rather than as selective, and having nothing to say is
/// better said by saying nothing. See `floor` for the rows this does not bind:
/// the viewer's own.
const SHELF: usize = 5;

/// How many rows the screen carries under its head (what the viewer is in the
/// middle of, the evening, the list). Past eight the viewer is scrolling a
/// catalogue rather than reading a recommendation, and the rows at the bottom
/// are the weakest ones the selection had.
const MAX_ROWS: usize = 8;

/// How many rows of one kind. Two actors they return to is a taste; five is a
/// filmography index, and it crowds out every other way of looking at the
/// library.
const MAX_PER_KIND: usize = 2;

/// One spare subject per kind beyond what can be shown, so a candidate thrown
/// out for saying what the row above it said leaves a row rather than a gap.
const SUBJECTS: usize = MAX_PER_KIND + 1;

/// Above this share of a candidate's titles already on the screen, the row is
/// repeating the one above it under another name. Rejected rather than
/// trimmed: cutting the overlap out would leave a row of leftovers, which is
/// the padding a floor exists to prevent.
const OVERLAP: f32 = 0.6;

/// How far a row's place can move from one day to the next, in the units
/// `rank` is spaced in. One tier: a row can trade places with the kind next to
/// it and never with one two tiers away, so the screen is recognisably the
/// same screen two evenings running while its order still moves.
const ORDER_SPREAD: f32 = 8.0;

/// How far down a kind's own ranking the day may reach, as a share of it: at
/// 0.6, roughly the top three fifths of the actors the history names are in
/// the running for tonight's row and the tail of the ranking is not. This is
/// where the variety lives - a dozen actors and a dozen eras qualify on this
/// library and only two of each fit - and it is bounded so that what the row
/// says is still something the history said.
const PICK_SPREAD: f32 = 0.6;

/// How many days back a row's launches are read, and how many days of the
/// mean rate a row's own record is weighed against: ten days before a row
/// offered daily speaks mostly for itself.
const LEARN_WINDOW_DAYS: i64 = 60;
const LEARN_PRIOR_DAYS: f32 = 10.0;

/// Why a row is on the screen. Everything the name on screen is rendered from
/// is in here, in the locale catalogs: "Parce que vous avez regardé Inception"
/// is a row a viewer can agree or disagree with, which is the whole point of
/// carrying the reason rather than a string the core made up in English.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Reason {
    /// Left running. What the row plays is where the viewer stopped.
    /// A show whose last episode was finished and whose next one is waiting.
    /// The neighbours of one title they watched, named after it. `seed_id` is
    /// what "not because of this" contests.
    BecauseYouWatched { seed: String, seed_id: i64 },
    /// One facet of the taste fingerprint, named after the title nearest that
    /// facet's centre (see `index::taste`). Still not a title they said they
    /// liked, even now that the detail screen asks: a facet is weighed on
    /// completion times recency and on whatever verdicts happen to fall in it,
    /// and a viewer who has never pressed the button gets exactly the row they
    /// got before. The name would have to be true for both of them, so it
    /// stays the one that is.
    TasteFacet { leader: String, leader_id: i64 },
    /// The next title of each collection they have begun, in the order the
    /// history returns to them.
    Sagas,
    /// An actor their history keeps coming back to.
    WithActor { name: String },
    /// A director their history keeps coming back to.
    ByDirector { name: String },
    /// A genre crossed with the decade they watch it in. `decade` is the first
    /// year of it: 1990, 2010.
    GenreEra { genre: String, decade: u16 },
    /// Newest on the shelf, films and series together, whether or not it has
    /// been played: a shelf, not a recommendation.
    RecentlyAdded,
    /// Watched once, years ago.
    LongAgo,
    /// Never played at all.
    Rediscovery,
    /// Deliberately a step aside from every taste: near enough to catch, far
    /// enough to be new (see `taste::discovery`).
    StepAside,
    /// The library against a seasonal anchor, in the window that anchor names.
    /// `window` is the key `taste::SEASONS` holds it under.
    Season { window: String },
    /// Titles added long ago, never played, and squarely in the taste the
    /// viewer has now; `seed` explains the first of them.
    ForgottenGem { seed: String },
    /// A cycle through one taste, from its most accessible member to its most
    /// particular. `done` of `total` have been watched.
    Thread {
        leader: String,
        done: u32,
        total: u32,
    },
    /// What the viewer asked for in one press: the library against one of
    /// `taste::MOODS`, leaning towards their own taste. Never dealt onto the
    /// shelf; it exists when it is asked for.
    Mood { key: String },
    /// What this day of the year brings back: a title's round anniversary, or
    /// what was finished a year ago.
    OnThisDay { kind: DayKind },
    /// Everything of one director's the library holds, seen or not, in the
    /// order it was made: for a week after the viewer finished one of their
    /// films and did not turn it down.
    Retrospective { name: String },
    /// The taste this month of the year has always leaned towards, named
    /// after its leader. `month` is 1 to 12.
    ThisMonth { month: u8, leader: String },
    /// The week's theme, drawn from the data rather than written: five titles
    /// of it, until `ends_at` (unix seconds, the next local Monday).
    CineClub { theme: ClubTheme, ends_at: i64 },
    /// What the viewer is in the middle of (see `queries::up_next`). Drawn by
    /// the home above the rows, never dealt; it exists to be opened.
    UpNext,
    /// The evening's picks and the ideas after them (see `tonight`). Drawn
    /// like `UpNext`.
    Tonight,
    /// What the viewer put aside for later, newest first.
    Watchlist,
    /// What the world is watching this week by TMDB's trending, as the
    /// library holds it, in TMDB's order. One row for films and one for
    /// series, like what arrived.
    Popular { series: bool },
    /// Filmed stage shows, stand-up and one-man shows, not yet seen: kept
    /// out of the taste and of every film row, and offered here instead.
    StageShows,
}

/// Which kind of date an "on this day" row keeps.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum DayKind {
    /// Released `years` ago, give or take `DAY_SLACK` days.
    Anniversary { years: u16 },
    /// Finished a year ago, give or take `DAY_SLACK` days.
    YearAgo,
}

/// What the week's club is about.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ClubTheme {
    Keyword { word: String },
    Composer { name: String },
    Writer { name: String },
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Row {
    pub reason: Reason,
    pub items: Vec<TitleRow>,
    /// Whether opening the row shows more than it carries: its generator
    /// filled every place it was given, so `row_items` has a deeper list.
    pub more: bool,
    /// Where each title stands in its saga, beside `items`; empty on every
    /// row but `Sagas`.
    pub places: Vec<SagaPlace>,
}

/// A title's place in its saga: the `position`th of `size`, with `watched`
/// of them seen. `name` is the saga's, cleaned (see `saga_name`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SagaPlace {
    pub name: String,
    pub position: u32,
    pub size: u32,
    pub watched: u32,
}

/// A row the library could fill, and where its kind sits on the screen today.
/// The pool holds more of these than fit; `select` decides.
struct Candidate {
    reason: Reason,
    items: Vec<TitleRow>,
    places: Vec<SagaPlace>,
    place: f32,
    more: bool,
    chapter: Chapter,
}

/// The parts the screen reads in, top to bottom. A row keeps to its part
/// whatever the day does to its place: the day orders a part, never the parts.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
enum Chapter {
    /// What the viewer already started.
    Carry,
    /// What is new or dated: one dated row at a time, and what arrived.
    News,
    /// What the history argues for.
    Taste,
    /// The shelf itself, and the way out of the taste.
    Explore,
}

/// The titles watched most recently, one row each, newest first: what the
/// "because you watched" rows are named after and search from. A show counts
/// once however many episodes it has, which is what grouping by title does.
const SEEDS: &str = "SELECT t.id, t.kind, t.name, m.tmdb_id
  FROM watch_state w
  CROSS JOIN files f ON f.id = w.file_id
  CROSS JOIN titles t ON t.id = f.title_id
  LEFT JOIN metadata m ON m.title_id = t.id
  WHERE w.watched = 1
    AND NOT EXISTS (SELECT 1 FROM taste_mute tm WHERE tm.leader_id = t.id AND tm.until > ?2)
  GROUP BY t.id
  ORDER BY MAX(w.updated_at) DESC, t.id
  LIMIT ?1";

/// The subject kind a "because you watched" row is recorded under, by its
/// seed's title id, so a seed passed over rests like a person does.
pub const SEED_SUBJECT: &str = "seed";

/// How many recently watched titles can seed a row of their own. Wider than
/// the two or three that fit, because which of them gets tonight's row is what
/// rotates (see `PICK_SPREAD`); wide enough to reach back past a single
/// evening's viewing, narrow enough that the seed is still something the
/// viewer remembers watching.
const SEED_POOL: u32 = 8;

/// The row the taste fingerprint picked, in the order it dealt them out
/// between the viewer's tastes (see `index::taste`), each pick beside the
/// facet that placed it and the watched title that facet was built around.
///
/// The pass wrote these against the history and the library as they stood
/// then, so the three filters are applied again here: a title watched since,
/// one the viewer has since had an opinion about, or one whose last file has
/// gone, must not still be on the shelf. That is what the depth `taste::PICKS`
/// goes to is for.
///
/// The verdict filter is also what makes a press felt at once. Recomputing the
/// fingerprint is what moves a rejected title's *neighbours*, and that is a
/// pass over the vectors; taking the rejected title itself off the shelf is
/// one indexed lookup per stored pick, on a query the screen was going to run
/// anyway, so the row the viewer walks back to has already lost it.
const PICKED: &str = "SELECT t.id, t.kind, t.name, t.year,
    (SELECT COUNT(*) FROM files c WHERE c.title_id = t.id) AS file_count,
    (SELECT c.id FROM files c WHERE c.title_id = t.id ORDER BY c.quality DESC, c.id LIMIT 1) AS first_file_id,
    p.facet, l.name, p.leader
  FROM taste_pick p
  CROSS JOIN titles t ON t.id = p.title_id
  LEFT JOIN titles l ON l.id = p.leader
  WHERE NOT EXISTS (SELECT 1 FROM watch_state w JOIN files f ON f.id = w.file_id
                    WHERE f.title_id = t.id)
    AND NOT EXISTS (SELECT 1 FROM title_verdict v WHERE v.title_id = t.id)
    AND EXISTS (SELECT 1 FROM files c WHERE c.title_id = t.id)
  ORDER BY p.rank";

/// The neighbours of the seed, from TMDB and from the model, fused. A title's
/// score is the sum over the lists naming it of 1 / (10 + rank), so appearing
/// on both beats appearing high on one. With no vectors the sum has a single
/// term and is strictly decreasing in rank, which is the order TMDB gave.
///
/// The kind is matched on both sides and again on the outside: TMDB numbers
/// movies and shows separately, and the semantic pass keeps to one kind, but a
/// stale link from before a purge must not be able to put a show in a film's
/// row. Id 0 is the "nothing was found" sentinel of both tables.
///
/// The model's links are read both ways, a pair only once: a title vectorised
/// after the seed names it, while the seed's own list was cut before it came.
///
/// CROSS JOIN pins the order the links are walked in. It is not a cartesian
/// product: SQLite reads it as "do not reorder", and without it the kind match
/// makes the title index look like an entry point and the query scans every
/// movie in the library.
const SIMILAR: &str = "SELECT t.id, t.kind, t.name, t.year,
    (SELECT COUNT(*) FROM files c WHERE c.title_id = t.id) AS file_count,
    (SELECT c.id FROM files c WHERE c.title_id = t.id ORDER BY c.quality DESC, c.id LIMIT 1) AS first_file_id
  FROM (
    SELECT m.title_id AS id, s.rank AS rank
      FROM tmdb_similar s
      CROSS JOIN metadata m ON m.tmdb_id = s.similar_tmdb_id
      CROSS JOIN titles x ON x.id = m.title_id AND x.kind = s.kind
      WHERE s.kind = ?1 AND s.tmdb_id = ?2 AND s.similar_tmdb_id <> 0
    UNION ALL
    SELECT n.similar_title_id, n.rank
      FROM similar_semantic n
      WHERE n.title_id = ?3 AND n.similar_title_id <> 0
    UNION ALL
    SELECT n.title_id, n.rank
      FROM similar_semantic n
      WHERE n.similar_title_id = ?3
        AND NOT EXISTS (SELECT 1 FROM similar_semantic o
                        WHERE o.title_id = ?3 AND o.similar_title_id = n.title_id)
  ) f
  CROSS JOIN titles t ON t.id = f.id
  WHERE t.kind = ?1 AND t.id <> ?3 AND EXISTS (SELECT 1 FROM files c WHERE c.title_id = t.id)
  GROUP BY t.id
  ORDER BY SUM(1.0 / (10 + f.rank)) DESC, t.id
  LIMIT ?4";

/// The same neighbours, minus what the viewer has already seen: a row that
/// recommends is not a row of films they watched last year. The detail
/// screen's own similar row keeps them, which is why this is a second query
/// rather than a filter on `SIMILAR`.
static SIMILAR_UNSEEN: LazyLock<String> = LazyLock::new(|| {
    SIMILAR.replace(
        "WHERE t.kind = ?1 AND t.id <> ?3",
        "WHERE t.kind = ?1 AND t.id <> ?3
    AND NOT EXISTS (SELECT 1 FROM watch_state w JOIN files c ON c.id = w.file_id
                    WHERE c.title_id = t.id)",
    )
});

/// The titles watched most recently, as the subject queries read history: one
/// row per title, so a show weighs as much as a film instead of once per
/// episode. CROSS JOIN pins the order: history is what bounds these counts,
/// and left alone SQLite groups by walking the whole file table.
const HISTORY: &str = "SELECT f.title_id FROM watch_state w
      CROSS JOIN files f ON f.id = w.file_id
      WHERE w.watched = 1
      GROUP BY f.title_id
      ORDER BY MAX(w.updated_at) DESC, f.title_id
      LIMIT ?1";

/// How many watched titles the subjects are read off. Enough that a stable
/// taste wins, few enough that what was watched years ago does not.
const HISTORY_WINDOW: u32 = 200;

/// The values of one `title_tags` kind the history carries, most-watched
/// first: which actors the viewer returns to, which genres they live in,
/// which collections they have started.
static TAG_SUBJECTS: LazyLock<String> = LazyLock::new(|| {
    format!(
        "SELECT g.value, COUNT(*) AS seen
  FROM ({HISTORY}) h
  CROSS JOIN title_tags g INDEXED BY idx_title_tags_title
    ON g.title_id = h.title_id AND g.kind = ?2
  GROUP BY g.value
  HAVING seen >= ?3
  ORDER BY seen DESC, g.value
  LIMIT ?4"
    )
});

/// A title the public, or the critics where the public said nothing, rated
/// under 5.5 in numbers large enough to mean it: never recommended.
const POORLY_RATED: &str = "EXISTS (SELECT 1 FROM metadata m WHERE m.title_id = t.id AND (
          (m.audience_source <> '' AND m.audience_rating < 5.5 AND m.audience_votes >= 200)
          OR (m.audience_source = '' AND m.critic_source <> ''
              AND m.critic_rating < 5.5 AND m.critic_votes >= 200)))";

/// Unwatched titles carrying one tag value, newest first. The lookup index
/// answers the (kind, value) pair, so the row costs the titles that carry the
/// tag and not the ones that do not.
/// A saga keeps its weak parts: what is left of it is the row.
static TAG_UNSEEN: LazyLock<String> = LazyLock::new(|| {
    format!(
        "SELECT t.id, t.kind, t.name, t.year,
    (SELECT COUNT(*) FROM files c WHERE c.title_id = t.id) AS file_count,
    (SELECT c.id FROM files c WHERE c.title_id = t.id ORDER BY c.quality DESC, c.id LIMIT 1) AS first_file_id
  FROM title_tags g
  CROSS JOIN titles t ON t.id = g.title_id
  WHERE g.kind = ?1 AND g.value = ?2
    AND NOT EXISTS (SELECT 1 FROM watch_state w JOIN files c ON c.id = w.file_id
                    WHERE c.title_id = t.id)
    AND EXISTS (SELECT 1 FROM files c WHERE c.title_id = t.id)
    AND (?1 = 'collection' OR NOT {POORLY_RATED})
  ORDER BY t.year DESC, t.name COLLATE NOCASE, t.id
  LIMIT ?3"
    )
});

/// How many watched titles an actor has to be in before the viewer can be said
/// to return to them. Two is a coincidence on a library of this size; three is
/// a habit.
const ACTOR_FLOOR: u32 = 3;

/// How many watched titles a director has to have made before the viewer can be
/// said to return to them. Lower than the actor's three, and the difference is
/// the point: an actor is in a film a year and shares a library with hundreds of
/// others, so three is what separates a habit from an accident. A director makes
/// a film every two or three years, and this library holds a handful of any
/// one's work, so two is already a return - and holding out for three would
/// silence exactly the auteur with eight features to their name, which is the
/// case this row exists for.
const DIRECTOR_FLOOR: u32 = 2;

/// How many of each kind of subject are ranked before the day picks between
/// them. Wide enough that a fortnight of openings is not the same two actors,
/// narrow enough that everything in it is genuinely something the history
/// says.
const SUBJECT_POOL: u32 = 12;

/// The genre-and-decade pairs the history actually holds: not every genre it
/// carries crossed with every decade the library has, but the ones the viewer
/// watches, ranked by how much of their history is in them.
static ERA_SUBJECTS: LazyLock<String> = LazyLock::new(|| {
    format!(
        "SELECT g.value, (t.year / 10) * 10 AS decade, COUNT(*) AS seen
  FROM ({HISTORY}) h
  CROSS JOIN title_tags g INDEXED BY idx_title_tags_title
    ON g.title_id = h.title_id AND g.kind = 'genre'
  CROSS JOIN titles t ON t.id = h.title_id
  WHERE t.year > 0
  GROUP BY g.value, decade
  HAVING seen >= ?2
  ORDER BY seen DESC, g.value, decade
  LIMIT ?3"
    )
});

/// How many watched titles a genre-and-decade pair needs before it is a taste
/// rather than an accident of two evenings.
const ERA_FLOOR: u32 = 3;

/// Unwatched titles of one genre and one decade, dealt by the day. The pool
/// behind a broad pair runs to hundreds on this library, so a fixed order
/// would show the same twenty of them for ever and never reach the rest:
/// `SHUFFLE` is what makes the row a different twenty tomorrow.
static ERA_UNSEEN: LazyLock<String> = LazyLock::new(|| {
    format!(
        "SELECT t.id, t.kind, t.name, t.year,
    (SELECT COUNT(*) FROM files c WHERE c.title_id = t.id) AS file_count,
    (SELECT c.id FROM files c WHERE c.title_id = t.id ORDER BY c.quality DESC, c.id LIMIT 1) AS first_file_id
  FROM title_tags g
  CROSS JOIN titles t ON t.id = g.title_id
  WHERE g.kind = 'genre' AND g.value = ?1
    AND t.year >= ?2 AND t.year < ?2 + 10
    AND NOT EXISTS (SELECT 1 FROM watch_state w JOIN files c ON c.id = w.file_id
                    WHERE c.title_id = t.id)
    AND EXISTS (SELECT 1 FROM files c WHERE c.title_id = t.id)
    AND NOT {POORLY_RATED}
  ORDER BY {shuffle}, t.id
  LIMIT ?4",
        shuffle = SHUFFLE.replace("DAY", "?3")
    )
});

/// Where the step-aside row's reach is kept, and how far back a gem has to
/// have been sitting to count as forgotten: a year, which is long enough that
/// the taste that ignored it then is not the taste reading the row now.
const STEP_ASIDE_REACH: &str = "step_aside.reach";
const GEM_AGE_SECS: i64 = 365 * 86_400;

/// The discovery band within the asked-for reach, never anything played.
static ASIDE: LazyLock<String> = LazyLock::new(|| {
    format!(
        "SELECT t.id, t.kind, t.name, t.year,
    (SELECT COUNT(*) FROM files c WHERE c.title_id = t.id) AS file_count,
    (SELECT c.id FROM files c WHERE c.title_id = t.id ORDER BY c.quality DESC, c.id LIMIT 1) AS first_file_id
  FROM discovery_pick p
  CROSS JOIN titles t ON t.id = p.title_id
  WHERE p.closeness >= ?1 AND p.closeness <= ?2
    AND NOT EXISTS (SELECT 1 FROM watch_state w JOIN files f ON f.id = w.file_id
                    WHERE f.title_id = t.id)
    AND NOT {POORLY_RATED}
    AND NOT EXISTS (SELECT 1 FROM title_verdict v WHERE v.title_id = t.id)
    AND EXISTS (SELECT 1 FROM files c WHERE c.title_id = t.id)
  ORDER BY p.rank LIMIT ?3"
    )
});

/// The library against one anchor, a season's or a mood's, best first.
const SEASONAL: &str = "SELECT t.id, t.kind, t.name, t.year,
    (SELECT COUNT(*) FROM files c WHERE c.title_id = t.id) AS file_count,
    (SELECT c.id FROM files c WHERE c.title_id = t.id ORDER BY c.quality DESC, c.id LIMIT 1) AS first_file_id
  FROM seasonal_pick p
  CROSS JOIN titles t ON t.id = p.title_id
  WHERE p.window = ?1
    AND NOT EXISTS (SELECT 1 FROM watch_state w JOIN files f ON f.id = w.file_id
                    WHERE f.title_id = t.id)
    AND NOT EXISTS (SELECT 1 FROM title_verdict v WHERE v.title_id = t.id)
    AND NOT EXISTS (SELECT 1 FROM stage_show s WHERE s.title_id = t.id)
    AND EXISTS (SELECT 1 FROM files c WHERE c.title_id = t.id)
  ORDER BY p.rank LIMIT ?2";

/// The forgotten gems, each with the facet leader that explains it. Ordered
/// by the week's own deal over the qualifying picks, so the row is the same
/// all week and a different one the next.
static GEM: LazyLock<String> = LazyLock::new(|| {
    format!(
        "SELECT t.id, t.kind, t.name, t.year,
    (SELECT COUNT(*) FROM files c WHERE c.title_id = t.id) AS file_count,
    (SELECT c.id FROM files c WHERE c.title_id = t.id ORDER BY c.quality DESC, c.id LIMIT 1) AS first_file_id,
    l.name
  FROM taste_pick p
  CROSS JOIN titles t ON t.id = p.title_id
  LEFT JOIN titles l ON l.id = p.leader
  WHERE t.added_at > 0 AND t.added_at <= ?1
    AND NOT EXISTS (SELECT 1 FROM watch_state w JOIN files f ON f.id = w.file_id
                    WHERE f.title_id = t.id)
    AND NOT EXISTS (SELECT 1 FROM title_verdict v WHERE v.title_id = t.id)
    AND NOT {POORLY_RATED}
    AND EXISTS (SELECT 1 FROM files c WHERE c.title_id = t.id)
  ORDER BY (p.rank * 2654435761 + ?2) % 1000, p.rank
  LIMIT ?3"
    )
});

/// Every member of the running thread in its own order, each with whether it
/// has been watched: the row shows what is left, and the label counts what is
/// done out of the whole.
const THREAD: &str = "SELECT t.id, t.kind, t.name, t.year,
    (SELECT COUNT(*) FROM files c WHERE c.title_id = t.id) AS file_count,
    (SELECT c.id FROM files c WHERE c.title_id = t.id ORDER BY c.quality DESC, c.id LIMIT 1) AS first_file_id,
    EXISTS (SELECT 1 FROM watch_state w JOIN files f ON f.id = w.file_id
            WHERE f.title_id = t.id AND w.watched = 1) AS seen
  FROM thread_item i
  CROSS JOIN titles t ON t.id = i.title_id
  WHERE EXISTS (SELECT 1 FROM files c WHERE c.title_id = t.id)
  ORDER BY i.rank";

/// Titles nothing has ever played, newest on the shelf first. The index is
/// pinned because the order has to be a walk that stops at the limit: sorted
/// instead, the row costs a pass over every title in the library.
/// What arrived, and nothing else. No filter on what has been played, unlike
/// every recommendation beside it: this row is a statement about the library
/// rather than a suggestion, and a viewer told "recently added" is owed the
/// fact. Hiding a film they had sampled made the row disagree with the shelf
/// its own last tile opens, which sorts on the same column and filters
/// nothing - two answers to one question, an arrow apart.
const RECENT: &str = "SELECT id, kind, name, year, file_count, first_file_id FROM (
  SELECT * FROM (SELECT t.id, t.kind, t.name, t.year, t.added_at,
    (SELECT COUNT(*) FROM files c WHERE c.title_id = t.id) AS file_count,
    (SELECT c.id FROM files c WHERE c.title_id = t.id ORDER BY c.quality DESC, c.id LIMIT 1) AS first_file_id
    FROM titles t INDEXED BY idx_titles_kind_added
    WHERE t.kind = 'movie' AND EXISTS (SELECT 1 FROM files c WHERE c.title_id = t.id)
    ORDER BY t.added_at DESC, t.id DESC LIMIT ?1)
  UNION ALL
  SELECT * FROM (SELECT t.id, t.kind, t.name, t.year, t.added_at,
    (SELECT COUNT(*) FROM files c WHERE c.title_id = t.id) AS file_count,
    (SELECT c.id FROM files c WHERE c.title_id = t.id ORDER BY c.quality DESC, c.id LIMIT 1) AS first_file_id
    FROM titles t INDEXED BY idx_titles_kind_added
    WHERE t.kind = 'show' AND EXISTS (SELECT 1 FROM files c WHERE c.title_id = t.id)
    ORDER BY t.added_at DESC, t.id DESC LIMIT ?1))
  ORDER BY added_at DESC, id DESC";

/// The library's share of the week's trending of one kind, most first.
const POPULAR: &str = "SELECT t.id, t.kind, t.name, t.year,
    (SELECT COUNT(*) FROM files c WHERE c.title_id = t.id) AS file_count,
    (SELECT c.id FROM files c WHERE c.title_id = t.id ORDER BY c.quality DESC, c.id LIMIT 1) AS first_file_id
  FROM tmdb_trending tr
  JOIN metadata m ON m.tmdb_id = tr.tmdb_id
  JOIN titles t ON t.id = m.title_id AND t.kind = tr.kind
  WHERE tr.kind = ?2 AND EXISTS (SELECT 1 FROM files c WHERE c.title_id = t.id)
  ORDER BY tr.rank
  LIMIT ?1";

/// Stage shows not yet seen, newest on the shelf first.
const STAGE: &str = "SELECT t.id, t.kind, t.name, t.year,
    (SELECT COUNT(*) FROM files c WHERE c.title_id = t.id) AS file_count,
    (SELECT c.id FROM files c WHERE c.title_id = t.id ORDER BY c.quality DESC, c.id LIMIT 1) AS first_file_id
  FROM stage_show s
  CROSS JOIN titles t ON t.id = s.title_id
  WHERE NOT EXISTS (SELECT 1 FROM watch_state w JOIN files f ON f.id = w.file_id
                    WHERE f.title_id = t.id)
    AND NOT EXISTS (SELECT 1 FROM title_verdict v WHERE v.title_id = t.id)
    AND EXISTS (SELECT 1 FROM files c WHERE c.title_id = t.id)
  ORDER BY t.added_at DESC, t.id DESC
  LIMIT ?1";

/// A shuffle by a seed that is the day: a row holds still while the user looks
/// at it, and is another one tomorrow. `DAY` is the placeholder each reader
/// binds its own parameter to.
///
/// The order is an avalanche of the id and the day: the day is spread, XORed
/// into the id, then two shift-add-multiply rounds. The id and the day must mix
/// rather than add, because title ids are dense and handed out in directory
/// order: a hash of their sum orders tomorrow's row by the same function one id
/// over, which slides the row through the library shelf by shelf.
///
/// `(a | b) - (a & b)` is XOR, which SQLite has no operator for, and every
/// round is masked to 30 bits so no product can overflow an i64 into a float.
const SHUFFLE: &str = "(SELECT ((u + (u >> 13)) * 3266489917) & 1073741823 FROM
             (SELECT (((s + (s >> 15)) * 2246822519) & 1073741823) AS u FROM
               (SELECT (((t.id | d) - (t.id & d)) & 1073741823) AS s FROM
                 (SELECT DAY * 2654435761 AS d))))";

/// Titles nothing has ever played, dealt by the day. This is the row the long
/// tail of the library is reachable through at all: twenty a day off a shelf
/// of thousands, in an order that is a different twenty tomorrow.
static REDISCOVERY: LazyLock<String> = LazyLock::new(|| {
    format!(
        "SELECT t.id, t.kind, t.name, t.year,
    (SELECT COUNT(*) FROM files c WHERE c.title_id = t.id) AS file_count,
    (SELECT c.id FROM files c WHERE c.title_id = t.id ORDER BY c.quality DESC, c.id LIMIT 1) AS first_file_id
  FROM titles t
  WHERE NOT EXISTS (SELECT 1 FROM watch_state w JOIN files f ON f.id = w.file_id
                    WHERE f.title_id = t.id)
    AND EXISTS (SELECT 1 FROM files c WHERE c.title_id = t.id)
    AND NOT EXISTS (SELECT 1 FROM title_verdict v WHERE v.title_id = t.id)
    AND NOT {POORLY_RATED}
  ORDER BY {shuffle}, t.id
  LIMIT ?2",
        shuffle = SHUFFLE.replace("DAY", "?1")
    )
});

/// Titles watched once and not since, dealt by the day like rediscovery: the
/// other half of the long tail, the part the viewer has seen and forgotten
/// rather than never opened.
static LONG_AGO: LazyLock<String> = LazyLock::new(|| {
    format!(
        "SELECT t.id, t.kind, t.name, t.year,
    (SELECT COUNT(*) FROM files c WHERE c.title_id = t.id) AS file_count,
    (SELECT c.id FROM files c WHERE c.title_id = t.id ORDER BY c.quality DESC, c.id LIMIT 1) AS first_file_id
  FROM watch_state w
  CROSS JOIN files f ON f.id = w.file_id
  CROSS JOIN titles t ON t.id = f.title_id
  WHERE w.watched = 1
  GROUP BY t.id
  HAVING MAX(w.updated_at) < ?1
  ORDER BY {shuffle}, t.id
  LIMIT ?3",
        shuffle = SHUFFLE.replace("DAY", "?2")
    )
});

/// How long ago "long ago" is. Three years: long enough that the evening is a
/// memory rather than a repeat, and this library's history reaches back seven.
const LONG_AGO_SECS: i64 = 3 * 365 * 86_400;

/// A title's own kind and TMDB id, the two keys `SIMILAR` searches from. The
/// detail screen only carries a title id, unlike the home row's seed, which
/// already has both off the watch state it was picked from.
const OWN: &str = "SELECT t.kind, m.tmdb_id FROM titles t
  LEFT JOIN metadata m ON m.title_id = t.id
  WHERE t.id = ?1";

/// Other titles carrying the most values in common with this one, of one
/// `title_tags` kind: genre, cast or collection. `mine` is this title's own
/// handful of rows; `idx_title_tags_lookup` turns the join from `mine` into
/// `g` into a lookup per value rather than a walk of every tagged title, and
/// the same index answers `mine` itself. A title with no tag of this kind
/// joins to nothing, and the row is left out the way an empty similar row is.
/// Ties go to the nearest year: a film of its era reads as a neighbour where
/// the next name in the alphabet reads as a list. An unknown year is last.
const SAME_TAG: &str = "SELECT t.id, t.kind, t.name, t.year,
    (SELECT COUNT(*) FROM files c WHERE c.title_id = t.id) AS file_count,
    (SELECT c.id FROM files c WHERE c.title_id = t.id ORDER BY c.quality DESC, c.id LIMIT 1) AS first_file_id
  FROM (
    SELECT g.title_id AS id, COUNT(*) AS shared
      FROM title_tags mine
      JOIN title_tags g ON g.kind = mine.kind AND g.value = mine.value
        AND g.title_id <> mine.title_id
      WHERE mine.title_id = ?1 AND mine.kind = ?2
      GROUP BY g.title_id
  ) f
  JOIN titles t ON t.id = f.id
  JOIN titles own ON own.id = ?1
  WHERE t.kind = ?3 AND EXISTS (SELECT 1 FROM files c WHERE c.title_id = t.id)
  ORDER BY f.shared DESC,
    CASE WHEN t.year = 0 OR own.year = 0 THEN 10000 ELSE ABS(t.year - own.year) END,
    t.name COLLATE NOCASE, t.id
  LIMIT ?4";

/// Titles sharing the most genres with this one. Kept to the same kind: a
/// film and a show tagged the same genre are not the recommendation this rail
/// means.
pub fn same_genre(
    db: &Db,
    title_id: i64,
    kind: MediaKind,
    limit: u32,
) -> Result<Vec<TitleRow>, IndexError> {
    titles(
        db,
        SAME_TAG,
        params![title_id, "genre", kind.as_str(), limit],
    )
}

/// Titles a lead actor of this one recurs in. Short lists are the point: a
/// cast in common is a stronger, rarer signal than a shared genre, worth
/// showing even with one title in it.
pub fn same_cast(
    db: &Db,
    title_id: i64,
    kind: MediaKind,
    limit: u32,
) -> Result<Vec<TitleRow>, IndexError> {
    titles(
        db,
        SAME_TAG,
        params![title_id, "cast", kind.as_str(), limit],
    )
}

/// Titles Plex tags into the same collection as this one. Empty for the
/// ordinary title, which belongs to none: see `title_tags` in the schema for
/// where "collection" comes from.
pub fn same_saga(
    db: &Db,
    title_id: i64,
    kind: MediaKind,
    limit: u32,
) -> Result<Vec<TitleRow>, IndexError> {
    titles(
        db,
        SAME_TAG,
        params![title_id, "collection", kind.as_str(), limit],
    )
}

/// Everything in this library credited to one name under one `title_tags`
/// kind. `idx_title_tags_lookup` answers the (kind, value) pair directly, so
/// this costs the titles that carry the name and nothing else - no scan, no
/// TMDB id, and the same answer for every name in the library rather than
/// only for the matched ones.
///
/// Newest first: a filmography is read by what someone did lately, and a name
/// with forty credits would otherwise open on the oldest of them.
const BY_TAG: &str = "SELECT t.id, t.kind, t.name, t.year,
    (SELECT COUNT(*) FROM files c WHERE c.title_id = t.id) AS file_count,
    (SELECT c.id FROM files c WHERE c.title_id = t.id ORDER BY c.quality DESC, c.id LIMIT 1) AS first_file_id
  FROM title_tags g
  JOIN titles t ON t.id = g.title_id
  WHERE g.kind = ?1 AND g.value = ?2
    AND EXISTS (SELECT 1 FROM files c WHERE c.title_id = t.id)
  ORDER BY t.year DESC, t.name COLLATE NOCASE, t.id
  LIMIT ?3";

/// What this library holds of one person's work in one role. The two roles a
/// name is tagged under, "cast" and "director", are the same query with a
/// different first argument: a person's page is one screen for both, because
/// the index makes no distinction between them either.
pub fn credited_to(
    db: &Db,
    role: &str,
    name: &str,
    limit: u32,
) -> Result<Vec<TitleRow>, IndexError> {
    titles(db, BY_TAG, params![role, name, limit])
}

/// The neighbours of one title, for its own detail screen. The same fused
/// query and order as "because you watched", with this title standing in for
/// the seed. Empty is the ordinary answer, not a failure: `similar_semantic`
/// holds only the neighbours of titles the sweep has reached, and
/// `tmdb_similar` is empty until `fetch_similar_pending` has run.
pub fn similar_titles(db: &Db, title_id: i64, limit: u32) -> Result<Vec<TitleRow>, IndexError> {
    let Some((kind, tmdb_id)) = seed_keys(db, title_id)? else {
        return Ok(Vec::new());
    };
    titles(db, SIMILAR, params![kind, tmdb_id, title_id, limit])
}

fn seed_keys(db: &Db, title_id: i64) -> Result<Option<(String, Option<i64>)>, IndexError> {
    let mut stmt = db.conn().prepare_cached(OWN)?;
    let mut rows = stmt.query(params![title_id])?;
    let Some(r) = rows.next()? else {
        return Ok(None);
    };
    Ok(Some((r.get(0)?, r.get(1)?)))
}

/// The home screen: every row the library can fill, ranked and cut to what
/// fits. Read-only and indexed throughout, so this stays the cheap query the
/// first screen after launch runs rather than anything that belongs on a pass.
///
/// `shown` is what the screen already carries above the rows. A title says
/// its reason once per screen, so the rows drop it, and a row left under its
/// floor goes. Recently added is the exception, for the reason `select` gives.
pub fn browse_rows(
    db: &Db,
    kind: Option<MediaKind>,
    now: i64,
    tz_offset_secs: i32,
    shown: &HashSet<i64>,
) -> Result<Vec<Row>, IndexError> {
    // the day is the only thing here that is not the data: a shelf holds
    // still while the viewer looks at it, and is dealt again tomorrow
    let epoch = (now + i64::from(tz_offset_secs)).div_euclid(86_400);
    let mut pool = candidates(db, now, epoch, tz_offset_secs, ROW_LIMIT)?;
    // The kind is cut here rather than in twenty queries. Most rows hold one
    // kind already, having been built from a collection or a person's credits,
    // and a row that loses half its items to the cut still has a shelf's
    // worth: the floor below is what decides whether it survives.
    //
    // No kind is the home, which mixes them: a shelf is films or series, an
    // evening is neither.
    //
    // A recommendation also drops what the viewer has already answered: a
    // title read twice on its page and never started, and one a taste row
    // has shown twice as long as it takes to sink to the back of it.
    let exposure = db.row_exposure(epoch - super::tonight::FATIGUE_EVENINGS)?;
    let worn = |id: i64| {
        exposure
            .get(&id)
            .is_some_and(|(shows, last)| shows - u32::from(*last == epoch) >= 2 * TIRED_DAYS)
    };
    let passed = db.passed_over(now - PASSED_OVER_SECS)?;
    for candidate in &mut pool {
        let fact = matches!(
            candidate.reason,
            Reason::RecentlyAdded | Reason::Watchlist | Reason::Popular { .. }
        );
        let chosen = fact || keeps_order(&candidate.reason);
        let tiring = tires(&candidate.reason);
        let keep = |t: &TitleRow| {
            kind.is_none_or(|k| t.kind == k)
                && (fact || !shown.contains(&t.id))
                && (chosen || !passed.contains(&t.id))
                && !(tiring && worn(t.id))
        };
        if candidate.places.is_empty() {
            candidate.items.retain(keep);
        } else {
            (candidate.items, candidate.places) = std::mem::take(&mut candidate.items)
                .into_iter()
                .zip(std::mem::take(&mut candidate.places))
                .filter(|(t, _)| keep(t))
                .unzip();
        }
        // both kinds are read deep so a tab of one still fills its row
        if candidate.reason == Reason::RecentlyAdded {
            candidate.items.truncate(ROW_LIMIT as usize);
        }
    }
    pool.retain(|c| c.items.len() >= floor(&c.reason));
    // the club is dealt deep and cut here, after the filter above, so a
    // title already on the home is replaced rather than taking the row down
    for candidate in pool.iter_mut() {
        if matches!(candidate.reason, Reason::CineClub { .. }) {
            candidate.more = candidate.items.len() > CLUB_TITLES;
            candidate.items.truncate(CLUB_TITLES);
        }
    }
    let mut rows = select(pool);

    // A row that is a fact about the shelf leads with what the taste would
    // pick of it; any row but one in its own order holds back, during an
    // evening, a film that would run past the end of it.
    let window = super::tonight::Window::of(db, now, tz_offset_secs, None)?;
    let mut read = db.conn().prepare_cached(
        "SELECT COALESCE((SELECT affinity FROM title_taste WHERE title_id = ?1), 0),
                COALESCE((SELECT MAX(duration_secs) FROM files WHERE title_id = ?1), 0)",
    )?;
    for row in rows.iter_mut().filter(|r| !keeps_order(&r.reason)) {
        let by_taste = sorted_by_taste(&row.reason);
        if !by_taste && window.is_none() {
            continue;
        }
        let mut scored = Vec::with_capacity(row.items.len());
        for t in row.items.drain(..) {
            let (affinity, runtime): (f32, f64) =
                read.query_row(params![t.id], |r| Ok((r.get(0)?, r.get(1)?)))?;
            let late = window
                .as_ref()
                .is_some_and(|w| t.kind == MediaKind::Movie && runtime > 0.0 && !w.fits(runtime));
            let score = if by_taste { affinity } else { 0.0 } - if late { 1.0 } else { 0.0 };
            scored.push((score, t));
        }
        // stable: at equal scores the row's own order stands
        scored.sort_by(|a, b| b.0.total_cmp(&a.0));
        row.items = scored.into_iter().map(|(_, t)| t).collect();
    }

    // today's showing aside, so a row holds still through the day
    for row in rows.iter_mut().filter(|r| tires(&r.reason)) {
        row.items.sort_by_key(|t| {
            exposure
                .get(&t.id)
                .is_some_and(|(shows, last)| shows - u32::from(*last == epoch) >= TIRED_DAYS)
        });
    }
    Ok(rows)
}

/// How far back a page read and left counts against a title.
const PASSED_OVER_SECS: i64 = 30 * 86_400;

/// Rows whose order is what they say: what arrived, newest first, a saga's,
/// a thread's, the next episodes', the list's, and a date's.
fn keeps_order(reason: &Reason) -> bool {
    matches!(
        reason,
        Reason::RecentlyAdded
            | Reason::Sagas
            | Reason::Thread { .. }
            | Reason::UpNext
            | Reason::Tonight
            | Reason::Watchlist
            | Reason::Popular { .. }
            | Reason::OnThisDay { .. }
    )
}

/// Rows drawn by a fact about the shelf rather than by the taste, which the
/// taste may still order.
fn sorted_by_taste(reason: &Reason) -> bool {
    matches!(
        reason,
        Reason::Rediscovery
            | Reason::ByDirector { .. }
            | Reason::WithActor { .. }
            | Reason::GenreEra { .. }
            | Reason::StageShows
            | Reason::Retrospective { .. }
    )
}

/// How many titles of a row a rail shows before the viewer scrolls: the head
/// a row's showing is counted on, and so the part of it that tires.
pub const ROW_VISIBLE: usize = 6;

/// How many days a taste row may show a title the viewer does not launch
/// before it goes to the back of the row: a working week of being passed over.
const TIRED_DAYS: u32 = 5;

/// Whether a row speaks for the taste, and so wears out a title it keeps
/// offering. The shelves of facts and of names are what they are every day.
fn tires(reason: &Reason) -> bool {
    matches!(
        reason,
        Reason::TasteFacet { .. }
            | Reason::BecauseYouWatched { .. }
            | Reason::StepAside
            | Reason::Thread { .. }
            | Reason::ThisMonth { .. }
            | Reason::CineClub { .. }
    )
}

/// Counts today's showing of the head of every taste row, once per title
/// and day. Only the head: a whole row counted tires together, and a stable
/// sort of titles all equally tired moves nothing.
pub fn record_shown(
    db: &Db,
    rows: &[Row],
    now: i64,
    tz_offset_secs: i32,
) -> Result<(), IndexError> {
    let day = (now + i64::from(tz_offset_secs)).div_euclid(86_400);
    let kinds: Vec<&str> = rows.iter().map(|r| launch_detail(&r.reason)).collect();
    db.record_row_kinds(&kinds, day)?;
    let seeds: Vec<String> = rows
        .iter()
        .filter_map(|r| match &r.reason {
            Reason::BecauseYouWatched { seed_id, .. } => Some(seed_id.to_string()),
            _ => None,
        })
        .collect();
    let mut subjects: Vec<(&str, &str)> = rows
        .iter()
        .filter_map(|r| match &r.reason {
            Reason::WithActor { name } => Some(("cast", name.as_str())),
            Reason::ByDirector { name } => Some(("director", name.as_str())),
            _ => None,
        })
        .collect();
    subjects.extend(seeds.iter().map(|id| (SEED_SUBJECT, id.as_str())));
    db.record_row_subjects(&subjects, day)?;
    let titles: Vec<i64> = rows
        .iter()
        .filter(|r| tires(&r.reason))
        .flat_map(|r| r.items.iter().take(ROW_VISIBLE).map(|t| t.id))
        .collect();
    if titles.is_empty() {
        return Ok(());
    }
    db.record_row_exposure(&titles, day, super::tonight::FATIGUE_EVENINGS)
}

/// Every row the data supports, each already placed by its kind and ordered
/// within its kind by what the history says and what the day picked.
fn candidates(
    db: &Db,
    now: i64,
    epoch: i64,
    tz_offset_secs: i32,
    limit: u32,
) -> Result<Vec<Candidate>, IndexError> {
    let mut pool = Vec::new();
    let learned = learned(db, epoch)?;

    // a saga already begun is the strongest thing this index can say, and the
    // one that costs nothing to believe: the viewer picked the collection
    let (items, places) = sagas(db)?.into_iter().unzip();
    offer(&mut pool, &learned, Reason::Sagas, epoch, items);
    if let Some(row) = pool.last_mut().filter(|c| c.reason == Reason::Sagas) {
        row.places = places;
    }

    let rested = db.rested_subjects(epoch)?;
    let awake = |kind: &str, names: Vec<String>| -> Vec<String> {
        names
            .into_iter()
            .filter(|n| !rested.contains(&(kind.to_string(), n.clone())))
            .collect()
    };
    let mut awake_seeds = seeds(db, now)?;
    awake_seeds.retain(|s| !rested.contains(&(SEED_SUBJECT.to_string(), s.id.to_string())));
    for seed in chosen(awake_seeds, epoch, "watched", |s: &Seed| s.id.to_string()) {
        let items = titles(
            db,
            &SIMILAR_UNSEEN,
            params![seed.kind, seed.tmdb_id, seed.id, limit],
        )?;
        offer(
            &mut pool,
            &learned,
            Reason::BecauseYouWatched {
                seed: seed.name,
                seed_id: seed.id,
            },
            epoch,
            items,
        );
    }

    for (leader, leader_id, items) in facets(db, epoch, now, tz_offset_secs)? {
        offer(
            &mut pool,
            &learned,
            Reason::TasteFacet { leader, leader_id },
            epoch,
            items,
        );
    }

    offer(
        &mut pool,
        &learned,
        Reason::StepAside,
        epoch,
        step_aside(db)?,
    );

    if let Some(window) = open_season(now, tz_offset_secs) {
        let items = titles(db, SEASONAL, params![window, limit])?;
        offer(
            &mut pool,
            &learned,
            Reason::Season {
                window: window.to_string(),
            },
            epoch,
            items,
        );
    }

    if let Some((seed, items)) = forgotten_gems(db, now, epoch)? {
        offer(
            &mut pool,
            &learned,
            Reason::ForgottenGem { seed },
            epoch,
            items,
        );
    }

    if let Some((leader, done, total, items)) = thread(db)? {
        offer(
            &mut pool,
            &learned,
            Reason::Thread {
                leader,
                done,
                total,
            },
            epoch,
            items,
        );
    }

    for name in chosen(
        awake("director", tag_subjects(db, "director", DIRECTOR_FLOOR)?),
        epoch,
        "director",
        String::clone,
    ) {
        let items = titles(db, &TAG_UNSEEN, params!["director", name, limit])?;
        offer(
            &mut pool,
            &learned,
            Reason::ByDirector { name },
            epoch,
            items,
        );
    }

    for name in chosen(
        awake("cast", tag_subjects(db, "cast", ACTOR_FLOOR)?),
        epoch,
        "actor",
        String::clone,
    ) {
        let items = titles(db, &TAG_UNSEEN, params!["cast", name, limit])?;
        offer(
            &mut pool,
            &learned,
            Reason::WithActor { name },
            epoch,
            items,
        );
    }

    // what arrived leads the news whether or not anything arrived today: it
    // is where this viewer picks from, far more than from the taste rows
    let items = titles(db, RECENT, params![limit])?;
    offer(&mut pool, &learned, Reason::RecentlyAdded, epoch, items);

    for (kind, items) in on_this_day(db, now, tz_offset_secs, limit)? {
        offer(
            &mut pool,
            &learned,
            Reason::OnThisDay { kind },
            epoch,
            items,
        );
    }

    for name in retrospectives(db, now)? {
        let items = titles(db, RETRO, params![name, limit])?;
        offer(
            &mut pool,
            &learned,
            Reason::Retrospective { name },
            epoch,
            items,
        );
    }

    if let Some((month, leader, items)) = this_month(db, now, tz_offset_secs)? {
        offer(
            &mut pool,
            &learned,
            Reason::ThisMonth { month, leader },
            epoch,
            items,
        );
    }

    if let Some((theme, ends_at, items)) = cine_club(db, now, tz_offset_secs, limit)? {
        offer(
            &mut pool,
            &learned,
            Reason::CineClub { theme, ends_at },
            epoch,
            items,
        );
    }

    offer(
        &mut pool,
        &learned,
        Reason::Watchlist,
        epoch,
        super::queries::watchlist(db, limit)?,
    );
    for kind in [MediaKind::Movie, MediaKind::Show] {
        offer(
            &mut pool,
            &learned,
            Reason::Popular {
                series: kind == MediaKind::Show,
            },
            epoch,
            titles(db, POPULAR, params![limit, kind.as_str()])?,
        );
    }
    offer(
        &mut pool,
        &learned,
        Reason::StageShows,
        epoch,
        titles(db, STAGE, params![limit])?,
    );

    for (genre, decade) in chosen(era_subjects(db)?, epoch, "era", |(g, d): &(String, u16)| {
        format!("{g}:{d}")
    }) {
        let items = titles(
            db,
            &ERA_UNSEEN,
            params![
                genre,
                decade,
                deal_seed(epoch, &format!("era:{genre}:{decade}")),
                limit
            ],
        )?;
        offer(
            &mut pool,
            &learned,
            Reason::GenreEra { genre, decade },
            epoch,
            items,
        );
    }

    offer(&mut pool, &learned, Reason::LongAgo, epoch, {
        titles(
            db,
            &LONG_AGO,
            params![now - LONG_AGO_SECS, deal_seed(epoch, "longago"), limit],
        )?
    });
    offer(&mut pool, &learned, Reason::Rediscovery, epoch, {
        titles(
            db,
            &REDISCOVERY,
            params![deal_seed(epoch, "rediscovery"), limit],
        )?
    });

    Ok(pool)
}

/// How deep one row goes when it is opened as a screen of its own. A rail
/// shows six of its twenty and the rest are reachable only by holding right;
/// a row that is a place shows what it actually holds.
pub const OPENED_LIMIT: u32 = 200;

/// Everything one row holds, past the handful a rail draws. A row named by
/// its own parameters runs its own query; the few whose content depends on
/// the rest of the deal are found by building the whole pool.
pub fn row_items(
    db: &Db,
    reason: &Reason,
    now: i64,
    tz_offset_secs: i32,
) -> Result<Vec<TitleRow>, IndexError> {
    let limit = OPENED_LIMIT;
    let epoch = (now + i64::from(tz_offset_secs)).div_euclid(86_400);
    let kind = |series: bool| {
        if series {
            MediaKind::Show
        } else {
            MediaKind::Movie
        }
        .as_str()
    };
    let items = match reason {
        Reason::Sagas => Ok(sagas(db)?.into_iter().map(|(t, _)| t).collect()),
        Reason::UpNext => Ok(super::queries::up_next(db, limit, now)?
            .into_iter()
            .map(|q| q.title)
            .collect()),
        Reason::Tonight => Ok(
            match super::tonight::compose_tonight(db, now, tz_offset_secs, None)? {
                Some((trio, _)) => trio
                    .cards
                    .into_iter()
                    .map(|c| c.title)
                    .chain(trio.more)
                    .collect(),
                None => Vec::new(),
            },
        ),
        Reason::Mood { key } => return titles(db, SEASONAL, params![key, limit]),
        Reason::Season { window } => titles(db, SEASONAL, params![window, limit]),
        Reason::WithActor { name } => titles(db, &TAG_UNSEEN, params!["cast", name, limit]),
        Reason::ByDirector { name } => titles(db, &TAG_UNSEEN, params!["director", name, limit]),
        Reason::BecauseYouWatched { seed_id, .. } => match seed_keys(db, *seed_id)? {
            Some((kind, tmdb_id)) => {
                titles(db, &SIMILAR_UNSEEN, params![kind, tmdb_id, seed_id, limit])
            }
            None => Ok(Vec::new()),
        },
        Reason::GenreEra { genre, decade } => titles(
            db,
            &ERA_UNSEEN,
            params![
                genre,
                decade,
                deal_seed(epoch, &format!("era:{genre}:{decade}")),
                limit
            ],
        ),
        Reason::RecentlyAdded => titles(db, RECENT, params![limit]),
        Reason::Popular { series } => titles(db, POPULAR, params![limit, kind(*series)]),
        Reason::Retrospective { name } => titles(db, RETRO, params![name, limit]),
        Reason::LongAgo => titles(
            db,
            &LONG_AGO,
            params![now - LONG_AGO_SECS, deal_seed(epoch, "longago"), limit],
        ),
        Reason::Rediscovery => titles(
            db,
            &REDISCOVERY,
            params![deal_seed(epoch, "rediscovery"), limit],
        ),
        Reason::StepAside => step_aside(db),
        Reason::Watchlist => super::queries::watchlist(db, limit),
        Reason::StageShows => titles(db, STAGE, params![limit]),
        _ => {
            return Ok(candidates(db, now, epoch, tz_offset_secs, limit)?
                .into_iter()
                .find(|c| &c.reason == reason)
                .map(|c| c.items)
                .unwrap_or_default())
        }
    }?;
    // a row too short to be offered is not one to open either
    Ok(if items.len() < floor(reason) {
        Vec::new()
    } else {
        items
    })
}

/// The moods with enough unseen titles behind them to be worth a press, in
/// the order `taste::MOODS` lists them, each with the shelf's worth of
/// titles that proved it: what a tile for it is drawn with.
pub fn moods(db: &Db) -> Result<Vec<(&'static str, Vec<i64>)>, IndexError> {
    let mut out = Vec::new();
    for (key, _) in super::taste::MOODS {
        let shelf = titles(db, SEASONAL, params![key, SHELF as u32])?;
        if shelf.len() >= SHELF {
            out.push((key, shelf.into_iter().map(|t| t.id).collect()));
        }
    }
    Ok(out)
}

/// Adds a candidate to the pool, unless it is too short to be worth a shelf.
fn offer(
    pool: &mut Vec<Candidate>,
    learned: &HashMap<String, f32>,
    reason: Reason,
    epoch: i64,
    items: Vec<TitleRow>,
) {
    if items.len() < floor(&reason) {
        return;
    }
    let place = rank(&reason)
        + ORDER_SPREAD * wobble(epoch, kind_key(&reason))
        + learned.get(launch_detail(&reason)).copied().unwrap_or(0.0);
    pool.push(Candidate {
        chapter: chapter(&reason),
        reason,
        more: items.len() >= ROW_LIMIT as usize,
        items,
        places: Vec::new(),
        place,
    });
}

/// How far each kind of row has moved from its place on what the viewer
/// launches from it, keyed by `launch_detail`. A kind is rated on its
/// launches per day offered, so a row is not rewarded for being on top, and
/// pulled towards the mean of all rows until it has a record of its own:
/// four times the mean rate is a whole tier up, a quarter of it a tier down.
fn learned(db: &Db, epoch: i64) -> Result<HashMap<String, f32>, IndexError> {
    let record = db.row_kind_record(epoch - LEARN_WINDOW_DAYS)?;
    let days: u32 = record.values().map(|r| r.0).sum();
    let launches: u32 = record.values().map(|r| r.1).sum();
    if days == 0 || launches == 0 {
        return Ok(HashMap::new());
    }
    let mean = launches as f32 / days as f32;
    Ok(record
        .into_iter()
        .map(|(kind, (days, launches))| {
            let rate =
                (launches as f32 + LEARN_PRIOR_DAYS * mean) / (days as f32 + LEARN_PRIOR_DAYS);
            (
                kind,
                ORDER_SPREAD * ((rate / mean).ln() / 4f32.ln()).clamp(-1.0, 1.0),
            )
        })
        .collect())
}

/// What a launch from a row of this kind is filed under, and what the row's
/// days on the home are counted under beside it.
pub fn launch_detail(reason: &Reason) -> &'static str {
    match reason {
        Reason::BecauseYouWatched { .. } => "because_you_watched",
        Reason::TasteFacet { .. } => "taste_facet",
        Reason::Sagas => "saga",
        Reason::WithActor { .. } => "with_actor",
        Reason::ByDirector { .. } => "by_director",
        Reason::GenreEra { .. } => "genre_era",
        Reason::RecentlyAdded => "recently_added",
        Reason::Popular { .. } => "popular",
        Reason::LongAgo => "long_ago",
        Reason::Rediscovery => "rediscovery",
        Reason::StepAside => "step_aside",
        Reason::Season { .. } => "season",
        Reason::ForgottenGem { .. } => "forgotten_gem",
        Reason::Thread { .. } => "thread",
        Reason::Mood { .. } => "mood",
        Reason::OnThisDay { .. } => "on_this_day",
        Reason::Retrospective { .. } => "retrospective",
        Reason::ThisMonth { .. } => "this_month",
        Reason::CineClub { .. } => "cine_club",
        Reason::UpNext => "up_next",
        Reason::Tonight => "tonight",
        Reason::StageShows => "stage_shows",
        Reason::Watchlist => "watchlist",
    }
}

/// The step-aside row: the discovery band, cut by how far aside the viewer
/// asked to be taken. The reach is a setting the core reads itself, so the
/// row answers the same on every screen that draws it.
fn step_aside(db: &Db) -> Result<Vec<TitleRow>, IndexError> {
    let (low, high) = match db.setting(STEP_ASIDE_REACH)?.as_deref() {
        // near the taste's own edge: a stranger, but a mild one
        Some("close") => (0.5, 1.0),
        // out at the library's background, where the surprises are
        Some("far") => (0.0, 0.5),
        _ => (0.0, 1.0),
    };
    titles(db, &ASIDE, params![low, high, ROW_LIMIT])
}

/// Which seasonal window today falls in, if any. Local dates, because a
/// window is a thing on a calendar hanging in the viewer's own room.
fn open_season(now: i64, tz_offset_secs: i32) -> Option<&'static str> {
    let (_, month, day) = civil(now + i64::from(tz_offset_secs));
    match month {
        10 => Some("oct"),
        // up to Boxing Day: a Christmas row on the 28th is a row about
        // something that has already happened
        12 if day <= 26 => Some("dec"),
        7 | 8 => Some("summer"),
        6 if day >= 21 => Some("summer"),
        _ => None,
    }
}

/// The civil year, month and day of a local timestamp. The proleptic
/// Gregorian arithmetic is here rather than in a dependency: a date crate for
/// a handful of calendar questions is a dependency to keep current forever.
fn civil(local: i64) -> (i64, u32, u32) {
    // days since 1970-01-01, shifted to a calendar starting in March, where
    // the leap day is the last day of the year and every month length falls
    // out of one formula
    let days = local.div_euclid(86_400) + 719_468;
    let era = days.div_euclid(146_097);
    let doe = days.rem_euclid(146_097);
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let day = (doy - (153 * mp + 2) / 5 + 1) as u32;
    let month = if mp < 10 { mp + 3 } else { mp - 9 } as u32;
    let year = yoe + era * 400 + i64::from(month <= 2);
    (year, month, day)
}

/// The day number of a civil date, the inverse of `civil`. A day past the end
/// of its month runs on into the next, which is where a 29 February lands on
/// a year that has none.
fn days_of(year: i64, month: u32, day: u32) -> i64 {
    let year = year - i64::from(month <= 2);
    let era = year.div_euclid(400);
    let yoe = year.rem_euclid(400);
    let mp = i64::from((month + 9) % 12);
    let doy = (153 * mp + 2) / 5 + i64::from(day) - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    era * 146_097 + doe - 719_468
}

/// The week's forgotten gems: added long ago, never played, and squarely in
/// the taste the viewer has now, with the seed the first is explained by.
///
/// Weekly rather than daily: the whole point is that these titles have been
/// sitting there for a year, and a row that changed every morning would read
/// as a shelf rather than as a find.
fn forgotten_gems(
    db: &Db,
    now: i64,
    epoch: i64,
) -> Result<Option<(String, Vec<TitleRow>)>, IndexError> {
    let week = epoch.div_euclid(7);
    let mut stmt = db.conn().prepare_cached(&GEM)?;
    let mut rows = stmt.query(params![
        now - GEM_AGE_SECS,
        deal_seed(week, "gem"),
        ROW_LIMIT
    ])?;
    let mut seed = None;
    let mut items = Vec::new();
    while let Some(r) = rows.next()? {
        if seed.is_none() {
            seed = r.get::<_, Option<String>>(6)?;
        }
        items.push(row_to_title(r)?);
    }
    Ok(seed.map(|seed| (seed, items)))
}

/// Every title of one collection the library can play, in the order it was
/// made, each with whether it has been watched and whether it was ever
/// started.
const SAGA_MEMBERS: &str = "SELECT t.id, t.kind, t.name, t.year,
    (SELECT COUNT(*) FROM files c WHERE c.title_id = t.id) AS file_count,
    (SELECT c.id FROM files c WHERE c.title_id = t.id ORDER BY c.quality DESC, c.id LIMIT 1) AS first_file_id,
    EXISTS (SELECT 1 FROM watch_state w JOIN files f ON f.id = w.file_id
            WHERE f.title_id = t.id AND w.watched = 1) AS seen,
    EXISTS (SELECT 1 FROM watch_state w JOIN files f ON f.id = w.file_id
            WHERE f.title_id = t.id) AS touched
  FROM title_tags g
  CROSS JOIN titles t ON t.id = g.title_id
  WHERE g.kind = 'collection' AND g.value = ?1
    AND EXISTS (SELECT 1 FROM files c WHERE c.title_id = t.id)
  ORDER BY COALESCE(t.year, 9999), t.name COLLATE NOCASE, t.id";

/// The next title of each saga the history has begun, in the order the
/// history returns to them: the first one never started, in the saga's own
/// order, with where it stands. A saga with nothing left to start is done.
fn sagas(db: &Db) -> Result<Vec<(TitleRow, SagaPlace)>, IndexError> {
    let mut stmt = db.conn().prepare_cached(SAGA_MEMBERS)?;
    let mut out: Vec<(TitleRow, SagaPlace)> = Vec::new();
    for name in tag_subjects(db, "collection", 1)? {
        let mut size = 0;
        let mut watched = 0;
        let mut next = None;
        let mut rows = stmt.query([&name])?;
        while let Some(r) = rows.next()? {
            size += 1;
            if r.get::<_, bool>(6)? {
                watched += 1;
            } else if next.is_none() && !r.get::<_, bool>(7)? {
                next = Some((row_to_title(r)?, size));
            }
        }
        let Some((title, position)) = next else {
            continue;
        };
        // a title in two sagas is offered for the one the history reached first
        if watched == 0 || out.iter().any(|(t, _)| t.id == title.id) {
            continue;
        }
        let place = SagaPlace {
            name: saga_name(&name),
            position,
            size,
            watched,
        };
        out.push((title, place));
    }
    Ok(out)
}

/// A collection's name without the word its source files it under, which
/// every line naming it already says: "Dune - Saga" and "Dune Collection" are
/// the Dune saga.
pub fn saga_name(raw: &str) -> String {
    const SEPARATORS: [char; 4] = [' ', '-', ':', '\u{2013}'];
    let mut name = raw.trim();
    for word in ["saga", "collection"] {
        let cut = name.len().saturating_sub(word.len());
        if let (Some(head), Some(tail)) = (name.get(..cut), name.get(cut..)) {
            if tail.eq_ignore_ascii_case(word) && head.ends_with(SEPARATORS) {
                name = head.trim_end_matches(SEPARATORS);
            }
        }
        if let (Some(head), Some(tail)) = (name.get(..word.len()), name.get(word.len()..)) {
            if head.eq_ignore_ascii_case(word) && tail.starts_with(' ') {
                name = tail.trim_start();
            }
        }
    }
    if name.is_empty() { raw.trim() } else { name }.to_string()
}

/// The running thread, with what is left of it: the leader it is named
/// after, how far in the viewer is, and the members still unwatched in their
/// own order. A thread every member of which has been watched is finished,
/// and the pass will lay a new one.
fn thread(db: &Db) -> Result<Option<(String, u32, u32, Vec<TitleRow>)>, IndexError> {
    let Some((leader, _)) = db.active_thread()? else {
        return Ok(None);
    };
    let Some((_, name, _)) = db.title_key(leader)? else {
        return Ok(None);
    };
    let mut stmt = db.conn().prepare_cached(THREAD)?;
    let mut total = 0u32;
    let mut left = Vec::new();
    let mut rows = stmt.query([])?;
    while let Some(r) = rows.next()? {
        total += 1;
        if r.get::<_, i64>(6)? == 0 {
            left.push(row_to_title(r)?);
        }
    }
    if left.is_empty() {
        return Ok(None);
    }
    Ok(Some((name, total - left.len() as u32, total, left)))
}

/// How far either side of today "on this day" reaches: a week centred on it,
/// so an anniversary on a Tuesday is still one on the Saturday before.
const DAY_SLACK: i64 = 3;

/// The anniversaries worth a row: the round ones people count.
const ANNIVERSARIES: [u16; 10] = [10, 20, 25, 30, 40, 50, 60, 70, 75, 100];

/// How many titles finished a year ago the row brings back: a reminder, not
/// a second history.
const YEAR_AGO_TITLES: u32 = 5;

/// The titles released within a day of the days `DAY_SLACK` reaches, by
/// "MM-DD" from `?1` to `?2`, across the new year when `?1` is the later one.
/// The cut is a superset of the exact one made in Rust; the day of slack
/// keeps a 29 February that a common year reads as 1 March.
const RELEASES: &str = "SELECT t.id, t.kind, t.name, t.year,
    (SELECT COUNT(*) FROM files c WHERE c.title_id = t.id) AS file_count,
    (SELECT c.id FROM files c WHERE c.title_id = t.id ORDER BY c.quality DESC, c.id LIMIT 1) AS first_file_id,
    m.release_date
  FROM metadata m
  CROSS JOIN titles t ON t.id = m.title_id
  WHERE CASE WHEN ?1 <= ?2 THEN substr(m.release_date, 6, 5) BETWEEN ?1 AND ?2
             ELSE substr(m.release_date, 6, 5) >= ?1 OR substr(m.release_date, 6, 5) <= ?2 END
    AND EXISTS (SELECT 1 FROM files c WHERE c.title_id = t.id)
  ORDER BY t.name COLLATE NOCASE, t.id";

/// Titles finished inside one span, the latest first.
const FINISHED_BETWEEN: &str = "SELECT t.id, t.kind, t.name, t.year,
    (SELECT COUNT(*) FROM files c WHERE c.title_id = t.id) AS file_count,
    (SELECT c.id FROM files c WHERE c.title_id = t.id ORDER BY c.quality DESC, c.id LIMIT 1) AS first_file_id
  FROM watch_state w
  CROSS JOIN files f ON f.id = w.file_id
  CROSS JOIN titles t ON t.id = f.title_id
  WHERE w.watched = 1 AND w.updated_at >= ?1 AND w.updated_at <= ?2
  GROUP BY t.id
  ORDER BY MAX(w.updated_at) DESC, t.id
  LIMIT ?3";

/// The rows today's date brings: one per round anniversary it reaches, and
/// what was finished a year ago.
fn on_this_day(
    db: &Db,
    now: i64,
    tz_offset_secs: i32,
    limit: u32,
) -> Result<Vec<(DayKind, Vec<TitleRow>)>, IndexError> {
    let today = (now + i64::from(tz_offset_secs)).div_euclid(86_400);
    let (year, _, _) = civil(today * 86_400);
    let span = [today - DAY_SLACK - 1, today + DAY_SLACK + 1].map(|day| {
        let (_, m, d) = civil(day * 86_400);
        format!("{m:02}-{d:02}")
    });
    let mut by_years: std::collections::BTreeMap<u16, Vec<TitleRow>> = Default::default();
    {
        let mut stmt = db.conn().prepare_cached(RELEASES)?;
        let mut rows = stmt.query(params![span[0], span[1]])?;
        while let Some(r) = rows.next()? {
            let date: String = r.get(6)?;
            let mut parts = date.splitn(3, '-').map(|p| p.parse::<u32>().ok());
            let (Some(Some(y)), Some(Some(m)), Some(Some(d))) =
                (parts.next(), parts.next(), parts.next())
            else {
                continue;
            };
            // the anniversary nearest today, which around the new year is
            // last year's or next year's
            let Some(years) = (year - 1..=year + 1)
                .find(|&at| (days_of(at, m, d) - today).abs() <= DAY_SLACK)
                .map(|at| at - i64::from(y))
            else {
                continue;
            };
            let Some(&years) = ANNIVERSARIES.iter().find(|&&a| i64::from(a) == years) else {
                continue;
            };
            let items = by_years.entry(years).or_default();
            if items.len() < limit as usize {
                items.push(row_to_title(r)?);
            }
        }
    }
    let mut out: Vec<(DayKind, Vec<TitleRow>)> = by_years
        .into_iter()
        .map(|(years, items)| (DayKind::Anniversary { years }, items))
        .collect();

    let year_ago = now - 365 * 86_400;
    out.push((
        DayKind::YearAgo,
        titles(
            db,
            FINISHED_BETWEEN,
            params![
                year_ago - DAY_SLACK * 86_400,
                year_ago + DAY_SLACK * 86_400,
                YEAR_AGO_TITLES
            ],
        )?,
    ));
    Ok(out)
}

/// How long a retrospective runs after the film that opened it was finished.
const RETRO_SECS: i64 = 7 * 86_400;

/// How many titles a director needs in the library before finishing one of
/// their films opens the rest: fewer is a pair, not a body of work.
const RETRO_FLOOR: u32 = 3;

/// The directors of films finished inside the retrospective's week and not
/// turned down, whose work the library holds enough of, the latest first.
const RETRO_DIRECTORS: &str = "SELECT g.value, MAX(w.updated_at) AS at
  FROM watch_state w
  CROSS JOIN files f ON f.id = w.file_id
  CROSS JOIN titles t ON t.id = f.title_id
  CROSS JOIN title_tags g INDEXED BY idx_title_tags_title
    ON g.title_id = t.id AND g.kind = 'director'
  WHERE w.watched = 1 AND w.updated_at > ?1 AND w.updated_at <= ?2 AND t.kind = 'movie'
    AND NOT EXISTS (SELECT 1 FROM title_verdict v WHERE v.title_id = t.id AND v.verdict < 0)
    AND (SELECT COUNT(*) FROM title_tags d
          WHERE d.kind = 'director' AND d.value = g.value
            AND EXISTS (SELECT 1 FROM files c WHERE c.title_id = d.title_id)) >= ?3
  GROUP BY g.value
  ORDER BY at DESC, g.value";

/// One director's work in the order it was made, what is undated last.
const RETRO: &str = "SELECT t.id, t.kind, t.name, t.year,
    (SELECT COUNT(*) FROM files c WHERE c.title_id = t.id) AS file_count,
    (SELECT c.id FROM files c WHERE c.title_id = t.id ORDER BY c.quality DESC, c.id LIMIT 1) AS first_file_id
  FROM title_tags g
  JOIN titles t ON t.id = g.title_id
  WHERE g.kind = 'director' AND g.value = ?1
    AND EXISTS (SELECT 1 FROM files c WHERE c.title_id = t.id)
  ORDER BY t.year = 0, t.year, t.name COLLATE NOCASE, t.id
  LIMIT ?2";

fn retrospectives(db: &Db, now: i64) -> Result<Vec<String>, IndexError> {
    let mut stmt = db.conn().prepare_cached(RETRO_DIRECTORS)?;
    let rows = stmt.query_map(params![now - RETRO_SECS, now, RETRO_FLOOR], |r| r.get(0))?;
    Ok(rows.collect::<Result<_, _>>()?)
}

/// How many titles finished in this month of earlier years it takes before
/// the month can be said to lean anywhere.
const MONTH_FLOOR: u32 = 6;

/// How far above its share of the whole history a taste's share of the month
/// must stand to be the month's.
const MONTH_LIFT: f32 = 1.5;

/// Each spent title once, with its taste and when it was last finished.
const FINISHED_FACETS: &str = "SELECT wf.facet, MAX(w.updated_at)
  FROM watched_facet wf
  CROSS JOIN files f ON f.title_id = wf.title_id
  CROSS JOIN watch_state w ON w.file_id = f.id
  WHERE w.watched = 1
  GROUP BY wf.title_id";

/// The taste this month of the year leans towards, in earlier years: its
/// month, the title that names it and its picks. None until the month has
/// `MONTH_FLOOR` titles behind it, or when no taste stands out in it.
fn this_month(
    db: &Db,
    now: i64,
    tz_offset_secs: i32,
) -> Result<Option<(u8, String, Vec<TitleRow>)>, IndexError> {
    let local = |at: i64| civil(at + i64::from(tz_offset_secs));
    let (year, month, _) = local(now);
    let mut all: HashMap<u32, u32> = HashMap::new();
    let mut in_month: HashMap<u32, u32> = HashMap::new();
    {
        let mut stmt = db.conn().prepare_cached(FINISHED_FACETS)?;
        let mut rows = stmt.query([])?;
        while let Some(r) = rows.next()? {
            let (facet, at): (u32, i64) = (r.get(0)?, r.get(1)?);
            *all.entry(facet).or_default() += 1;
            let (y, m, _) = local(at);
            if m == month && y < year {
                *in_month.entry(facet).or_default() += 1;
            }
        }
    }
    let month_total: u32 = in_month.values().sum();
    if month_total < MONTH_FLOOR {
        return Ok(None);
    }
    let total: u32 = all.values().sum();
    // the lift of each taste: its share of the month over its share of all
    let mut best: Option<(u32, f32)> = None;
    for (&facet, &count) in &in_month {
        let share = count as f32 / month_total as f32;
        let overall = all[&facet] as f32 / total as f32;
        let lift = share / overall;
        if lift > MONTH_LIFT && best.is_none_or(|(f, l)| lift > l || (lift == l && facet < f)) {
            best = Some((facet, lift));
        }
    }
    let Some((facet, _)) = best else {
        return Ok(None);
    };
    let Some(meta) = db.taste_facets()?.into_iter().find(|f| f.facet == facet) else {
        return Ok(None);
    };
    let Some((_, leader, _)) = db.title_key(meta.leader)? else {
        return Ok(None);
    };
    let mut stmt = db.conn().prepare_cached(PICKED)?;
    let mut items = Vec::new();
    let mut rows = stmt.query([])?;
    while let Some(r) = rows.next()? {
        if r.get::<_, u32>(6)? == facet && items.len() < ROW_LIMIT as usize {
            items.push(row_to_title(r)?);
        }
    }
    Ok(Some((month as u8, leader, items)))
}

/// How many titles the club shows: a week's worth of evenings.
pub(crate) const CLUB_TITLES: usize = 5;

/// The themes the taste pass stored, each once.
const CLUB_THEMES: &str = "SELECT DISTINCT kind, value FROM club_pick";

/// One theme's members still unseen, nearest the taste first. The primary
/// key answers the theme, so this costs its members and nothing else.
const CLUB_ITEMS: &str = "SELECT t.id, t.kind, t.name, t.year,
    (SELECT COUNT(*) FROM files c WHERE c.title_id = t.id) AS file_count,
    (SELECT c.id FROM files c WHERE c.title_id = t.id ORDER BY c.quality DESC, c.id LIMIT 1) AS first_file_id
  FROM club_pick p
  CROSS JOIN titles t ON t.id = p.title_id
  WHERE p.kind = ?1 AND p.value = ?2
    AND NOT EXISTS (SELECT 1 FROM watch_state w JOIN files f ON f.id = w.file_id
                    WHERE f.title_id = t.id)
    AND NOT EXISTS (SELECT 1 FROM title_verdict v WHERE v.title_id = t.id)
    AND EXISTS (SELECT 1 FROM files c WHERE c.title_id = t.id)
  ORDER BY p.affinity DESC, t.id
  LIMIT ?3";

/// The week's club: one of the themes the taste pass stored (see
/// `taste::club_themes`), its unseen members nearest the taste first, and
/// when the week ends. None when the pass stored no theme.
///
/// The week walks the themes in an order dealt from their names, so no theme
/// runs two weeks in a row while there are two: a fresh draw each week that
/// only avoids last week's draw can still repeat what last week showed.
fn cine_club(
    db: &Db,
    now: i64,
    tz_offset_secs: i32,
    limit: u32,
) -> Result<Option<(ClubTheme, i64, Vec<TitleRow>)>, IndexError> {
    let mut themes: Vec<(String, String)> = {
        let mut stmt = db.conn().prepare_cached(CLUB_THEMES)?;
        let rows = stmt.query_map([], |r| Ok((r.get(0)?, r.get(1)?)))?;
        rows.collect::<Result<_, _>>()?
    };
    if themes.is_empty() {
        return Ok(None);
    }
    themes.sort_by_cached_key(|(kind, value)| {
        let key = format!("{kind}:{value}");
        (hash(0, &key), key)
    });
    // Mondays, counted from the one before 1970-01-01, which was a Thursday
    let today = (now + i64::from(tz_offset_secs)).div_euclid(86_400);
    let week = (today + 3).div_euclid(7);
    let ends_at = (week * 7 + 4) * 86_400 - i64::from(tz_offset_secs);
    let (kind, value) = themes.swap_remove(week.rem_euclid(themes.len() as i64) as usize);
    let items = titles(db, CLUB_ITEMS, params![kind, value, limit])?;
    let theme = match kind.as_str() {
        "keyword" => ClubTheme::Keyword { word: value },
        "composer" => ClubTheme::Composer { name: value },
        _ => ClubTheme::Writer { name: value },
    };
    Ok(Some((theme, ends_at, items)))
}

/// One facet of the fingerprint each, named after the title it was built
/// around. A facet whose leader has left the library cannot name itself and is
/// dropped rather than shown as a row that means nothing.
///
/// Dealt by the day like every other subject: the strongest facets lead, and
/// the screen holds two of them, so taking the strongest two outright left a
/// fingerprint of four tastes showing the same two every morning. Strongest
/// means for this moment of the week (see `tonight::facet_order`), so the
/// taste a viewer reaches for on a Friday night leads on a Friday night.
fn facets(
    db: &Db,
    epoch: i64,
    now: i64,
    tz_offset_secs: i32,
) -> Result<Vec<(String, i64, Vec<TitleRow>)>, IndexError> {
    let mut stmt = db.conn().prepare_cached(PICKED)?;
    let rows = stmt.query_map([], |r| {
        Ok((
            row_to_title(r)?,
            r.get::<_, u32>(6)?,
            r.get::<_, Option<String>>(7)?,
            r.get::<_, i64>(8)?,
        ))
    })?;
    // the picks arrive in rank order, which is the order they were dealt out
    // between the facets: the facet met first is the one with most of the
    // history behind it
    let mut out: Vec<(u32, String, i64, Vec<TitleRow>)> = Vec::new();
    for row in rows {
        let (title, facet, leader, leader_id) = row?;
        let Some(leader) = leader else { continue };
        match out.iter_mut().find(|(f, _, _, _)| *f == facet) {
            Some((_, _, _, items)) if items.len() < ROW_LIMIT as usize => items.push(title),
            Some(_) => {}
            None => out.push((facet, leader, leader_id, vec![title])),
        }
    }
    let metas = db.taste_facets()?;
    if !metas.is_empty() {
        let ends = db.watched_facet_ends()?;
        let order = super::tonight::facet_order(&ends, &metas, tz_offset_secs, now);
        out.sort_by_key(|(f, _, _, _)| order.iter().position(|o| o == f).unwrap_or(order.len()));
    }
    Ok(chosen(
        out,
        epoch,
        "like",
        |(_, leader, _, _): &(u32, String, i64, Vec<TitleRow>)| leader.clone(),
    )
    .into_iter()
    .map(|(_, leader, leader_id, items)| (leader, leader_id, items))
    .collect())
}

/// One recently watched title, and the two keys `SIMILAR` searches from.
struct Seed {
    id: i64,
    kind: String,
    name: String,
    tmdb_id: Option<i64>,
}

/// The titles watched most recently, newest first: what recency ranks the
/// "because you watched" rows by. A seed the viewer contested seeds nothing.
fn seeds(db: &Db, now: i64) -> Result<Vec<Seed>, IndexError> {
    let mut stmt = db.conn().prepare_cached(SEEDS)?;
    let rows = stmt.query_map(params![SEED_POOL, now], |r| {
        Ok(Seed {
            id: r.get(0)?,
            kind: r.get(1)?,
            name: r.get(2)?,
            tmdb_id: r.get(3)?,
        })
    })?;
    Ok(rows.collect::<Result<Vec<_>, _>>()?)
}

/// The values of one tag kind the history carries, most watched first: which
/// actors the viewer returns to, which collections they have started.
fn tag_subjects(db: &Db, kind: &str, floor: u32) -> Result<Vec<String>, IndexError> {
    let mut stmt = db.conn().prepare_cached(&TAG_SUBJECTS)?;
    let rows = stmt.query_map(params![HISTORY_WINDOW, kind, floor, SUBJECT_POOL], |r| {
        r.get::<_, String>(0)
    })?;
    Ok(rows.collect::<Result<Vec<_>, _>>()?)
}

/// The genre-and-decade pairs the history holds, ranked the same way.
fn era_subjects(db: &Db) -> Result<Vec<(String, u16)>, IndexError> {
    let mut stmt = db.conn().prepare_cached(&ERA_SUBJECTS)?;
    let rows = stmt.query_map(params![HISTORY_WINDOW, ERA_FLOOR, SUBJECT_POOL], |r| {
        Ok((r.get::<_, String>(0)?, r.get::<_, u16>(1)?))
    })?;
    Ok(rows.collect::<Result<Vec<_>, _>>()?)
}

/// Which subjects of one kind get tonight's rows. `subjects` arrives in the
/// order the history puts them in; each is worth its place in that order, and
/// the day adds up to `PICK_SPREAD` of the whole ranking on top. So the front
/// of the ranking is where tonight's row comes from and the tail of it is not,
/// while which of the front gets the row is the day's to decide - which is
/// what stops a fortnight of openings being the same two actors.
///
/// `key` names a subject for the deal, so an actor is dealt the same way
/// whichever query found them and not by where they happened to rank.
fn chosen<T>(subjects: Vec<T>, epoch: i64, kind: &str, key: impl Fn(&T) -> String) -> Vec<T> {
    let depth = subjects.len() as f32;
    let mut scored: Vec<(T, f32)> = subjects
        .into_iter()
        .enumerate()
        .map(|(place, subject)| {
            let standing = 1.0 - place as f32 / depth;
            let luck = PICK_SPREAD * wobble(epoch, &format!("{kind}:{}", key(&subject)));
            (subject, standing + luck)
        })
        .collect();
    scored.sort_by(|a, b| b.1.partial_cmp(&a.1).unwrap());
    scored.truncate(SUBJECTS);
    scored.into_iter().map(|(subject, _)| subject).collect()
}

/// The pool, cut and ordered into the screen, part by part (see `Chapter`),
/// and greedy down the placed order inside a part:
/// each row is taken unless its kind already has as many as it may have, its
/// subject is already on the screen, or it would say again what a row above it
/// has said.
///
/// The list leads, outside the count: what the viewer put aside is the head of
/// the screen, not a row that has to win a day. The two rows that deal the
/// shelf by the day never compete for a place either: they are held back and
/// put at the foot of the screen. They are how a library of thousands is
/// reachable through a screen of a few rows at all, and coverage is a
/// constraint on this selection rather than a row that has to win one.
fn select(pool: Vec<Candidate>) -> Vec<Row> {
    let (head, pool): (Vec<Candidate>, Vec<Candidate>) = pool
        .into_iter()
        .partition(|c| c.reason == Reason::Watchlist);
    let (mut ranked, tail): (Vec<Candidate>, Vec<Candidate>) =
        pool.into_iter().partition(|c| !reaches_the_tail(&c.reason));
    // one dated row is the news; the others it outplaced close the taste,
    // under every row that argues from the history
    let lead = ranked
        .iter()
        .filter(|c| dated(&c.reason))
        .max_by(|a, b| a.place.total_cmp(&b.place))
        .map(|c| c.reason.clone());
    for c in ranked
        .iter_mut()
        .filter(|c| dated(&c.reason) && lead.as_ref() != Some(&c.reason))
    {
        c.chapter = Chapter::Taste;
        c.place -= DATED_DROP;
    }
    // stable, so the order the generators put a kind's own candidates in
    // survives: within a kind, what the history and the day chose still leads
    ranked.sort_by(|a, b| a.chapter.cmp(&b.chapter).then(b.place.total_cmp(&a.place)));

    let budget = MAX_ROWS - tail.len();
    let mut shown: HashSet<i64> = HashSet::new();
    // held apart until the ranked rows are dealt: see where it is filled
    let mut shelf: HashSet<i64> = HashSet::new();
    let mut counts: Vec<(&'static str, usize)> = Vec::new();
    let mut subjects: Vec<String> = Vec::new();
    let mut rows: Vec<Row> = head.into_iter().map(Row::from).collect();
    let mut rows_ranked = 0;
    for candidate in ranked {
        if rows_ranked == budget {
            break;
        }
        let key = kind_key(&candidate.reason);
        if counts.iter().any(|(k, n)| *k == key && *n >= MAX_PER_KIND) {
            continue;
        }
        // "because you watched X" and "because you like X" are one row said
        // twice, however far apart their titles turn out to be
        let subject = subject(&candidate.reason);
        if subject.is_some_and(|s| subjects.iter().any(|had| had == s)) {
            continue;
        }
        // What arrived is exempt, the same way it is exempt from filling
        // `shown` below and for the same reason: it is a shelf and not a
        // recommendation. A fact is not suppressed for being unsurprising, and
        // a viewer who has started most of what they added recently is exactly
        // the viewer this row is still true for - dropping it there would take
        // the row away from the library that needs it most.
        let repeated = candidate
            .items
            .iter()
            .filter(|t| shown.contains(&t.id))
            .count();
        if !matches!(
            candidate.reason,
            Reason::RecentlyAdded | Reason::Popular { .. }
        ) && repeated as f32 > OVERLAP * candidate.items.len() as f32
        {
            continue;
        }
        match counts.iter_mut().find(|(k, _)| *k == key) {
            Some((_, n)) => *n += 1,
            None => counts.push((key, 1)),
        }
        if let Some(s) = subject {
            subjects.push(s.to_string());
        }
        // What arrived is a shelf, not a recommendation. Pinned near the top,
        // it would otherwise claim the very films most worth recommending and
        // starve every row under it - so a recommendation may repeat it, and
        // that second row is the one that says why the film is worth an
        // evening. The sweeps at the foot of the screen may not: a shelf that
        // copies the shelf above it is reaching nothing.
        if candidate.reason == Reason::RecentlyAdded {
            shelf.extend(candidate.items.iter().map(|t| t.id));
        } else {
            shown.extend(candidate.items.iter().map(|t| t.id));
        }
        rows_ranked += 1;
        rows.push(candidate.into());
    }
    shown.extend(shelf.iter().copied());
    for candidate in tail {
        // reserved a place, not exempt from the rule: a sweep of the shelf
        // that is what the screen already holds is reaching nothing, which is
        // the only reason its place was reserved
        let repeated = candidate
            .items
            .iter()
            .filter(|t| shown.contains(&t.id))
            .count();
        if repeated as f32 > OVERLAP * candidate.items.len() as f32 {
            continue;
        }
        shown.extend(candidate.items.iter().map(|t| t.id));
        rows.push(candidate.into());
    }
    rows
}

impl From<Candidate> for Row {
    fn from(c: Candidate) -> Self {
        Row {
            reason: c.reason,
            items: c.items,
            more: c.more,
            places: c.places,
        }
    }
}

/// Which part of the screen a kind of row belongs to.
fn chapter(reason: &Reason) -> Chapter {
    match reason {
        Reason::Sagas => Chapter::Carry,
        Reason::RecentlyAdded => Chapter::News,
        _ if dated(reason) => Chapter::News,
        Reason::BecauseYouWatched { .. }
        | Reason::TasteFacet { .. }
        | Reason::Thread { .. }
        | Reason::ForgottenGem { .. }
        | Reason::ByDirector { .. }
        | Reason::WithActor { .. } => Chapter::Taste,
        _ => Chapter::Explore,
    }
}

/// The rows that exist for a stretch of the calendar, of which the news
/// carries one.
fn dated(reason: &Reason) -> bool {
    matches!(
        reason,
        Reason::Retrospective { .. }
            | Reason::CineClub { .. }
            | Reason::OnThisDay { .. }
            | Reason::Season { .. }
            | Reason::ThisMonth { .. }
    )
}

/// Whether this row's whole job is to reach titles no other row would show.
/// Both deal the shelf by the day, so what they offer this evening is not what
/// they offered yesterday, and between them they cover the library the viewer
/// has never opened and the one they have forgotten.
fn reaches_the_tail(reason: &Reason) -> bool {
    matches!(reason, Reason::LongAgo | Reason::Rediscovery)
}

/// What a row is about, when it is about something nameable. Two rows on one
/// subject are one row: whichever of them the order reached first is the one
/// the viewer gets.
fn subject(reason: &Reason) -> Option<&str> {
    match reason {
        Reason::BecauseYouWatched { seed, .. } => Some(seed),
        Reason::TasteFacet { leader, .. } => Some(leader),
        Reason::WithActor { name }
        | Reason::ByDirector { name }
        | Reason::Retrospective { name } => Some(name),
        Reason::ThisMonth { leader, .. } => Some(leader),
        Reason::CineClub { theme, .. } => Some(match theme {
            ClubTheme::Keyword { word } => word,
            ClubTheme::Composer { name } | ClubTheme::Writer { name } => name,
        }),
        Reason::GenreEra { genre, .. } => Some(genre),
        Reason::Thread { leader, .. } => Some(leader),
        // The gem names the taste that explains its first title, not a subject
        // of its own: claiming the leader as a subject would put it in
        // competition with the facet row that IS about that leader - and win,
        // leaving the shelf with no facet row at all.
        Reason::ForgottenGem { .. }
        | Reason::Sagas
        | Reason::Mood { .. }
        | Reason::RecentlyAdded
        | Reason::LongAgo
        | Reason::Rediscovery
        | Reason::StepAside
        | Reason::Season { .. }
        | Reason::OnThisDay { .. }
        | Reason::UpNext
        | Reason::Tonight
        | Reason::StageShows
        | Reason::Popular { .. }
        | Reason::Watchlist => None,
    }
}

/// Where each kind of row sits in its part (see `Chapter`) before the day
/// moves it, and which dated row is the news when several could be. Only
/// rows of one part are ever compared.
fn rank(reason: &Reason) -> f32 {
    match reason {
        // what the viewer already started
        Reason::Sagas => 72.0,
        // news: what arrived
        Reason::RecentlyAdded => 85.0,
        // the dated rows, in the order that picks the one that is the news:
        // the week about the film just finished, then the week's club, then
        // the rarest of the calendar
        Reason::Retrospective { .. } => 80.0,
        Reason::CineClub { .. } => 75.0,
        Reason::ThisMonth { .. } => 71.0,
        Reason::Season { .. } => 70.0,
        Reason::OnThisDay { .. } => 69.0,
        // the taste: what they are told they already own over the
        // fingerprint's own rows, who made a film over who is in it
        Reason::ForgottenGem { .. } => 68.0,
        Reason::BecauseYouWatched { .. } => 66.0,
        Reason::Thread { .. } => 64.0,
        Reason::TasteFacet { .. } => 60.0,
        Reason::ByDirector { .. } => 57.0,
        Reason::WithActor { .. } => 54.0,
        // the shelf, led by what the world is watching
        Reason::Popular { .. } => 50.0,
        Reason::StepAside => 45.0,
        Reason::GenreEra { .. } => 42.0,
        Reason::StageShows => 40.0,
        Reason::LongAgo => 30.0,
        Reason::Rediscovery => 24.0,
        // asked for, never dealt, or kept a place at the foot by `select`:
        // the rank is never read
        Reason::Mood { .. } | Reason::UpNext | Reason::Tonight | Reason::Watchlist => 0.0,
    }
}

/// What a dated row that is not the news loses, to sit under every taste row
/// whatever the day does to either.
const DATED_DROP: f32 = 100.0;

/// The fewest titles this kind of row is worth drawing with: a shelf's worth,
/// since a heading over a few posters and a screen of nothing reads as broken
/// rather than as selective. The viewer's own rows say everything they have
/// at any length: what they are in the middle of, the evening, the list, and
/// the next of each saga.
fn floor(reason: &Reason) -> usize {
    match reason {
        Reason::UpNext | Reason::Tonight | Reason::Watchlist | Reason::Sagas => 1,
        _ => SHELF,
    }
}

/// What counts as the same kind of row, for the cap on how many of one kind
/// the screen carries and for the day's deal over the order.
fn kind_key(reason: &Reason) -> &'static str {
    match reason {
        Reason::BecauseYouWatched { .. } => "watched",
        Reason::TasteFacet { .. } => "like",
        Reason::Sagas => "saga",
        Reason::WithActor { .. } => "actor",
        Reason::ByDirector { .. } => "director",
        Reason::GenreEra { .. } => "era",
        Reason::RecentlyAdded => "recent",
        Reason::Popular { .. } => "popular",
        Reason::LongAgo => "longago",
        Reason::Rediscovery => "rediscovery",
        Reason::StepAside => "aside",
        Reason::Season { .. } => "season",
        Reason::ForgottenGem { .. } => "gem",
        Reason::Thread { .. } => "thread",
        Reason::Mood { .. } => "mood",
        Reason::OnThisDay { .. } => "day",
        Reason::Retrospective { .. } => "retro",
        Reason::ThisMonth { .. } => "month",
        Reason::CineClub { .. } => "club",
        Reason::UpNext => "upnext",
        Reason::Tonight => "tonight",
        Reason::StageShows => "stage",
        Reason::Watchlist => "watchlist",
    }
}

/// A number in 0..1 dealt from the day and a key. The day is the only input to
/// this screen that is not the data, and it is the caller's `now`: whatever
/// varies here varies from something a test can fix.
fn wobble(epoch: i64, key: &str) -> f32 {
    (hash(epoch, key) >> 40) as f32 / (1u32 << 24) as f32
}

/// What `SHUFFLE` deals from, for a row that has to deal differently from the
/// row beside it: two genre-and-decade rows on one screen share most of the
/// library, and a seed that is the day alone would put the same titles at the
/// front of both. Masked to 30 bits, which is what keeps the multiplication
/// inside `SHUFFLE` an integer rather than overflowing into a float.
fn deal_seed(epoch: i64, key: &str) -> i64 {
    (hash(epoch, key) & 0x3fff_ffff) as i64
}

fn hash(epoch: i64, key: &str) -> u64 {
    let mut h: u64 = 0xcbf2_9ce4_8422_2325;
    for b in key.as_bytes().iter().chain(epoch.to_le_bytes().iter()) {
        h ^= u64::from(*b);
        h = h.wrapping_mul(0x0000_0100_0000_01b3);
    }
    h
}

fn titles(db: &Db, sql: &str, args: impl rusqlite::Params) -> Result<Vec<TitleRow>, IndexError> {
    let mut stmt = db.conn().prepare_cached(sql)?;
    let rows = stmt.query_map(args, row_to_title)?;
    Ok(rows.collect::<Result<Vec<_>, _>>()?)
}
#[cfg(test)]
mod tests {
    use super::*;
    use crate::index::db::{
        Db, FileMedia, FileRecord, MetadataRecord, MetadataSource, TastePassOutput, WatchAuthority,
        WatchRecord,
    };
    use crate::index::MediaKind;

    const DAY: i64 = 86_400;
    const NOW: i64 = 20_000 * DAY;

    fn file(db: &Db, title_id: i64, path: &str) -> i64 {
        file_at(db, title_id, path, 0)
    }

    /// A file with an mtime, which is what a title's `added_at` is taken from.
    fn file_at(db: &Db, title_id: i64, path: &str, mtime: i64) -> i64 {
        db.upsert_file(&FileRecord {
            source_id: "s1".into(),
            dir: "Movies".into(),
            path: path.into(),
            size: 1,
            mtime,
            seen_gen: 1,
            title_id,
            season: None,
            episode: None,
            rating_key: None,
            media: FileMedia::default(),
        })
        .unwrap();
        db.file_id("s1", path).unwrap().unwrap()
    }

    fn episode(db: &Db, title_id: i64, path: &str, season: u16, number: u16) -> i64 {
        db.upsert_file(&FileRecord {
            source_id: "s1".into(),
            dir: "Shows".into(),
            path: path.into(),
            size: 1,
            mtime: 0,
            seen_gen: 1,
            title_id,
            season: Some(season),
            episode: Some(number),
            rating_key: None,
            media: FileMedia::default(),
        })
        .unwrap();
        db.file_id("s1", path).unwrap().unwrap()
    }

    fn describe(db: &Db, title_id: i64, tmdb_id: i64, genres: &str) {
        db.upsert_metadata(&MetadataRecord {
            title_id,
            tmdb_id: Some(tmdb_id),
            overview_fr: None,
            overview_en: None,
            poster_path: None,
            backdrop_path: None,
            genres: genres.to_string(),
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
    }

    /// Like `describe`, with the cast and the collections a real Plex sync
    /// would also carry, for the tests below that rank titles by them.
    fn describe_tags(db: &Db, title_id: i64, genres: &str, cast: &str, collections: &str) {
        db.upsert_metadata(&MetadataRecord {
            title_id,
            tmdb_id: None,
            overview_fr: None,
            overview_en: None,
            poster_path: None,
            backdrop_path: None,
            genres: genres.to_string(),
            cast_names: cast.to_string(),
            collections: collections.to_string(),
            director_names: String::new(),
            writer_names: String::new(),
            composer_names: String::new(),
            source: MetadataSource::Plex,
            fetched_at: 1,
            critics: None,
            audience: None,
            release_date: None,
        })
        .unwrap();
    }

    /// A person's page is the same query asked of the two roles a name is
    /// tagged under, so one screen serves an actor and a director - and a name
    /// that is both comes back under both, from the one library.
    #[test]
    fn a_name_is_credited_under_each_role_it_was_tagged_with() {
        let db = Db::open_in_memory().unwrap();
        let acted = db
            .upsert_title(MediaKind::Movie, "Rosemary's Baby", Some(1968))
            .unwrap();
        file(&db, acted, "Movies/rosemary.mkv");
        describe_tags(&db, acted, "Horreur", "Mia Farrow,John Cassavetes", "");
        let directed = db
            .upsert_title(MediaKind::Movie, "Faces", Some(1968))
            .unwrap();
        file(&db, directed, "Movies/faces.mkv");
        describe_director(&db, directed, "John Cassavetes");

        let billed = credited_to(&db, "cast", "John Cassavetes", ROW_LIMIT).unwrap();
        assert_eq!(billed.iter().map(|t| t.id).collect::<Vec<_>>(), [acted]);
        let behind = credited_to(&db, "director", "John Cassavetes", ROW_LIMIT).unwrap();
        assert_eq!(behind.iter().map(|t| t.id).collect::<Vec<_>>(), [directed]);

        // the other name is only ever in front of a camera, and asking after
        // the role she does not hold is empty rather than an error
        assert_eq!(
            credited_to(&db, "cast", "Mia Farrow", ROW_LIMIT)
                .unwrap()
                .len(),
            1
        );
        assert!(credited_to(&db, "director", "Mia Farrow", ROW_LIMIT)
            .unwrap()
            .is_empty());
        // and a name nothing ever tagged is a person with no work here
        assert!(credited_to(&db, "cast", "Nobody At All", ROW_LIMIT)
            .unwrap()
            .is_empty());
    }

    /// A filmography reads by what someone did lately, and a title with no
    /// file of its own is not something the viewer can open.
    #[test]
    fn a_persons_work_is_newest_first_and_only_what_can_be_played() {
        let db = Db::open_in_memory().unwrap();
        for (name, year) in [("Heat", 1995), ("Casino", 1995), ("Ronin", 1998)] {
            let id = db.upsert_title(MediaKind::Movie, name, Some(year)).unwrap();
            file(&db, id, &format!("Movies/{name}.mkv"));
            describe_tags(&db, id, "Polar", "Robert De Niro", "");
        }
        // a title the library lists but holds no copy of
        let gone = db
            .upsert_title(MediaKind::Movie, "Jackie Brown", Some(1997))
            .unwrap();
        describe_tags(&db, gone, "Polar", "Robert De Niro", "");

        let work = credited_to(&db, "cast", "Robert De Niro", ROW_LIMIT).unwrap();
        assert_eq!(
            work.iter().map(|t| t.name.as_str()).collect::<Vec<_>>(),
            ["Ronin", "Casino", "Heat"]
        );
    }

    fn describe_director(db: &Db, title_id: i64, director: &str) {
        db.upsert_metadata(&MetadataRecord {
            title_id,
            tmdb_id: None,
            overview_fr: None,
            overview_en: None,
            poster_path: None,
            backdrop_path: None,
            genres: "Drame".into(),
            cast_names: String::new(),
            collections: String::new(),
            director_names: director.to_string(),
            writer_names: String::new(),
            composer_names: String::new(),
            source: MetadataSource::Plex,
            fetched_at: 1,
            critics: None,
            audience: None,
            release_date: None,
        })
        .unwrap();
    }

    /// A director with `seen` of their films watched and `left` waiting.
    fn filmography(db: &Db, director: &str, seen: usize, left: usize) {
        for n in 0..seen + left {
            let id = db
                .upsert_title(MediaKind::Movie, &format!("{director} {n}"), Some(2009))
                .unwrap();
            let f = file(db, id, &format!("Movies/{director}{n}.mkv"));
            describe_director(db, id, director);
            // finished longer ago than a retrospective runs
            if n < seen {
                watched(db, f, NOW - 10 * DAY);
            }
        }
    }

    #[test]
    fn a_director_the_history_returns_to_gets_a_row_of_what_is_left() {
        // two of their films watched is a return, which is the floor: counted
        // here rather than read off the constant, so moving the constant moves
        // this test rather than agreeing with it
        let db = Db::open_in_memory().unwrap();
        filmography(&db, "Jacques Audiard", 2, 5);

        let rows = browse_rows(&db, Some(MediaKind::Movie), NOW, 0, &HashSet::new()).unwrap();
        let row = find(&rows, "director").expect("a director row");
        let Reason::ByDirector { name } = &row.reason else {
            panic!("{:?}", row.reason);
        };
        assert_eq!(name, "Jacques Audiard");
        // what is left, and nothing already seen
        let names: Vec<&str> = row.items.iter().map(|i| i.name.as_str()).collect();
        assert_eq!(names.len(), 5);
        assert!(names.iter().all(|n| n.starts_with("Jacques Audiard")));
    }

    #[test]
    fn one_film_of_a_director_is_not_a_taste_and_four_left_is_not_a_rail() {
        // below the history floor: one film of theirs watched says nothing
        let db = Db::open_in_memory().unwrap();
        filmography(&db, "Un realisateur", 1, 3);
        assert!(find(
            &browse_rows(&db, Some(MediaKind::Movie), NOW, 0, &HashSet::new()).unwrap(),
            "director"
        )
        .is_none());

        // the taste is there, but the library holds four films of theirs the
        // viewer has not seen, and a rail short of a shelf reads as a bug
        let db = Db::open_in_memory().unwrap();
        filmography(&db, "Un autre", 2, 4);
        assert!(find(
            &browse_rows(&db, Some(MediaKind::Movie), NOW, 0, &HashSet::new()).unwrap(),
            "director"
        )
        .is_none());

        // one more waiting and the rail is worth drawing
        let db = Db::open_in_memory().unwrap();
        filmography(&db, "Un troisieme", 2, 5);
        assert!(find(
            &browse_rows(&db, Some(MediaKind::Movie), NOW, 0, &HashSet::new()).unwrap(),
            "director"
        )
        .is_some());
    }

    /// Neighbours for one title, as the semantic sweep writes them: best
    /// first, and a sentinel row saying the title was searched.
    fn semantic(db: &Db, title_id: i64, near: &[i64]) {
        let links: Vec<(i64, i32)> = near
            .iter()
            .enumerate()
            .map(|(i, id)| (*id, 9000 - i as i32 * 100))
            .collect();
        db.upsert_semantic(&[(title_id, links)], 1, NOW).unwrap();
    }

    fn title_id(db: &Db, name: &str) -> i64 {
        db.conn()
            .query_row(
                "SELECT id FROM titles WHERE name = ?1",
                params![name],
                |r| r.get(0),
            )
            .unwrap()
    }

    fn watched(db: &Db, file_id: i64, at: i64) {
        db.upsert_watch_state(
            &WatchRecord {
                file_id,
                position_secs: 0.0,
                duration_secs: 7000.0,
                watched: true,
                plays: 0,
                updated_at: at,
            },
            WatchAuthority::Report,
        )
        .unwrap();
    }

    fn in_progress(db: &Db, file_id: i64, position: f64, at: i64) {
        db.upsert_watch_state(
            &WatchRecord {
                file_id,
                position_secs: position,
                duration_secs: 7000.0,
                watched: false,
                plays: 0,
                updated_at: at,
            },
            WatchAuthority::Report,
        )
        .unwrap();
    }

    /// The kinds on the screen, in the order it draws them.
    fn shape(db: &Db, now: i64) -> Vec<&'static str> {
        browse_rows(db, Some(MediaKind::Movie), now, 0, &HashSet::new())
            .unwrap()
            .iter()
            .map(|r| kind_key(&r.reason))
            .collect()
    }

    fn names(row: &Row) -> Vec<&str> {
        row.items.iter().map(|t| t.name.as_str()).collect()
    }

    fn find<'a>(rows: &'a [Row], kind: &str) -> Option<&'a Row> {
        rows.iter().find(|r| kind_key(&r.reason) == kind)
    }

    /// Every row the library can fill on `now`, before the screen is cut to
    /// what fits: what a generator makes, whether or not today has room for it.
    fn pool(db: &Db, now: i64) -> Vec<Row> {
        candidates(db, now, now.div_euclid(DAY), 0, ROW_LIMIT)
            .unwrap()
            .into_iter()
            .map(Row::from)
            .collect()
    }

    /// A library that can fill all four rows: Dune and one episode watched,
    /// Alien and the next episode in progress, Blade Runner and Solaris
    /// similar to Dune and never watched, Home Movie described by nothing.
    /// Black Lotus is a show numbered like the Blade Runner film, and Unmatched
    /// carries the id the sentinel row is written with: neither may reach a
    /// movie's similar row.
    fn library() -> Db {
        let db = Db::open_in_memory().unwrap();
        let dune = db
            .upsert_title(MediaKind::Movie, "Dune", Some(2021))
            .unwrap();
        let alien = db
            .upsert_title(MediaKind::Movie, "Alien", Some(1979))
            .unwrap();
        let expanse = db
            .upsert_title(MediaKind::Show, "The Expanse", None)
            .unwrap();
        let blade = db
            .upsert_title(MediaKind::Movie, "Blade Runner", Some(1982))
            .unwrap();
        let solaris = db
            .upsert_title(MediaKind::Movie, "Solaris", Some(1972))
            .unwrap();
        let home = db
            .upsert_title(MediaKind::Movie, "Home Movie", None)
            .unwrap();
        let lotus = db
            .upsert_title(MediaKind::Show, "Blade Runner: Black Lotus", None)
            .unwrap();
        let unmatched = db
            .upsert_title(MediaKind::Movie, "Unmatched", None)
            .unwrap();

        let dune_file = file(&db, dune, "Movies/dune.mkv");
        let alien_file = file(&db, alien, "Movies/alien.mkv");
        let first = episode(&db, expanse, "Shows/s01e01.mkv", 1, 1);
        let second = episode(&db, expanse, "Shows/s01e02.mkv", 1, 2);
        file(&db, blade, "Movies/blade.mkv");
        file(&db, solaris, "Movies/solaris.mkv");
        file(&db, home, "Movies/home.mkv");
        file(&db, lotus, "Shows/lotus.mkv");
        file(&db, unmatched, "Movies/unmatched.mkv");

        describe(&db, dune, 438631, "Science-Fiction,Aventure");
        describe(&db, alien, 348, "Horreur,Science-Fiction");
        describe(&db, expanse, 63639, "Science-Fiction");
        describe(&db, blade, 78, "Science-Fiction,Thriller");
        describe(&db, solaris, 762, "Science-Fiction");
        // TMDB numbers shows apart from films, so this show is a 78 too
        describe(&db, lotus, 78, "");
        // 0 is the id the empty-answer sentinel row carries
        describe(&db, unmatched, 0, "");
        db.upsert_similar(438631, MediaKind::Movie, &[78, 762, 11111])
            .unwrap();
        db.upsert_similar(762, MediaKind::Movie, &[438631, 78])
            .unwrap();

        watched(&db, dune_file, NOW - 100);
        in_progress(&db, alien_file, 1200.0, NOW - 50);
        // the first episode is seen and the next one is running: the show is in
        // progress on the episode that was left, not on its first file
        watched(&db, first, NOW - 200);
        in_progress(&db, second, 900.0, NOW - 10);
        db
    }

    #[test]
    fn a_row_opened_as_a_screen_holds_more_than_its_rail_drew() {
        let db = home();
        let rows = browse_rows(&db, None, NOW, 0, &HashSet::new()).unwrap();
        let row = find(&rows, "recent").expect("the shelf of new arrivals");
        assert_eq!(row.items.len(), ROW_LIMIT as usize);

        let whole = row_items(&db, &row.reason, NOW, 0).unwrap();
        assert!(
            whole.len() > row.items.len(),
            "a rail draws {} of what the row holds, and opening it drew {}",
            row.items.len(),
            whole.len()
        );
        // and it opens on the same titles, in the same order: a screen that
        // reshuffled what the rail showed would lose the card pressed to get
        // there
        assert_eq!(names(row), names_of(&whole[..row.items.len()]));
    }

    fn names_of(items: &[TitleRow]) -> Vec<&str> {
        items.iter().map(|t| t.name.as_str()).collect()
    }

    #[test]
    fn a_row_nothing_fills_opens_on_nothing_rather_than_failing() {
        let db = Db::open_in_memory().unwrap();
        let empty = row_items(&db, &Reason::RecentlyAdded, NOW, 0).unwrap();
        assert!(empty.is_empty());
    }

    #[test]
    fn the_rows_are_what_the_library_can_fill_and_nothing_else() {
        let db = library();
        let rows = browse_rows(&db, Some(MediaKind::Movie), NOW, 0, &HashSet::new()).unwrap();
        // nothing is vectorised, no genre-and-decade pair reaches its floor on
        // two watched films, and nothing was watched years ago. What is left
        // is the one shelf sweep a browse still makes: what arrived.
        assert_eq!(shape(&db, NOW), ["recent"]);

        // Playable, and nothing else asked of it: a title with no file would
        // be a dead tile, but one already watched is still something that
        // arrived. The shelf is asked one kind at a time, so the series stay
        // on their own tab.
        let recent = find(&rows, "recent").unwrap();
        let mut found = names(recent);
        found.sort();
        assert_eq!(
            found,
            [
                "Alien",
                "Blade Runner",
                "Dune",
                "Home Movie",
                "Solaris",
                "Unmatched"
            ]
        );

        // two series are not a shelf of what arrived, and the home mixes both
        let shows = browse_rows(&db, Some(MediaKind::Show), NOW, 0, &HashSet::new()).unwrap();
        assert!(find(&shows, "recent").is_none(), "{shows:?}");
        let home = browse_rows(&db, None, NOW, 0, &HashSet::new()).unwrap();
        assert_eq!(find(&home, "recent").unwrap().items.len(), 8);
    }

    /// What arrived is one row, films and series together, newest first.
    #[test]
    fn what_arrived_is_one_row_of_both_kinds_newest_first() {
        let db = Db::open_in_memory().unwrap();
        for (n, kind) in [
            MediaKind::Movie,
            MediaKind::Show,
            MediaKind::Movie,
            MediaKind::Show,
            MediaKind::Movie,
        ]
        .into_iter()
        .enumerate()
        {
            let id = db
                .upsert_title(kind, &format!("Arrival {n}"), None)
                .unwrap();
            file(&db, id, &format!("Shelf/arrival{n}.mkv"));
            db.conn()
                .execute(
                    "UPDATE titles SET added_at = ?1 WHERE id = ?2",
                    params![NOW - (10 - n as i64) * DAY, id],
                )
                .unwrap();
        }
        let rows = browse_rows(&db, None, NOW, 0, &HashSet::new()).unwrap();
        assert_eq!(
            names(find(&rows, "recent").unwrap()),
            [
                "Arrival 4",
                "Arrival 3",
                "Arrival 2",
                "Arrival 1",
                "Arrival 0"
            ]
        );
        assert_eq!(
            names_of(&row_items(&db, &Reason::RecentlyAdded, NOW, 0).unwrap()),
            [
                "Arrival 4",
                "Arrival 3",
                "Arrival 2",
                "Arrival 1",
                "Arrival 0"
            ]
        );
    }

    /// A library with enough history behind it that the screen has to choose,
    /// and with its groups kept apart so that what each row is about is not
    /// what the row above it was about: three crime films watched this week
    /// with neighbours of their own, a film left running and a show one
    /// episode in, two sagas begun, two actors the history returns to, two
    /// genre-and-decade pairs, a shelf of a hundred nobody has opened and one
    /// watched five years ago. Every generator has something to offer here,
    /// which is what makes the selection something to assert about.
    fn home() -> Db {
        let db = Db::open_in_memory().unwrap();

        // three films watched this week, and fifteen neighbours nothing else
        // in the library shares a tag with: five per seed, so each seed has a
        // row of its own to offer
        let mut seeds = Vec::new();
        for (n, name) in ["Heat", "Casino", "Goodfellas"].iter().enumerate() {
            let id = db.upsert_title(MediaKind::Movie, name, Some(1995)).unwrap();
            let f = file(&db, id, &format!("Movies/{name}.mkv"));
            describe_tags(&db, id, "Crime", "Robert De Niro", "");
            watched(&db, f, NOW - (n as i64 + 1) * DAY);
            seeds.push(id);
        }
        let near: Vec<i64> = (0..15)
            .map(|n| {
                let id = db
                    .upsert_title(MediaKind::Movie, &format!("Near {n}"), Some(2001))
                    .unwrap();
                file(&db, id, &format!("Movies/near{n}.mkv"));
                describe_tags(&db, id, "Polar", "", "");
                id
            })
            .collect();
        for (n, seed) in seeds.iter().enumerate() {
            // the film watched before this one is among its neighbours, which
            // is the ordinary case and never a recommendation
            let mut links = vec![seeds[(n + 1) % seeds.len()]];
            links.extend_from_slice(&near[n * 5..n * 5 + 5]);
            semantic(&db, *seed, &links);
        }

        // a film left running, and a show whose second episode is waiting
        let samourai = db
            .upsert_title(MediaKind::Movie, "Le Samourai", Some(1967))
            .unwrap();
        let running = file(&db, samourai, "Movies/samourai.mkv");
        describe_tags(&db, samourai, "Polar", "", "");
        in_progress(&db, running, 1200.0, NOW - 3600);
        for name in ["Deadwood", "The Wire", "Oz"] {
            let show = db.upsert_title(MediaKind::Show, name, None).unwrap();
            let first = episode(&db, show, &format!("Shows/{name}e01.mkv"), 1, 1);
            episode(&db, show, &format!("Shows/{name}e02.mkv"), 1, 2);
            // a third, so a show left running still has an episode after the
            // one being watched and both rows could reach for it
            episode(&db, show, &format!("Shows/{name}e03.mkv"), 1, 3);
            watched(&db, first, NOW - DAY);
        }

        // two sagas two films into themselves, two more of each waiting
        for saga in ["Rocky", "Halloween"] {
            for n in 0..4 {
                let id = db
                    .upsert_title(MediaKind::Movie, &format!("{saga} {n}"), Some(1976))
                    .unwrap();
                let f = file(&db, id, &format!("Movies/{saga}{n}.mkv"));
                describe_tags(&db, id, "Serie B", "", saga);
                if n < 2 {
                    watched(&db, f, NOW - 4 * DAY);
                }
            }
        }

        // two actors the history returns to, whose unwatched films are of
        // another decade than the era rows below reach into
        for (actor, genre) in [("Bruce Willis", "Action"), ("Gena Rowlands", "Drame")] {
            for n in 0..3 {
                let id = db
                    .upsert_title(MediaKind::Movie, &format!("{actor} seen {n}"), Some(2015))
                    .unwrap();
                let f = file(&db, id, &format!("Movies/{actor}s{n}.mkv"));
                describe_tags(&db, id, genre, actor, "");
                watched(&db, f, NOW - 6 * DAY);
            }
            for n in 0..6 {
                let id = db
                    .upsert_title(MediaKind::Movie, &format!("{actor} left {n}"), Some(2016))
                    .unwrap();
                file(&db, id, &format!("Movies/{actor}l{n}.mkv"));
                describe_tags(&db, id, genre, actor, "");
            }
        }

        // two genre-and-decade pairs: three watched of each and eight waiting,
        // carrying no cast, so an era row is nobody's filmography
        for genre in ["Horreur", "Comedie"] {
            for n in 0..11 {
                let id = db
                    .upsert_title(MediaKind::Movie, &format!("{genre} {n}"), Some(1983))
                    .unwrap();
                let f = file(&db, id, &format!("Movies/{genre}{n}.mkv"));
                describe_tags(&db, id, genre, "", "");
                if n < 3 {
                    watched(&db, f, NOW - 7 * DAY);
                }
            }
        }

        // a shelf of a hundred nobody has opened, newest last so the recently
        // added row has an order to walk rather than a tie to break on the id
        for n in 0..100 {
            let id = db
                .upsert_title(MediaKind::Movie, &format!("Unopened {n:03}"), Some(2024))
                .unwrap();
            file_at(&db, id, &format!("Movies/unopened{n}.mkv"), n as i64 + 1);
            describe_tags(&db, id, "Documentaire", "", "");
        }

        // and a shelf watched once, five years back
        for n in 0..8 {
            let id = db
                .upsert_title(MediaKind::Movie, &format!("Forgotten {n}"), Some(1988))
                .unwrap();
            let f = file(&db, id, &format!("Movies/forgotten{n}.mkv"));
            describe_tags(&db, id, "Western", "", "");
            watched(&db, f, NOW - 5 * 365 * DAY);
        }
        db
    }

    /// The taste row as a pass would leave it: one facet per entry, each of
    /// `size` picks off the unopened shelf and built around the watched title
    /// named. The picks are dealt facet by facet, which is one order the pass
    /// could have written and enough for a reader that groups by facet.
    fn taste(db: &Db, facets: &[(&str, usize)]) {
        let mut picks = Vec::new();
        for (facet, (leader, size)) in facets.iter().enumerate() {
            let leader = title_id(db, leader);
            for _ in 0..*size {
                picks.push(crate::index::db::TastePick {
                    title_id: title_id(db, &format!("Unopened {:03}", picks.len())),
                    facet: facet as u32,
                    leader,
                });
            }
        }
        db.replace_taste(&TastePassOutput {
            picks,
            ..Default::default()
        })
        .unwrap();
    }

    #[test]
    fn every_row_on_the_screen_can_say_why_it_is_there() {
        let db = home();
        let rows = browse_rows(&db, Some(MediaKind::Movie), NOW, 0, &HashSet::new()).unwrap();
        assert!(rows.len() > 5, "{:?}", shape(&db, NOW));

        // the point of the reason: a row about something names the something,
        // and a row about nothing in particular is one of the three that are
        // about the viewer's shelf rather than about a title
        for row in &rows {
            let named = subject(&row.reason).is_some();
            let sweep = matches!(
                row.reason,
                Reason::RecentlyAdded | Reason::Sagas | Reason::LongAgo | Reason::Rediscovery
            );
            assert!(named ^ sweep, "{:?}", row.reason);
        }

        // and the screen is not five rows any more: every kind this library
        // can fill without a taste pass behind it reaches it inside a
        // fortnight of openings
        let mut kinds: Vec<&str> = (0..14)
            .flat_map(|day| shape(&db, NOW + day * DAY))
            .collect();
        kinds.sort_unstable();
        kinds.dedup();
        assert_eq!(
            kinds,
            [
                "actor",
                "era",
                "longago",
                "recent",
                "rediscovery",
                "saga",
                "watched",
            ]
        );

        let rows = browse_rows(&db, Some(MediaKind::Movie), NOW + DAY, 0, &HashSet::new()).unwrap();

        // and the named rows name what they were actually built from: a film
        // this history holds, a collection it has begun, an actor it returns
        // to, a decade of a genre it watches
        let Reason::BecauseYouWatched { seed, .. } = &find(&rows, "watched").unwrap().reason else {
            panic!("{:?}", shape(&db, NOW))
        };
        assert!(
            ["Heat", "Casino", "Goodfellas"].contains(&seed.as_str()),
            "{seed}"
        );
        let sagas = find(&rows, "saga").unwrap();
        let names: Vec<&str> = sagas.places.iter().map(|p| p.name.as_str()).collect();
        assert!(
            names.contains(&"Rocky") && names.contains(&"Halloween"),
            "{names:?}"
        );
        let Reason::WithActor { name } = &find(&rows, "actor").unwrap().reason else {
            panic!()
        };
        assert!(
            ["Bruce Willis", "Gena Rowlands"].contains(&name.as_str()),
            "{name}"
        );
        let Reason::GenreEra { genre, decade } = &find(&rows, "era").unwrap().reason else {
            panic!("{:?}", shape(&db, NOW + DAY))
        };
        assert!(["Horreur", "Comedie"].contains(&genre.as_str()), "{genre}");
        assert_eq!(*decade, 1980);
    }

    #[test]
    fn each_saga_begun_offers_its_next_film_and_where_it_stands() {
        let db = home();
        let rows = browse_rows(&db, Some(MediaKind::Movie), NOW, 0, &HashSet::new()).unwrap();
        let sagas = find(&rows, "saga").expect("the collections the viewer started");
        // one card a saga, the first film never started in the saga's order,
        // however short the row: it is the whole of what the history began
        let mut cards: Vec<(String, &SagaPlace)> = sagas
            .items
            .iter()
            .map(|t| t.name.clone())
            .zip(&sagas.places)
            .collect();
        cards.sort_by(|a, b| a.0.cmp(&b.0));
        let expected = |name: &str| SagaPlace {
            name: name.to_string(),
            position: 3,
            size: 4,
            watched: 2,
        };
        assert_eq!(
            cards,
            [
                ("Halloween 2".to_string(), &expected("Halloween")),
                ("Rocky 2".to_string(), &expected("Rocky")),
            ]
        );
    }

    #[test]
    fn a_saga_started_and_left_running_offers_the_one_after() {
        let db = Db::open_in_memory().unwrap();
        let ids: Vec<i64> = (1..=3)
            .map(|n| {
                let id = db
                    .upsert_title(MediaKind::Movie, &format!("Alien {n}"), Some(1978 + n))
                    .unwrap();
                describe_tags(&db, id, "Horreur", "", "Alien - Saga");
                id
            })
            .collect();
        let first = file(&db, ids[0], "Movies/Alien1.mkv");
        let second = file(&db, ids[1], "Movies/Alien2.mkv");
        file(&db, ids[2], "Movies/Alien3.mkv");
        watched(&db, first, NOW - DAY);
        // the second is in the queue already: the saga moves on past it
        in_progress(&db, second, 600.0, NOW - DAY);
        let rows = browse_rows(&db, None, NOW, 0, &HashSet::new()).unwrap();
        let sagas = find(&rows, "saga").expect("a saga begun");
        assert_eq!(names(sagas), ["Alien 3"]);
        assert_eq!(
            sagas.places,
            [SagaPlace {
                name: "Alien".into(),
                position: 3,
                size: 3,
                watched: 1
            }]
        );
    }

    #[test]
    fn a_collection_is_named_without_the_word_its_source_files_it_under() {
        assert_eq!(saga_name("Astérix & Obélix - Saga"), "Astérix & Obélix");
        assert_eq!(saga_name("Dune Saga"), "Dune");
        assert_eq!(
            saga_name("The Lord of the Rings Collection"),
            "The Lord of the Rings"
        );
        assert_eq!(saga_name("Saga Dune"), "Dune");
        assert_eq!(saga_name("Alien: Collection"), "Alien");
        // a word inside a name is the name
        assert_eq!(saga_name("Sagaland"), "Sagaland");
        assert_eq!(saga_name("Saga"), "Saga");
    }

    #[test]
    fn the_newest_on_the_shelf_is_the_order_recently_added_walks() {
        let db = home();
        let rows = browse_rows(&db, Some(MediaKind::Movie), NOW, 0, &HashSet::new()).unwrap();
        let recent = find(&rows, "recent").unwrap();
        // the mtimes count up with n, so the last file added leads
        assert_eq!(
            names(recent)[..3],
            ["Unopened 099", "Unopened 098", "Unopened 097"]
        );
    }

    #[test]
    fn what_arrived_sits_over_the_taste_whether_or_not_it_is_new() {
        let db = home();
        let taste = ["watched", "like", "thread", "gem", "director", "actor"];
        let at = |shape: &[&str], kind: &str| shape.iter().position(|k| *k == kind);
        // drawn yesterday and nothing added since: still over the taste
        db.record_row_kinds(&["recent"], NOW / DAY - 1).unwrap();
        let stale = shape(&db, NOW);
        let recent = at(&stale, "recent").expect("the shelf of arrivals");
        assert!(
            taste
                .iter()
                .all(|k| at(&stale, k).is_none_or(|i| i > recent)),
            "{stale:?}"
        );

        // one film since: the same place, and not claiming the films every
        // recommendation below it wanted to name
        let arrival = db
            .upsert_title(MediaKind::Movie, "Arrival", Some(2016))
            .unwrap();
        file_at(&db, arrival, "Films/Arrival.mkv", NOW - 3_600);
        let fresh = shape(&db, NOW);
        assert_eq!(at(&fresh, "recent"), Some(recent), "{fresh:?}");
        assert!(fresh.len() > 4, "{fresh:?}");
    }

    #[test]
    fn the_rows_that_reach_the_long_tail_are_on_the_screen_whatever_else_is() {
        let db = home();
        // twelve rows' worth of better-placed candidates would push these two
        // off a screen that only ranked: their places are reserved instead,
        // because coverage is a constraint on the selection and not a row that
        // has to win one
        for day in 0..30 {
            let shape = shape(&db, NOW + day * DAY);
            assert_eq!(shape.last(), Some(&"rediscovery"), "{shape:?}");
            assert!(shape.contains(&"longago"), "{shape:?}");
            // and what arrived, new or not: the shelf is always there
            assert!(shape.contains(&"recent"), "{shape:?}");
            assert!(shape.len() <= MAX_ROWS, "{shape:?}");
        }
    }

    #[test]
    fn the_long_tail_is_reached_by_opening_the_screen_again_tomorrow() {
        let db = home();
        let mut seen = HashSet::new();
        for row in browse_rows(&db, Some(MediaKind::Movie), NOW, 0, &HashSet::new()).unwrap() {
            seen.extend(row.items.iter().map(|t| t.id));
        }
        let first_day = seen.len();
        for day in 1..14 {
            for row in browse_rows(
                &db,
                Some(MediaKind::Movie),
                NOW + day * DAY,
                0,
                &HashSet::new(),
            )
            .unwrap()
            {
                seen.extend(row.items.iter().map(|t| t.id));
            }
        }
        let library: usize = db
            .conn()
            .query_row("SELECT COUNT(*) FROM titles", [], |r| r.get::<_, i64>(0))
            .unwrap() as usize;
        // a screen that showed the same titles every day would leave the rest
        // of the library unreachable however many rows it had. One opening
        // cannot show a library of two hundred; a fortnight of them has to
        // reach most of it, and the two rows dealt by the day are how.
        assert!(first_day < library / 2, "{first_day} of {library} at once");
        assert!(seen.len() > library * 3 / 4, "{} of {library}", seen.len());
    }

    #[test]
    fn the_screen_holds_still_all_day_and_is_dealt_again_tomorrow() {
        let db = home();
        let today = browse_rows(&db, Some(MediaKind::Movie), NOW, 0, &HashSet::new()).unwrap();
        // the viewer moves between the tabs and comes back: the same screen
        assert_eq!(
            today,
            browse_rows(&db, Some(MediaKind::Movie), NOW + 3600, 0, &HashSet::new()).unwrap()
        );
        assert_eq!(
            today,
            browse_rows(
                &db,
                Some(MediaKind::Movie),
                NOW + DAY - 1,
                0,
                &HashSet::new()
            )
            .unwrap()
        );

        // over a month it is neither frozen nor a slot machine: the kinds on
        // the screen move places, and what they are about changes
        let mut orders = HashSet::new();
        let mut subjects = HashSet::new();
        for day in 0..30 {
            let rows = browse_rows(
                &db,
                Some(MediaKind::Movie),
                NOW + day * DAY,
                0,
                &HashSet::new(),
            )
            .unwrap();
            orders.insert(rows.iter().map(|r| kind_key(&r.reason)).collect::<Vec<_>>());
            subjects.insert(
                rows.iter()
                    .filter_map(|r| subject(&r.reason).map(str::to_string))
                    .collect::<Vec<_>>(),
            );
        }
        assert!(subjects.len() > 1, "the same subjects for a month");

        // and the screen itself is dealt again: the rows it holds, and where,
        // are not the same every day. The shelf of arrivals and the sweeps
        // keep their reserved places, so what moves is the ranked rows.
        assert!(orders.len() > 1, "the same screen for a month: {orders:?}");
    }

    #[test]
    fn a_row_never_trades_places_with_one_two_tiers_away() {
        let db = home();
        // the wobble is one tier wide, so a screen two evenings running is
        // recognisably the same screen: what is about the viewer stays above
        // what is about the shelf
        for day in 0..60 {
            let shape = shape(&db, NOW + day * DAY);
            let at = |kind| shape.iter().position(|k| *k == kind);
            let (Some(watched), Some(era)) = (at("watched"), at("era")) else {
                continue;
            };
            assert!(watched < era, "{shape:?}");
        }
    }

    #[test]
    fn two_rows_never_say_the_same_thing_under_two_names() {
        let db = home();
        // the taste facet is built around the film that leads it, which is
        // also the film the neighbour row is named after: two rows called
        // "because you watched Heat" and "because you like Heat" are one row
        // said twice, however far apart their titles turn out to be
        taste(&db, &[("Heat", 8), ("Casino", 8), ("Goodfellas", 8)]);

        let rows = browse_rows(&db, Some(MediaKind::Movie), NOW, 0, &HashSet::new()).unwrap();
        let named: Vec<&str> = rows.iter().filter_map(|r| subject(&r.reason)).collect();
        let mut once = named.clone();
        once.sort_unstable();
        once.dedup();
        assert_eq!(named.len(), once.len(), "{named:?}");
        // and each of the three films is on the screen once at most, as one
        // row or as the other, never as both
        for film in ["Heat", "Casino", "Goodfellas"] {
            assert!(
                named.iter().filter(|s| **s == film).count() <= 1,
                "{named:?}"
            );
        }
    }

    /// A step aside is a risk worth taking, a film most who saw it disliked
    /// is not: one scored low by enough voters leaves the row.
    #[test]
    fn the_step_aside_row_leaves_out_what_enough_voters_disliked() {
        let db = home();
        let ids: Vec<i64> = (0..6)
            .map(|n| title_id(&db, &format!("Unopened {n:03}")))
            .collect();
        db.replace_taste(&TastePassOutput {
            discovery: ids
                .iter()
                .map(|&title_id| crate::index::db::DiscoveryPick {
                    title_id,
                    closeness: 0.5,
                })
                .collect(),
            ..Default::default()
        })
        .unwrap();
        let rate = |id: i64, value: f32, votes: u32| {
            db.upsert_metadata(&MetadataRecord {
                title_id: id,
                tmdb_id: Some(9000 + id),
                overview_fr: None,
                overview_en: None,
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
                audience: Some(crate::index::db::Score {
                    value,
                    source: "imdb".into(),
                    votes: Some(votes),
                }),
                release_date: None,
            })
            .unwrap();
        };
        rate(ids[0], 4.1, 5000);
        // a low score few voted for says little, and stays
        rate(ids[1], 4.1, 12);
        rate(ids[2], 7.4, 5000);
        let aside = step_aside(&db).unwrap();
        assert!(!aside.iter().any(|t| t.id == ids[0]));
        assert!(aside.iter().any(|t| t.id == ids[1]));
        assert!(aside.iter().any(|t| t.id == ids[2]));
    }

    /// A kind of row is rated on its launches per day offered: the one the
    /// viewer launches from rises, the one they pass over sinks, both within
    /// a tier, and a kind never offered stays where its rank puts it.
    #[test]
    fn a_row_the_viewer_launches_from_rises_and_one_passed_over_sinks() {
        let db = home();
        let film = title_id(&db, "Unopened 000");
        let epoch = NOW.div_euclid(DAY);
        for day in epoch - 20..epoch {
            db.record_row_kinds(&["saga", "with_actor"], day).unwrap();
        }
        for n in 0..10 {
            db.record_launch(film, NOW - n * DAY, "row", "with_actor")
                .unwrap();
        }
        db.record_launch(film, NOW - DAY, "row", "saga").unwrap();
        let shift = learned(&db, epoch).unwrap();
        assert!(shift["with_actor"] > 0.0 && shift["with_actor"] <= ORDER_SPREAD);
        assert!(shift["saga"] < 0.0 && shift["saga"] >= -ORDER_SPREAD);
        assert!(!shift.contains_key("taste_facet"));
    }

    /// What a library of French stand-up actually carries: a show named for
    /// its headliner with no keyword and no crew, a film about a comedian
    /// with a comedian's keyword and a film's cast, and a documentary its
    /// one voice directed. Only the first is a stage show.
    #[test]
    fn a_stage_show_is_told_from_a_film_about_one_and_from_a_documentary() {
        let db = Db::open_in_memory().unwrap();
        let show = db
            .upsert_title(MediaKind::Movie, "Dieudonné - Finissons-en !", Some(2020))
            .unwrap();
        describe_crew(&db, show, "Dieudonné", "");
        let biopic = db
            .upsert_title(MediaKind::Movie, "Man on the Moon", Some(1999))
            .unwrap();
        let billing: Vec<String> = (0..20).map(|n| format!("Actor {n}")).collect();
        describe_crew(&db, biopic, &billing.join(","), "");
        db.set_keywords(biopic, "biography, stand-up comedy", 1)
            .unwrap();
        let documentary = db
            .upsert_title(MediaKind::Movie, "Vivant", Some(2023))
            .unwrap();
        db.upsert_metadata(&MetadataRecord {
            title_id: documentary,
            tmdb_id: Some(905),
            overview_fr: None,
            overview_en: None,
            poster_path: None,
            backdrop_path: None,
            genres: "Documentaire".to_string(),
            cast_names: "Yann Arthus-Bertrand".to_string(),
            collections: String::new(),
            director_names: "Yann Arthus-Bertrand".to_string(),
            writer_names: String::new(),
            composer_names: String::new(),
            source: MetadataSource::Tmdb,
            fetched_at: 1,
            critics: None,
            audience: None,
            release_date: None,
        })
        .unwrap();
        // a compilation titled after its writer, no one billed
        let sketches = db
            .upsert_title(MediaKind::Movie, "Sellig : Épisodes", Some(2021))
            .unwrap();
        describe_crew(&db, sketches, "", "Sellig");
        // a documentary titled after its subject
        let subject = db
            .upsert_title(MediaKind::Movie, "Avicii: True Stories", Some(2017))
            .unwrap();
        db.upsert_metadata(&MetadataRecord {
            title_id: subject,
            tmdb_id: Some(906),
            overview_fr: None,
            overview_en: None,
            poster_path: None,
            backdrop_path: None,
            genres: "Documentaire".to_string(),
            cast_names: "Avicii".to_string(),
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
        assert_eq!(db.stage_shows().unwrap(), HashSet::from([show, sketches]));
    }

    /// A filmed stage show is offered on its own shelf.
    #[test]
    fn a_stage_show_not_yet_seen_is_offered_on_its_own_shelf() {
        let db = home();
        let shows: HashSet<i64> = (0..SHELF)
            .map(|n| {
                let show = title_id(&db, &format!("Unopened {n:03}"));
                describe(&db, show, 900 + show, "Comedy");
                db.set_keywords(show, "stand-up comedy", 1).unwrap();
                show
            })
            .collect();
        let shelf = row_items(&db, &Reason::StageShows, NOW, 0).unwrap();
        assert_eq!(shelf.iter().map(|t| t.id).collect::<HashSet<_>>(), shows);
    }

    /// The band the pass swept, cut by the reach the viewer asked for.
    #[test]
    fn the_step_aside_row_reaches_as_far_as_the_setting_says() {
        let db = home();
        // six a side: a half-band under the shelf floor would not be drawn at
        // all, which is the row being selective rather than the reach failing
        let mut discovery = Vec::new();
        for (n, closeness) in [
            0.05f32, 0.1, 0.15, 0.2, 0.25, 0.3, 0.7, 0.75, 0.8, 0.85, 0.9, 0.95,
        ]
        .iter()
        .enumerate()
        {
            discovery.push(crate::index::db::DiscoveryPick {
                title_id: title_id(&db, &format!("Unopened {n:03}")),
                closeness: *closeness,
            });
        }
        db.replace_taste(&TastePassOutput {
            discovery,
            ..Default::default()
        })
        .unwrap();

        // by default the whole band is in the running
        let rows = browse_rows(&db, Some(MediaKind::Movie), NOW, 0, &HashSet::new()).unwrap();
        assert_eq!(find(&rows, "aside").unwrap().items.len(), 12);

        // "close" keeps the half nearest the taste, "far" the half out at the
        // library's own background: the same band, read from either end
        db.set_setting("step_aside.reach", "close").unwrap();
        let close = find(
            &browse_rows(&db, Some(MediaKind::Movie), NOW, 0, &HashSet::new()).unwrap(),
            "aside",
        )
        .map(|r| r.items.len())
        .unwrap_or(0);
        db.set_setting("step_aside.reach", "far").unwrap();
        let far = find(
            &browse_rows(&db, Some(MediaKind::Movie), NOW, 0, &HashSet::new()).unwrap(),
            "aside",
        )
        .map(|r| r.items.len())
        .unwrap_or(0);
        assert_eq!((close, far), (6, 6));
    }

    /// A mood is offered once it has a shelf behind it, and opens on what the
    /// viewer has not seen, whatever the pass stored before they saw it.
    #[test]
    fn a_mood_is_offered_with_a_shelf_behind_it_and_opens_on_the_unseen() {
        let db = home();
        let titles: Vec<i64> = (0..6)
            .map(|n| title_id(&db, &format!("Unopened {n:03}")))
            .collect();
        db.replace_taste(&TastePassOutput {
            seasonal: vec![
                ("light".to_string(), titles.clone()),
                ("chills".to_string(), titles[..3].to_vec()),
            ],
            ..Default::default()
        })
        .unwrap();
        assert_eq!(moods(&db).unwrap(), [("light", titles[..5].to_vec())]);
        let opened = row_items(
            &db,
            &Reason::Mood {
                key: "light".into(),
            },
            NOW,
            0,
        )
        .unwrap();
        assert_eq!(opened.iter().map(|t| t.id).collect::<Vec<_>>(), titles);
        // a mood is asked for, never dealt onto the shelf
        assert!(find(
            &browse_rows(&db, None, NOW, 0, &HashSet::new()).unwrap(),
            "mood"
        )
        .is_none());
    }

    /// The popular rows hold what the library has of the week's trending, in
    /// TMDB's order, films and series kept apart though their ids overlap.
    #[test]
    fn a_popular_row_follows_the_trending_order_of_its_own_kind() {
        let db = Db::open_in_memory().unwrap();
        for n in 0..6 {
            let id = db
                .upsert_title(MediaKind::Movie, &format!("Film {n}"), Some(2024))
                .unwrap();
            file(&db, id, &format!("Movies/Film {n}.mkv"));
            describe(&db, id, 100 + n, "Drama");
        }
        // the same id as Film 1, in the other sequence
        let show = db
            .upsert_title(MediaKind::Show, "Series", Some(2024))
            .unwrap();
        file(&db, show, "Shows/Series/S01E01.mkv");
        describe(&db, show, 101, "Drama");
        db.replace_trending(MediaKind::Movie, &[105, 999, 103, 101, 104, 102, 100], NOW)
            .unwrap();
        db.replace_trending(MediaKind::Show, &[101], NOW).unwrap();
        assert_eq!(db.trending_fetched_at().unwrap(), Some(NOW));

        let films = row_items(&db, &Reason::Popular { series: false }, NOW, 0).unwrap();
        assert_eq!(
            films.iter().map(|t| t.name.as_str()).collect::<Vec<_>>(),
            ["Film 5", "Film 3", "Film 1", "Film 4", "Film 2", "Film 0"]
        );
        // one trending series is no shelf
        assert!(row_items(&db, &Reason::Popular { series: true }, NOW, 0)
            .unwrap()
            .is_empty());
    }

    /// A filmed stand-up set sits near "light" by its words alone, and is
    /// still no film to deal for a mood.
    #[test]
    fn a_stage_show_is_left_out_of_a_mood() {
        let db = home();
        let titles: Vec<i64> = (0..6)
            .map(|n| title_id(&db, &format!("Unopened {n:03}")))
            .collect();
        describe(&db, titles[2], 902, "Comedy");
        db.set_keywords(titles[2], "stand-up comedy, paris", 1)
            .unwrap();
        db.replace_taste(&TastePassOutput {
            seasonal: vec![("light".to_string(), titles.clone())],
            ..Default::default()
        })
        .unwrap();
        // one performer who also wrote it, and no keyword to say so
        describe_crew(&db, titles[4], "Dieudonné", "Dieudonné");
        let opened = row_items(
            &db,
            &Reason::Mood {
                key: "light".into(),
            },
            NOW,
            0,
        )
        .unwrap();
        assert!(!opened
            .iter()
            .any(|t| t.id == titles[2] || t.id == titles[4]));
        assert_eq!(opened.len(), 4);
    }

    fn describe_crew(db: &Db, title_id: i64, cast: &str, writers: &str) {
        db.upsert_metadata(&MetadataRecord {
            title_id,
            tmdb_id: Some(903),
            overview_fr: None,
            overview_en: None,
            poster_path: None,
            backdrop_path: None,
            genres: "Comedy".to_string(),
            cast_names: cast.to_string(),
            collections: String::new(),
            director_names: String::new(),
            writer_names: writers.to_string(),
            composer_names: String::new(),
            source: MetadataSource::Tmdb,
            fetched_at: 1,
            critics: None,
            audience: None,
            release_date: None,
        })
        .unwrap();
    }

    /// A dated row exists in its window and nowhere else in the year.
    #[test]
    fn the_seasonal_row_is_drawn_only_inside_its_own_window() {
        let db = home();
        let titles: Vec<i64> = (0..6)
            .map(|n| title_id(&db, &format!("Unopened {n:03}")))
            .collect();
        db.replace_taste(&TastePassOutput {
            seasonal: vec![("oct".to_string(), titles)],
            ..Default::default()
        })
        .unwrap();

        // 2026-10-15 and 2026-08-15, both at noon UTC
        const IN_OCTOBER: i64 = 1_792_065_600;
        const IN_AUGUST: i64 = 1_786_968_000;
        let rows =
            browse_rows(&db, Some(MediaKind::Movie), IN_OCTOBER, 0, &HashSet::new()).unwrap();
        assert_eq!(
            find(&rows, "season").unwrap().reason,
            Reason::Season {
                window: "oct".to_string()
            }
        );
        let august =
            browse_rows(&db, Some(MediaKind::Movie), IN_AUGUST, 0, &HashSet::new()).unwrap();
        assert!(find(&august, "season").is_none());
    }

    /// A taste row that shows the same head day after day to a viewer who
    /// never takes it is saying nothing new: five days on, the head goes to
    /// the back and the titles behind it come forward, and a launch brings one
    /// back to the front.
    #[test]
    fn a_stable_taste_row_rotates_its_head_after_five_days_until_launched() {
        let db = Db::open_in_memory().unwrap();
        let heat = db
            .upsert_title(MediaKind::Movie, "Heat", Some(1995))
            .unwrap();
        let picks: Vec<i64> = (0..ROW_LIMIT as usize)
            .map(|n| {
                let id = db
                    .upsert_title(MediaKind::Movie, &format!("Pick {n:02}"), Some(2001))
                    .unwrap();
                file(&db, id, &format!("Movies/pick{n}.mkv"));
                id
            })
            .collect();
        db.replace_taste(&TastePassOutput {
            picks: picks
                .iter()
                .map(|&title_id| crate::index::db::TastePick {
                    title_id,
                    facet: 0,
                    leader: heat,
                })
                .collect(),
            ..Default::default()
        })
        .unwrap();
        let facet_row = |now: i64| -> Vec<i64> {
            let rows = browse_rows(&db, None, now, 0, &HashSet::new()).unwrap();
            record_shown(&db, &rows, now, 0).unwrap();
            find(&rows, "like")
                .unwrap()
                .items
                .iter()
                .map(|t| t.id)
                .collect()
        };
        for day in 0..5 {
            // asked twice a day, counted once
            facet_row(NOW + day * DAY);
            assert_eq!(facet_row(NOW + day * DAY + 3600), picks, "day {day}");
        }

        // the six a rail showed all week give way to the six behind them
        let tired = &picks[..ROW_VISIBLE];
        let rotated = facet_row(NOW + 5 * DAY);
        assert_eq!(rotated[..ROW_VISIBLE], picks[ROW_VISIBLE..2 * ROW_VISIBLE]);
        assert!(rotated.ends_with(tired), "{rotated:?}");
        // and the new head is not tired the next day for having been dealt
        assert_eq!(facet_row(NOW + 6 * DAY), rotated);

        db.record_launch(picks[0], NOW + 6 * DAY, "row", "taste_facet")
            .unwrap();
        let back = facet_row(NOW + 6 * DAY);
        assert_eq!(back[0], picks[0]);
        assert_eq!(back[1..=ROW_VISIBLE], picks[ROW_VISIBLE..2 * ROW_VISIBLE]);
    }

    /// The home is browsed many times a day and each title counts once: a
    /// browse that would change nothing opens no write at all.
    #[test]
    fn a_browse_already_counted_today_writes_nothing() {
        let tmp = tempfile::tempdir().unwrap();
        let path = tmp.path().join("index.sqlite");
        let db = Db::open(&path).unwrap();
        let heat = db
            .upsert_title(MediaKind::Movie, "Heat", Some(1995))
            .unwrap();
        let picks: Vec<i64> = (0..SHELF)
            .map(|n| {
                let id = db
                    .upsert_title(MediaKind::Movie, &format!("Pick {n}"), Some(2001))
                    .unwrap();
                file(&db, id, &format!("Movies/pick{n}.mkv"));
                id
            })
            .collect();
        db.replace_taste(&TastePassOutput {
            picks: picks
                .iter()
                .map(|&title_id| crate::index::db::TastePick {
                    title_id,
                    facet: 0,
                    leader: heat,
                })
                .collect(),
            ..Default::default()
        })
        .unwrap();
        let rows = browse_rows(&db, None, NOW, 0, &HashSet::new()).unwrap();
        record_shown(&db, &rows, NOW, 0).unwrap();
        // a connection that cannot write proves no write is attempted
        let reader = Db::open_read_only(&path).unwrap();
        record_shown(&reader, &rows, NOW + 3600, 0).unwrap();
    }

    /// Old on the shelf, never played, and in the taste as it stands now -
    /// which is what makes them worth saying anything about.
    #[test]
    fn the_forgotten_gems_are_old_never_played_titles_of_the_taste() {
        let db = home();
        taste(&db, &[("Rocky 0", 8)]);
        // everything arrived this month except five titles, which have been
        // sitting there over a year: those are the whole of the row's claim
        let old: HashSet<i64> = (0..5)
            .map(|n| title_id(&db, &format!("Unopened {n:03}")))
            .collect();
        db.conn()
            .execute("UPDATE titles SET added_at = ?1", params![NOW - 10 * DAY])
            .unwrap();
        for id in &old {
            db.conn()
                .execute(
                    "UPDATE titles SET added_at = ?1 WHERE id = ?2",
                    params![NOW - 400 * DAY, id],
                )
                .unwrap();
        }

        let rows = pool(&db, NOW);
        let gem = find(&rows, "gem").unwrap();
        let found: HashSet<i64> = gem.items.iter().map(|t| t.id).collect();
        assert_eq!(found, old, "the ones added long ago, not the new");
        assert_eq!(
            gem.reason,
            Reason::ForgottenGem {
                seed: "Rocky 0".to_string()
            }
        );
    }

    /// The thread shows what is left of itself and counts what is done.
    #[test]
    fn the_thread_carries_its_progress_and_shows_only_what_is_left() {
        let db = home();
        let leader = title_id(&db, "Rocky 0");
        let members: Vec<i64> = (0..5)
            .map(|n| title_id(&db, &format!("Unopened {n:03}")))
            .collect();
        db.create_thread(leader, 0, &members, NOW).unwrap();

        let rows = pool(&db, NOW);
        let thread = find(&rows, "thread").unwrap();
        assert_eq!(
            thread.reason,
            Reason::Thread {
                leader: "Rocky 0".to_string(),
                done: 0,
                total: 5
            }
        );
        assert_eq!(thread.items.len(), 5);

        // two watched: the row is shorter and says so
        for member in &members[..2] {
            let f: i64 = db
                .conn()
                .query_row(
                    "SELECT id FROM files WHERE title_id = ?1",
                    params![member],
                    |r| r.get(0),
                )
                .unwrap();
            watched(&db, f, NOW - DAY);
        }
        // three left is short of a shelf: the thread waits for its next lay
        let rows = pool(&db, NOW);
        assert!(find(&rows, "thread").is_none());
    }

    #[test]
    fn a_facet_names_itself_after_the_film_the_taste_was_built_around() {
        let db = home();
        taste(&db, &[("Rocky 0", 8)]);
        let rows = pool(&db, NOW);
        assert_eq!(
            find(&rows, "like").unwrap().reason,
            Reason::TasteFacet {
                leader: "Rocky 0".to_string(),
                leader_id: title_id(&db, "Rocky 0"),
            }
        );

        // a pass that wrote no leader wrote a row that cannot say why it is
        // there, and a row that cannot is not shown
        let orphan: Vec<crate::index::db::TastePick> = (0..8)
            .map(|n| crate::index::db::TastePick {
                title_id: title_id(&db, &format!("Unopened {n:03}")),
                facet: 0,
                leader: 0,
            })
            .collect();
        db.replace_taste(&TastePassOutput {
            picks: orphan,
            ..Default::default()
        })
        .unwrap();
        assert!(find(
            &browse_rows(&db, Some(MediaKind::Movie), NOW, 0, &HashSet::new()).unwrap(),
            "like"
        )
        .is_none());
    }

    /// Four tastes and two places for them: which two are offered moves with
    /// the day, or a fingerprint of four shows the same two every morning.
    #[test]
    fn the_facets_offered_are_dealt_by_the_day() {
        let db = home();
        taste(
            &db,
            &[("Heat", 8), ("Casino", 8), ("Goodfellas", 8), ("Near 0", 8)],
        );

        let mut over_a_fortnight: HashSet<String> = HashSet::new();
        for day in 0..14 {
            let rows = pool(&db, NOW + day * DAY);
            let leaders: Vec<String> = rows
                .iter()
                .filter_map(|row| match &row.reason {
                    Reason::TasteFacet { leader, .. } => Some(leader.clone()),
                    _ => None,
                })
                .collect();
            assert!(leaders.len() <= SUBJECTS, "{leaders:?}");
            over_a_fortnight.extend(leaders);
        }
        assert!(
            over_a_fortnight.len() > MAX_PER_KIND,
            "{over_a_fortnight:?}"
        );
    }

    #[test]
    fn a_row_says_it_has_more_only_when_it_is_full() {
        let db = home();
        let rows = browse_rows(&db, None, NOW, 0, &HashSet::new()).unwrap();
        assert!(rows.iter().any(|r| r.more));
        for row in &rows {
            assert_eq!(
                row.more,
                row.items.len() >= ROW_LIMIT as usize,
                "{:?}",
                row.reason
            );
        }
    }

    #[test]
    fn a_title_already_above_the_rows_is_not_said_again_below() {
        let db = home();
        let before = browse_rows(&db, None, NOW, 0, &HashSet::new()).unwrap();
        let shown: HashSet<i64> = before
            .iter()
            .filter(|r| !matches!(r.reason, Reason::RecentlyAdded))
            .flat_map(|r| r.items.iter().take(2).map(|t| t.id))
            .collect();
        assert!(!shown.is_empty());
        for row in browse_rows(&db, None, NOW, 0, &shown).unwrap() {
            if matches!(row.reason, Reason::RecentlyAdded) {
                continue;
            }
            assert!(row.items.len() >= floor(&row.reason), "{:?}", row.reason);
            for item in &row.items {
                assert!(!shown.contains(&item.id), "{:?}: {}", row.reason, item.name);
            }
        }
    }

    #[test]
    fn a_recommendation_row_recommends_nothing_already_watched() {
        let db = home();
        let rows = browse_rows(&db, Some(MediaKind::Movie), NOW, 0, &HashSet::new()).unwrap();
        let seen: HashSet<i64> = db
            .conn()
            .prepare("SELECT f.title_id FROM watch_state w JOIN files f ON f.id = w.file_id")
            .unwrap()
            .query_map([], |r| r.get(0))
            .unwrap()
            .collect::<Result<_, _>>()
            .unwrap();
        for row in &rows {
            if matches!(row.reason, Reason::LongAgo) {
                continue;
            }
            for item in &row.items {
                assert!(!seen.contains(&item.id), "{:?}: {}", row.reason, item.name);
            }
        }
    }

    #[test]
    fn a_recommendation_row_too_short_to_fill_a_shelf_is_left_out() {
        let db = Db::open_in_memory().unwrap();
        let dune = db
            .upsert_title(MediaKind::Movie, "Dune", Some(2021))
            .unwrap();
        let seen = file(&db, dune, "Movies/dune.mkv");
        watched(&db, seen, NOW);
        let near: Vec<i64> = (0..5)
            .map(|n| {
                let id = db
                    .upsert_title(MediaKind::Movie, &format!("Near {n}"), Some(2020))
                    .unwrap();
                file(&db, id, &format!("Movies/near{n}.mkv"));
                id
            })
            .collect();

        // four is what the model can vouch for, and four tiles beside rows of
        // twenty read as a broken shelf rather than a short one
        semantic(&db, dune, &near[..4]);
        assert!(!shape(&db, NOW).contains(&"watched"));

        // the same row with a screenful behind it is worth showing
        semantic(&db, dune, &near);
        let rows = browse_rows(&db, Some(MediaKind::Movie), NOW, 0, &HashSet::new()).unwrap();
        let row = find(&rows, "watched").unwrap();
        assert_eq!(
            row.reason,
            Reason::BecauseYouWatched {
                seed: "Dune".to_string(),
                seed_id: dune,
            }
        );
        assert_eq!(row.items.len(), SHELF);

        // and the next of a saga is not held to that: it is the viewer's own,
        // and one card is the whole of it
        for (n, id) in near.iter().enumerate() {
            describe_tags(&db, *id, "", "", if n < 2 { "Trilogie" } else { "" });
        }
        describe_tags(&db, dune, "", "", "Trilogie");
        let rows = browse_rows(&db, Some(MediaKind::Movie), NOW, 0, &HashSet::new()).unwrap();
        assert_eq!(names(find(&rows, "saga").unwrap()), ["Near 0"]);
    }

    #[test]
    fn a_contested_seed_seeds_no_row_until_the_contest_lapses() {
        let db = Db::open_in_memory().unwrap();
        let dune = db
            .upsert_title(MediaKind::Movie, "Dune", Some(2021))
            .unwrap();
        let seen = file(&db, dune, "Movies/dune.mkv");
        watched(&db, seen, NOW);
        let near: Vec<i64> = (0..6)
            .map(|n| {
                let id = db
                    .upsert_title(MediaKind::Movie, &format!("Near {n}"), Some(2020))
                    .unwrap();
                file(&db, id, &format!("Movies/near{n}.mkv"));
                id
            })
            .collect();
        semantic(&db, dune, &near);
        assert!(shape(&db, NOW).contains(&"watched"));

        db.mute_taste(dune, NOW + DAY).unwrap();
        assert!(!shape(&db, NOW).contains(&"watched"));
        assert!(shape(&db, NOW + 2 * DAY).contains(&"watched"));
    }

    #[test]
    fn the_similar_row_holds_one_kind_and_never_the_sentinel() {
        let db = library();
        let near = similar_titles(&db, title_id(&db, "Dune"), ROW_LIMIT).unwrap();
        // the show numbered like Blade Runner is another title entirely, and
        // every answer carries a sentinel row naming id 0
        assert_eq!(
            near.iter().map(|t| t.name.as_str()).collect::<Vec<_>>(),
            ["Blade Runner", "Solaris"]
        );
    }

    #[test]
    fn similar_titles_searches_from_the_title_asked_about_not_watch_history() {
        let db = Db::open_in_memory().unwrap();
        let dune = db
            .upsert_title(MediaKind::Movie, "Dune", Some(2021))
            .unwrap();
        let blade = db
            .upsert_title(MediaKind::Movie, "Blade Runner", Some(1982))
            .unwrap();
        file(&db, dune, "Movies/dune.mkv");
        file(&db, blade, "Movies/blade.mkv");
        describe(&db, dune, 438631, "Science-Fiction");
        describe(&db, blade, 78, "Science-Fiction");
        db.upsert_similar(438631, MediaKind::Movie, &[78]).unwrap();

        // nothing has ever been watched, so the home row's own seed would
        // find nothing; the detail screen's own query still has something,
        // because the title on screen stands in for the seed directly
        let near = similar_titles(&db, dune, ROW_LIMIT).unwrap();
        assert_eq!(
            near.iter().map(|t| t.name.as_str()).collect::<Vec<_>>(),
            ["Blade Runner"]
        );
    }

    #[test]
    fn similar_titles_is_empty_for_a_title_nothing_has_been_linked_to() {
        let db = Db::open_in_memory().unwrap();
        let alien = db
            .upsert_title(MediaKind::Movie, "Alien", Some(1979))
            .unwrap();
        file(&db, alien, "Movies/alien.mkv");
        describe(&db, alien, 348, "Horreur");

        // the common case on a real library: this title is matched to TMDB
        // but carries no similar link, and the semantic pass has never
        // searched from it either
        assert!(similar_titles(&db, alien, ROW_LIMIT).unwrap().is_empty());
    }

    #[test]
    fn the_model_reorders_the_row_tmdb_ordered_and_adds_what_it_missed() {
        let db = library();
        let dune = title_id(&db, "Dune");
        let solaris = title_id(&db, "Solaris");
        let home = title_id(&db, "Home Movie");
        // TMDB says Blade Runner then Solaris; the model says Solaris, then a
        // home movie TMDB has never heard of
        semantic(&db, dune, &[solaris, home]);

        let near = similar_titles(&db, dune, ROW_LIMIT).unwrap();
        // Solaris is on both lists and wins; Blade Runner is on one at rank 0
        // and beats the home movie, which is on one at rank 1
        assert_eq!(
            near.iter().map(|t| t.name.as_str()).collect::<Vec<_>>(),
            ["Solaris", "Blade Runner", "Home Movie"]
        );
    }

    /// A title vectorised after the seed names it, while the seed's own list
    /// was cut before it existed: the link is read from the newer side too,
    /// and a pair the model names both ways still counts once.
    #[test]
    fn the_model_links_a_newer_title_back_to_the_seed() {
        let db = library();
        let dune = title_id(&db, "Dune");
        let solaris = title_id(&db, "Solaris");
        let home = title_id(&db, "Home Movie");
        semantic(&db, home, &[dune]);
        semantic(&db, solaris, &[dune]);
        semantic(&db, dune, &[solaris]);

        let near = similar_titles(&db, dune, ROW_LIMIT).unwrap();
        assert_eq!(
            near.iter().map(|t| t.name.as_str()).collect::<Vec<_>>(),
            ["Solaris", "Blade Runner", "Home Movie"]
        );
    }

    #[test]
    fn a_show_never_reaches_a_films_similar_row() {
        let db = library();
        let dune = title_id(&db, "Dune");
        let lotus = title_id(&db, "Blade Runner: Black Lotus");
        // the pass keeps to one kind; the query does not take its word for it
        semantic(&db, dune, &[lotus]);

        let near = similar_titles(&db, dune, ROW_LIMIT).unwrap();
        assert!(!near.iter().any(|t| t.id == lotus));
    }

    /// A library nothing has ever matched to TMDB, which is every device with
    /// no key on it, and the state the owner's own index is in. Three films of
    /// one taste watched, six more of it unwatched, three of something else.
    fn unmatched_library() -> Db {
        let db = Db::open_in_memory().unwrap();
        for (n, name) in ["Seen One", "Seen Two", "Seen Three"].iter().enumerate() {
            let id = db.upsert_title(MediaKind::Movie, name, None).unwrap();
            let f = file(&db, id, &format!("Movies/seen{n}.mkv"));
            // one direction, so the fingerprint is one taste and its row is
            // the whole of what that taste picked rather than a third of it
            embed(&db, id, &[100, 0, 0, 0]);
            watched(&db, f, NOW - DAY);
        }
        for n in 0..6 {
            let id = db
                .upsert_title(MediaKind::Movie, &format!("Unseen {n}"), None)
                .unwrap();
            file(&db, id, &format!("Movies/unseen{n}.mkv"));
            embed(&db, id, &[100, n as i8 + 4, 0, 0]);
        }
        // a library that is not all one thing, so "nearer than average" means
        // something: without it every title here is everything's neighbour
        for n in 0..3 {
            let id = db
                .upsert_title(MediaKind::Movie, &format!("Elsewhere {n}"), None)
                .unwrap();
            file(&db, id, &format!("Movies/else{n}.mkv"));
            let mut v = [0i8; 4];
            v[n + 1] = 100;
            embed(&db, id, &v);
        }
        crate::index::taste::refresh(&db, NOW).unwrap();
        db
    }

    fn embed(db: &Db, title_id: i64, vector: &[i8]) {
        db.upsert_embedding(&crate::index::db::EmbeddingRecord {
            title_id,
            model_version: crate::embed::Encoder::Small.version(),
            source_hash: 0,
            vector: vector.to_vec(),
            computed_at: 1,
        })
        .unwrap();
    }

    #[test]
    fn the_fingerprint_row_renders_with_no_tmdb_id_in_the_index_at_all() {
        let db = unmatched_library();
        assert_eq!(
            db.conn()
                .query_row("SELECT COUNT(*) FROM metadata", [], |r| r.get::<_, i64>(0))
                .unwrap(),
            0,
            "the fixture is a library TMDB has never described"
        );

        let rows = browse_rows(&db, Some(MediaKind::Movie), NOW, 0, &HashSet::new()).unwrap();
        let picked = find(&rows, "like")
            .expect("a taste built out of vectors needs no tmdb_id to name a row");
        // the facet is named after the heaviest film in it, which is one of
        // the three the history holds
        let Reason::TasteFacet { leader, .. } = &picked.reason else {
            panic!("{:?}", picked.reason)
        };
        assert!(leader.starts_with("Seen "), "{leader}");
        assert_eq!(
            names(picked),
            ["Unseen 0", "Unseen 1", "Unseen 2", "Unseen 3", "Unseen 4", "Unseen 5"]
        );
    }

    #[test]
    fn a_title_watched_since_the_pass_ran_leaves_the_fingerprint_row() {
        let db = unmatched_library();
        let first = title_id(&db, "Unseen 0");
        // the picks are the last pass's; the read is what keeps them honest
        let f = db.file_id("s1", "Movies/unseen0.mkv").unwrap().unwrap();
        watched(&db, f, NOW);

        let rows = browse_rows(&db, Some(MediaKind::Movie), NOW, 0, &HashSet::new()).unwrap();
        let picked = find(&rows, "like").unwrap();
        assert!(!picked.items.iter().any(|t| t.id == first));
        assert_eq!(picked.items.len(), 5);
    }

    /// What a press costs on the way back to the home screen: nothing. Moving
    /// the rejected film's neighbours is a recompute of the fingerprint, and
    /// taking the film itself off the shelf is this read, which was going to
    /// happen anyway.
    #[test]
    fn a_title_the_viewer_rejected_leaves_the_fingerprint_row_without_a_recompute() {
        let db = unmatched_library();
        let first = title_id(&db, "Unseen 0");
        db.set_verdict(first, Some(crate::index::Verdict::Down), NOW)
            .unwrap();

        let rows = browse_rows(&db, Some(MediaKind::Movie), NOW, 0, &HashSet::new()).unwrap();
        let picked = find(&rows, "like").unwrap();
        assert!(!picked.items.iter().any(|t| t.id == first));
        assert_eq!(picked.items.len(), 5);

        // a title they said they liked is spent the same way - the row is for
        // what they have not decided about yet - and this fixture has nothing
        // left to fall back on, so the row goes rather than being padded. On a
        // real library `set_verdict` recomputes as it writes, and the row
        // refills out of the sixty picks the pass keeps for exactly this.
        db.set_verdict(
            title_id(&db, "Unseen 1"),
            Some(crate::index::Verdict::Loved),
            NOW,
        )
        .unwrap();
        let rows = browse_rows(&db, Some(MediaKind::Movie), NOW, 0, &HashSet::new()).unwrap();
        assert!(find(&rows, "like").is_none());
    }

    #[test]
    fn rediscovery_holds_still_for_a_day_and_moves_the_next() {
        let db = shelf();
        let deal = |now: i64| -> Vec<i64> {
            find(
                &browse_rows(&db, Some(MediaKind::Movie), now, 0, &HashSet::new()).unwrap(),
                "rediscovery",
            )
            .unwrap()
            .items
            .iter()
            .map(|t| t.id)
            .collect()
        };
        let today = deal(NOW);
        assert_eq!(today, deal(NOW + DAY - 1));

        // and another twenty of the forty tomorrow, which is how a shelf
        // deeper than a row is reachable at all
        let tomorrow = deal(NOW + DAY);
        assert_ne!(today, tomorrow);
        let fresh = tomorrow.iter().filter(|id| !today.contains(id)).count();
        assert!(fresh > 0, "{today:?} then {tomorrow:?}");
    }

    /// Two rows' worth of titles nothing has watched, ids handed out in
    /// sequence the way the scanner hands them out along a shelf. Two rows
    /// rather than one: a shelf a row can hold whole is a shelf the newest-
    /// first row already showed, and there is nothing left for the shuffle to
    /// reach.
    fn shelf() -> Db {
        let db = Db::open_in_memory().unwrap();
        for i in 0..2 * ROW_LIMIT as u16 {
            let id = db
                .upsert_title(MediaKind::Movie, &format!("Film {i}"), Some(2000 + i))
                .unwrap();
            file(&db, id, &format!("Movies/film{i}.mkv"));
        }
        db
    }

    #[test]
    fn rediscovery_reshuffles_the_shelf_rather_than_sliding_it() {
        let db = shelf();
        let day = |now: i64| -> Vec<i64> {
            find(
                &browse_rows(&db, Some(MediaKind::Movie), now, 0, &HashSet::new()).unwrap(),
                "rediscovery",
            )
            .unwrap()
            .items
            .iter()
            .map(|t| t.id)
            .collect()
        };
        let today = day(NOW);
        let tomorrow = day(NOW + DAY);
        assert_eq!(today.len(), ROW_LIMIT as usize);

        // "other titles" is not enough: a hash of (id + day) slides
        // the whole shelf, every slot taking its neighbour, which no id offset
        // may reproduce here beyond the few slots chance lines up
        for shift in 1..today.len() as i64 {
            for offset in [shift, -shift] {
                let slid = today
                    .iter()
                    .enumerate()
                    .filter(|(slot, id)| tomorrow.get(*slot) == Some(&(**id + offset)))
                    .count();
                assert!(slid <= 4, "offset {offset} kept {slid} slots");
            }
        }

        // and the titles both days hold must pass each other, not keep their
        // relative order
        let both: Vec<i64> = today
            .iter()
            .copied()
            .filter(|id| tomorrow.contains(id))
            .collect();
        let rank = |order: &[i64], id: i64| order.iter().position(|x| *x == id).unwrap();
        let flipped = both
            .iter()
            .flat_map(|a| both.iter().map(move |b| (*a, *b)))
            .filter(|(a, b)| a < b)
            .filter(|(a, b)| {
                (rank(&today, *a) < rank(&today, *b)) != (rank(&tomorrow, *a) < rank(&tomorrow, *b))
            })
            .count();
        assert!(flipped >= 2, "{flipped} pairs flipped of {}", both.len());
    }

    #[test]
    fn two_rows_dealt_on_one_day_are_not_dealt_alike() {
        // the two era rows draw on almost the same shelf here; dealt from the
        // day alone they would put the same titles at the front of both, and
        // the second row would read as the first one repeated
        let db = Db::open_in_memory().unwrap();
        for n in 0..100 {
            let id = db
                .upsert_title(MediaKind::Movie, &format!("Both {n:03}"), Some(1993))
                .unwrap();
            file(&db, id, &format!("Movies/both{n}.mkv"));
            describe_tags(&db, id, "Action,Drame", "", "");
        }
        for n in 0..4 {
            let id = db
                .upsert_title(MediaKind::Movie, &format!("Seen {n}"), Some(1993))
                .unwrap();
            let f = file(&db, id, &format!("Movies/seen{n}.mkv"));
            describe_tags(&db, id, "Action,Drame", "", "");
            watched(&db, f, NOW - DAY);
        }

        let rows = browse_rows(&db, Some(MediaKind::Movie), NOW, 0, &HashSet::new()).unwrap();
        let era: Vec<Vec<i64>> = rows
            .iter()
            .filter(|r| kind_key(&r.reason) == "era")
            .map(|r| r.items.iter().map(|t| t.id).collect())
            .collect();
        assert_eq!(era.len(), 2, "{:?}", shape(&db, NOW));
        assert_ne!(era[0], era[1]);
    }

    #[test]
    fn an_empty_library_has_no_rows_at_all() {
        let db = Db::open_in_memory().unwrap();
        assert!(
            browse_rows(&db, Some(MediaKind::Movie), NOW, 0, &HashSet::new())
                .unwrap()
                .is_empty()
        );

        // a library nobody has watched yet still has something to say, and
        // says it once: the shelf sweep at the foot of the screen is reserved
        // a place, not licensed to repeat the row above it
        for n in 0..SHELF {
            let id = db
                .upsert_title(MediaKind::Movie, &format!("Alien {n}"), Some(1979))
                .unwrap();
            file(&db, id, &format!("Movies/alien{n}.mkv"));
        }
        assert_eq!(shape(&db, NOW), ["recent"]);
    }

    #[test]
    fn a_watched_title_leaves_the_rows_it_no_longer_belongs_in() {
        let db = library();
        let solaris = title_id(&db, "Solaris");
        let file_id = db.file_id("s1", "Movies/solaris.mkv").unwrap().unwrap();
        watched(&db, file_id, NOW);

        let rows = browse_rows(&db, Some(MediaKind::Movie), NOW, 0, &HashSet::new()).unwrap();
        // What arrived is not one of them: a viewer told "recently added" is
        // owed what arrived, whether or not they have since watched it. The
        // shelf that row's last tile opens has always answered that way, and
        // the row disagreeing with it was the row being wrong.
        let recent = find(&rows, "recent").unwrap();
        assert!(recent.items.iter().any(|t| t.id == solaris));

        // and a similar row never recommends the title it was built from
        let near = similar_titles(&db, solaris, ROW_LIMIT).unwrap();
        assert!(!near.iter().any(|t| t.id == solaris));
        assert_eq!(
            near.iter().map(|t| t.name.as_str()).collect::<Vec<_>>(),
            ["Dune", "Blade Runner"]
        );
    }

    #[test]
    fn a_tag_is_matched_whole_and_literally() {
        let db = Db::open_in_memory().unwrap();
        // a Plex tag is whatever the user typed, wildcards included, and the
        // three tags below all match each other under a LIKE pattern
        for (n, tag) in ["Doc_100%", "DocX100Y", "Documentaire"].iter().enumerate() {
            for m in 0..3 {
                let id = db
                    .upsert_title(MediaKind::Movie, &format!("Seen {n}-{m}"), Some(2000))
                    .unwrap();
                let f = file(&db, id, &format!("Movies/seen{n}{m}.mkv"));
                describe_tags(&db, id, "", tag, "");
                watched(&db, f, NOW - (n as i64 + 1) * DAY);
            }
            for m in 0..6 {
                let id = db
                    .upsert_title(MediaKind::Movie, &format!("Film {n}-{m}"), Some(2001))
                    .unwrap();
                file(&db, id, &format!("Movies/film{n}{m}.mkv"));
                describe_tags(&db, id, "", tag, "");
            }
        }

        for day in 0..14 {
            let rows = browse_rows(
                &db,
                Some(MediaKind::Movie),
                NOW + day * DAY,
                0,
                &HashSet::new(),
            )
            .unwrap();
            for row in rows.iter().filter(|r| kind_key(&r.reason) == "actor") {
                let Reason::WithActor { name } = &row.reason else {
                    panic!()
                };
                // the tag is a value in title_tags matched by equality, so a
                // "%" in one of them is a per cent sign and not a pattern
                let group = ["Doc_100%", "DocX100Y", "Documentaire"]
                    .iter()
                    .position(|t| t == name)
                    .unwrap();
                assert!(
                    names(row)
                        .iter()
                        .all(|n| n.starts_with(&format!("Film {group}-"))),
                    "{name}: {:?}",
                    names(row)
                );
            }
        }
    }

    /// A library for the three "same ..." rails: Dune shares both genres with
    /// Aventures Spatiales and only one with Blade Runner, so the count is
    /// what leads; Dune and its own sequel share a lead actor and a saga
    /// nothing else belongs to; Alien, Solaris and the show carry none of it.
    fn sagas() -> Db {
        let db = Db::open_in_memory().unwrap();
        let dune = db
            .upsert_title(MediaKind::Movie, "Dune", Some(2021))
            .unwrap();
        let dune2 = db
            .upsert_title(MediaKind::Movie, "Dune: Part Two", Some(2024))
            .unwrap();
        let aventures = db
            .upsert_title(MediaKind::Movie, "Aventures Spatiales", Some(1999))
            .unwrap();
        let blade = db
            .upsert_title(MediaKind::Movie, "Blade Runner", Some(1982))
            .unwrap();
        let alien = db
            .upsert_title(MediaKind::Movie, "Alien", Some(1979))
            .unwrap();
        let show = db
            .upsert_title(MediaKind::Show, "Dune: The Sisterhood", None)
            .unwrap();
        for (id, path) in [
            (dune, "Movies/dune.mkv"),
            (dune2, "Movies/dune2.mkv"),
            (aventures, "Movies/aventures.mkv"),
            (blade, "Movies/blade.mkv"),
            (alien, "Movies/alien.mkv"),
            (show, "Shows/sisterhood.mkv"),
        ] {
            file(&db, id, path);
        }
        describe_tags(
            &db,
            dune,
            "Science-Fiction,Aventure",
            "Timothee Chalamet,Rebecca Ferguson",
            "Dune Saga",
        );
        describe_tags(
            &db,
            dune2,
            "Science-Fiction",
            "Timothee Chalamet,Zendaya",
            "Dune Saga",
        );
        describe_tags(&db, aventures, "Science-Fiction,Aventure", "", "");
        describe_tags(&db, blade, "Science-Fiction,Thriller", "Harrison Ford", "");
        describe_tags(
            &db,
            alien,
            "Horreur,Science-Fiction",
            "Sigourney Weaver",
            "",
        );
        // a show tagged the same genre, cast and saga must never reach a
        // film's row: same_tag matches kind as strictly as SIMILAR does
        describe_tags(
            &db,
            show,
            "Science-Fiction,Aventure",
            "Timothee Chalamet",
            "Dune Saga",
        );
        db
    }

    #[test]
    fn same_genre_leads_with_the_most_shared_genres_and_excludes_itself() {
        let db = sagas();
        let dune = title_id(&db, "Dune");
        let near = same_genre(&db, dune, MediaKind::Movie, ROW_LIMIT).unwrap();
        // both genres beats one, ties go to the nearest year, and Dune
        // itself and the show that carries the same tags never appear
        assert_eq!(
            near.iter().map(|t| t.name.as_str()).collect::<Vec<_>>(),
            [
                "Aventures Spatiales",
                "Dune: Part Two",
                "Blade Runner",
                "Alien"
            ]
        );
    }

    #[test]
    fn same_cast_surfaces_even_a_single_shared_actor() {
        let db = sagas();
        let dune = title_id(&db, "Dune");
        let near = same_cast(&db, dune, MediaKind::Movie, ROW_LIMIT).unwrap();
        // one shared name is enough to earn the rail's place, and a film with
        // none of Dune's billing (Blade Runner, Alien) is not in it
        assert_eq!(
            near.iter().map(|t| t.name.as_str()).collect::<Vec<_>>(),
            ["Dune: Part Two"]
        );
    }

    #[test]
    fn same_saga_is_empty_for_the_ordinary_title_and_full_for_a_franchise() {
        let db = sagas();
        let dune = title_id(&db, "Dune");
        let blade = title_id(&db, "Blade Runner");
        let near = same_saga(&db, dune, MediaKind::Movie, ROW_LIMIT).unwrap();
        assert_eq!(
            near.iter().map(|t| t.name.as_str()).collect::<Vec<_>>(),
            ["Dune: Part Two"]
        );

        // the common case on this library: a title in no collection at all,
        // which the rail has to leave out rather than draw empty
        assert!(same_saga(&db, blade, MediaKind::Movie, ROW_LIMIT)
            .unwrap()
            .is_empty());
    }

    fn plan(db: &Db, sql: &str, args: impl rusqlite::Params) -> Vec<String> {
        let mut stmt = db
            .conn()
            .prepare(&format!("EXPLAIN QUERY PLAN {sql}"))
            .unwrap();
        let steps = stmt.query_map(args, |r| r.get(3)).unwrap();
        steps.collect::<Result<_, _>>().unwrap()
    }

    /// The screen is a dozen queries now instead of five, so each of them has
    /// to stay a lookup: the similar row a lookup of the links, the subject
    /// queries a walk of what history holds, the tag rows a lookup of the tag
    /// index, the recently added row a walk of its own index. Any of them
    /// driving from titles or files grows with the shelf, and twelve of those
    /// is a home screen that stalls.
    #[test]
    fn the_rows_are_driven_by_the_links_the_history_and_the_tags() {
        let db = home();

        // the fused row is still two lookups and a walk of what they returned:
        // "SCAN f" is the forty rows of the union, not the library
        let steps = plan(&db, &SIMILAR_UNSEEN, params!["movie", 438631, 1, ROW_LIMIT]);
        // the links must be the entry point of their branch, not merely looked
        // up somewhere inside it: reordered, the branch drives from every movie
        // in the library, and SQLite calls that a SEARCH too, on the kind
        // prefix of the name index, so no SCAN assertion can catch it
        let branch = steps
            .iter()
            .position(|s| s.contains("LEFT-MOST SUBQUERY"))
            .unwrap_or_else(|| panic!("{steps:#?}"));
        assert!(steps[branch + 1].contains("tmdb_similar"), "{steps:#?}");
        assert!(
            steps.iter().any(|s| s.contains("SEARCH n USING INDEX")),
            "{steps:#?}"
        );
        assert!(
            !steps
                .iter()
                .any(|s| s.contains("SCAN t") || s.contains("SCAN m")),
            "{steps:#?}"
        );

        // the subject queries are the history joined to the tags one title at
        // a time. Left to choose, SQLite reads the lookup index on its kind
        // prefix alone and walks every cast row in the library per title
        // watched, which is a home screen slower by an order of magnitude and
        // still a "SEARCH".
        let subjects = [
            plan(
                &db,
                &TAG_SUBJECTS,
                params![HISTORY_WINDOW, "cast", ACTOR_FLOOR, SUBJECT_POOL],
            ),
            plan(
                &db,
                &ERA_SUBJECTS,
                params![HISTORY_WINDOW, ERA_FLOOR, SUBJECT_POOL],
            ),
        ];
        for steps in subjects {
            assert!(steps.iter().any(|s| s.contains("SCAN w")), "{steps:#?}");
            assert!(
                steps
                    .iter()
                    .any(|s| s.contains("SEARCH g") && s.contains("idx_title_tags_title")),
                "{steps:#?}"
            );
        }

        // a tag's own row is a lookup of the value, never a walk of the tagged
        let steps = plan(
            &db,
            &TAG_UNSEEN,
            params!["cast", "Robert De Niro", ROW_LIMIT],
        );
        assert!(
            steps[0].contains("SEARCH g") && steps[0].contains("idx_title_tags_lookup"),
            "{steps:#?}"
        );
        let steps = plan(&db, &ERA_UNSEEN, params!["Horreur", 1980, 7, ROW_LIMIT]);
        assert!(
            steps[0].contains("SEARCH g") && steps[0].contains("idx_title_tags_lookup"),
            "{steps:#?}"
        );

        // and the newest of each kind is the kind's added index walked to the
        // limit: sorted instead, the row costs a pass over every title there
        // is. Only the two limited walks are sorted together.
        let steps = plan(&db, RECENT, params![ROW_LIMIT]);
        let walks = steps
            .iter()
            .filter(|s| s.contains("SEARCH t USING INDEX idx_titles_kind_added"))
            .count();
        assert_eq!(walks, 2, "{steps:#?}");
        assert!(!steps.iter().any(|s| s.starts_with("SCAN t")), "{steps:#?}");
    }

    #[test]
    fn the_same_tag_rails_are_driven_by_the_tag_index_not_a_library_scan() {
        let db = sagas();
        let dune = title_id(&db, "Dune");
        let steps = plan(&db, SAME_TAG, params![dune, "genre", "movie", ROW_LIMIT]);
        // "mine" is looked up on title_id, and every match on "g" goes through
        // the same lookup index the other way: neither branch may walk the
        // whole table title_tags holds, which grows with the library
        assert!(
            steps
                .iter()
                .any(|s| s.contains("SEARCH mine") && s.contains("idx_title_tags_title")),
            "{steps:#?}"
        );
        assert!(
            steps
                .iter()
                .any(|s| s.contains("SEARCH g") && s.contains("idx_title_tags_lookup")),
            "{steps:#?}"
        );
        assert!(
            !steps
                .iter()
                .any(|s| s.contains("SCAN t") || s.contains("SCAN titles")),
            "{steps:#?}"
        );
    }

    /// A film with a known release date and a file, as TMDB would have left it.
    fn released(db: &Db, name: &str, date: &str) -> i64 {
        let id = db.upsert_title(MediaKind::Movie, name, None).unwrap();
        file(db, id, &format!("Movies/{name}.mkv"));
        db.conn()
            .execute(
                "INSERT INTO metadata (title_id, source, fetched_at, release_date)
                 VALUES (?1, 'tmdb', 1, ?2)",
                params![id, date],
            )
            .unwrap();
        id
    }

    fn day_rows(rows: &[Row]) -> Vec<&Row> {
        rows.iter()
            .filter(|r| kind_key(&r.reason) == "day")
            .collect()
    }

    /// Twenty years to the day is an anniversary, and so is twenty years and
    /// two days; twenty-one is not a number anyone counts, and five days off
    /// is another week.
    #[test]
    fn a_film_out_twenty_years_ago_today_is_on_this_day_and_twenty_one_is_not() {
        let db = Db::open_in_memory().unwrap();
        let date = |at: i64, back: i64| {
            let (y, m, d) = civil(at);
            format!("{}-{m:02}-{d:02}", y - back)
        };
        for n in 0..4 {
            released(&db, &format!("Twenty {n}"), &date(NOW, 20));
        }
        released(&db, "Twenty One", &date(NOW, 21));
        released(&db, "Twenty Near", &date(NOW + 2 * DAY, 20));
        released(&db, "Twenty Far", &date(NOW + 5 * DAY, 20));

        let rows = browse_rows(&db, None, NOW, 0, &HashSet::new()).unwrap();
        let days = day_rows(&rows);
        assert_eq!(days.len(), 1, "{rows:?}");
        assert_eq!(
            days[0].reason,
            Reason::OnThisDay {
                kind: DayKind::Anniversary { years: 20 }
            }
        );
        let mut found = names(days[0]);
        found.sort_unstable();
        assert_eq!(
            found,
            [
                "Twenty 0",
                "Twenty 1",
                "Twenty 2",
                "Twenty 3",
                "Twenty Near"
            ]
        );
    }

    /// The same day also brings back what was finished a year ago.
    #[test]
    fn what_was_finished_a_year_ago_is_on_this_day_too() {
        let db = Db::open_in_memory().unwrap();
        for (name, back) in [
            ("Last Year 0", 365),
            ("Last Year 1", 365),
            ("Last Year 2", 365),
            ("Last Year 3", 365),
            ("Last Year 4", 365),
            ("Two Years Ago", 730),
        ] {
            let id = db.upsert_title(MediaKind::Movie, name, None).unwrap();
            let f = file(&db, id, &format!("Movies/{name}.mkv"));
            watched(&db, f, NOW - back * DAY + 3_600);
        }
        let rows = browse_rows(&db, None, NOW, 0, &HashSet::new()).unwrap();
        let days = day_rows(&rows);
        assert_eq!(days.len(), 1, "{rows:?}");
        assert_eq!(
            days[0].reason,
            Reason::OnThisDay {
                kind: DayKind::YearAgo
            }
        );
        let mut found = names(days[0]);
        found.sort_unstable();
        assert_eq!(
            found,
            [
                "Last Year 0",
                "Last Year 1",
                "Last Year 2",
                "Last Year 3",
                "Last Year 4"
            ]
        );
    }

    /// Finishing one of a director's films opens all of their work, in the
    /// order it was made, at the head of the rows under what arrived and in
    /// place of the row of what is left of them - for a week, and not on the
    /// eighth day.
    #[test]
    fn a_retrospective_runs_a_week_and_is_gone_on_the_eighth_day() {
        let db = Db::open_in_memory().unwrap();
        let mut ids = Vec::new();
        for (name, year) in [
            ("Sans toit", 1985),
            ("Cleo", 1962),
            ("Glaneurs", 2000),
            ("Kung-fu", 1988),
            ("Bonheur", 1965),
            ("Jacquot", 1991),
            ("Visages", 2017),
        ] {
            let id = db.upsert_title(MediaKind::Movie, name, Some(year)).unwrap();
            file(&db, id, &format!("Movies/{name}.mkv"));
            describe_director(&db, id, "Agnes Varda");
            ids.push(id);
        }
        let f = |id: i64| -> i64 {
            db.conn()
                .query_row("SELECT id FROM files WHERE title_id = ?1", [id], |r| {
                    r.get(0)
                })
                .unwrap()
        };
        watched(&db, f(ids[3]), NOW - 20 * DAY);
        watched(&db, f(ids[0]), NOW - 6 * DAY);

        let rows = browse_rows(&db, None, NOW, 0, &HashSet::new()).unwrap();
        let head = rows
            .iter()
            .find(|r| r.reason != Reason::RecentlyAdded)
            .unwrap();
        assert_eq!(
            head.reason,
            Reason::Retrospective {
                name: "Agnes Varda".into()
            }
        );
        assert_eq!(
            names(head),
            [
                "Cleo",
                "Bonheur",
                "Sans toit",
                "Kung-fu",
                "Jacquot",
                "Glaneurs",
                "Visages"
            ]
        );
        assert!(find(&rows, "director").is_none(), "{rows:?}");

        // the eighth day: the director's own row is back, of what is left
        let rows = browse_rows(&db, None, NOW + 2 * DAY, 0, &HashSet::new()).unwrap();
        assert!(find(&rows, "retro").is_none(), "{rows:?}");
        assert_eq!(
            names(find(&rows, "director").unwrap()),
            ["Visages", "Glaneurs", "Jacquot", "Bonheur", "Cleo"]
        );

        // and a film turned down opens nothing
        db.set_verdict(ids[0], Some(crate::index::Verdict::Down), NOW)
            .unwrap();
        assert!(find(
            &browse_rows(&db, None, NOW, 0, &HashSet::new()).unwrap(),
            "retro"
        )
        .is_none());
    }

    /// Two tastes, one of which the viewer comes back to every November: in
    /// November it has a row of its own, and in March, a month with nothing
    /// behind it, nothing does.
    #[test]
    fn a_facet_that_comes_out_every_november_leads_in_november_and_not_in_march() {
        let db = Db::open_in_memory().unwrap();
        let mut watched_facet = Vec::new();
        let mut spend = |name: String, facet: u32, at: i64| {
            let id = db.upsert_title(MediaKind::Movie, &name, None).unwrap();
            let f = file(&db, id, &format!("Movies/{name}.mkv"));
            watched(&db, f, at);
            watched_facet.push((id, facet));
            id
        };
        let at = |y: i64, m: u32| days_of(y, m, 10) * DAY + 20 * 3_600;
        let mut leaders = [0; 2];
        for y in 2021..=2023 {
            for n in 0..2 {
                leaders[1] = spend(format!("Autumn {y} {n}"), 1, at(y, 11));
            }
        }
        for n in 0..16 {
            leaders[0] = spend(
                format!("Year Round {n}"),
                0,
                at(2022 + n % 2, 1 + (n as u32 % 8)),
            );
        }
        spend("Autumn Stray".into(), 0, at(2022, 11));
        let mut picks = Vec::new();
        for n in 0..6 {
            let id = db
                .upsert_title(MediaKind::Movie, &format!("Waiting {n}"), None)
                .unwrap();
            file(&db, id, &format!("Movies/waiting{n}.mkv"));
            picks.push(crate::index::db::TastePick {
                title_id: id,
                facet: 1,
                leader: leaders[1],
            });
        }
        let facets = (0..2)
            .map(|f| crate::index::db::TasteFacetMeta {
                facet: f,
                weight: 1.0,
                leader: leaders[f as usize],
                cos_to_top: 0.0,
            })
            .collect();
        db.replace_taste(&TastePassOutput {
            picks,
            facets,
            watched_facet,
            ..Default::default()
        })
        .unwrap();

        let november = days_of(2024, 11, 15) * DAY + 12 * 3_600;
        let rows = browse_rows(&db, None, november, 0, &HashSet::new()).unwrap();
        let month = find(&rows, "month").expect("the month's taste");
        assert_eq!(
            month.reason,
            Reason::ThisMonth {
                month: 11,
                leader: "Autumn 2023 1".into()
            }
        );
        assert_eq!(month.items.len(), 6);

        let march = days_of(2025, 3, 15) * DAY + 12 * 3_600;
        assert!(find(
            &browse_rows(&db, None, march, 0, &HashSet::new()).unwrap(),
            "month"
        )
        .is_none());
    }

    /// Unseen titles, stored as members of one club theme at an affinity each,
    /// the way the taste pass leaves them.
    fn themed(db: &Db, kind: &str, value: &str, names: &[(&str, f32)]) -> Vec<i64> {
        let mut members = Vec::new();
        for (name, affinity) in names {
            let id = db.upsert_title(MediaKind::Movie, name, None).unwrap();
            file(db, id, &format!("Movies/{name}.mkv"));
            members.push((id, *affinity));
        }
        for (id, affinity) in &members {
            db.conn()
                .execute(
                    "INSERT INTO club_pick (kind, value, title_id, affinity) VALUES (?1, ?2, ?3, ?4)",
                    params![kind, value, id, affinity],
                )
                .unwrap();
        }
        members.into_iter().map(|(id, _)| id).collect()
    }

    fn club(rows: &[Row]) -> Option<&Row> {
        find(rows, "club")
    }

    fn five(prefix: &str) -> Vec<(String, f32)> {
        (0..5)
            .map(|n| (format!("{prefix} {n}"), 0.9 - n as f32 / 100.0))
            .collect()
    }

    fn names_of_pairs(pairs: &[(String, f32)]) -> Vec<(&str, f32)> {
        pairs.iter().map(|(n, a)| (n.as_str(), *a)).collect()
    }

    /// The club is read off the themes the taste pass stored, at the head of
    /// the screen under what arrived, its titles nearest the taste first,
    /// until the next Monday.
    #[test]
    fn the_club_is_the_stored_theme_at_the_head_of_the_screen() {
        let db = Db::open_in_memory().unwrap();
        let heist = five("Heist");
        let ids = themed(&db, "keyword", "heist", &names_of_pairs(&heist));
        let rows = browse_rows(&db, None, NOW, 0, &HashSet::new()).unwrap();
        let head = rows
            .iter()
            .find(|r| r.reason != Reason::RecentlyAdded)
            .unwrap();
        let Reason::CineClub { theme, ends_at } = &head.reason else {
            panic!("{rows:?}");
        };
        assert_eq!(
            theme,
            &ClubTheme::Keyword {
                word: "heist".into()
            }
        );
        // NOW is a Friday: the club runs to the Monday after
        assert_eq!(*ends_at, NOW.div_euclid(DAY) * DAY + 3 * DAY);
        assert_eq!(head.items.iter().map(|t| t.id).collect::<Vec<_>>(), ids);

        // a member watched since the pass is not offered, and four is not a club
        let f: i64 = db
            .conn()
            .query_row("SELECT id FROM files WHERE title_id = ?1", [ids[0]], |r| {
                r.get(0)
            })
            .unwrap();
        watched(&db, f, NOW - DAY);
        assert!(club(&browse_rows(&db, None, NOW, 0, &HashSet::new()).unwrap()).is_none());
    }

    /// A club title already on the home above the rows leaves the club, and
    /// the next of the theme takes its place: the row is still five.
    #[test]
    fn the_club_keeps_five_titles_when_one_is_already_on_the_home() {
        let db = Db::open_in_memory().unwrap();
        let mut heist = five("Heist");
        heist.push(("Heist 5".into(), 0.5));
        let ids = themed(&db, "keyword", "heist", &names_of_pairs(&heist));
        let shown: HashSet<i64> = [ids[1]].into_iter().collect();
        let rows = browse_rows(&db, None, NOW, 0, &shown).unwrap();
        let club = club(&rows).expect("the club survives the title above it");
        assert_eq!(
            club.items.iter().map(|t| t.id).collect::<Vec<_>>(),
            [ids[0], ids[2], ids[3], ids[4], ids[5]]
        );
    }

    /// The theme holds all week and is another the next, however the week's
    /// deal falls, and the home reads nothing but the stored themes to say so.
    #[test]
    fn the_club_keeps_its_theme_all_week_and_changes_it_the_next() {
        let db = Db::open_in_memory().unwrap();
        themed(&db, "keyword", "heist", &names_of_pairs(&five("Heist")));
        themed(
            &db,
            "composer",
            "Ennio Morricone",
            &names_of_pairs(&five("Western")),
        );
        themed(
            &db,
            "writer",
            "Paul Schrader",
            &names_of_pairs(&five("Taxi")),
        );
        let theme = |now: i64| -> ClubTheme {
            let rows = browse_rows(&db, None, now, 0, &HashSet::new()).unwrap();
            match &club(&rows).expect("a club").reason {
                Reason::CineClub { theme, .. } => theme.clone(),
                other => panic!("{other:?}"),
            }
        };
        let mut last = theme(NOW);
        assert_eq!(theme(NOW + DAY), last, "the same week");
        for week in 1..30 {
            let next = theme(NOW + week * 7 * DAY);
            assert_ne!(next, last, "week {week}");
            last = next;
        }
        for (sql, args) in [
            (CLUB_THEMES, vec![]),
            (CLUB_ITEMS, vec!["keyword", "heist"]),
        ] {
            let steps = if args.is_empty() {
                plan(&db, sql, [])
            } else {
                plan(&db, sql, params![args[0], args[1], ROW_LIMIT])
            };
            for step in &steps {
                assert!(
                    !step.starts_with("SCAN") || step.contains("club_pick"),
                    "{sql}: {steps:?}"
                );
            }
        }
    }

    /// A show with its episodes, the first `done` finished at `at`, one hour
    /// apart, and the one after left at `position` seconds when not 0.
    fn followed(db: &Db, name: &str, episodes: u16, done: u16, at: i64, position: f64) -> Vec<i64> {
        let show = db.upsert_title(MediaKind::Show, name, None).unwrap();
        let files: Vec<i64> = (1..=episodes)
            .map(|e| episode(db, show, &format!("Shows/{name}e{e:02}.mkv"), 1, e))
            .collect();
        for (n, f) in files.iter().take(done as usize).enumerate() {
            watched(db, *f, at + n as i64 * 3_600);
        }
        if position > 0.0 {
            in_progress(db, files[done as usize], position, at + done as i64 * 3_600);
        }
        files
    }

    /// A series left at the end of its sixth episode two months ago is in
    /// the queue at the seventh; one stopped in the middle of an episode is
    /// too, where it stopped; one left last week at its next episode; and a
    /// finished one whose new season arrived since at the start of it. All
    /// in one row, ranked by when each last moved.
    #[test]
    fn the_queue_is_what_runs_what_is_next_what_was_set_down_and_what_is_new() {
        let db = Db::open_in_memory().unwrap();
        let mad_men = followed(&db, "Mad Men", 10, 6, NOW - 60 * DAY, 0.0);
        followed(&db, "Lost", 10, 5, NOW - 70 * DAY, 1_200.0);
        let wire = followed(&db, "The Wire", 10, 4, NOW - 7 * DAY, 0.0);
        followed(&db, "Severance", 4, 4, NOW - 90 * DAY, 0.0);
        let opener = second_season(&db, "Severance", NOW - 10 * DAY);
        let queue = crate::index::queries::up_next(&db, 20, NOW).unwrap();
        let found: Vec<(&str, Option<i64>)> = queue
            .iter()
            .map(|q| (q.title.name.as_str(), q.resume_file_id))
            .collect();
        let lost = queue.iter().find(|q| q.title.name == "Lost").unwrap();
        assert_eq!(
            found,
            [
                ("The Wire", Some(wire[4])),
                ("Severance", Some(opener)),
                ("Mad Men", Some(mad_men[6])),
                ("Lost", lost.resume_file_id),
            ]
        );
        assert!(lost.position_secs > 0.0);
        // and none of them is a row of its own any more
        let rows = browse_rows(&db, None, NOW, 0, &HashSet::new()).unwrap();
        assert!(
            rows.iter().all(|r| !names(r).contains(&"Mad Men")),
            "{rows:?}"
        );
    }

    /// A director named on the home a week with nothing of theirs played
    /// rests, and is back once the rest is over.
    #[test]
    fn a_director_passed_over_for_a_week_rests_for_a_month() {
        let db = Db::open_in_memory().unwrap();
        filmography(&db, "Jacques Audiard", 2, 5);
        let today = NOW / DAY;
        for day in today - 6..=today {
            db.record_row_subjects(&[("director", "Jacques Audiard")], day)
                .unwrap();
        }
        let rows = browse_rows(&db, Some(MediaKind::Movie), NOW, 0, &HashSet::new()).unwrap();
        assert!(find(&rows, "director").is_none(), "{rows:?}");
        let later = NOW + 31 * DAY;
        let rows = browse_rows(&db, Some(MediaKind::Movie), later, 0, &HashSet::new()).unwrap();
        assert!(find(&rows, "director").is_some(), "{rows:?}");
    }

    /// A title a "because you watched" row was named after for a week with
    /// nothing launched off such a row stops naming one for a month.
    #[test]
    fn a_seed_passed_over_for_a_week_rests_for_a_month() {
        let db = home();
        let seeded = |rows: &[Row]| -> Vec<i64> {
            rows.iter()
                .filter_map(|r| match &r.reason {
                    Reason::BecauseYouWatched { seed_id, .. } => Some(*seed_id),
                    _ => None,
                })
                .collect()
        };
        let heat = title_id(&db, "Heat");
        let today = NOW / DAY;
        for day in today - 6..=today {
            db.record_row_subjects(&[(SEED_SUBJECT, &heat.to_string())], day)
                .unwrap();
        }
        for day in 0..5 {
            let rows = browse_rows(&db, None, NOW + day * DAY, 0, &HashSet::new()).unwrap();
            assert!(!seeded(&rows).contains(&heat), "{:?}", seeded(&rows));
        }
        let later = NOW + 31 * DAY;
        let back = (0..5).any(|day| {
            let rows = browse_rows(&db, None, later + day * DAY, 0, &HashSet::new()).unwrap();
            seeded(&rows).contains(&heat)
        });
        assert!(back);
    }

    /// A page read on two days and never started leaves the rows that
    /// recommend it; read once, it is still an interest.
    #[test]
    fn a_title_read_twice_and_never_started_leaves_the_recommendations() {
        let db = Db::open_in_memory().unwrap();
        filmography(&db, "Jacques Audiard", 2, 6);
        let (twice, once) = (
            title_id(&db, "Jacques Audiard 2"),
            title_id(&db, "Jacques Audiard 3"),
        );
        for day in [3, 1] {
            db.record_interest(twice, crate::index::db::TASTE_DWELL, NOW - day * DAY)
                .unwrap();
        }
        db.record_interest(once, crate::index::db::TASTE_DWELL, NOW - DAY)
            .unwrap();
        let rows = browse_rows(&db, Some(MediaKind::Movie), NOW, 0, &HashSet::new()).unwrap();
        let row = find(&rows, "director").expect("a director row");
        assert!(row.items.iter().all(|t| t.id != twice), "{row:?}");
        assert!(row.items.iter().any(|t| t.id == once), "{row:?}");
    }

    /// A second season of `name`, its two episodes on the shelf since `mtime`.
    fn second_season(db: &Db, name: &str, mtime: i64) -> i64 {
        let show = db.upsert_title(MediaKind::Show, name, None).unwrap();
        (1..=2)
            .map(|e| {
                db.upsert_file(&FileRecord {
                    source_id: "s1".into(),
                    dir: "Shows".into(),
                    path: format!("Shows/{name}s02e{e:02}.mkv"),
                    size: 1,
                    mtime,
                    seen_gen: 1,
                    title_id: show,
                    season: Some(2),
                    episode: Some(e),
                    rating_key: None,
                    media: FileMedia::default(),
                })
                .unwrap()
            })
            .next()
            .unwrap()
    }

    /// The list leads the rows, ahead of anything the day deals, however
    /// short it is.
    #[test]
    fn the_list_leads_the_rows() {
        let db = home();
        let listed = title_id(&db, "Unopened 050");
        db.set_watchlisted(listed, true, NOW - DAY).unwrap();
        let rows = browse_rows(&db, None, NOW, 0, &HashSet::new()).unwrap();
        assert_eq!(rows[0].reason, Reason::Watchlist, "{rows:?}");
        assert_eq!(names(&rows[0]), ["Unopened 050"]);
        // and under it, no more than the screen carries
        assert!(rows.len() <= MAX_ROWS + 1, "{}", rows.len());
    }
}
