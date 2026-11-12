use super::{MediaKind, Verdict};
use crate::metadata::enrich::normalize;
use rusqlite::{params, types::ToSql, Connection, OpenFlags, OptionalExtension};
use std::collections::{HashMap, HashSet};
use std::path::Path;

#[derive(Debug, thiserror::Error)]
pub enum IndexError {
    #[error("sqlite error: {0}")]
    Sqlite(#[from] rusqlite::Error),
    #[error(
        "this index was written by a newer version of the app (schema {found}, \
         this build reads up to schema {supported}); the file was left on disk untouched"
    )]
    SchemaTooNew { found: i64, supported: i64 },
}

impl IndexError {
    /// True only when sqlite itself reports the bytes on disk as unusable:
    /// a header that fails its magic check, or a page that fails a
    /// consistency check. Every other failure - locked, out of space, wrong
    /// permissions, a schema newer than this build, a migration bug - leaves
    /// a file a later attempt, or a newer build, could still read.
    fn is_corrupt(&self) -> bool {
        matches!(
            self,
            IndexError::Sqlite(rusqlite::Error::SqliteFailure(e, _))
                if matches!(e.code, rusqlite::ErrorCode::DatabaseCorrupt | rusqlite::ErrorCode::NotADatabase)
        )
    }
}

pub struct Db {
    conn: Connection,
}

#[derive(Debug, Clone)]
pub struct FileRecord {
    pub source_id: String,
    pub dir: String,
    pub path: String,
    pub size: u64,
    pub mtime: i64,
    pub seen_gen: i64,
    pub title_id: i64,
    pub season: Option<u16>,
    pub episode: Option<u16>,
    /// The Plex ratingKey this file came from; None for file sources.
    pub rating_key: Option<String>,
    /// What the source says this copy is. A file scanner opens nothing to find
    /// out, so it leaves every one of these at its default and the UI draws no
    /// technical block for it.
    pub media: FileMedia,
}

/// What a source says one episode is, as `episode_meta` holds it: its own
/// title, its own sentence, and the path its own frame is served from. Every
/// field carries "nothing said so" as an empty string, which is the ordinary
/// answer rather than a failure - a server that names its episodes and stores
/// no frame for them fills two of the three.
#[derive(Debug, Clone, PartialEq, Default)]
pub struct EpisodeMeta {
    pub title: String,
    pub summary: String,
    /// A path on the source that enumerated the file, never a URL: the source
    /// is what turns it into one, the same way a poster path is.
    pub still_path: String,
    /// The year the episode first aired, 0 when nothing said so.
    pub air_year: u16,
}

/// The shape of one copy: how long it runs, and what a viewer would see and
/// hear of it. Every field carries "nothing said so" as its own default -
/// `duration_secs` 0, the strings empty, `audio_channels` 0 - because a source
/// that answers for none of them is the ordinary case, not a failure.
#[derive(Debug, Clone, PartialEq, Default)]
pub struct FileMedia {
    pub duration_secs: f64,
    /// Plex's own token: "4k", "1080", "720", "sd".
    pub video_resolution: String,
    pub video_codec: String,
    /// "hdr10", "hlg", "dolby_vision", or "" for plain SDR.
    pub dynamic_range: String,
    pub audio_codec: String,
    pub audio_channels: u32,
    pub atmos: bool,
    /// ISO 639-1 codes of the audio tracks, comma-joined in track order;
    /// "mul" where a release names more tracks than it lists.
    pub audio_languages: String,
    pub subtitle_languages: String,
    /// The cut this copy is ("Extended Edition"), empty for the one cut there is.
    pub edition: String,
}

/// The ten media columns, `duration_secs` through `edition`, at the head of a row.
fn media_at(r: &rusqlite::Row) -> rusqlite::Result<FileMedia> {
    Ok(FileMedia {
        duration_secs: r.get(0)?,
        video_resolution: r.get(1)?,
        video_codec: r.get(2)?,
        dynamic_range: r.get(3)?,
        audio_codec: r.get(4)?,
        audio_channels: r.get(5)?,
        atmos: r.get(6)?,
        audio_languages: r.get(7)?,
        subtitle_languages: r.get(8)?,
        edition: r.get(9)?,
    })
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct SourceCounts {
    pub titles: u32,
    pub files: u32,
}

/// Where a metadata row came from. Plex is authoritative for its own items,
/// so a Plex row is never overwritten by enrichment.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MetadataSource {
    Plex,
    Tmdb,
}

impl MetadataSource {
    pub fn as_str(self) -> &'static str {
        match self {
            MetadataSource::Plex => "plex",
            MetadataSource::Tmdb => "tmdb",
        }
    }

    #[allow(clippy::should_implement_trait)]
    pub fn from_str(s: &str) -> Option<Self> {
        match s {
            "plex" => Some(MetadataSource::Plex),
            "tmdb" => Some(MetadataSource::Tmdb),
            _ => None,
        }
    }
}

/// How many names `cast_names` carries: the billing a detail screen draws as
/// faces. Past it a credit list is extras and cameos, which every title shares
/// with every other. The embedding reads only the head of it (`EMBEDDED_CAST`),
/// so every description in one vector space stays the same size.
pub const MAX_CAST: usize = 20;

/// How many names each crew column carries. A credit list runs to dozens and
/// almost all of it is nobody a viewer picks a film by: only the three roles
/// below are stored at all, and each is cut where a real credit stops being one
/// person's work. Two directors is the directing duo; a third is an anthology or
/// a season's worth of episodes, which names nobody. Two writers is the
/// screenplay; past that come the adaptation and dialogue credits. One composer
/// is the score.
pub const MAX_DIRECTORS: usize = 2;
pub const MAX_WRITERS: usize = 2;
pub const MAX_COMPOSERS: usize = 1;

/// One crew column out of the names a source listed, in its order: cut to
/// `max`, commas scrubbed because a comma is what separates two entries, and
/// never a name `taken` already carries. That last rule is what keeps an auteur
/// who writes his own films one name in the embedded text instead of two, which
/// is the difference between a signal and the same signal counted twice.
pub fn crew_column<'a>(names: impl Iterator<Item = &'a str>, max: usize, taken: &str) -> String {
    let mut out: Vec<String> = Vec::with_capacity(max);
    for raw in names {
        if out.len() == max {
            break;
        }
        let scrubbed = raw.replace(',', " ");
        let name = scrubbed.trim();
        if name.is_empty()
            || taken
                .split(',')
                .any(|t| t.trim().eq_ignore_ascii_case(name))
            || out.iter().any(|o| o.eq_ignore_ascii_case(name))
        {
            continue;
        }
        out.push(name.to_string());
    }
    out.join(",")
}

/// What the metadata row holds about a title's own lettering, plus the two
/// fields deciding who to ask for it.
#[derive(Debug, Clone, PartialEq)]
pub struct LogoState {
    pub kind: MediaKind,
    /// The title the app writes when it draws no logo, which is what a logo
    /// has to agree with to be worth drawing instead.
    pub name: String,
    pub tmdb_id: Option<i64>,
    pub path: Option<String>,
    /// Width over height, 0 when there is no logo.
    pub aspect: f32,
    /// When TMDB last answered, 0 when it has never been asked.
    pub checked_at: i64,
}

/// What the trailer pass needs to know before it decides to ask TMDB.
#[derive(Debug, Clone, PartialEq)]
pub struct TrailerState {
    pub kind: MediaKind,
    pub tmdb_id: Option<i64>,
    /// The YouTube key, None when there is none or nobody has asked yet.
    pub key: Option<String>,
    /// When TMDB last answered, 0 when it has never been asked.
    pub checked_at: i64,
}

/// What `Db::skip_lookup` answers.
#[derive(Debug, Clone, PartialEq)]
pub struct SkipLookup {
    pub tmdb_id: i64,
    pub kind: MediaKind,
    pub season_episode: Option<(u16, u16)>,
    pub duration_secs: f64,
}

#[derive(Debug, Clone, PartialEq)]
pub struct MetadataRecord {
    pub title_id: i64,
    pub tmdb_id: Option<i64>,
    pub overview_fr: Option<String>,
    pub overview_en: Option<String>,
    pub poster_path: Option<String>,
    pub backdrop_path: Option<String>,
    /// Comma-joined display names; TMDB genre names carry no comma, but Plex
    /// tags are user-supplied and may.
    pub genres: String,
    /// Top billing first, comma-joined, "" when nobody knows. Read by the
    /// embeddings and by nothing else, so it is never matched against.
    pub cast_names: String,
    /// Comma-joined, "" when no source names one. Its own column rather than a
    /// share of the crew: it is the only credit with a reader that needs it by
    /// role, since the home screen builds a row out of it.
    pub director_names: String,
    /// The screenplay, comma-joined, "" when no source names one.
    pub writer_names: String,
    /// Who wrote the score, comma-joined. TMDB alone answers for this: no Plex
    /// agent carries a composer, so it stays "" until a title is matched.
    pub composer_names: String,
    /// Comma-joined collection names Plex tags the item with, "" when it
    /// belongs to none. TMDB enrichment never sets this: without a token
    /// (spec: Recommendations) it never runs, and a Plex row is the only
    /// source that carries collection membership at all.
    pub collections: String,
    /// The critics' score, None when nothing measured one or nothing said who
    /// did. Plex's own agent answers for this and TMDB enrichment does not, so
    /// a write carrying None never clears a stored score.
    pub critics: Option<Score>,
    /// The audience's score, on the same terms. Never a stand-in for the
    /// critics': they are two populations, and a reader that cannot tell them
    /// apart is drawing a number it cannot name.
    pub audience: Option<Score>,
    /// "YYYY-MM-DD", TMDB's release date for a film and first air date for a
    /// show. None never clears a stored date: Plex carries none.
    pub release_date: Option<String>,
    pub source: MetadataSource,
    pub fetched_at: i64,
}

/// The local day a session key names, as SQL over `column`: an evening is its
/// own day, an afternoon `-(day) - 1` (see `tonight::session_of`).
fn day_of(column: &str) -> String {
    format!("(CASE WHEN {column} >= 0 THEN {column} ELSE -{column} - 1 END)")
}

/// What the viewer said about one session of the trio. `window_min` is
/// minutes from when it was said, None leaving the estimator to answer,
/// `mood` a key of `taste::MOODS`, and `guest_id` who the viewer watches with.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct EveningAnswers {
    pub together: bool,
    pub window_min: Option<u32>,
    pub mood: Option<String>,
    pub guest_id: Option<i64>,
}

/// A measured score and who measured it.
///
/// The two travel together or not at all: a number out of 10 says nothing
/// about the scale it is on or the population behind it, and both of those are
/// what the provider is. `source` is the provider's own token, the way
/// `MediaRecord::video_resolution` carries Plex's - naming it in words, and
/// deciding a percentage is not a mark, is the screen's job.
#[derive(Debug, Clone, PartialEq)]
pub struct Score {
    /// Out of 10, always: the wire's own scale, normalised on the way in.
    pub value: f32,
    /// Lower-case and never empty: "imdb", "themoviedb", "rottentomatoes".
    pub source: String,
    /// How many voters the score stands on, None when the source never said:
    /// Plex carries a score without its count, TMDB carries both.
    pub votes: Option<u32>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PendingTitle {
    pub id: i64,
    pub kind: MediaKind,
    pub name: String,
    pub year: Option<u16>,
}

/// A file's watch state. `watched` is stored, not derived on read: a title can
/// be marked watched by hand, with no position at all.
#[derive(Debug, Clone, PartialEq)]
pub struct WatchRecord {
    pub file_id: i64,
    pub position_secs: f64,
    pub duration_secs: f64,
    pub watched: bool,
    /// How many times the file was played through. Read from the record only
    /// under `WatchAuthority::Owner`, where a server answers for it; a report
    /// leaves it at zero and the write counts the crossing itself.
    pub plays: u32,
    /// Unix seconds. Continue-watching order, and the stale guard on a restore.
    pub updated_at: i64,
}

/// Who decides `watched` when the row already carries it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum WatchAuthority {
    /// A position this device reported: it may raise the flag, never lower it.
    Report,
    /// The server that owns the item, answering for it in full.
    Owner,
}

/// One file as the writeback path needs it: where it lives, and the Plex item
/// it came from when a Plex server owns its watch state.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FileRef {
    pub id: i64,
    pub source_id: String,
    pub path: String,
    pub rating_key: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PendingSimilar {
    pub tmdb_id: i64,
    pub kind: MediaKind,
}

/// A placed title whose billing is worth one request: the id to ask about,
/// which endpoint to ask, and the title the answer is stamped against.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PendingFaces {
    pub title_id: i64,
    pub kind: MediaKind,
    pub tmdb_id: i64,
}

/// The library's size against the background pass's own three totals, read at
/// any time and not only while a pass is ticking.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct PassCounts {
    pub total: u32,
    pub described: u32,
    pub linked: u32,
    pub embedded: u32,
}

/// One title's vector, as the index holds it: one byte per dimension, unit
/// length before quantization, so the dot product of two of them is their
/// cosine and an integer comparison ranks them.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct EmbeddingRecord {
    pub title_id: i64,
    pub model_version: i64,
    /// Hash of the exact text that produced it. A sync that rewrites the same
    /// description must not cost the library a recompute.
    pub source_hash: i64,
    pub vector: Vec<i8>,
    pub computed_at: i64,
}

/// A title owed a vector, with everything the text is built from.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PendingEmbed {
    pub title_id: i64,
    pub kind: MediaKind,
    pub name: String,
    pub year: Option<u16>,
    pub genres: String,
    pub collections: String,
    pub cast_names: String,
    pub director_names: String,
    pub writer_names: String,
    pub composer_names: String,
    /// TMDB's tags, comma-separated: the tone and the subject a synopsis
    /// describes without naming.
    pub keywords: String,
    pub overview: String,
    /// What the stored row was computed from, when this model stored one.
    /// None for another model's row, which is owed a vector whatever its
    /// description still says.
    pub source_hash: Option<i64>,
}

/// One vector out of the cache, with the kind the neighbour search keeps to.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TitleVector {
    pub title_id: i64,
    pub kind: MediaKind,
    pub vector: Vec<i8>,
}

/// One `watch_state` row against the title it belongs to. The taste
/// fingerprint reads the rows rather than a per-title aggregate: how far into
/// a file the viewer got and when they got there are what weighs it, and SQL
/// has no exponential to fold the two together with.
#[derive(Debug, Clone, PartialEq)]
pub struct WatchedFile {
    pub title_id: i64,
    pub kind: MediaKind,
    pub watched: bool,
    pub position_secs: f64,
    pub duration_secs: f64,
    pub plays: u32,
    pub updated_at: i64,
}

/// One title the taste pass picked out of the library: which facet of the
/// fingerprint reached for it, and the watched title that facet was built
/// around. `leader` is 0 when the facet had none.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct TastePick {
    pub title_id: i64,
    pub facet: u32,
    pub leader: i64,
}

/// One taste, as the pass persists it for the readers that come after: its
/// share of the history, the title that names it, and how close it sits to
/// the dominant taste (what "the other mood" is chosen by).
#[derive(Debug, Clone, PartialEq)]
pub struct TasteFacetMeta {
    pub facet: u32,
    pub weight: f32,
    pub leader: i64,
    pub cos_to_top: f32,
}

/// One taste as the screen that shows movement reads it: where it stands now,
/// and where it stood at the last snapshot older than the cutoff asked for.
/// `was` is None when no snapshot reaches that far back, which is not the same
/// as a taste that has not moved.
#[derive(Debug, Clone, PartialEq)]
pub struct TasteFacetShift {
    pub facet: u32,
    pub weight: f32,
    pub leader: i64,
    pub was: Option<f32>,
}

/// One thing the viewer did that moved the taste, with the name of the title
/// it was done to. The kind is one of the TASTE_* constants: the core names
/// what happened and never words it.
#[derive(Debug, Clone, PartialEq)]
pub struct TasteEvent {
    pub at: i64,
    pub kind: u32,
    pub title: String,
}

/// A position that crossed the finish line.
pub const TASTE_FINISHED: u32 = 0;
/// An opinion stated, whichever one.
pub const TASTE_VERDICT: u32 = 1;
/// An evening's refusal.
pub const TASTE_DEFERRED: u32 = 2;
/// A title put aside to watch later.
pub const TASTE_QUEUED: u32 = 3;
/// A detail page left open long enough to be read.
pub const TASTE_DWELL: u32 = 4;
/// A trailer watched past its opening.
pub const TASTE_TRAILER: u32 = 5;
/// A title picked over another when the viewer was asked to choose.
pub const TASTE_CHOSEN: u32 = 6;

/// What the evenings have shown of one title: how many evenings it was a card
/// and how many it was in the lane under the trio, and the latest of each.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Exposure {
    pub cards: u32,
    pub lanes: u32,
    pub last_card: i64,
    pub last_lane: i64,
}

/// One title of the discovery band, with where in the band it sits: 0 at the
/// library's own background, 1 at the edge of the taste. The step-aside row's
/// reach is a cut on this.
#[derive(Debug, Clone, PartialEq)]
pub struct DiscoveryPick {
    pub title_id: i64,
    pub closeness: f32,
}

/// What the fingerprint has to say about one title, precomputed: which taste
/// claims it, how strongly (0..1), and the rejected title that holds it back
/// the most, empty when none does.
#[derive(Debug, Clone, PartialEq)]
pub struct TitleTasteRow {
    pub title_id: i64,
    pub facet: u32,
    pub affinity: f32,
    pub rejected: String,
}

/// Everything one taste pass produces, written in a single transaction: the
/// row, the facets behind it, the discovery band, the per-title explanation
/// and the seasonal rankings.
#[derive(Debug, Default)]
pub struct TastePassOutput {
    pub picks: Vec<TastePick>,
    pub facets: Vec<TasteFacetMeta>,
    pub discovery: Vec<DiscoveryPick>,
    pub title_taste: Vec<TitleTasteRow>,
    /// Which facet each already-watched title belongs to. `title_taste` drops
    /// these on purpose - it answers "why is this being offered" - and the
    /// evening block needs exactly the ones it drops, to weigh which taste
    /// this viewer reaches for on a weeknight against a weekend.
    pub watched_facet: Vec<(i64, u32)>,
    /// Per anchor key, a season's or a mood's, the library's best against
    /// that anchor, best first. Both live in `seasonal_pick`, keyed apart.
    pub seasonal: Vec<(String, Vec<i64>)>,
    /// Each title's tones: a mood key and how far past that mood's floor the
    /// title stands, at most two per title.
    pub tones: Vec<(i64, &'static str, f32)>,
    /// When the pass ran, which is what its snapshot of the facets is stamped
    /// with and the only instant the movement of a taste is measured between.
    pub now: i64,
}

/// What the watch state says about one title: how many files it has, how many
/// of them are seen, and the one left in progress most recently, which is what
/// "resume" means for a show. A file can be both: `watched_files` counts what
/// has been finished at some point, `resume` is where the viewer is now.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct TitleWatch {
    pub files: u32,
    pub watched_files: u32,
    /// The most any one file of the title was played through. A film has one
    /// file and this is exact; a show reports its most rewatched episode,
    /// which is the same number the familiar role ranks on.
    pub plays: u32,
    pub resume: Option<WatchRecord>,
}

/// One episode as the continuity queries answer it: the file to play, where it
/// sits in its show, what its own `episode_meta` row says, and whatever watch
/// row it has. `name` is the show's and `title` is the episode's; both are
/// carried because a screen draws them together and neither implies the other.
/// `title` and `summary` are empty for a movie and for any episode a source
/// named nothing about, which is a real answer rather than a missing one.
#[derive(Debug, Clone, PartialEq)]
pub struct EpisodeRow {
    pub file_id: i64,
    pub title_id: i64,
    pub name: String,
    pub title: String,
    pub summary: String,
    pub season: Option<u16>,
    pub episode: Option<u16>,
    /// The year the episode first aired, None when no source said.
    pub air_year: Option<u16>,
    pub watched: bool,
    pub position_secs: f64,
    /// The runtime the watch row measured `position_secs` against, and only
    /// that: 0 on an episode never played. `runtime_secs` is what the file
    /// itself says, which is the one a screen labels an unplayed episode with.
    pub duration_secs: f64,
    /// How long the file runs, whatever has been watched of it. 0 when no
    /// source answered for it - a directory scanner opens nothing.
    pub runtime_secs: f64,
}

// year 0 encodes "unknown": SQLite UNIQUE treats NULLs as distinct, which
// would create duplicate titles on every rescan.
const SCHEMA: &str = "
CREATE TABLE titles (
  id INTEGER PRIMARY KEY,
  kind TEXT NOT NULL CHECK (kind IN ('movie','show')),
  name TEXT NOT NULL,
  year INTEGER NOT NULL DEFAULT 0,
  UNIQUE (kind, name, year)
);
CREATE INDEX idx_titles_name ON titles(name COLLATE NOCASE);
CREATE INDEX idx_titles_kind_name ON titles(kind, name COLLATE NOCASE, id);
CREATE TABLE files (
  id INTEGER PRIMARY KEY,
  source_id TEXT NOT NULL,
  dir TEXT NOT NULL,
  path TEXT NOT NULL,
  size INTEGER NOT NULL,
  mtime INTEGER NOT NULL,
  seen_gen INTEGER NOT NULL,
  title_id INTEGER NOT NULL REFERENCES titles(id),
  season INTEGER,
  episode INTEGER,
  UNIQUE (source_id, path)
);
CREATE INDEX idx_files_title ON files(title_id);
CREATE INDEX idx_files_dir ON files(source_id, dir);
CREATE TABLE dirs (
  source_id TEXT NOT NULL,
  path TEXT NOT NULL,
  mtime INTEGER NOT NULL,
  PRIMARY KEY (source_id, path)
);
";

// v2 is additive and runs on a fresh database too, right after SCHEMA: the
// migration path is the only path, so it is exercised by every test.
const MIGRATE_V2: &str = "
ALTER TABLE files ADD COLUMN rating_key TEXT;
CREATE TABLE metadata (
  title_id INTEGER PRIMARY KEY REFERENCES titles(id) ON DELETE CASCADE,
  tmdb_id INTEGER,
  overview_fr TEXT,
  overview_en TEXT,
  poster_path TEXT,
  backdrop_path TEXT,
  genres TEXT NOT NULL DEFAULT '',
  source TEXT NOT NULL CHECK (source IN ('plex','tmdb')),
  fetched_at INTEGER NOT NULL
);
";

// v3 is additive like v2, and has no ALTER at all, so it runs the same way on a
// fresh database, on a v1 cache and on a v2 one.
//
// watch_state is a cache of what the Plex server or the host store holds: it
// goes with the file row it describes, and comes back from the durable copy.
// tmdb_similar is keyed by kind as well as id: TMDB numbers movies and shows in
// two independent sequences that overlap, so an id alone names two titles.
// The index on metadata(tmdb_id) is what makes the similar join a lookup
// instead of a scan per similar id.
const MIGRATE_V3: &str = "
CREATE TABLE watch_state (
  file_id INTEGER PRIMARY KEY REFERENCES files(id) ON DELETE CASCADE,
  position_secs REAL NOT NULL DEFAULT 0,
  duration_secs REAL NOT NULL DEFAULT 0,
  watched INTEGER NOT NULL DEFAULT 0,
  updated_at INTEGER NOT NULL
);
CREATE TABLE tmdb_similar (
  kind TEXT NOT NULL CHECK (kind IN ('movie','show')),
  tmdb_id INTEGER NOT NULL,
  similar_tmdb_id INTEGER NOT NULL,
  rank INTEGER NOT NULL,
  PRIMARY KEY (kind, tmdb_id, similar_tmdb_id)
);
CREATE INDEX idx_metadata_tmdb ON metadata(tmdb_id);
";

// v4 adds the cast the embeddings read and the two tables they write. The
// column is named cast_names because CAST is an SQL keyword and a bare `cast`
// would have to be quoted in every statement that touches it.
//
// Both tables are keyed by title_id and cascade with it: a vector is a few
// milliseconds of CPU to recompute and nothing outside the cache needs it, so
// it is not worth keying on a tmdb_id an unmatched home movie does not have.
// similar_semantic carries no foreign key on its right-hand side, the same way
// tmdb_similar carries none: a link to a title that has gone is joined away by
// every reader.
const MIGRATE_V4: &str = "
ALTER TABLE metadata ADD COLUMN cast_names TEXT NOT NULL DEFAULT '';
CREATE TABLE embeddings (
  title_id INTEGER PRIMARY KEY REFERENCES titles(id) ON DELETE CASCADE,
  model_version INTEGER NOT NULL,
  source_hash INTEGER NOT NULL,
  vector BLOB NOT NULL,
  computed_at INTEGER NOT NULL
);
CREATE TABLE similar_semantic (
  title_id INTEGER NOT NULL REFERENCES titles(id) ON DELETE CASCADE,
  similar_title_id INTEGER NOT NULL,
  rank INTEGER NOT NULL,
  score INTEGER NOT NULL,
  PRIMARY KEY (title_id, similar_title_id)
);
CREATE INDEX idx_semantic_similar ON similar_semantic(similar_title_id);
";

// v5 is what browsing and searching need, and like v3 it has no ALTER on a
// table any earlier version filled, so it runs the same way on a fresh
// database and on any cache from v1 up.
//
// added_at is the newest mtime any file of the title has carried. The two
// triggers on files keep it, rather than every writer: a scan that re-sees a
// file updates no row because the guard in the WHERE is false, and a source
// that hands back an older file cannot pull the date backwards. It never goes
// down, so a title whose newest version is deleted keeps the date it arrived
// on, which is what the order means.
//
// title_search is FTS5 over the three things a viewer types. The bundled
// SQLite ships the module, so this costs no dependency. It holds its own copy
// of that text, which a rebuildable cache can afford, and the five triggers are
// what keep the copy true: a writer cannot forget one. There is no rename
// trigger on titles.name: the UNIQUE (kind, name, year) constraint has no
// COLLATE NOCASE, so upsert_title's ON CONFLICT DO UPDATE SET name =
// excluded.name only ever fires when the name is already byte-identical, and
// titles.name has no other writer. unicode61 with
// remove_diacritics 2 folds accents both ways, which a fr-FR library needs, and
// the prefix index covers the two- and three-letter case, which is every
// keystroke of a search that has just started.
//
// A title that goes must take its row with it: ids are reused after a delete,
// and a row left behind would describe whatever takes the number. The delete
// trigger on titles does that; the one on metadata rewrites the row with the
// name alone, and inserts nothing at all when the metadata went because the
// title did, because the title row is gone by the time it runs.
const MIGRATE_V5: &str = "
ALTER TABLE titles ADD COLUMN added_at INTEGER NOT NULL DEFAULT 0;
UPDATE titles SET added_at =
  COALESCE((SELECT MAX(f.mtime) FROM files f WHERE f.title_id = titles.id), 0);
CREATE INDEX idx_titles_kind_year ON titles(kind, year DESC, name COLLATE NOCASE, id);
CREATE INDEX idx_titles_kind_added ON titles(kind, added_at DESC, id DESC);
CREATE TRIGGER titles_added_on_insert AFTER INSERT ON files BEGIN
  UPDATE titles SET added_at = new.mtime
    WHERE id = new.title_id AND added_at < new.mtime;
END;
CREATE TRIGGER titles_added_on_update AFTER UPDATE OF mtime, title_id ON files BEGIN
  UPDATE titles SET added_at = new.mtime
    WHERE id = new.title_id AND added_at < new.mtime;
END;
CREATE VIRTUAL TABLE title_search USING fts5(
  name, genres, cast_names,
  tokenize = 'unicode61 remove_diacritics 2',
  prefix = '2 3'
);
INSERT INTO title_search (rowid, name, genres, cast_names)
  SELECT t.id, t.name, COALESCE(m.genres, ''), COALESCE(m.cast_names, '')
    FROM titles t LEFT JOIN metadata m ON m.title_id = t.id;
CREATE TRIGGER title_search_title_insert AFTER INSERT ON titles BEGIN
  INSERT INTO title_search (rowid, name, genres, cast_names)
    VALUES (new.id, new.name, '', '');
END;
CREATE TRIGGER title_search_title_delete AFTER DELETE ON titles BEGIN
  DELETE FROM title_search WHERE rowid = old.id;
END;
CREATE TRIGGER title_search_metadata_insert AFTER INSERT ON metadata BEGIN
  DELETE FROM title_search WHERE rowid = new.title_id;
  INSERT INTO title_search (rowid, name, genres, cast_names)
    SELECT t.id, t.name, new.genres, new.cast_names FROM titles t WHERE t.id = new.title_id;
END;
CREATE TRIGGER title_search_metadata_update AFTER UPDATE ON metadata
  WHEN new.genres <> old.genres OR new.cast_names <> old.cast_names BEGIN
  DELETE FROM title_search WHERE rowid = new.title_id;
  INSERT INTO title_search (rowid, name, genres, cast_names)
    SELECT t.id, t.name, new.genres, new.cast_names FROM titles t WHERE t.id = new.title_id;
END;
CREATE TRIGGER title_search_metadata_delete AFTER DELETE ON metadata BEGIN
  DELETE FROM title_search WHERE rowid = old.title_id;
  INSERT INTO title_search (rowid, name, genres, cast_names)
    SELECT t.id, t.name, '', '' FROM titles t WHERE t.id = old.title_id;
END;
";

// v6 tracks when each title's semantic neighbours were last computed,
// separately from similar_semantic itself: a title can legitimately hold zero
// rows there (nothing passed the similarity floor) and still be up to date,
// which a COUNT over similar_semantic could not tell apart from "never
// looked at". The staleness test this enables mirrors titles_needing_embedding:
// missing, another model's row, or older than the vector it is meant to
// reflect.
const MIGRATE_V6: &str = "
CREATE TABLE semantic_computed (
  title_id INTEGER PRIMARY KEY REFERENCES titles(id) ON DELETE CASCADE,
  model_version INTEGER NOT NULL,
  computed_at INTEGER NOT NULL
);
";

// v7 is additive like v3, v5 and v6. collections is a title's Plex collection
// membership, comma-joined the same way genres is; title_tags is genres, cast
// and collections again, one row per value, which is what a detail screen's
// "same genre", "same cast" and "same saga" rails rank overlap from. Ranking
// off the comma column would mean a scan of the whole table per screen open;
// the index below turns "who else carries this value" into a lookup.
//
// ON DELETE CASCADE off titles rather than a trigger: foreign_keys is on for
// every connection (see init), so a title that goes takes its tags with it
// the same way it takes its files.
const MIGRATE_V7: &str = "
ALTER TABLE metadata ADD COLUMN collections TEXT NOT NULL DEFAULT '';
CREATE TABLE title_tags (
  title_id INTEGER NOT NULL REFERENCES titles(id) ON DELETE CASCADE,
  kind TEXT NOT NULL,
  value TEXT NOT NULL
);
CREATE INDEX idx_title_tags_lookup ON title_tags(kind, value, title_id);
CREATE INDEX idx_title_tags_title ON title_tags(title_id, kind);
";

// v8 is storage-only: a per-file probe cache the player reads and writes
// through its own FFI calls (lexis_analysis_load/lexis_analysis_store),
// never touched by a scan or a recommendation. Keyed by identity, not by
// title_id or file_id: the player's own notion of a file's identity is
// source id + file id, and this table outlives a rescan the way a Plex
// rating key does, since nothing here references titles or files at all.
// mtime is a separate column, not buried in the JSON, so a stale-mtime
// miss is a plain indexed lookup rather than a deserialize-then-compare.
const MIGRATE_V8: &str = "
CREATE TABLE media_analysis (
  identity TEXT PRIMARY KEY,
  mtime INTEGER NOT NULL,
  json TEXT NOT NULL
);
";

// v9 is where the taste fingerprint lands: the ordered row the background
// pass computed out of the watch history and the vectors, one title per rank.
// Nothing here references a tmdb_id, which is what lets the row exist on a
// device that has never had a TMDB key.
//
// The picks are stored rather than recomputed per home screen because the
// arithmetic behind them reads every vector in the library: that belongs on
// the pass, next to the sweep whose output it depends on, not on the thread
// drawing the first screen. `facet` says which of the viewer's tastes put the
// title here, so a row is a mix by construction and can be asserted as one.
const MIGRATE_V9: &str = "
CREATE TABLE taste_pick (
  rank INTEGER PRIMARY KEY,
  title_id INTEGER NOT NULL REFERENCES titles(id) ON DELETE CASCADE,
  facet INTEGER NOT NULL
);
";

// v10 changes no shape at all: it drops what the neighbour sweep stored,
// because the rule that decides how much of a list to keep has changed (see
// `embed::pass::nearest`) and every row on disk was cut by the old one. The
// vectors stay - they are the expensive half and the model behind them has
// not moved - and clearing semantic_computed is what puts every title back in
// the sweep's queue.
const MIGRATE_V10: &str = "
DELETE FROM similar_semantic;
DELETE FROM semantic_computed;
";

// v11 changes no shape either: a title's text now carries the collections it
// belongs to (see `embed::pass::embed_text`), so every vector on disk was
// computed from a description this build no longer composes. source_hash
// catches a description that moves, but nothing moves here - the text does -
// so the rows have to go for the queue to name those titles again. The
// neighbour rows stand: they are the old vectors' answer, which is a stale
// answer rather than a wrong one, and each is rewritten as its title's vector
// lands rather than leaving the rows blank across the sweep.
const MIGRATE_V11: &str = "
DELETE FROM embeddings;
";

// v12 is additive. matched_at is when TMDB was last asked to place this title,
// which is not what fetched_at says: a Plex row is written by a sync that
// knows nothing about TMDB, and the search behind a match is what must not run
// again on every pass. 0 is "never asked", which every row on disk is.
const MIGRATE_V12: &str = "
ALTER TABLE metadata ADD COLUMN matched_at INTEGER NOT NULL DEFAULT 0;
";

// v13 is additive. `leader` is the watched title the facet that placed a pick
// was built around, so the row that pick lands in can name itself after
// something the viewer has actually seen; 0 is "the pass that wrote this row
// did not know", which every row on disk is until the next one runs. The index
// is what "recently added" walks: without it that order is a sort of the whole
// library, since idx_titles_kind_added is only usable one kind at a time.
const MIGRATE_V13: &str = "
ALTER TABLE taste_pick ADD COLUMN leader INTEGER NOT NULL DEFAULT 0;
CREATE INDEX idx_titles_added ON titles(added_at DESC, id);
";

// v14 is the title treatment: the logo a hero draws instead of setting the
// name in the app's own face.
//
// Three columns on metadata rather than a table of one row per title: a logo
// belongs to the same row the poster and backdrop paths do, and nothing joins
// on it.
//
// They are deliberately absent from upsert_metadata's column list, which is
// what keeps them: that statement rewrites a row from whatever a scan or an
// enrichment last saw, and neither a Plex server nor a TMDB details payload
// knows anything about a logo. A column it does not name is a column a
// rescan cannot erase.
//
// logo_checked_at is the negative cache, and it is the column that matters
// most: most titles have no logo, and without it every draw of the hero
// would ask TMDB again for an answer it already gave. It is also what keeps
// the artwork sweep cheap - the answer that chose the logo lives here, in
// the index, so evicting the PNG costs a download and never a second query.
const MIGRATE_V14: &str = "
ALTER TABLE metadata ADD COLUMN logo_path TEXT;
ALTER TABLE metadata ADD COLUMN logo_aspect REAL NOT NULL DEFAULT 0;
ALTER TABLE metadata ADD COLUMN logo_checked_at INTEGER NOT NULL DEFAULT 0;
";

// v15 is who made the film, next to who is in it. Three columns and not one:
// the director has readers that need it by role - the home row and the tag
// lookup behind it - while the writer and the composer are only ever read as
// names, and each is filled by a different source, so one merged column would
// let Plex's writers stand in the way of TMDB's composer.
//
// title_search is rebuilt rather than altered: FTS5 has no ADD COLUMN. The two
// new columns are separate so a hit can say which it was - "réalisé par" and
// "avec" are different sentences - and so bm25 can weigh a director above a
// composer. The five triggers are dropped by name and not by dropping the
// table: they hang off titles and metadata, which stay, so the table going
// leaves every one of them behind still writing the old column list.
//
// The embeddings go for the same reason they went in v11: `embed_text` now
// composes the director into the text, so every vector on disk was computed
// from a description this build no longer writes. source_hash catches a
// description that moves; it cannot catch the composer moving, because a title
// whose row is current is never named by the queue at all.
const MIGRATE_V15: &str = "
ALTER TABLE metadata ADD COLUMN director_names TEXT NOT NULL DEFAULT '';
ALTER TABLE metadata ADD COLUMN writer_names TEXT NOT NULL DEFAULT '';
ALTER TABLE metadata ADD COLUMN composer_names TEXT NOT NULL DEFAULT '';
DROP TRIGGER title_search_title_insert;
DROP TRIGGER title_search_title_delete;
DROP TRIGGER title_search_metadata_insert;
DROP TRIGGER title_search_metadata_update;
DROP TRIGGER title_search_metadata_delete;
DROP TABLE title_search;
CREATE VIRTUAL TABLE title_search USING fts5(
  name, genres, cast_names, director_names, crew_names,
  tokenize = 'unicode61 remove_diacritics 2',
  prefix = '2 3'
);
INSERT INTO title_search (rowid, name, genres, cast_names, director_names, crew_names)
  SELECT t.id, t.name, COALESCE(m.genres, ''), COALESCE(m.cast_names, ''),
         COALESCE(m.director_names, ''),
         COALESCE(m.writer_names, '') || ',' || COALESCE(m.composer_names, '')
    FROM titles t LEFT JOIN metadata m ON m.title_id = t.id;
CREATE TRIGGER title_search_title_insert AFTER INSERT ON titles BEGIN
  INSERT INTO title_search (rowid, name, genres, cast_names, director_names, crew_names)
    VALUES (new.id, new.name, '', '', '', '');
END;
CREATE TRIGGER title_search_title_delete AFTER DELETE ON titles BEGIN
  DELETE FROM title_search WHERE rowid = old.id;
END;
CREATE TRIGGER title_search_metadata_insert AFTER INSERT ON metadata BEGIN
  DELETE FROM title_search WHERE rowid = new.title_id;
  INSERT INTO title_search (rowid, name, genres, cast_names, director_names, crew_names)
    SELECT t.id, t.name, new.genres, new.cast_names, new.director_names,
           new.writer_names || ',' || new.composer_names
      FROM titles t WHERE t.id = new.title_id;
END;
CREATE TRIGGER title_search_metadata_update AFTER UPDATE ON metadata
  WHEN new.genres <> old.genres OR new.cast_names <> old.cast_names
    OR new.director_names <> old.director_names
    OR new.writer_names <> old.writer_names
    OR new.composer_names <> old.composer_names BEGIN
  DELETE FROM title_search WHERE rowid = new.title_id;
  INSERT INTO title_search (rowid, name, genres, cast_names, director_names, crew_names)
    SELECT t.id, t.name, new.genres, new.cast_names, new.director_names,
           new.writer_names || ',' || new.composer_names
      FROM titles t WHERE t.id = new.title_id;
END;
CREATE TRIGGER title_search_metadata_delete AFTER DELETE ON metadata BEGIN
  DELETE FROM title_search WHERE rowid = old.title_id;
  INSERT INTO title_search (rowid, name, genres, cast_names, director_names, crew_names)
    SELECT t.id, t.name, '', '', '', '' FROM titles t WHERE t.id = old.title_id;
END;
DELETE FROM embeddings;
";

// v16 is what a title says about itself beyond its description: how long it
// runs, how it was rated, and the shape of the picture and the sound.
//
// The score is a judgement of the work and sits with the description; the rest
// describes one copy of it and sits on the file, where a scan writes it
// unconditionally. A movie whose server sends no summary, no poster and no
// genre gets no metadata row at all (see write_plex_metadata), and a runtime
// kept there would go with it - which is the one fact such a title still has.
//
// 0 and '' mean "nothing said so", not "zero": every reader treats them as
// absent, and an empty write never overwrites a real value.
//
// The `dirs` rows go with them. That table is what both scanners skip work
// against - a directory whose mtime has not moved, a Plex section whose
// updatedAt has not moved - and every row already on disk was written by a
// build that filled none of the columns above. Left in place, a library would
// carry empty media columns until something upstream happened to change.
const MIGRATE_V16: &str = "
ALTER TABLE metadata ADD COLUMN rating REAL NOT NULL DEFAULT 0;
ALTER TABLE files ADD COLUMN duration_secs REAL NOT NULL DEFAULT 0;
ALTER TABLE files ADD COLUMN video_resolution TEXT NOT NULL DEFAULT '';
ALTER TABLE files ADD COLUMN video_codec TEXT NOT NULL DEFAULT '';
ALTER TABLE files ADD COLUMN dynamic_range TEXT NOT NULL DEFAULT '';
ALTER TABLE files ADD COLUMN audio_codec TEXT NOT NULL DEFAULT '';
ALTER TABLE files ADD COLUMN audio_channels INTEGER NOT NULL DEFAULT 0;
ALTER TABLE files ADD COLUMN atmos INTEGER NOT NULL DEFAULT 0;
DELETE FROM dirs;
";

// v17 gives a credited name a number. `title_tags` already answers "what else
// carries this name" for cast and director, correctly and for the whole
// library, off the name alone - a person's page needs nothing here at all.
// What needs a number is the photograph: the artwork cache queues, holds and
// evicts by an integer key, and a face has to go through that cache rather
// than beside it.
//
// So the row is the name, and the identity is this table's own rowid, not
// TMDB's person id. A name gets its row the moment it is tagged, which is why
// `tmdb_person_id` and `profile_path` default to 0 and '': the person is real
// and their filmography is complete from the first scan, and only their face
// is pending. That is the ordinary state of this table, not a degenerate one,
// and an empty `profile_path` is a final answer that costs no request - the
// enrichment fills it as a side effect of a call it already makes, so nothing
// here ever asks TMDB a question of its own.
//
// Two performers who share a name share a row, and would share a photograph.
// Identity per credit is the alternative, and it costs a column on every tag
// row plus an id whose only source is the TMDB match that most of a library
// does not have.
//
// The backfill is one statement rather than a Rust loop: every name already
// tagged gets its row on migrate, so a library that has been scanned once can
// open a person without being scanned again.
const MIGRATE_V17: &str = "
CREATE TABLE people (
  id INTEGER PRIMARY KEY,
  name TEXT NOT NULL UNIQUE,
  tmdb_person_id INTEGER NOT NULL DEFAULT 0,
  profile_path TEXT NOT NULL DEFAULT ''
);
INSERT OR IGNORE INTO people (name)
  SELECT DISTINCT value FROM title_tags WHERE kind IN ('cast', 'director');
";

// v18 is additive, and it is what lets a face be asked for at all.
//
// v17 filled `profile_path` as a side effect of the describe call, which every
// title in a placed library has already had: their credits were read before
// there was anything to read out of them, and a title that is placed with a
// fresh row is named by no queue again. `profile_checked_at` is what a queue
// of its own can be built on - 0 is "TMDB has never been asked about this
// name", which every row on disk is.
//
// It sits on the person and not on the title because the answer does: a
// performer TMDB holds no photograph of is billed in a dozen films, and asked
// once. `logo_checked_at` and `matched_at` are the same column against a
// title; this is the same column against a name.
const MIGRATE_V18: &str = "
ALTER TABLE people ADD COLUMN profile_checked_at INTEGER NOT NULL DEFAULT 0;
";

/// Neighbours computed before the cosines were measured from the library's
/// own centre answer a question this build no longer asks (see `embed::space`).
/// The vectors are untouched and stay on disk; only the search over them is
/// owed again, which is what forgetting `semantic_computed` asks the sweep for.
/// The links themselves stay until each title's own row is rewritten, so the
/// detail screen keeps the neighbours it had across the sweep rather than
/// going blank for as long as the sweep takes.
const MIGRATE_V19: &str = "
DELETE FROM semantic_computed;
";

/// v20 is additive, and it is the one thing that takes a title out of the
/// continue-watching row without claiming it was watched.
///
/// `dismissed_at` is a timestamp rather than a flag because the dismissal is
/// only about the progress that was there when it was made: `CONTINUE` keeps
/// the title out for as long as nothing has touched it since, and a later
/// report - this device, or another Plex client the sync mirrors - carries a
/// newer `updated_at` and brings it back on its own.
///
/// Nothing here is ever sent anywhere. It is the one piece of watch-adjacent
/// state that belongs to this device and not to whoever owns the history.
const MIGRATE_V20: &str = "
CREATE TABLE resume_dismissed (
  title_id INTEGER PRIMARY KEY REFERENCES titles(id) ON DELETE CASCADE,
  dismissed_at INTEGER NOT NULL
);
";

/// v21 is additive, and it is the first thing in this index that records an
/// opinion rather than an event. Everything else here is something that
/// happened - a file was found, a position was reported, a description was
/// fetched - and the taste fingerprint has had to infer a preference from the
/// only two facts a play carries: how much of it was watched and when.
///
/// `verdict` is -1, 1 or 2: rejected, liked, loved. Three values and not a
/// score, because a viewer pressing a button on a television is not
/// calibrating anything; the arithmetic those three are worth lives in
/// `index::taste`, where it can be read beside the play weight it stands
/// against.
///
/// `stated_at` is stored and never decayed. It orders the verdicts - which is
/// what bounds how many of them steer the row (see `taste::MAX_DISTASTE`) -
/// and it is what the durable copy in the host store merges on. A play's age
/// is what `play_weight` has to guess with; a verdict leaves nothing to guess.
///
/// Nothing here is ever sent anywhere, and that is the point rather than an
/// omission: Plex carries a user rating field, and writing to it would put
/// this viewer's opinion on their account in every other client they own.
const MIGRATE_V21: &str = "
CREATE TABLE title_verdict (
  title_id INTEGER PRIMARY KEY REFERENCES titles(id) ON DELETE CASCADE,
  verdict INTEGER NOT NULL,
  stated_at INTEGER NOT NULL
);
";

/// v22 is additive, and it is the first thing here that describes a work
/// smaller than a title. `metadata` is keyed by `title_id`, which for a show
/// names the series: an episode's own title, its own sentence and its own
/// frame have had nowhere to sit, so a screen has composed "S01E03" out of
/// two numbers and drawn nothing else.
///
/// The key is a `files` row because that is the only thing in this index an
/// episode is. It is a table of its own rather than three more columns on
/// `files`: those columns describe the work, not the copy - two files of the
/// same episode carry one title between them - and a movie file, which is
/// most of a library, holds no row here at all.
///
/// Every column defaults to empty because empty is a real answer and the
/// ordinary one: a source that names its episodes but stores no frame for
/// them writes a row with `still_path` empty, and nothing ever asks the
/// network to find that out.
const MIGRATE_V22: &str = "
CREATE TABLE episode_meta (
  file_id INTEGER PRIMARY KEY REFERENCES files(id) ON DELETE CASCADE,
  title TEXT NOT NULL DEFAULT '',
  summary TEXT NOT NULL DEFAULT '',
  still_path TEXT NOT NULL DEFAULT ''
);
";

/// v23 splits the score in two and makes each half name its own source.
///
/// `rating` held whichever of the two Plex sent, the critics' preferred - a
/// number whose scale and whose population depended on which fields that
/// item's agent happened to carry, and which nothing downstream could tell
/// apart. It goes rather than staying as a fallback: a score nobody can source
/// reads as a fact and is not one, and leaving the column would leave every
/// row on disk holding one.
///
/// The source column is the presence flag, not the number: 0 is a legitimate
/// score to nobody, but "" is the only honest way to say "this library was
/// never told who measured it", and it is what keeps a TMDB write from
/// clearing what Plex put there.
///
/// The `dirs` rows go with them, for the reason v16's did: both scanners skip
/// a directory or a section whose stamp has not moved, and every row on disk
/// was written by a build that never read `ratingImage` at all.
const MIGRATE_V23: &str = "
ALTER TABLE metadata ADD COLUMN critic_rating REAL NOT NULL DEFAULT 0;
ALTER TABLE metadata ADD COLUMN critic_source TEXT NOT NULL DEFAULT '';
ALTER TABLE metadata ADD COLUMN audience_rating REAL NOT NULL DEFAULT 0;
ALTER TABLE metadata ADD COLUMN audience_source TEXT NOT NULL DEFAULT '';
ALTER TABLE metadata DROP COLUMN rating;
DELETE FROM dirs;
";

// v24: the Tonight block. taste_facet and discovery_pick are written by the
// taste pass beside taste_pick; tonight_pick freezes one evening's trio;
// tonight_deferred is "not tonight", the same idea as resume_dismissed.
const MIGRATE_V24: &str = "
CREATE TABLE taste_facet (
  facet INTEGER PRIMARY KEY,
  weight REAL NOT NULL,
  leader INTEGER NOT NULL REFERENCES titles(id) ON DELETE CASCADE,
  cos_to_top REAL NOT NULL
);
CREATE TABLE discovery_pick (
  rank INTEGER PRIMARY KEY,
  title_id INTEGER NOT NULL REFERENCES titles(id) ON DELETE CASCADE
);
CREATE TABLE tonight_pick (
  evening INTEGER NOT NULL,
  role INTEGER NOT NULL,
  title_id INTEGER NOT NULL REFERENCES titles(id) ON DELETE CASCADE,
  PRIMARY KEY (evening, role)
);
CREATE TABLE tonight_deferred (
  title_id INTEGER PRIMARY KEY REFERENCES titles(id) ON DELETE CASCADE,
  deferred_at INTEGER NOT NULL
);
";

// v25: everything the recommendations batch precomputes. title_taste is the
// per-title explanation the detail screen reads; discovery_pick gains how
// close to the taste each band member sits, which is what the step-aside
// reach filters on; anchor_vector holds the seasonal anchors the embedding
// pass vectorises once per model, and seasonal_pick the library ranked
// against each; thread is the running cycle; tonight_queued is what "after
// this" accepted; setting is the handful of choices the core itself reads.
const MIGRATE_V25: &str = "
CREATE TABLE title_taste (
  title_id INTEGER PRIMARY KEY REFERENCES titles(id) ON DELETE CASCADE,
  facet INTEGER NOT NULL,
  affinity REAL NOT NULL,
  rejected TEXT NOT NULL
);
ALTER TABLE discovery_pick ADD COLUMN closeness REAL NOT NULL DEFAULT 0.5;
CREATE TABLE anchor_vector (
  key TEXT NOT NULL,
  model_version INTEGER NOT NULL,
  vector BLOB NOT NULL,
  PRIMARY KEY (key, model_version)
);
CREATE TABLE seasonal_pick (
  window TEXT NOT NULL,
  rank INTEGER NOT NULL,
  title_id INTEGER NOT NULL REFERENCES titles(id) ON DELETE CASCADE,
  PRIMARY KEY (window, rank)
);
CREATE TABLE thread (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  leader INTEGER NOT NULL REFERENCES titles(id) ON DELETE CASCADE,
  facet INTEGER NOT NULL,
  created_at INTEGER NOT NULL
);
CREATE TABLE thread_item (
  thread_id INTEGER NOT NULL REFERENCES thread(id) ON DELETE CASCADE,
  rank INTEGER NOT NULL,
  title_id INTEGER NOT NULL REFERENCES titles(id) ON DELETE CASCADE,
  PRIMARY KEY (thread_id, rank)
);
CREATE TABLE tonight_queued (
  title_id INTEGER PRIMARY KEY REFERENCES titles(id) ON DELETE CASCADE,
  queued_at INTEGER NOT NULL
);
CREATE TABLE setting (
  key TEXT PRIMARY KEY,
  value TEXT NOT NULL
);
";

/// The schema `user_version` this build reads and writes. A file stamped
/// higher was written by a newer build; opening it here must not run a
/// migration meant for an older shape, and must not treat "newer" as
/// "corrupt".
// v26 is the watchlist: what a viewer put aside to watch later.
//
// Its own table and not a column on `titles`, because it is the viewer's and
// the row is the scanner's: a purge rewrites every title row and would take
// the list with it. The cascade drops an entry whose title really has gone,
// which is the one case where losing it is right.
//
// Deliberately not `tonight_queued`, which looks like the same thing and is
// not. That one is a nudge for one evening, cleared three days on and consumed
// the moment the trio shows it. This one is kept until the viewer says
// otherwise, which is the whole of what "later" means.
const MIGRATE_V26: &str = "
CREATE TABLE watchlist (
  title_id INTEGER PRIMARY KEY REFERENCES titles(id) ON DELETE CASCADE,
  added_at INTEGER NOT NULL
);
CREATE INDEX idx_watchlist_added ON watchlist(added_at DESC, title_id);
";

// v27 is the trailer: the YouTube key the detail screen offers, and the
// negative cache that keeps a library of thousands from asking TMDB about
// every one of them again on every open.
//
// Two columns and not three: the site is not stored because only one is ever
// written. TMDB lists Vimeo beside YouTube and there is nothing on an Apple TV
// to hand a Vimeo key to, so the trailer pass skips those rather than keeping
// a key it could not use.
const MIGRATE_V27: &str = "
ALTER TABLE metadata ADD COLUMN trailer_key TEXT;
ALTER TABLE metadata ADD COLUMN trailer_checked_at INTEGER NOT NULL DEFAULT 0;
";

// v28 is which taste each spent title belongs to. The taste pass
// already computes it for every vector it places; title_taste drops the seen
// ones, because it answers "why is this being offered" and a watched title is
// not being offered. This keeps them, so the evening can ask a different
// question: which taste this viewer actually reaches for on a weeknight.
const MIGRATE_V28: &str = "
CREATE TABLE watched_facet (
  title_id INTEGER PRIMARY KEY REFERENCES titles(id) ON DELETE CASCADE,
  facet INTEGER NOT NULL
);
";

// v29 is the year an episode aired, a billing read to its full length, and the
// part each name on it plays.
//
// `billed_at` stamps a title whose TMDB billing was read at the current
// MAX_CAST: every placed row starts at 0, so each is asked for its credits
// once more and the faces queue drains again. The `dirs` rows go for the
// reason v23's did: a Plex section whose stamp has not moved is skipped, and
// every episode on disk was written by a build that never read its year.
const MIGRATE_V29: &str = "
ALTER TABLE episode_meta ADD COLUMN air_year INTEGER NOT NULL DEFAULT 0;
ALTER TABLE metadata ADD COLUMN billed_at INTEGER NOT NULL DEFAULT 0;
ALTER TABLE metadata ADD COLUMN cast_characters TEXT NOT NULL DEFAULT '';
DELETE FROM dirs;
";

// A row already marked watched has been played at least once, whatever the
// server or the local history can still say about it: the flag is all a
// build before this one kept, so it is all there is to count from.
const MIGRATE_V31: &str = "
ALTER TABLE watch_state ADD COLUMN plays INTEGER NOT NULL DEFAULT 0;
UPDATE watch_state SET plays = 1 WHERE watched = 1;
";

// The evening's own answers: who is watching, and how long they have. One
// row per evening, dropped with the picks it belongs to.
//
// The picks go because the roles were renumbered with this schema: a frozen
// row from an older build names a slot that no longer means what it said.
const MIGRATE_V32: &str = "
CREATE TABLE evening_state (
  evening INTEGER PRIMARY KEY,
  together INTEGER NOT NULL DEFAULT 0,
  window_min INTEGER
);
DELETE FROM tonight_pick;
";

// The taste keeps a memory: what the viewer did that moved it, and what it
// looked like each time it was recomputed.
//
// taste_event has no primary key on purpose. It is a log: the same title
// finished twice is two events, and the second one is not a correction of the
// first.
const MIGRATE_V33: &str = "
CREATE TABLE taste_event (
  at INTEGER NOT NULL,
  kind INTEGER NOT NULL,
  title_id INTEGER NOT NULL REFERENCES titles(id) ON DELETE CASCADE
);
CREATE INDEX taste_event_at ON taste_event(at);
CREATE TABLE taste_facet_snapshot (
  at INTEGER NOT NULL,
  facet INTEGER NOT NULL,
  weight REAL NOT NULL,
  leader INTEGER NOT NULL,
  PRIMARY KEY (at, facet)
);
";

// v34 is what a copy speaks: the languages of its audio and subtitle tracks.
const MIGRATE_V34: &str = "
ALTER TABLE files ADD COLUMN audio_languages TEXT NOT NULL DEFAULT '';
ALTER TABLE files ADD COLUMN subtitle_languages TEXT NOT NULL DEFAULT '';
";

// v35 is what the evening has already shown, and what TMDB says a title is
// about. `cards` counts the evenings a title was one of the trio's cards,
// `last_card` is the latest of them, and `last_lane` the latest evening it
// was anywhere in the evening's lane. `keywords` is TMDB's tags for a placed
// title, and `keywords_at` when they were asked for: 0 is never.
const MIGRATE_V35: &str = "
CREATE TABLE tonight_exposure (
  title_id INTEGER PRIMARY KEY REFERENCES titles(id) ON DELETE CASCADE,
  cards INTEGER NOT NULL DEFAULT 0,
  last_card INTEGER NOT NULL DEFAULT 0,
  last_lane INTEGER NOT NULL
);
ALTER TABLE metadata ADD COLUMN keywords TEXT NOT NULL DEFAULT '';
ALTER TABLE metadata ADD COLUMN keywords_at INTEGER NOT NULL DEFAULT 0;
";

// v36 is where each launch came from, when the home was opened, and which
// cards each evening showed in which role: what the stats measure the
// propositions against. `detail` is the kind of a row's reason, never its name.
const MIGRATE_V36: &str = "
CREATE TABLE launch (
  at INTEGER NOT NULL,
  title_id INTEGER NOT NULL REFERENCES titles(id) ON DELETE CASCADE,
  surface TEXT NOT NULL,
  detail TEXT NOT NULL DEFAULT ''
);
CREATE INDEX launch_at ON launch(at);
CREATE TABLE home_open (at INTEGER NOT NULL);
CREATE INDEX home_open_at ON home_open(at);
CREATE TABLE tonight_shown (
  evening INTEGER NOT NULL,
  title_id INTEGER NOT NULL REFERENCES titles(id) ON DELETE CASCADE,
  role INTEGER NOT NULL,
  PRIMARY KEY (evening, title_id)
);
";

// v37 is how often the rest of the page has shown a title: `lanes` counts the
// evenings it sat in the lane under the trio, and `row_exposure` the days a
// taste row carried it (reset by a launch), both forgotten after a month away.
const MIGRATE_V37: &str = "
ALTER TABLE tonight_exposure ADD COLUMN lanes INTEGER NOT NULL DEFAULT 0;
CREATE TABLE row_exposure (
  title_id INTEGER PRIMARY KEY REFERENCES titles(id) ON DELETE CASCADE,
  shows INTEGER NOT NULL DEFAULT 0,
  last_day INTEGER NOT NULL
);
";

// v38 is the mood the viewer asked of the evening, and how many voters stand
// behind each score: a NULL count is a source that never said, which the trio
// reads as a score worth half of its own weight.
const MIGRATE_V38: &str = "
ALTER TABLE evening_state ADD COLUMN mood TEXT;
ALTER TABLE metadata ADD COLUMN audience_votes INTEGER;
ALTER TABLE metadata ADD COLUMN critic_votes INTEGER;
";

// v39 is when a title came out, NULL where no source has said, and the film
// club's themes as the taste pass found them: each qualifying theme's unseen
// titles and how near the taste each sits. `kind` is "keyword", "composer" or
// "writer".
const MIGRATE_V39: &str = "
ALTER TABLE metadata ADD COLUMN release_date TEXT;
CREATE TABLE club_pick (
  kind TEXT NOT NULL,
  value TEXT NOT NULL,
  title_id INTEGER NOT NULL REFERENCES titles(id) ON DELETE CASCADE,
  affinity REAL NOT NULL,
  PRIMARY KEY (kind, value, title_id)
);
";

// v40 is the tone the taste pass reads in each title: up to two moods whose
// anchor it stands out towards, and by how much past that anchor's floor.
//
// It also keys embeddings on the encoder as well as the title, so the vectors
// one encoder wrote stand beside another's instead of being overwritten by it.
const MIGRATE_V40: &str = "
CREATE TABLE embeddings_v40 (
  title_id INTEGER NOT NULL REFERENCES titles(id) ON DELETE CASCADE,
  model_version INTEGER NOT NULL,
  source_hash INTEGER NOT NULL,
  vector BLOB NOT NULL,
  computed_at INTEGER NOT NULL,
  PRIMARY KEY (title_id, model_version)
);
INSERT INTO embeddings_v40 (title_id, model_version, source_hash, vector, computed_at)
  SELECT title_id, model_version, source_hash, vector, computed_at FROM embeddings;
DROP TABLE embeddings;
ALTER TABLE embeddings_v40 RENAME TO embeddings;
CREATE TABLE title_tone (
  title_id INTEGER NOT NULL REFERENCES titles(id) ON DELETE CASCADE,
  mood TEXT NOT NULL,
  score REAL NOT NULL,
  PRIMARY KEY (title_id, mood)
);
";

// v41 is the people the viewer watches with: each guest's own verdicts, the
// guest chosen for the session, and how near each unseen title sits to that
// guest's taste. `guest_taste` is written by the duo's sweep so the trio,
// asked every minute, reads a guest's taste rather than measuring it.
const MIGRATE_V41: &str = "
CREATE TABLE guest (
  id INTEGER PRIMARY KEY,
  name TEXT NOT NULL UNIQUE,
  created_at INTEGER NOT NULL
);
CREATE TABLE guest_verdict (
  guest_id INTEGER NOT NULL REFERENCES guest(id) ON DELETE CASCADE,
  title_id INTEGER NOT NULL REFERENCES titles(id) ON DELETE CASCADE,
  verdict INTEGER NOT NULL,
  stated_at INTEGER NOT NULL,
  PRIMARY KEY (guest_id, title_id)
);
CREATE TABLE guest_taste (
  guest_id INTEGER NOT NULL REFERENCES guest(id) ON DELETE CASCADE,
  title_id INTEGER NOT NULL REFERENCES titles(id) ON DELETE CASCADE,
  cos REAL NOT NULL,
  PRIMARY KEY (guest_id, title_id)
);
ALTER TABLE evening_state ADD COLUMN guest_id INTEGER;
";

// v42 is the tastes the viewer contested: a facet led by `leader_id` weighs
// less in the fingerprint until `until`.
const MIGRATE_V42: &str = "
CREATE TABLE taste_mute (
  leader_id INTEGER PRIMARY KEY REFERENCES titles(id) ON DELETE CASCADE,
  until INTEGER NOT NULL
);
";

// v43 indexes the title_id of the tables a deleted title cascades through,
// and when each file was last watched, which the minute's trio filters on.
// It also stamps when a session's trio froze, so a title queued after it can
// be told from one queued before, and keeps the double feature being watched
// so its second film can be proposed as the first one ends.
const MIGRATE_V43: &str = "
CREATE INDEX IF NOT EXISTS launch_title ON launch(title_id);
CREATE INDEX IF NOT EXISTS tonight_shown_title ON tonight_shown(title_id);
CREATE INDEX IF NOT EXISTS club_pick_title ON club_pick(title_id);
CREATE INDEX IF NOT EXISTS guest_verdict_title ON guest_verdict(title_id);
CREATE INDEX IF NOT EXISTS guest_taste_title ON guest_taste(title_id);
CREATE INDEX IF NOT EXISTS watch_state_updated ON watch_state(updated_at);
ALTER TABLE tonight_pick ADD COLUMN at INTEGER NOT NULL DEFAULT 0;
CREATE TABLE double_next (
  first_id INTEGER PRIMARY KEY REFERENCES titles(id) ON DELETE CASCADE,
  second_id INTEGER NOT NULL REFERENCES titles(id) ON DELETE CASCADE,
  at INTEGER NOT NULL
);
";

// v44 indexes episode names for search, kept in step with episode_meta by
// its own triggers: a viewer looks for an episode by what it is called.
const MIGRATE_V44: &str = "
CREATE VIRTUAL TABLE episode_search USING fts5(
  title,
  tokenize = 'unicode61 remove_diacritics 2',
  prefix = '2 3'
);
INSERT INTO episode_search (rowid, title) SELECT file_id, title FROM episode_meta;
CREATE TRIGGER episode_search_insert AFTER INSERT ON episode_meta BEGIN
  INSERT INTO episode_search (rowid, title) VALUES (new.file_id, new.title);
END;
CREATE TRIGGER episode_search_update AFTER UPDATE OF title ON episode_meta BEGIN
  UPDATE episode_search SET title = new.title WHERE rowid = new.file_id;
END;
CREATE TRIGGER episode_search_delete AFTER DELETE ON episode_meta BEGIN
  DELETE FROM episode_search WHERE rowid = old.file_id;
END;
";

// v45 remembers which kinds of row the home offered each day: what a row's
// launches are weighed against, so a row is not rated for being on top.
const MIGRATE_V45: &str = "
CREATE TABLE row_kind_shown (
  day INTEGER NOT NULL,
  kind TEXT NOT NULL,
  PRIMARY KEY (day, kind)
) WITHOUT ROWID;
";

// v46 remembers which people the home named on a row each day, and the ones
// it has let rest after naming them a week with nothing of theirs played.
const MIGRATE_V46: &str = "
CREATE TABLE row_subject_shown (
  kind TEXT NOT NULL,
  value TEXT NOT NULL,
  day INTEGER NOT NULL,
  PRIMARY KEY (kind, value, day)
) WITHOUT ROWID;
CREATE TABLE subject_rest (
  kind TEXT NOT NULL,
  value TEXT NOT NULL,
  until_day INTEGER NOT NULL,
  PRIMARY KEY (kind, value)
) WITHOUT ROWID;
";

// v47 is TMDB's trending of the week, films and shows apart for the same
// reason as tmdb_similar: the two id sequences overlap. Replaced whole by each
// daily fetch; `fetched_at` is the same on every row of one kind.
const MIGRATE_V47: &str = "
CREATE TABLE tmdb_trending (
  kind TEXT NOT NULL CHECK (kind IN ('movie','show')),
  tmdb_id INTEGER NOT NULL,
  rank INTEGER NOT NULL,
  fetched_at INTEGER NOT NULL,
  PRIMARY KEY (kind, tmdb_id)
) WITHOUT ROWID;
";

// v48 changes no shape: tmdb_similar is filled from TMDB's recommendations
// now, and emptying it puts every matched title back in the fetch queue.
const MIGRATE_V48: &str = "
DELETE FROM tmdb_similar;
";

// v49 drops the double feature's pairing, which nothing reads any more, and
// the unattributed launches `record_launch` no longer keeps.
const MIGRATE_V49: &str = "
DROP TABLE IF EXISTS double_next;
DELETE FROM launch WHERE surface = 'other' AND EXISTS (
  SELECT 1 FROM launch p
  WHERE p.title_id = launch.title_id AND p.at < launch.at AND p.at > launch.at - 21600
);
";

// v50 makes title and file ids never come back: the artwork cache is filed
// under the title id, so a reused id would show a deleted title's poster.
// AUTOINCREMENT needs the tables rebuilt, which `init` runs with foreign keys
// off and the legacy rename, ids kept as they are. It also indexes the child
// side of every cascade from titles, which a title delete otherwise pays as
// a scan of each child table, and keeps the stage shows in a table of their
// own, which every home render otherwise asked of the whole metadata table.
const MIGRATE_V50: &str = concat!(
    "
CREATE TABLE titles_v50 (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  kind TEXT NOT NULL CHECK (kind IN ('movie','show')),
  name TEXT NOT NULL,
  year INTEGER NOT NULL DEFAULT 0,
  added_at INTEGER NOT NULL DEFAULT 0,
  UNIQUE (kind, name, year)
);
INSERT INTO titles_v50 (id, kind, name, year, added_at)
  SELECT id, kind, name, year, added_at FROM titles;
DROP TABLE titles;
ALTER TABLE titles_v50 RENAME TO titles;
CREATE INDEX idx_titles_name ON titles(name COLLATE NOCASE);
CREATE INDEX idx_titles_kind_name ON titles(kind, name COLLATE NOCASE, id);
CREATE INDEX idx_titles_kind_year ON titles(kind, year DESC, name COLLATE NOCASE, id);
CREATE INDEX idx_titles_kind_added ON titles(kind, added_at DESC, id DESC);
CREATE INDEX idx_titles_added ON titles(added_at DESC, id);
CREATE TRIGGER title_search_title_insert AFTER INSERT ON titles BEGIN
  INSERT INTO title_search (rowid, name, genres, cast_names, director_names, crew_names)
    VALUES (new.id, new.name, '', '', '', '');
END;
CREATE TRIGGER title_search_title_delete AFTER DELETE ON titles BEGIN
  DELETE FROM title_search WHERE rowid = old.id;
END;
CREATE TABLE files_v50 (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  source_id TEXT NOT NULL,
  dir TEXT NOT NULL,
  path TEXT NOT NULL,
  size INTEGER NOT NULL,
  mtime INTEGER NOT NULL,
  seen_gen INTEGER NOT NULL,
  title_id INTEGER NOT NULL REFERENCES titles(id),
  season INTEGER,
  episode INTEGER,
  rating_key TEXT,
  duration_secs REAL NOT NULL DEFAULT 0,
  video_resolution TEXT NOT NULL DEFAULT '',
  video_codec TEXT NOT NULL DEFAULT '',
  dynamic_range TEXT NOT NULL DEFAULT '',
  audio_codec TEXT NOT NULL DEFAULT '',
  audio_channels INTEGER NOT NULL DEFAULT 0,
  atmos INTEGER NOT NULL DEFAULT 0,
  audio_languages TEXT NOT NULL DEFAULT '',
  subtitle_languages TEXT NOT NULL DEFAULT '',
  UNIQUE (source_id, path)
);
INSERT INTO files_v50 SELECT id, source_id, dir, path, size, mtime, seen_gen, title_id,
  season, episode, rating_key, duration_secs, video_resolution, video_codec,
  dynamic_range, audio_codec, audio_channels, atmos, audio_languages, subtitle_languages
  FROM files;
DROP TABLE files;
ALTER TABLE files_v50 RENAME TO files;
CREATE INDEX idx_files_title ON files(title_id);
CREATE INDEX idx_files_dir ON files(source_id, dir);
CREATE INDEX idx_files_rating_key ON files(source_id, rating_key) WHERE rating_key IS NOT NULL;
CREATE TRIGGER titles_added_on_insert AFTER INSERT ON files BEGIN
  UPDATE titles SET added_at = new.mtime
    WHERE id = new.title_id AND added_at < new.mtime;
END;
CREATE TRIGGER titles_added_on_update AFTER UPDATE OF mtime, title_id ON files BEGIN
  UPDATE titles SET added_at = new.mtime
    WHERE id = new.title_id AND added_at < new.mtime;
END;
CREATE INDEX IF NOT EXISTS taste_pick_title ON taste_pick(title_id);
CREATE INDEX IF NOT EXISTS taste_facet_leader ON taste_facet(leader);
CREATE INDEX IF NOT EXISTS discovery_pick_title ON discovery_pick(title_id);
CREATE INDEX IF NOT EXISTS tonight_pick_title ON tonight_pick(title_id);
CREATE INDEX IF NOT EXISTS seasonal_pick_title ON seasonal_pick(title_id);
CREATE INDEX IF NOT EXISTS thread_leader ON thread(leader);
CREATE INDEX IF NOT EXISTS thread_item_title ON thread_item(title_id);
CREATE INDEX IF NOT EXISTS taste_event_title ON taste_event(title_id);
DROP TRIGGER IF EXISTS episode_search_update;
CREATE TRIGGER episode_search_update AFTER UPDATE OF title ON episode_meta
  WHEN new.title <> old.title BEGIN
  UPDATE episode_search SET title = new.title WHERE rowid = new.file_id;
END;
CREATE TABLE IF NOT EXISTS stage_show (
  title_id INTEGER PRIMARY KEY REFERENCES metadata(title_id) ON DELETE CASCADE
);
INSERT OR IGNORE INTO stage_show SELECT title_id FROM metadata WHERE ",
    stage_show!("metadata"),
    ";
"
);

// v51 drops the anchors embedded from their earlier texts, so the pass embeds
// the current ones, and files every person under the last word of their
// folded name: a question asked in words finds "de godard" by index.
const MIGRATE_V51: &str = "
DELETE FROM anchor_vector;
ALTER TABLE people ADD COLUMN last_word TEXT NOT NULL DEFAULT '';
CREATE INDEX idx_people_last_word ON people(last_word);
";

/// How long after a launch an unattributed one of the same title is the
/// player going on rather than a new choice. `MIGRATE_V49` spells it out.
const LAUNCH_REPEAT_SECS: i64 = 6 * 3_600;

// v53 forgets every stamp a sync skips a section or a directory on, so the
// next sync reads each source whole once: a Plex item's logo is only written
// as the item is read, and an unchanged section is otherwise never read again.
const MIGRATE_V53: &str = "DELETE FROM dirs;";

// v52 tells the copies of a title apart: the cut each one is (a Plex
// edition), and a rank of what it shows, so a title plays its best copy and
// not the first one scanned. The rank is 0 on an episode, whose copies are
// other episodes and never compete. Resolution first, then the dynamic range,
// then the bytes per second of film.
const MIGRATE_V52: &str = "
ALTER TABLE files ADD COLUMN edition TEXT NOT NULL DEFAULT '';
ALTER TABLE files ADD COLUMN quality INTEGER GENERATED ALWAYS AS (
  CASE WHEN season IS NOT NULL THEN 0 ELSE
    (CASE video_resolution WHEN '4k' THEN 4 WHEN '1080' THEN 3 WHEN '720' THEN 2
      WHEN 'sd' THEN 1 ELSE 0 END) * 1000000000
    + (CASE dynamic_range WHEN 'dolby_vision' THEN 3 WHEN 'hdr10' THEN 2
      WHEN 'hlg' THEN 1 ELSE 0 END) * 100000000
    + min(CAST(COALESCE(size / NULLIF(duration_secs, 0), 0) AS INTEGER), 99999999)
  END) VIRTUAL;
CREATE INDEX idx_files_title_quality ON files(title_id, quality DESC, id);
";

const SCHEMA_VERSION: i64 = 53;

/// Puts one title back in `stage_show` if it is one, after anything the test
/// reads moved; `STAGE_CLEAR` runs first.
const STAGE_REFRESH: &str = concat!(
    "INSERT OR IGNORE INTO stage_show SELECT title_id FROM metadata WHERE title_id = ?1 AND ",
    stage_show!("metadata")
);
const STAGE_CLEAR: &str = "DELETE FROM stage_show WHERE title_id = ?1";

/// How many prepared statements each connection keeps.
const STATEMENT_CACHE: usize = 128;

/// A person the home names on a row for this many days of the last
/// `SUBJECT_WINDOW_DAYS` with nothing of theirs played rests for
/// `SUBJECT_REST_DAYS`: a week of being passed over is an answer.
const SUBJECT_TRIAL_DAYS: u32 = 7;
const SUBJECT_WINDOW_DAYS: i64 = 14;
const SUBJECT_REST_DAYS: i64 = 30;

/// Rank of the "TMDB was asked and listed nothing" row. Last in any
/// `ORDER BY rank`, so a reader that skips `similar_tmdb_id = 0` and one that
/// forgets both see the real recommendations in the same order.
const SIMILAR_SENTINEL_RANK: i64 = i64::MAX;

/// The share of a runtime past which a position is a finish rather than a place
/// to carry on from. `upsert_watch_state` raises `watched` when a write crosses
/// it, and no reader offers a resume beyond it.
const WATCHED_FRACTION: f64 = 0.9;

/// A position this close to the end of a file is the credits. The player clamps
/// a seek to the duration and then has nothing left to read, so a resume point
/// in there is a dead player: the detail offers a start instead. The 90% rule
/// usually gets there first; this is what catches a short file.
const RESUME_TAIL_SECS: f64 = 30.0;

/// Whether this row is somewhere a viewer can carry on from. The position
/// alone answers it: `watched` says the file has been finished at least once,
/// which a rewatch does not undo, and Plex hands back a live `viewOffset` on an
/// item it has also counted as played. A position past the finish rule, or in
/// the credits, is a file that ended rather than one left running.
///
/// The SQL form below is the same rule for the queries that cannot call this,
/// and `the two forms of in progress agree` is what keeps them one rule.
pub fn in_progress(position_secs: f64, duration_secs: f64) -> bool {
    position_secs > 0.0
        && (duration_secs <= 0.0
            || (position_secs / duration_secs <= WATCHED_FRACTION
                && position_secs < duration_secs - RESUME_TAIL_SECS))
}

/// `in_progress` over a `watch_state` joined as `w`. Written for a LEFT JOIN,
/// where a file nothing ever played has no row at all.
pub const IN_PROGRESS: &str = "COALESCE(w.position_secs, 0) > 0
     AND (COALESCE(w.duration_secs, 0) <= 0
          OR (w.position_secs / w.duration_secs <= 0.9
              AND w.position_secs < w.duration_secs - 30.0))";

/// The columns both episode queries answer with. The watch row is a LEFT JOIN:
/// a file nothing ever played has none.
const EPISODE_SELECT: &str = "SELECT f.id, f.title_id, t.name, f.season, f.episode,
    COALESCE(w.watched, 0), COALESCE(w.position_secs, 0), COALESCE(w.duration_secs, 0),
    COALESCE(e.title, ''), COALESCE(e.summary, ''), f.duration_secs, COALESCE(e.air_year, 0)
  FROM files f
  JOIN titles t ON t.id = f.title_id
  LEFT JOIN watch_state w ON w.file_id = f.id
  LEFT JOIN episode_meta e ON e.file_id = f.id";

/// Replaces this title's `title_tags` rows of one kind with the values `csv`
/// carries. Called with the same comma-joined string a metadata write is
/// storing, so title_tags is never out of step with genres, cast_names or
/// collections: a title with no value of this kind is simply left with none.
fn write_tags(conn: &Connection, title_id: i64, kind: &str, csv: &str) -> Result<(), IndexError> {
    conn.prepare_cached("DELETE FROM title_tags WHERE title_id = ?1 AND kind = ?2")?
        .execute(params![title_id, kind])?;
    let mut stmt =
        conn.prepare_cached("INSERT INTO title_tags (title_id, kind, value) VALUES (?1, ?2, ?3)")?;
    for value in csv.split(',').filter(|v| !v.is_empty()) {
        stmt.execute(params![title_id, kind, value])?;
    }
    Ok(())
}

/// A `people` row for every name in one credit column, created on first sight
/// and never removed: a person is not owned by the title that introduced them,
/// and their number is what a cached photograph is filed under.
///
/// Called beside `write_tags` rather than from inside it. The two kinds that
/// name a person are the only ones a face is ever drawn for, and the v7
/// backfill runs `write_tags` ten migrations before this table exists.
fn write_people(conn: &Connection, csv: &str) -> Result<(), IndexError> {
    let mut stmt =
        conn.prepare_cached("INSERT OR IGNORE INTO people (name, last_word) VALUES (?1, ?2)")?;
    for name in csv.split(',').filter(|v| !v.is_empty()) {
        stmt.execute(params![name, normalize(name).rsplit(' ').next()])?;
    }
    Ok(())
}

fn row_to_episode(r: &rusqlite::Row) -> rusqlite::Result<EpisodeRow> {
    Ok(EpisodeRow {
        file_id: r.get(0)?,
        title_id: r.get(1)?,
        name: r.get(2)?,
        season: r.get(3)?,
        episode: r.get(4)?,
        watched: r.get(5)?,
        position_secs: r.get(6)?,
        duration_secs: r.get(7)?,
        title: r.get(8)?,
        summary: r.get(9)?,
        runtime_secs: r.get(10)?,
        air_year: Some(r.get::<_, u16>(11)?).filter(|y| *y != 0),
    })
}

impl Db {
    pub fn open(path: &Path) -> Result<Db, IndexError> {
        match Self::open_file(path) {
            Ok(db) => Ok(db),
            // only bytes sqlite itself calls unusable are worth losing: a
            // missing file already opens clean above (sqlite creates it), and
            // every other failure - locked, out of space, wrong permissions,
            // a schema newer than this build, a migration bug - leaves a file
            // a later attempt, or a newer build, could still read. Deleting
            // on those would turn a fixable problem into a lost library.
            Err(e) if e.is_corrupt() => {
                for suffix in ["", "-wal", "-shm"] {
                    let mut p = path.as_os_str().to_os_string();
                    p.push(suffix);
                    let _ = std::fs::remove_file(p);
                }
                Self::open_file(path)
            }
            Err(e) => Err(e),
        }
    }

    pub fn open_read_only(path: &Path) -> Result<Db, IndexError> {
        let conn = Connection::open_with_flags(
            path,
            OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NO_MUTEX,
        )?;
        // the vector table is re-read whole by taste and the sweep: mmap
        // turns those blob reads into address-space reads instead of page
        // cache misses, and a roomy page cache covers the rest. busy_timeout
        // for the same reason as the writable side.
        conn.execute_batch(
            "PRAGMA busy_timeout=5000;
             PRAGMA cache_size=-16000;
             PRAGMA mmap_size=134217728;",
        )?;
        // a home render alone runs some forty distinct statements
        conn.set_prepared_statement_cache_capacity(STATEMENT_CACHE);
        Ok(Db { conn })
    }

    pub fn open_in_memory() -> Result<Db, IndexError> {
        Self::init(Connection::open_in_memory()?)
    }

    /// A private in-memory copy of this database, migrated to this build's
    /// schema. Nothing done to the copy reaches the original.
    pub fn copy_in_memory(&self) -> Result<Db, IndexError> {
        let version: i64 = self
            .conn
            .query_row("PRAGMA user_version", [], |r| r.get(0))?;
        if version > SCHEMA_VERSION {
            return Err(IndexError::SchemaTooNew {
                found: version,
                supported: SCHEMA_VERSION,
            });
        }
        let mut conn = Connection::open_in_memory()?;
        rusqlite::backup::Backup::new(&self.conn, &mut conn)?.run_to_completion(
            i32::MAX,
            std::time::Duration::ZERO,
            None,
        )?;
        Self::init(conn)
    }

    fn open_file(path: &Path) -> Result<Db, IndexError> {
        let conn = Connection::open(path)?;
        // read before journal_mode is touched: a schema newer than this
        // build must leave the file exactly as the newer build wrote it, WAL
        // mode included, for that build to read cleanly
        let version: i64 = conn.query_row("PRAGMA user_version", [], |r| r.get(0))?;
        if version > SCHEMA_VERSION {
            return Err(IndexError::SchemaTooNew {
                found: version,
                supported: SCHEMA_VERSION,
            });
        }
        conn.pragma_update(None, "journal_mode", "WAL")?;
        Self::init(conn)
    }

    fn init(conn: Connection) -> Result<Db, IndexError> {
        // a rebuildable cache does not need a durable commit per transaction
        conn.pragma_update(None, "synchronous", "NORMAL")?;
        // a BUSY from a checkpoint or a stale -shm must wait out its cause,
        // not surface as a Storage error on a browse call
        conn.pragma_update(None, "busy_timeout", 5000)?;
        // the same reads as the readonly side, and a WAL a full sync grew
        // is cut back after its checkpoint instead of keeping its peak size
        conn.execute_batch(
            "PRAGMA cache_size=-16000;
             PRAGMA mmap_size=134217728;
             PRAGMA journal_size_limit=8388608;",
        )?;
        conn.set_prepared_statement_cache_capacity(STATEMENT_CACHE);
        // on by default in this build: see v50 for why the migrations run without
        conn.pragma_update(None, "foreign_keys", "OFF")?;
        let version: i64 = conn.query_row("PRAGMA user_version", [], |r| r.get(0))?;
        // a schema newer than SCHEMA_VERSION never reaches here: open_file
        // returns IndexError::SchemaTooNew before calling init, and
        // open_in_memory always starts a fresh connection at version 0
        debug_assert!(version <= SCHEMA_VERSION);
        // the DDL and the stamp commit together: a file left migrated but still
        // stamped with the old version would re-run the migration on the next
        // open and fail, which now leaves the file in place rather than
        // wiping it (see `open`)
        if version < SCHEMA_VERSION {
            let tx = conn.unchecked_transaction()?;
            if version < 1 {
                conn.execute_batch(SCHEMA)?;
            }
            if version < 2 {
                conn.execute_batch(MIGRATE_V2)?;
            }
            if version < 3 {
                conn.execute_batch(MIGRATE_V3)?;
            }
            if version < 4 {
                conn.execute_batch(MIGRATE_V4)?;
            }
            if version < 5 {
                conn.execute_batch(MIGRATE_V5)?;
            }
            if version < 6 {
                conn.execute_batch(MIGRATE_V6)?;
            }
            if version < 7 {
                conn.execute_batch(MIGRATE_V7)?;
                // title_tags is new and metadata is not: every row already on
                // disk backfills once here, the same split upsert_metadata
                // does for every write from now on.
                let existing: Vec<(i64, String, String, String)> = conn
                    .prepare("SELECT title_id, genres, cast_names, collections FROM metadata")?
                    .query_map([], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?)))?
                    .collect::<Result<_, _>>()?;
                for (title_id, genres, cast_names, collections) in existing {
                    write_tags(&conn, title_id, "genre", &genres)?;
                    write_tags(&conn, title_id, "cast", &cast_names)?;
                    write_tags(&conn, title_id, "collection", &collections)?;
                }
            }
            if version < 8 {
                conn.execute_batch(MIGRATE_V8)?;
            }
            if version < 9 {
                conn.execute_batch(MIGRATE_V9)?;
            }
            if version < 10 {
                conn.execute_batch(MIGRATE_V10)?;
            }
            if version < 11 {
                conn.execute_batch(MIGRATE_V11)?;
            }
            if version < 12 {
                conn.execute_batch(MIGRATE_V12)?;
            }
            if version < 13 {
                conn.execute_batch(MIGRATE_V13)?;
            }
            if version < 14 {
                conn.execute_batch(MIGRATE_V14)?;
            }
            if version < 15 {
                conn.execute_batch(MIGRATE_V15)?;
            }
            if version < 16 {
                conn.execute_batch(MIGRATE_V16)?;
            }
            if version < 17 {
                conn.execute_batch(MIGRATE_V17)?;
            }
            if version < 18 {
                conn.execute_batch(MIGRATE_V18)?;
            }
            if version < 19 {
                conn.execute_batch(MIGRATE_V19)?;
            }
            if version < 20 {
                conn.execute_batch(MIGRATE_V20)?;
            }
            if version < 21 {
                conn.execute_batch(MIGRATE_V21)?;
            }
            if version < 22 {
                conn.execute_batch(MIGRATE_V22)?;
            }
            if version < 23 {
                conn.execute_batch(MIGRATE_V23)?;
            }
            if version < 24 {
                conn.execute_batch(MIGRATE_V24)?;
            }
            if version < 25 {
                conn.execute_batch(MIGRATE_V25)?;
            }
            if version < 26 {
                conn.execute_batch(MIGRATE_V26)?;
            }
            if version < 27 {
                conn.execute_batch(MIGRATE_V27)?;
            }
            if version < 28 {
                conn.execute_batch(MIGRATE_V28)?;
            }
            if version < 29 {
                conn.execute_batch(MIGRATE_V29)?;
            }
            if version < 30 {
                // v30: the crew columns are not new, the tag rows for them
                // are. Every row on disk backfills once here, the same way
                // upsert_metadata splits every write from now on.
                let existing: Vec<(i64, String, String)> = conn
                    .prepare("SELECT title_id, writer_names, composer_names FROM metadata")?
                    .query_map([], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)))?
                    .collect::<Result<_, _>>()?;
                for (title_id, writers, composers) in existing {
                    write_tags(&conn, title_id, "writer", &writers)?;
                    write_tags(&conn, title_id, "composer", &composers)?;
                }
                // not write_people: `last_word` is v51's
                conn.execute_batch(
                    "INSERT OR IGNORE INTO people (name)
                     SELECT DISTINCT value FROM title_tags WHERE kind IN ('writer', 'composer')",
                )?;
            }
            if version < 31 {
                conn.execute_batch(MIGRATE_V31)?;
            }
            if version < 32 {
                conn.execute_batch(MIGRATE_V32)?;
            }
            if version < 33 {
                conn.execute_batch(MIGRATE_V33)?;
            }
            if version < 34 {
                conn.execute_batch(MIGRATE_V34)?;
            }
            if version < 35 {
                conn.execute_batch(MIGRATE_V35)?;
            }
            if version < 36 {
                conn.execute_batch(MIGRATE_V36)?;
            }
            if version < 37 {
                conn.execute_batch(MIGRATE_V37)?;
            }
            if version < 38 {
                conn.execute_batch(MIGRATE_V38)?;
            }
            if version < 39 {
                conn.execute_batch(MIGRATE_V39)?;
            }
            if version < 40 {
                conn.execute_batch(MIGRATE_V40)?;
            }
            if version < 41 {
                conn.execute_batch(MIGRATE_V41)?;
            }
            if version < 42 {
                conn.execute_batch(MIGRATE_V42)?;
            }
            if version < 43 {
                conn.execute_batch(MIGRATE_V43)?;
            }
            if version < 44 {
                conn.execute_batch(MIGRATE_V44)?;
            }
            if version < 45 {
                conn.execute_batch(MIGRATE_V45)?;
            }
            if version < 46 {
                conn.execute_batch(MIGRATE_V46)?;
            }
            if version < 47 {
                conn.execute_batch(MIGRATE_V47)?;
            }
            if version < 48 {
                conn.execute_batch(MIGRATE_V48)?;
            }
            if version < 49 {
                conn.execute_batch(MIGRATE_V49)?;
            }
            if version < 50 {
                // the rebuild drops and renames titles and files: with foreign
                // keys on, the drop would cascade through every child table,
                // and a modern rename would trip over the triggers naming them
                conn.execute_batch("PRAGMA legacy_alter_table=ON;")?;
                conn.execute_batch(MIGRATE_V50)?;
                conn.execute_batch("PRAGMA legacy_alter_table=OFF;")?;
            }
            if version < 51 {
                conn.execute_batch(MIGRATE_V51)?;
                let names: Vec<(i64, String)> = conn
                    .prepare("SELECT id, name FROM people")?
                    .query_map([], |r| Ok((r.get(0)?, r.get(1)?)))?
                    .collect::<Result<_, _>>()?;
                let mut stmt = conn.prepare("UPDATE people SET last_word = ?2 WHERE id = ?1")?;
                for (id, name) in names {
                    stmt.execute(params![id, normalize(&name).rsplit(' ').next()])?;
                }
            }
            if version < 52 {
                conn.execute_batch(MIGRATE_V52)?;
            }
            if version < 53 {
                conn.execute_batch(MIGRATE_V53)?;
            }
            conn.pragma_update(None, "user_version", SCHEMA_VERSION)?;
            tx.commit()?;
        }
        // off until the migrations are done: see v50. Inside a transaction
        // this pragma is a no-op, so it waits for the commit above.
        conn.pragma_update(None, "foreign_keys", "ON")?;
        Ok(Db { conn })
    }

    /// The title row for one name, created on first sight.
    ///
    /// A movie is identified by its name and its year together: two films
    /// carry the same name often enough, and a movie always arrives with a
    /// year. A show is identified by its name alone, and its year is an
    /// attribute written onto the row. Only one of the two passes that reach a
    /// series knows its year - the show-level one - and keying on it would
    /// file the summary and the episodes under separate rows.
    pub fn upsert_title(
        &self,
        kind: MediaKind,
        name: &str,
        year: Option<u16>,
    ) -> Result<i64, IndexError> {
        if kind == MediaKind::Show {
            let existing = {
                let mut stmt = self
                    .conn
                    .prepare_cached("SELECT id FROM titles WHERE kind = 'show' AND name = ?1")?;
                let mut rows = stmt.query(params![name])?;
                match rows.next()? {
                    Some(r) => Some(r.get::<_, i64>(0)?),
                    None => None,
                }
            };
            if let Some(id) = existing {
                // a pass that knows no year never erases the one already there
                if let Some(y) = year {
                    self.conn
                        .prepare_cached("UPDATE titles SET year = ?2 WHERE id = ?1")?
                        .execute(params![id, y])?;
                }
                return Ok(id);
            }
        }
        let id = self
            .conn
            .prepare_cached(
                "INSERT INTO titles (kind, name, year) VALUES (?1, ?2, ?3)
                 ON CONFLICT (kind, name, year) DO UPDATE SET name = excluded.name
                 RETURNING id",
            )?
            .query_row(params![kind.as_str(), name, year.unwrap_or(0)], |r| {
                r.get(0)
            })?;
        Ok(id)
    }

    /// Writes one file row and answers its id, on the insert and on the update
    /// alike: `DO UPDATE` always runs, so `RETURNING` always fires. The id is
    /// what a caller needs to write anything keyed on the file - a watch row,
    /// an episode's own metadata - and taking it from here is one statement
    /// where looking it up again is two.
    pub fn upsert_file(&self, f: &FileRecord) -> Result<i64, IndexError> {
        Ok(self.conn.prepare_cached(
            // a file scanner opens nothing and answers for none of the media
            // columns, so a rescan by one must not wipe what a Plex sync of the
            // same file wrote: each of those keeps its stored value when the
            // write carries the "nothing said so" default. SDR and no-Atmos are
            // real answers that look like the default, so those two follow
            // `video_resolution`, which is the field that says whether the
            // writer answered for the media at all.
            "INSERT INTO files (source_id, dir, path, size, mtime, seen_gen, title_id, season, episode, rating_key,
                                duration_secs, video_resolution, video_codec, dynamic_range,
                                audio_codec, audio_channels, atmos,
                                audio_languages, subtitle_languages, edition)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16, ?17, ?18, ?19, ?20)
             ON CONFLICT (source_id, path) DO UPDATE SET
               dir = excluded.dir, size = excluded.size, mtime = excluded.mtime,
               seen_gen = excluded.seen_gen, title_id = excluded.title_id,
               season = excluded.season, episode = excluded.episode,
               rating_key = excluded.rating_key,
               duration_secs = CASE WHEN excluded.duration_secs = 0
                 THEN files.duration_secs ELSE excluded.duration_secs END,
               video_resolution = CASE WHEN excluded.video_resolution = ''
                 THEN files.video_resolution ELSE excluded.video_resolution END,
               video_codec = CASE WHEN excluded.video_codec = ''
                 THEN files.video_codec ELSE excluded.video_codec END,
               dynamic_range = CASE WHEN excluded.video_resolution = ''
                 THEN files.dynamic_range ELSE excluded.dynamic_range END,
               audio_codec = CASE WHEN excluded.audio_codec = ''
                 THEN files.audio_codec ELSE excluded.audio_codec END,
               audio_channels = CASE WHEN excluded.audio_channels = 0
                 THEN files.audio_channels ELSE excluded.audio_channels END,
               atmos = CASE WHEN excluded.video_resolution = ''
                 THEN files.atmos ELSE excluded.atmos END,
               audio_languages = CASE WHEN excluded.audio_languages = ''
                 THEN files.audio_languages ELSE excluded.audio_languages END,
               subtitle_languages = CASE WHEN excluded.subtitle_languages = ''
                 THEN files.subtitle_languages ELSE excluded.subtitle_languages END,
               edition = CASE WHEN excluded.video_resolution = ''
                 THEN files.edition ELSE excluded.edition END
             RETURNING id",
        )?.query_row(
            params![
                f.source_id, f.dir, f.path, f.size as i64, f.mtime, f.seen_gen,
                f.title_id, f.season, f.episode, f.rating_key,
                f.media.duration_secs, f.media.video_resolution, f.media.video_codec,
                f.media.dynamic_range, f.media.audio_codec, f.media.audio_channels,
                f.media.atmos, f.media.audio_languages, f.media.subtitle_languages,
                f.media.edition
            ],
            |r| r.get(0),
        )?)
    }

    /// What a source says this episode is, keyed on the file it sent it with.
    ///
    /// A field it left empty keeps whatever is stored, the same rule the media
    /// columns of `files` follow: a second source that knows the file but not
    /// the episode must not erase a title the first one named.
    pub fn upsert_episode_meta(&self, file_id: i64, m: &EpisodeMeta) -> Result<(), IndexError> {
        let mut stmt = self.conn.prepare_cached(
            "INSERT INTO episode_meta (file_id, title, summary, still_path, air_year)
             VALUES (?1, ?2, ?3, ?4, ?5)
             ON CONFLICT (file_id) DO UPDATE SET
               title = CASE WHEN excluded.title = ''
                 THEN episode_meta.title ELSE excluded.title END,
               summary = CASE WHEN excluded.summary = ''
                 THEN episode_meta.summary ELSE excluded.summary END,
               still_path = CASE WHEN excluded.still_path = ''
                 THEN episode_meta.still_path ELSE excluded.still_path END,
               air_year = CASE WHEN excluded.air_year = 0
                 THEN episode_meta.air_year ELSE excluded.air_year END",
        )?;
        stmt.execute(params![
            file_id,
            m.title,
            m.summary,
            m.still_path,
            m.air_year
        ])?;
        Ok(())
    }

    /// Where one episode's frame is served from: the source that enumerated the
    /// file, and the path that source stored for it. None when nothing named a
    /// frame, which is the answer for every movie and for any episode a server
    /// holds no still of - and the reason a screen asking for one costs an
    /// indexed lookup rather than a request.
    pub fn still_source(&self, file_id: i64) -> Result<Option<(String, String)>, IndexError> {
        let mut stmt = self.conn.prepare_cached(
            "SELECT f.source_id, e.still_path FROM episode_meta e
             JOIN files f ON f.id = e.file_id
             WHERE e.file_id = ?1 AND e.still_path <> ''",
        )?;
        let mut rows = stmt.query(params![file_id])?;
        Ok(match rows.next()? {
            Some(r) => Some((r.get(0)?, r.get(1)?)),
            None => None,
        })
    }

    pub fn dir_mtime(&self, source_id: &str, path: &str) -> Result<Option<i64>, IndexError> {
        let mut stmt = self
            .conn
            .prepare_cached("SELECT mtime FROM dirs WHERE source_id = ?1 AND path = ?2")?;
        let mut rows = stmt.query(params![source_id, path])?;
        Ok(match rows.next()? {
            Some(row) => Some(row.get(0)?),
            None => None,
        })
    }

    pub fn set_dir_mtime(&self, source_id: &str, path: &str, mtime: i64) -> Result<(), IndexError> {
        self.conn
            .prepare_cached(
                "INSERT INTO dirs (source_id, path, mtime) VALUES (?1, ?2, ?3)
                 ON CONFLICT (source_id, path) DO UPDATE SET mtime = excluded.mtime",
            )?
            .execute(params![source_id, path, mtime])?;
        Ok(())
    }

    pub fn has_files(&self, source_id: &str) -> Result<bool, IndexError> {
        let any: bool = self.conn.query_row(
            "SELECT EXISTS (SELECT 1 FROM files WHERE source_id = ?1)",
            params![source_id],
            |r| r.get(0),
        )?;
        Ok(any)
    }

    pub fn next_scan_gen(&self, source_id: &str) -> Result<i64, IndexError> {
        let max: i64 = self.conn.query_row(
            "SELECT COALESCE(MAX(seen_gen), 0) FROM files WHERE source_id = ?1",
            params![source_id],
            |r| r.get(0),
        )?;
        Ok(max + 1)
    }

    /// Bumps every file under this dir to `gen` without rewriting a single
    /// row's own data, and reports how many rows that touched.
    pub fn touch_dir_files(&self, source_id: &str, dir: &str, gen: i64) -> Result<u32, IndexError> {
        let n = self
            .conn
            .prepare_cached("UPDATE files SET seen_gen = ?3 WHERE source_id = ?1 AND dir = ?2")?
            .execute(params![source_id, dir, gen])?;
        Ok(n as u32)
    }

    pub fn delete_files_not_seen(&self, source_id: &str, gen: i64) -> Result<u32, IndexError> {
        let n = self.conn.execute(
            "DELETE FROM files WHERE source_id = ?1 AND seen_gen < ?2",
            params![source_id, gen],
        )?;
        Ok(n as u32)
    }

    /// Forgets the ratingKeys one source's files carry. The rows stay: a Plex
    /// file's watch state has no other copy, and the next sync re-keys them
    /// against whatever server the source now names.
    pub fn clear_rating_keys(&self, source_id: &str) -> Result<(), IndexError> {
        self.conn.execute(
            "UPDATE files SET rating_key = NULL WHERE source_id = ?1",
            params![source_id],
        )?;
        Ok(())
    }

    /// Drops everything one source contributed, in one transaction: its files,
    /// its `dirs` bookkeeping, the Plex rows nothing backs anymore and the
    /// titles it leaves orphaned. Returns the number of files removed.
    ///
    /// The `dirs` rows have to go with the files: a source added back under the
    /// same id would otherwise find its old mtimes, read every settled
    /// directory as unchanged and index nothing.
    ///
    /// A Plex metadata row on a title that survives (another source holds a
    /// file for it) would be immortal: Plex rows never go stale, so nothing
    /// would ever replace it, and its poster path points at a server that is
    /// gone. `rating_key` is set on Plex files and only on them, so the title
    /// having none is exactly "no Plex source describes this anymore".
    pub fn purge_source(&self, source_id: &str) -> Result<u32, IndexError> {
        let tx = self.conn.unchecked_transaction()?;
        let n = self
            .conn
            .execute("DELETE FROM files WHERE source_id = ?1", params![source_id])?;
        self.conn
            .execute("DELETE FROM dirs WHERE source_id = ?1", params![source_id])?;
        self.conn.execute(
            "DELETE FROM metadata WHERE source = 'plex'
               AND title_id NOT IN (SELECT title_id FROM files WHERE rating_key IS NOT NULL)",
            [],
        )?;
        self.prune_orphan_titles()?;
        tx.commit()?;
        Ok(n as u32)
    }

    pub fn prune_orphan_titles(&self) -> Result<u32, IndexError> {
        let n = self.conn.execute(
            "DELETE FROM titles WHERE id NOT IN (SELECT DISTINCT title_id FROM files)",
            [],
        )?;
        Ok(n as u32)
    }

    /// The TMDB id follows the source of the write. A Plex row never carries
    /// one, so it keeps whatever is stored rather than erasing the match the
    /// recommendations join on; a TMDB row is the search's own verdict, and a
    /// null there means "searched, no match" and must clear a stale id. The
    /// saga goes the same way: Plex tagging none of its items is not Plex
    /// saying the one TMDB named is wrong.
    pub fn upsert_metadata(&self, m: &MetadataRecord) -> Result<(), IndexError> {
        // RETURNING, so the tag rows are written from what the row now holds
        // rather than from what this writer offered: the CASE above can keep a
        // director an empty Plex write did not mean to erase, and tags that
        // disagreed with the column would answer a row query the detail screen
        // contradicts.
        // what the tag rows were last written from: a write that changes
        // none of it, which is most of a Plex resync, rewrites no tag
        let before: Option<[String; 6]> = self
            .conn
            .prepare_cached(
                "SELECT genres, cast_names, collections, director_names, writer_names,
                        composer_names
                 FROM metadata WHERE title_id = ?1",
            )?
            .query_row(params![m.title_id], |r| {
                Ok([
                    r.get(0)?,
                    r.get(1)?,
                    r.get(2)?,
                    r.get(3)?,
                    r.get(4)?,
                    r.get(5)?,
                ])
            })
            .optional()?;
        let Some((
            stored_directors,
            stored_cast,
            stored_writers,
            stored_composers,
            stored_collections,
        )): Option<(String, String, String, String, String)> = self
            .conn
            .prepare_cached(
                "INSERT INTO metadata (title_id, tmdb_id, overview_fr, overview_en,
                                   poster_path, backdrop_path, genres, cast_names,
                                   director_names, writer_names, composer_names,
                                   collections, critic_rating, critic_source,
                                   audience_rating, audience_source, source, fetched_at,
                                   critic_votes, audience_votes, release_date)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15,
                     ?16, ?17, ?18, ?19, ?20, ?21)
             ON CONFLICT (title_id) DO UPDATE SET
               tmdb_id = CASE excluded.source
                           WHEN 'plex' THEN COALESCE(excluded.tmdb_id, metadata.tmdb_id)
                           ELSE excluded.tmdb_id END,
               overview_fr = excluded.overview_fr,
               overview_en = excluded.overview_en, poster_path = excluded.poster_path,
               backdrop_path = excluded.backdrop_path, genres = excluded.genres,
               cast_names = CASE
                   WHEN excluded.source = 'plex'
                    AND length(excluded.cast_names) - length(replace(excluded.cast_names, ',', ''))
                        + (excluded.cast_names <> '')
                      < length(metadata.cast_names) - length(replace(metadata.cast_names, ',', ''))
                        + (metadata.cast_names <> '')
                   THEN metadata.cast_names ELSE excluded.cast_names END,
               -- the parts follow the names they were written for, and go
               -- when the names change under them
               cast_characters = CASE WHEN metadata.cast_names = CASE
                   WHEN excluded.source = 'plex'
                    AND length(excluded.cast_names) - length(replace(excluded.cast_names, ',', ''))
                        + (excluded.cast_names <> '')
                      < length(metadata.cast_names) - length(replace(metadata.cast_names, ',', ''))
                        + (metadata.cast_names <> '')
                   THEN metadata.cast_names ELSE excluded.cast_names END
                   THEN metadata.cast_characters ELSE '' END,
               director_names = CASE
                   WHEN excluded.source = 'plex' AND excluded.director_names = ''
                   THEN metadata.director_names ELSE excluded.director_names END,
               writer_names = CASE
                   WHEN excluded.source = 'plex' AND excluded.writer_names = ''
                   THEN metadata.writer_names ELSE excluded.writer_names END,
               composer_names = CASE
                   WHEN excluded.source = 'plex' AND excluded.composer_names = ''
                   THEN metadata.composer_names ELSE excluded.composer_names END,
               collections = CASE
                   WHEN excluded.source = 'plex' AND excluded.collections = ''
                   THEN metadata.collections ELSE excluded.collections END,
               critic_rating = CASE WHEN excluded.critic_source = ''
                   THEN metadata.critic_rating ELSE excluded.critic_rating END,
               critic_source = CASE WHEN excluded.critic_source = ''
                   THEN metadata.critic_source ELSE excluded.critic_source END,
               critic_votes = CASE WHEN excluded.critic_source = ''
                   THEN metadata.critic_votes ELSE excluded.critic_votes END,
               audience_rating = CASE WHEN excluded.audience_source = ''
                   THEN metadata.audience_rating ELSE excluded.audience_rating END,
               audience_source = CASE WHEN excluded.audience_source = ''
                   THEN metadata.audience_source ELSE excluded.audience_source END,
               audience_votes = CASE WHEN excluded.audience_source = ''
                   THEN metadata.audience_votes ELSE excluded.audience_votes END,
               release_date = COALESCE(excluded.release_date, metadata.release_date),
               source = excluded.source, fetched_at = excluded.fetched_at
             -- a Plex walk restating what the row already says changes nothing,
             -- fetched_at included: the embedding queue reads that as news
             WHERE NOT (excluded.source = 'plex' AND metadata.source = 'plex'
               AND (excluded.tmdb_id IS NULL OR metadata.tmdb_id IS excluded.tmdb_id)
               AND metadata.overview_fr IS excluded.overview_fr
               AND metadata.overview_en IS excluded.overview_en
               AND metadata.poster_path IS excluded.poster_path
               AND metadata.backdrop_path IS excluded.backdrop_path
               AND metadata.genres = excluded.genres
               AND metadata.cast_names = excluded.cast_names
               AND excluded.director_names IN ('', metadata.director_names)
               AND excluded.writer_names IN ('', metadata.writer_names)
               AND excluded.composer_names IN ('', metadata.composer_names)
               AND excluded.collections IN ('', metadata.collections)
               AND (excluded.critic_source = ''
                    OR (metadata.critic_source = excluded.critic_source
                        AND metadata.critic_rating = excluded.critic_rating
                        AND metadata.critic_votes IS excluded.critic_votes))
               AND (excluded.audience_source = ''
                    OR (metadata.audience_source = excluded.audience_source
                        AND metadata.audience_rating = excluded.audience_rating
                        AND metadata.audience_votes IS excluded.audience_votes))
               AND (excluded.release_date IS NULL
                    OR metadata.release_date IS excluded.release_date))
             RETURNING director_names, cast_names, writer_names, composer_names, collections",
            )?
            .query_row(
                params![
                    m.title_id,
                    m.tmdb_id,
                    m.overview_fr,
                    m.overview_en,
                    m.poster_path,
                    m.backdrop_path,
                    m.genres,
                    m.cast_names,
                    m.director_names,
                    m.writer_names,
                    m.composer_names,
                    m.collections,
                    m.critics.as_ref().map_or(0.0, |s| s.value),
                    m.critics.as_ref().map_or("", |s| s.source.as_str()),
                    m.audience.as_ref().map_or(0.0, |s| s.value),
                    m.audience.as_ref().map_or("", |s| s.source.as_str()),
                    m.source.as_str(),
                    m.fetched_at,
                    m.critics.as_ref().and_then(|s| s.votes),
                    m.audience.as_ref().and_then(|s| s.votes),
                    m.release_date
                ],
                |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?, r.get(4)?)),
            )
            .optional()?
        else {
            return Ok(());
        };
        // the director gets tag rows like the cast: they answer "who else
        // carries this value", and the home row asks it of a crew credit. The
        // writer and the composer are each a tile on the detail screen, and a
        // tile opens the person. The four credits also get a `people` row,
        // so a library that has only ever been scanned can still open one.
        let columns = [
            ("genre", m.genres.as_str(), false),
            ("cast", stored_cast.as_str(), true),
            ("collection", stored_collections.as_str(), false),
            ("director", stored_directors.as_str(), true),
            ("writer", stored_writers.as_str(), true),
            ("composer", stored_composers.as_str(), true),
        ];
        let mut changed = false;
        for (i, (kind, csv, person)) in columns.into_iter().enumerate() {
            if before.as_ref().is_some_and(|b| b[i] == csv) {
                continue;
            }
            changed = true;
            write_tags(&self.conn, m.title_id, kind, csv)?;
            if person {
                write_people(&self.conn, csv)?;
            }
        }
        if changed {
            self.conn
                .prepare_cached(STAGE_CLEAR)?
                .execute(params![m.title_id])?;
            self.conn
                .prepare_cached(STAGE_REFRESH)?
                .execute(params![m.title_id])?;
        }
        Ok(())
    }

    /// The poster path, the backdrop path and who wrote them: what a tile asks
    /// about many times a second, without the overviews and credits beside it.
    pub fn artwork_paths(
        &self,
        title_id: i64,
    ) -> Result<Option<(Option<String>, Option<String>, MetadataSource)>, IndexError> {
        let mut stmt = self.conn.prepare_cached(
            "SELECT poster_path, backdrop_path, source FROM metadata WHERE title_id = ?1",
        )?;
        let mut rows = stmt.query(params![title_id])?;
        let Some(r) = rows.next()? else {
            return Ok(None);
        };
        Ok(Some((
            r.get(0)?,
            r.get(1)?,
            MetadataSource::from_str(&r.get::<_, String>(2)?).unwrap_or(MetadataSource::Tmdb),
        )))
    }

    /// The part each name on the billing plays, written only over the very
    /// names it was read beside: a comma list aligned with `cast_names`, and a
    /// write for names the row no longer holds is dropped rather than misfiled.
    pub fn set_cast_characters(
        &self,
        title_id: i64,
        names: &str,
        characters: &str,
    ) -> Result<(), IndexError> {
        self.conn
            .prepare_cached(
                "UPDATE metadata SET cast_characters = ?3 WHERE title_id = ?1 AND cast_names = ?2",
            )?
            .execute(params![title_id, names, characters])?;
        Ok(())
    }

    /// The parts, aligned with the stored `cast_names`; "" when no source named
    /// any, or when the title has no row.
    pub fn cast_characters(&self, title_id: i64) -> Result<String, IndexError> {
        let mut stmt = self
            .conn
            .prepare_cached("SELECT cast_characters FROM metadata WHERE title_id = ?1")?;
        let mut rows = stmt.query(params![title_id])?;
        Ok(match rows.next()? {
            Some(r) => r.get(0)?,
            None => String::new(),
        })
    }

    pub fn metadata(&self, title_id: i64) -> Result<Option<MetadataRecord>, IndexError> {
        let mut stmt = self.conn.prepare_cached(
            "SELECT title_id, tmdb_id, overview_fr, overview_en, poster_path,
                    backdrop_path, genres, cast_names, collections, source, fetched_at,
                    director_names, writer_names, composer_names,
                    critic_rating, critic_source, audience_rating, audience_source,
                    critic_votes, audience_votes, release_date
             FROM metadata WHERE title_id = ?1",
        )?;
        let mut rows = stmt.query(params![title_id])?;
        let Some(r) = rows.next()? else {
            return Ok(None);
        };
        // the source column is the presence flag: a stored 0 is the score
        // nobody measured, and 0.0 from a source that named itself is not
        let measured = |value: f32, source: String, votes: Option<u32>| {
            (!source.is_empty()).then_some(Score {
                value,
                source,
                votes,
            })
        };
        Ok(Some(MetadataRecord {
            title_id: r.get(0)?,
            tmdb_id: r.get(1)?,
            overview_fr: r.get(2)?,
            overview_en: r.get(3)?,
            poster_path: r.get(4)?,
            backdrop_path: r.get(5)?,
            genres: r.get(6)?,
            cast_names: r.get(7)?,
            collections: r.get(8)?,
            source: MetadataSource::from_str(&r.get::<_, String>(9)?)
                .unwrap_or(MetadataSource::Tmdb),
            fetched_at: r.get(10)?,
            director_names: r.get(11)?,
            writer_names: r.get(12)?,
            composer_names: r.get(13)?,
            critics: measured(r.get(14)?, r.get(15)?, r.get(18)?),
            audience: measured(r.get(16)?, r.get(17)?, r.get(19)?),
            release_date: r.get(20)?,
        }))
    }

    /// The number this library knows a credited name by, and the TMDB path to
    /// their photograph. The path is empty for most of a library and always
    /// will be for some of it: it is filled only where a title matched TMDB,
    /// and it is the caller's cue to draw the person without a face rather
    /// than to go looking for one.
    pub fn person(&self, name: &str) -> Result<Option<(i64, String)>, IndexError> {
        let mut stmt = self
            .conn
            .prepare_cached("SELECT id, profile_path FROM people WHERE name = ?1")?;
        let mut rows = stmt.query(params![name])?;
        let Some(r) = rows.next()? else {
            return Ok(None);
        };
        Ok(Some((r.get(0)?, r.get(1)?)))
    }

    /// One lookup for many names: a detail screen credits up to a dozen
    /// people, and a point query per name on the hottest screen is a textbook
    /// N+1 even when every hit is indexed. Names this library has never
    /// tagged are simply absent from the answer.
    pub fn person_ids(&self, names: &[String]) -> Result<HashMap<String, i64>, IndexError> {
        let mut out = HashMap::with_capacity(names.len());
        if names.is_empty() {
            return Ok(out);
        }
        // the IN list is tiny and bounded by MAX_CAST + MAX_DIRECTORS, so
        // binding positionally per call is cheaper than any temp-table dance
        let placeholders = vec!["?"; names.len()].join(", ");
        let sql = format!("SELECT id, name FROM people WHERE name IN ({placeholders})");
        let mut stmt = self.conn.prepare(&sql)?;
        let params: Vec<&dyn ToSql> = names.iter().map(|n| n as &dyn ToSql).collect();
        let mut rows = stmt.query(params.as_slice())?;
        while let Some(r) = rows.next()? {
            out.insert(r.get::<_, String>(1)?, r.get(0)?);
        }
        Ok(out)
    }

    /// The same, by number, for the artwork path: it holds a person's id and
    /// never their name.
    pub fn person_profile(&self, person_id: i64) -> Result<Option<String>, IndexError> {
        let mut stmt = self
            .conn
            .prepare_cached("SELECT profile_path FROM people WHERE id = ?1")?;
        let mut rows = stmt.query(params![person_id])?;
        let Some(r) = rows.next()? else {
            return Ok(None);
        };
        Ok(Some(r.get(0)?))
    }

    /// What the enrichment learned about one credited name. Creates the row
    /// when a scan has not: the two writers agree on the name, so whichever
    /// arrives first wins and the other updates.
    ///
    /// A face is never erased by a write that carries none. TMDB lists a cast
    /// per title, and the same performer is billed with a photograph on one
    /// film and without on another; letting the second overwrite the first
    /// would make a face flicker with whatever was enriched last.
    ///
    /// `checked_at` moves on every write, an empty `profile_path` included:
    /// that is the answer "TMDB holds no photograph of this person", and
    /// recording it is what keeps them out of `titles_needing_faces`.
    pub fn set_person(
        &self,
        name: &str,
        tmdb_person_id: i64,
        profile_path: &str,
        checked_at: i64,
    ) -> Result<(), IndexError> {
        self.conn.execute(
            "INSERT INTO people (name, tmdb_person_id, profile_path, profile_checked_at, last_word)
             VALUES (?1, ?2, ?3, ?4, ?5)
             ON CONFLICT (name) DO UPDATE SET
               tmdb_person_id = CASE WHEN excluded.tmdb_person_id = 0
                   THEN people.tmdb_person_id ELSE excluded.tmdb_person_id END,
               profile_path = CASE WHEN excluded.profile_path = ''
                   THEN people.profile_path ELSE excluded.profile_path END,
               profile_checked_at = excluded.profile_checked_at",
            params![
                name,
                tmdb_person_id,
                profile_path,
                checked_at,
                normalize(name).rsplit(' ').next()
            ],
        )?;
        Ok(())
    }

    /// Records that TMDB's billing for one title has been read, on every name
    /// tagged to it. `set_person` already stamped the names the billing
    /// listed; this catches the ones it did not.
    ///
    /// Those are names no billing will ever list, so the stamp is final rather
    /// than a guess: a face is filed under TMDB's own spelling, so a name that
    /// came off a Plex server in some other spelling has no photograph to be
    /// found under it anywhere. Without this a title whose cast Plex spells its
    /// own way sits in the queue forever, one request per launch.
    pub fn mark_faces_checked(&self, title_id: i64, checked_at: i64) -> Result<(), IndexError> {
        self.conn.execute(
            "UPDATE people SET profile_checked_at = ?2
              WHERE profile_checked_at = 0
                AND name IN (SELECT value FROM title_tags
                              WHERE title_id = ?1 AND kind IN ('cast', 'director'))",
            params![title_id, checked_at],
        )?;
        self.conn.execute(
            "UPDATE metadata SET billed_at = ?2 WHERE title_id = ?1",
            params![title_id, checked_at],
        )?;
        Ok(())
    }

    /// Titles TMDB has placed that still credit somebody it has never been
    /// asked about.
    ///
    /// This queue exists because a field added to the describe path arrives
    /// too late for a library already described: `profile_path` was parsed
    /// after every title here was placed, a placed title with a fresh row is
    /// named by no other queue, and so nothing would ever ask again. It asks
    /// once, for the credits alone.
    ///
    /// It drains and stays drained: every name a batch touches is stamped,
    /// including the ones the answer did not carry, so a title leaves for
    /// good. Once the last one has, this costs one query per launch and no
    /// request at all.
    pub fn titles_needing_faces(&self, limit: u32) -> Result<Vec<PendingFaces>, IndexError> {
        let mut stmt = self.conn.prepare_cached(
            "SELECT m.title_id, t.kind, m.tmdb_id FROM metadata m
             JOIN titles t ON t.id = m.title_id
             WHERE m.tmdb_id IS NOT NULL
               AND (m.billed_at = 0
                    OR EXISTS (SELECT 1 FROM title_tags tt
                               JOIN people p ON p.name = tt.value
                               WHERE tt.title_id = m.title_id
                                 AND tt.kind IN ('cast', 'director')
                                 AND p.profile_checked_at = 0))
             ORDER BY m.title_id LIMIT ?1",
        )?;
        let rows = stmt.query_map(params![limit], |r| {
            Ok(PendingFaces {
                title_id: r.get(0)?,
                kind: MediaKind::from_str(&r.get::<_, String>(1)?).unwrap_or(MediaKind::Movie),
                tmdb_id: r.get(2)?,
            })
        })?;
        Ok(rows.collect::<Result<Vec<_>, _>>()?)
    }

    /// Titles TMDB has placed and never been asked the keywords of. It drains
    /// and stays drained: every answer is stamped, an empty one included.
    pub fn titles_needing_keywords(&self, limit: u32) -> Result<Vec<PendingFaces>, IndexError> {
        let mut stmt = self.conn.prepare_cached(
            "SELECT m.title_id, t.kind, m.tmdb_id FROM metadata m
             JOIN titles t ON t.id = m.title_id
             WHERE m.tmdb_id IS NOT NULL AND m.keywords_at = 0
             ORDER BY m.title_id LIMIT ?1",
        )?;
        let rows = stmt.query_map(params![limit], |r| {
            Ok(PendingFaces {
                title_id: r.get(0)?,
                kind: MediaKind::from_str(&r.get::<_, String>(1)?).unwrap_or(MediaKind::Movie),
                tmdb_id: r.get(2)?,
            })
        })?;
        Ok(rows.collect::<Result<Vec<_>, _>>()?)
    }

    /// Stores a title's keywords. `fetched_at` moves only when there are
    /// some, because the embedding is recomputed off it: an empty answer
    /// changes nothing the encoder reads.
    pub fn set_keywords(&self, title_id: i64, keywords: &str, now: i64) -> Result<(), IndexError> {
        self.conn.execute(
            "UPDATE metadata SET keywords = ?2, keywords_at = ?3,
                    fetched_at = CASE WHEN ?2 = '' THEN fetched_at ELSE ?3 END
              WHERE title_id = ?1",
            params![title_id, keywords, now],
        )?;
        self.conn
            .prepare_cached(STAGE_CLEAR)?
            .execute(params![title_id])?;
        self.conn
            .prepare_cached(STAGE_REFRESH)?
            .execute(params![title_id])?;
        Ok(())
    }

    /// What this title's best copy is, or None when no source has answered for
    /// any of its files. One row rather than a column-by-column aggregate: a
    /// picture and a sound that came from two different files describe a copy
    /// nobody can play, and the badges a viewer reads are a promise about the
    /// one that would start.
    ///
    /// "Best" is the copy that plays first, then the resolution and the channel
    /// count: for a film that is the copy it opens on, and for a series it is
    /// the episode that shows what the season was mastered at.
    pub fn title_media(&self, title_id: i64) -> Result<Option<FileMedia>, IndexError> {
        let mut stmt = self.conn.prepare_cached(
            "SELECT duration_secs, video_resolution, video_codec, dynamic_range,
                    audio_codec, audio_channels, atmos, audio_languages, subtitle_languages,
                    edition
             FROM files WHERE title_id = ?1 AND (video_resolution <> '' OR duration_secs > 0)
             ORDER BY quality DESC, CASE video_resolution
                        WHEN '4k' THEN 4 WHEN '1080' THEN 3 WHEN '720' THEN 2 ELSE 1 END DESC,
                      audio_channels DESC, size DESC
             LIMIT 1",
        )?;
        let mut rows = stmt.query(params![title_id])?;
        let Some(r) = rows.next()? else {
            return Ok(None);
        };
        Ok(Some(media_at(r)?))
    }

    /// Every copy of a film, the one it plays first leading: (file id, size,
    /// media). Empty for a series, whose files are its episodes.
    pub fn title_versions(&self, title_id: i64) -> Result<Vec<(i64, u64, FileMedia)>, IndexError> {
        let mut stmt = self.conn.prepare_cached(
            "SELECT duration_secs, video_resolution, video_codec, dynamic_range,
                    audio_codec, audio_channels, atmos, audio_languages, subtitle_languages,
                    edition, id, size
             FROM files WHERE title_id = ?1 AND season IS NULL
             ORDER BY quality DESC, id",
        )?;
        let rows = stmt.query_map(params![title_id], |r| {
            Ok((r.get(10)?, r.get::<_, i64>(11)? as u64, media_at(r)?))
        })?;
        Ok(rows.collect::<Result<_, _>>()?)
    }

    /// The TMDB half of a row Plex wrote: the id the recommendations join on,
    /// and the fields the caller found empty and filled. Everything else on
    /// `m` is what was read out of the row, so a write here changes only what
    /// TMDB actually added.
    ///
    /// `matched_at` moves either way. A title TMDB could not place gets the
    /// same stamp as one it did, which is what stops the search running again
    /// on every pass over a library where a few hundred titles will never
    /// match.
    pub fn attach_tmdb_match(&self, m: &MetadataRecord, now: i64) -> Result<(), IndexError> {
        self.upsert_metadata(m)?;
        self.conn.execute(
            "UPDATE metadata SET matched_at = ?2 WHERE title_id = ?1",
            params![m.title_id, now],
        )?;
        Ok(())
    }

    /// Rows Plex described that carry no tmdb_id: they join no similar list,
    /// no saga and no seed until one is attached. A title TMDB was asked about
    /// and could not place comes back after `max_age`, the same month a
    /// no-match TMDB row waits; one that matched never comes back here at all.
    pub fn titles_needing_match(
        &self,
        now: i64,
        max_age: i64,
        limit: u32,
    ) -> Result<Vec<PendingTitle>, IndexError> {
        let mut stmt = self.conn.prepare_cached(
            "SELECT t.id, t.kind, t.name, t.year FROM titles t
             JOIN metadata m ON m.title_id = t.id
             WHERE m.source = 'plex' AND m.tmdb_id IS NULL AND m.matched_at < ?1
             ORDER BY t.id LIMIT ?2",
        )?;
        let rows = stmt.query_map(params![now - max_age, limit], |r| {
            let year: u16 = r.get(3)?;
            Ok(PendingTitle {
                id: r.get(0)?,
                kind: MediaKind::from_str(&r.get::<_, String>(1)?).unwrap_or(MediaKind::Movie),
                name: r.get(2)?,
                year: if year == 0 { None } else { Some(year) },
            })
        })?;
        Ok(rows.collect::<Result<Vec<_>, _>>()?)
    }

    /// Everything deciding a title's logo turns on, in one read: the id to
    /// ask TMDB about, which of its two endpoints to ask, and what the last
    /// answer was. None when nothing has described the title at all.
    pub fn logo_state(&self, title_id: i64) -> Result<Option<LogoState>, IndexError> {
        let mut stmt = self.conn.prepare_cached(
            "SELECT t.kind, t.name, m.tmdb_id, m.logo_path, m.logo_aspect, m.logo_checked_at
             FROM titles t JOIN metadata m ON m.title_id = t.id
             WHERE t.id = ?1",
        )?;
        let mut rows = stmt.query(params![title_id])?;
        let Some(r) = rows.next()? else {
            return Ok(None);
        };
        Ok(Some(LogoState {
            kind: MediaKind::from_str(&r.get::<_, String>(0)?).unwrap_or(MediaKind::Movie),
            name: r.get(1)?,
            tmdb_id: r.get(2)?,
            path: r.get(3)?,
            aspect: r.get(4)?,
            checked_at: r.get(5)?,
        }))
    }

    /// Records what TMDB answered. `path` None is the answer "there is none",
    /// which `checked_at` is what makes worth storing at all.
    pub fn set_logo(
        &self,
        title_id: i64,
        path: Option<&str>,
        aspect: f32,
        checked_at: i64,
    ) -> Result<(), IndexError> {
        self.conn.execute(
            "UPDATE metadata SET logo_path = ?2, logo_aspect = ?3, logo_checked_at = ?4
             WHERE title_id = ?1",
            params![title_id, path, aspect, checked_at],
        )?;
        Ok(())
    }

    /// Records the lettering a source holds for the title, which is drawn
    /// before TMDB's. The aspect is measured when the file is first fetched,
    /// so it is reset only when the path changes.
    pub fn set_source_logo(&self, title_id: i64, path: &str, now: i64) -> Result<(), IndexError> {
        self.conn.execute(
            "UPDATE metadata SET logo_path = ?2, logo_aspect = 0, logo_checked_at = ?3
             WHERE title_id = ?1 AND logo_path IS NOT ?2",
            params![title_id, path, now],
        )?;
        Ok(())
    }

    pub fn trailer_state(&self, title_id: i64) -> Result<Option<TrailerState>, IndexError> {
        let mut stmt = self.conn.prepare_cached(
            "SELECT t.kind, m.tmdb_id, m.trailer_key, m.trailer_checked_at
             FROM titles t JOIN metadata m ON m.title_id = t.id
             WHERE t.id = ?1",
        )?;
        let mut rows = stmt.query(params![title_id])?;
        let Some(r) = rows.next()? else {
            return Ok(None);
        };
        Ok(Some(TrailerState {
            kind: MediaKind::from_str(&r.get::<_, String>(0)?).unwrap_or(MediaKind::Movie),
            tmdb_id: r.get(1)?,
            key: r.get(2)?,
            checked_at: r.get(3)?,
        }))
    }

    /// Records what TMDB answered. `key` None is the answer "there is none",
    /// which `checked_at` is what makes worth storing at all.
    pub fn set_trailer(
        &self,
        title_id: i64,
        key: Option<&str>,
        checked_at: i64,
    ) -> Result<(), IndexError> {
        self.conn.execute(
            "UPDATE metadata SET trailer_key = ?2, trailer_checked_at = ?3
             WHERE title_id = ?1",
            params![title_id, key, checked_at],
        )?;
        Ok(())
    }

    /// Titles with no metadata row, plus TMDB rows older than `max_age`. Plex
    /// rows never expire here: the server is authoritative for its own items.
    pub fn titles_needing_metadata(
        &self,
        now: i64,
        max_age: i64,
        limit: u32,
    ) -> Result<Vec<PendingTitle>, IndexError> {
        let mut stmt = self.conn.prepare_cached(
            "SELECT t.id, t.kind, t.name, t.year FROM titles t
             LEFT JOIN metadata m ON m.title_id = t.id
             WHERE m.title_id IS NULL
                OR (m.source = 'tmdb' AND m.fetched_at < ?1)
             ORDER BY t.id LIMIT ?2",
        )?;
        let rows = stmt.query_map(params![now - max_age, limit], |r| {
            let year: u16 = r.get(3)?;
            Ok(PendingTitle {
                id: r.get(0)?,
                kind: MediaKind::from_str(&r.get::<_, String>(1)?).unwrap_or(MediaKind::Movie),
                name: r.get(2)?,
                year: if year == 0 { None } else { Some(year) },
            })
        })?;
        Ok(rows.collect::<Result<Vec<_>, _>>()?)
    }

    /// The source ids that hold files for a title, most files first.
    pub fn title_source_ids(&self, title_id: i64) -> Result<Vec<String>, IndexError> {
        let mut stmt = self.conn.prepare_cached(
            "SELECT source_id FROM files WHERE title_id = ?1
             GROUP BY source_id ORDER BY COUNT(*) DESC, source_id",
        )?;
        let rows = stmt.query_map(params![title_id], |r| r.get(0))?;
        Ok(rows.collect::<Result<Vec<_>, _>>()?)
    }

    /// How much of the library one source holds: distinct titles, and every
    /// file, whichever title it belongs to.
    pub fn source_counts(&self, source_id: &str) -> Result<SourceCounts, IndexError> {
        Ok(self.conn.query_row(
            "SELECT COUNT(DISTINCT title_id), COUNT(*) FROM files WHERE source_id = ?1",
            params![source_id],
            |r| {
                Ok(SourceCounts {
                    titles: r.get(0)?,
                    files: r.get(1)?,
                })
            },
        )?)
    }

    /// Where playback got to. Crossing 90% of the duration is what turns a
    /// position into "seen", and it is decided here, once, on the write: every
    /// caller that stores a position gets the same rule for free.
    ///
    /// `authority` settles what happens to a flag the row already carries. A
    /// report only ever raises it: a rewatch reports a low position every few
    /// seconds, and clearing it on those would lose a finished state no owner
    /// can hand back, so `set_watched` is the way down. A server that owns the
    /// item answers for it either way, "not watched" included.
    ///
    /// A caller that knows no runtime writes zero, and the row keeps the one it
    /// has: a player without a clock reports a position every few seconds, and
    /// a zero would cost the row the runtime the 90% rule is decided against.
    pub fn upsert_watch_state(
        &self,
        w: &WatchRecord,
        authority: WatchAuthority,
    ) -> Result<(), IndexError> {
        // the effective runtime is resolved once, before any rule reads it, so
        // the 90% test and the stored column cannot disagree. SQLite needs the
        // WHERE to tell this ON CONFLICT from a join's ON clause.
        // plays counts the position crossing the threshold, never the flag
        // turning: the flag only ever rises, so a rewatch would never move it.
        //
        // The ledger takes the same crossing, and has to take it here: once
        // the row below is written the position it was measured against is
        // gone. A file with no row yet sits at nought, which is under the
        // line, exactly as the insert path reads it.
        self.conn
            .prepare_cached(
                "INSERT INTO taste_event (at, kind, title_id)
             SELECT ?4, ?6, f.title_id
             FROM files f
             CROSS JOIN (SELECT COALESCE(NULLIF(?3, 0.0),
                                         (SELECT duration_secs FROM watch_state WHERE file_id = ?1),
                                         0.0) AS dur)
             WHERE f.id = ?1 AND NOT ?5 AND dur > 0 AND ?2 / dur > 0.9
               AND COALESCE((SELECT position_secs FROM watch_state WHERE file_id = ?1), 0.0)
                   / dur <= 0.9",
            )?
            .execute(params![
                w.file_id,
                w.position_secs,
                w.duration_secs,
                w.updated_at,
                matches!(authority, WatchAuthority::Owner),
                TASTE_FINISHED
            ])?;
        self.conn
            .prepare_cached(
                "INSERT INTO watch_state
               (file_id, position_secs, duration_secs, watched, plays, updated_at)
             SELECT ?1, ?2, dur, ?4 OR (dur > 0 AND ?2 / dur > 0.9),
                    CASE WHEN ?6 THEN ?7
                         WHEN dur > 0 AND ?2 / dur > 0.9 THEN 1
                         ELSE 0 END,
                    ?5
             FROM (SELECT COALESCE(NULLIF(?3, 0.0),
                                   (SELECT duration_secs FROM watch_state WHERE file_id = ?1),
                                   0.0) AS dur)
             WHERE true
             ON CONFLICT (file_id) DO UPDATE SET
               position_secs = excluded.position_secs,
               duration_secs = excluded.duration_secs,
               watched = CASE WHEN ?6 THEN excluded.watched
                              ELSE MAX(watch_state.watched, excluded.watched) END,
               plays = CASE WHEN ?6 THEN MAX(watch_state.plays, ?7)
                            WHEN excluded.duration_secs > 0
                                 AND watch_state.position_secs / excluded.duration_secs <= 0.9
                                 AND excluded.position_secs / excluded.duration_secs > 0.9
                            THEN watch_state.plays + 1
                            ELSE watch_state.plays END,
               updated_at = excluded.updated_at",
            )?
            .execute(params![
                w.file_id,
                w.position_secs,
                w.duration_secs,
                w.watched,
                w.updated_at,
                matches!(authority, WatchAuthority::Owner),
                w.plays
            ])?;
        Ok(())
    }

    /// Puts back what the durable copy remembers, without overwriting anything
    /// fresher: a rebuilt cache gets its rows back, and a Plex sync that has
    /// already answered for the same file keeps its own.
    ///
    /// A copy that knows no runtime writes zero and the row keeps the one it
    /// has, exactly as `upsert_watch_state` does: a title marked watched by
    /// hand carries no duration, and the 90% rule is decided against it.
    ///
    /// `owns_flag` is whether the copy answers for `watched` at all. A copy
    /// that only remembers a position must not assert a flag nobody wrote:
    /// the row keeps the one it has, whoever last answered for it.
    ///
    /// The play count needs no such flag: it only ever rises, so a copy that
    /// knows a smaller one, or none, never takes a play away.
    pub fn restore_watch_state(&self, w: &WatchRecord, owns_flag: bool) -> Result<(), IndexError> {
        self.conn
            .prepare_cached(
                "INSERT INTO watch_state
               (file_id, position_secs, duration_secs, watched, plays, updated_at)
             VALUES (?1, ?2, ?3, ?4, ?7, ?5)
             ON CONFLICT (file_id) DO UPDATE SET
               position_secs = excluded.position_secs,
               duration_secs = CASE WHEN excluded.duration_secs > 0
                                    THEN excluded.duration_secs
                                    ELSE watch_state.duration_secs END,
               watched = CASE WHEN ?6 THEN excluded.watched
                              ELSE watch_state.watched END,
               plays = MAX(watch_state.plays, excluded.plays),
               updated_at = excluded.updated_at
             WHERE excluded.updated_at > watch_state.updated_at",
            )?
            .execute(params![
                w.file_id,
                w.position_secs,
                w.duration_secs,
                w.watched,
                w.updated_at,
                owns_flag,
                w.plays
            ])?;
        Ok(())
    }

    /// The manual flag. The position goes back to zero either way, and the
    /// duration is left alone: nothing else in the index knows a runtime.
    pub fn set_watched(&self, file_id: i64, watched: bool, now: i64) -> Result<(), IndexError> {
        self.conn.execute(
            "INSERT INTO watch_state (file_id, position_secs, duration_secs, watched, updated_at)
             VALUES (?1, 0, 0, ?2, ?3)
             ON CONFLICT (file_id) DO UPDATE SET
               position_secs = 0,
               watched = excluded.watched,
               updated_at = excluded.updated_at",
            params![file_id, watched, now],
        )?;
        Ok(())
    }

    /// Takes a title out of the continue-watching row without touching a byte
    /// of its watch state, so what it resumes from and what the source has been
    /// told both stand.
    ///
    /// The later timestamp wins, which is what lets one call serve both a press
    /// and the replay of the durable copy after a purge: `now` is always at or
    /// past anything already stored, and a replay must never move a dismissal
    /// forward over progress the index has since caught up on.
    pub fn dismiss_resume(&self, title_id: i64, dismissed_at: i64) -> Result<(), IndexError> {
        self.conn
            .prepare_cached(
                "INSERT INTO resume_dismissed (title_id, dismissed_at) VALUES (?1, ?2)
             ON CONFLICT (title_id) DO UPDATE SET
               dismissed_at = MAX(resume_dismissed.dismissed_at, excluded.dismissed_at)
             WHERE resume_dismissed.dismissed_at < excluded.dismissed_at",
            )?
            .execute(params![title_id, dismissed_at])?;
        Ok(())
    }

    pub fn restore_resume(&self, title_id: i64) -> Result<(), IndexError> {
        self.conn.execute(
            "DELETE FROM resume_dismissed WHERE title_id = ?1",
            params![title_id],
        )?;
        Ok(())
    }

    /// Records what the viewer said about one title, or clears it with `None`.
    /// A second verdict replaces the first outright: the viewer is not adding
    /// to an opinion, they are stating the one they hold now.
    ///
    /// `stated_at` is the later of the two on a replace, so replaying the
    /// durable copy after a purge cannot move a verdict backwards in the order
    /// that decides which ones still steer the row.
    pub fn set_verdict(
        &self,
        title_id: i64,
        verdict: Option<Verdict>,
        stated_at: i64,
    ) -> Result<(), IndexError> {
        match verdict {
            Some(v) => {
                // Only an opinion the index does not already hold reaches the
                // ledger: the durable copy is replayed onto every scan, and a
                // verdict stated once moved the taste once.
                self.conn
                    .prepare_cached(
                        "INSERT INTO taste_event (at, kind, title_id)
                     SELECT ?3, ?4, ?1
                     WHERE NOT EXISTS (SELECT 1 FROM title_verdict
                                       WHERE title_id = ?1 AND verdict = ?2)",
                    )?
                    .execute(params![title_id, v.as_i64(), stated_at, TASTE_VERDICT])?;
                self.conn.prepare_cached(
                    "INSERT INTO title_verdict (title_id, verdict, stated_at) VALUES (?1, ?2, ?3)
                     ON CONFLICT (title_id) DO UPDATE SET
                       verdict = excluded.verdict,
                       stated_at = MAX(title_verdict.stated_at, excluded.stated_at)
                     WHERE title_verdict.verdict <> excluded.verdict
                        OR title_verdict.stated_at < excluded.stated_at",
                )?.execute(params![title_id, v.as_i64(), stated_at])?;
            }
            None => {
                self.conn
                    .prepare_cached("DELETE FROM title_verdict WHERE title_id = ?1")?
                    .execute(params![title_id])?;
            }
        }
        Ok(())
    }

    /// What the viewer said about one title, for the screen that offers to
    /// change it. None is "they have not said", which is not the same as a
    /// thumb down and must never be drawn as one.
    pub fn verdict(&self, title_id: i64) -> Result<Option<Verdict>, IndexError> {
        let mut stmt = self
            .conn
            .prepare_cached("SELECT verdict FROM title_verdict WHERE title_id = ?1")?;
        let mut rows = stmt.query(params![title_id])?;
        let Some(r) = rows.next()? else {
            return Ok(None);
        };
        Ok(Verdict::from_i64(r.get(0)?))
    }

    /// Every verdict on a title this model has a vector for, most recently
    /// stated first: the other half of what the taste fingerprint is built
    /// out of, read the same way and under the same restriction as
    /// `watch_history`. A title nothing vectorised has no direction, so an
    /// opinion about it has nowhere to point.
    ///
    /// The order is what `taste` cuts on, and title ids break every tie so the
    /// same verdicts always yield the same row.
    pub fn verdicts(&self, model_version: i64) -> Result<Vec<(i64, Verdict)>, IndexError> {
        let mut stmt = self.conn.prepare_cached(
            "SELECT v.title_id, v.verdict FROM title_verdict v
             CROSS JOIN embeddings e ON e.title_id = v.title_id
             WHERE e.model_version = ?1 AND LENGTH(e.vector) > 0
             ORDER BY v.stated_at DESC, v.title_id",
        )?;
        let rows = stmt.query_map(params![model_version], |r| {
            Ok((r.get::<_, i64>(0)?, r.get::<_, i64>(1)?))
        })?;
        Ok(rows
            .collect::<Result<Vec<_>, _>>()?
            .into_iter()
            .filter_map(|(id, v)| Verdict::from_i64(v).map(|v| (id, v)))
            .collect())
    }

    /// The three columns that name a title outside the index, for a caller
    /// holding only its id. `year` is 0 for a title nothing dated, the encoding
    /// the column and `title_by_key` both use.
    ///
    /// An id is worth nothing once written down: a purge and a rescan hand the
    /// same numbers back to different films (see `title_by_key`), so anything
    /// that has to survive one is stored by this instead.
    pub fn title_key(&self, title_id: i64) -> Result<Option<(MediaKind, String, u16)>, IndexError> {
        let mut stmt = self
            .conn
            .prepare_cached("SELECT kind, name, year FROM titles WHERE id = ?1")?;
        let mut rows = stmt.query(params![title_id])?;
        let Some(r) = rows.next()? else {
            return Ok(None);
        };
        Ok(Some((
            MediaKind::from_str(&r.get::<_, String>(0)?).unwrap_or(MediaKind::Movie),
            r.get(1)?,
            r.get(2)?,
        )))
    }

    pub fn watch_state(&self, file_id: i64) -> Result<Option<WatchRecord>, IndexError> {
        let mut stmt = self.conn.prepare_cached(
            "SELECT file_id, position_secs, duration_secs, watched, plays, updated_at
             FROM watch_state WHERE file_id = ?1",
        )?;
        let mut rows = stmt.query(params![file_id])?;
        let Some(r) = rows.next()? else {
            return Ok(None);
        };
        Ok(Some(WatchRecord {
            file_id: r.get(0)?,
            position_secs: r.get(1)?,
            duration_secs: r.get(2)?,
            watched: r.get(3)?,
            plays: r.get(4)?,
            updated_at: r.get(5)?,
        }))
    }

    pub fn file_ref(&self, file_id: i64) -> Result<Option<FileRef>, IndexError> {
        let mut stmt = self
            .conn
            .prepare_cached("SELECT id, source_id, path, rating_key FROM files WHERE id = ?1")?;
        let mut rows = stmt.query(params![file_id])?;
        let Some(r) = rows.next()? else {
            return Ok(None);
        };
        Ok(Some(FileRef {
            id: r.get(0)?,
            source_id: r.get(1)?,
            path: r.get(2)?,
            rating_key: r.get(3)?,
        }))
    }

    /// Every file of a title, so marking it watched marks the whole season.
    pub fn title_file_refs(&self, title_id: i64) -> Result<Vec<FileRef>, IndexError> {
        let mut stmt = self.conn.prepare_cached(
            "SELECT id, source_id, path, rating_key FROM files WHERE title_id = ?1 ORDER BY id",
        )?;
        let rows = stmt.query_map(params![title_id], |r| {
            Ok(FileRef {
                id: r.get(0)?,
                source_id: r.get(1)?,
                path: r.get(2)?,
                rating_key: r.get(3)?,
            })
        })?;
        Ok(rows.collect::<Result<Vec<_>, _>>()?)
    }

    /// Every file of a title with whatever watch row it has, folded here rather
    /// than in SQL: a season answers three different questions at once, and
    /// asking them one file at a time would be a query per episode.
    pub fn title_watch(&self, title_id: i64) -> Result<TitleWatch, IndexError> {
        let mut stmt = self.conn.prepare_cached(
            "SELECT f.id, COALESCE(w.position_secs, 0), COALESCE(w.duration_secs, 0),
                    COALESCE(w.watched, 0), COALESCE(w.plays, 0), COALESCE(w.updated_at, 0)
             FROM files f LEFT JOIN watch_state w ON w.file_id = f.id
             WHERE f.title_id = ?1 ORDER BY f.id",
        )?;
        let rows = stmt.query_map(params![title_id], |r| {
            Ok(WatchRecord {
                file_id: r.get(0)?,
                position_secs: r.get(1)?,
                duration_secs: r.get(2)?,
                watched: r.get(3)?,
                plays: r.get(4)?,
                updated_at: r.get(5)?,
            })
        })?;
        let mut summary = TitleWatch {
            files: 0,
            watched_files: 0,
            plays: 0,
            resume: None,
        };
        for row in rows {
            let row = row?;
            summary.files += 1;
            summary.plays = summary.plays.max(row.plays);
            if row.watched {
                summary.watched_files += 1;
            }
            // seen and left running are two different questions: an episode
            // being watched again carries both
            if in_progress(row.position_secs, row.duration_secs) {
                let better = match &summary.resume {
                    Some(best) => row.updated_at > best.updated_at,
                    None => true,
                };
                if better {
                    summary.resume = Some(row);
                }
            }
        }
        Ok(summary)
    }

    /// The same summary for many titles in one pass: a shelf snapshot asks
    /// per tile, and one query over the whole shelf beats a point query per
    /// tile even though every one of them is indexed.
    pub fn title_watch_many(
        &self,
        title_ids: &[i64],
    ) -> Result<std::collections::HashMap<i64, TitleWatch>, IndexError> {
        let mut out = std::collections::HashMap::with_capacity(title_ids.len());
        if title_ids.is_empty() {
            return Ok(out);
        }
        let mut stmt = self.conn.prepare_cached(
            "SELECT f.title_id, f.id, COALESCE(w.position_secs, 0), COALESCE(w.duration_secs, 0),
                    COALESCE(w.watched, 0), COALESCE(w.plays, 0), COALESCE(w.updated_at, 0)
             FROM files f LEFT JOIN watch_state w ON w.file_id = f.id
             ORDER BY f.id",
        )?;
        let rows = stmt.query_map([], |r| {
            Ok((
                r.get::<_, i64>(0)?,
                WatchRecord {
                    file_id: r.get(1)?,
                    position_secs: r.get(2)?,
                    duration_secs: r.get(3)?,
                    watched: r.get(4)?,
                    plays: r.get(5)?,
                    updated_at: r.get(6)?,
                },
            ))
        })?;
        let wanted: std::collections::HashSet<i64> = title_ids.iter().copied().collect();
        for row in rows {
            let (title_id, record) = row?;
            if !wanted.contains(&title_id) {
                continue;
            }
            let entry = out.entry(title_id).or_insert_with(|| TitleWatch {
                files: 0,
                watched_files: 0,
                plays: 0,
                resume: None,
            });
            entry.files += 1;
            entry.plays = entry.plays.max(record.plays);
            if record.watched {
                entry.watched_files += 1;
            }
            // the same resume rule the single-title read applies: the most
            // recently touched file still in progress
            if in_progress(record.position_secs, record.duration_secs) {
                let better = match &entry.resume {
                    Some(best) => record.updated_at > best.updated_at,
                    None => true,
                };
                if better {
                    entry.resume = Some(record);
                }
            }
        }
        // titles with files but no watch rows must still answer with a zeroed
        // summary rather than go missing from the map
        for id in title_ids {
            out.entry(*id).or_default();
        }
        Ok(out)
    }

    /// The episode that follows `file_id` in its own show, in season and
    /// episode order. None for a movie, for the last episode, and for a file no
    /// row has.
    ///
    /// A seen episode is not skipped: the viewer has just finished the one
    /// before it, and the order of a show is the order of its story.
    pub fn next_episode(&self, file_id: i64) -> Result<Option<EpisodeRow>, IndexError> {
        // the file's own place in the show, resolved first so the query below
        // is a plain indexed lookup rather than a self join
        let current = {
            let mut stmt = self.conn.prepare_cached(
                "SELECT title_id, COALESCE(season, 0), COALESCE(episode, 0)
                 FROM files WHERE id = ?1",
            )?;
            let mut rows = stmt.query(params![file_id])?;
            match rows.next()? {
                Some(r) => (
                    r.get::<_, i64>(0)?,
                    r.get::<_, i64>(1)?,
                    r.get::<_, i64>(2)?,
                ),
                None => return Ok(None),
            }
        };
        // the id breaks ties: a show whose filenames carry no numbers still has
        // a total order, and one episode never follows itself
        let sql = format!(
            "{EPISODE_SELECT}
             WHERE f.title_id = ?1
               AND (COALESCE(f.season, 0), COALESCE(f.episode, 0), f.id) > (?2, ?3, ?4)
             ORDER BY COALESCE(f.season, 0), COALESCE(f.episode, 0), f.id
             LIMIT 1"
        );
        let mut stmt = self.conn.prepare_cached(&sql)?;
        let mut rows = stmt.query(params![current.0, current.1, current.2, file_id])?;
        Ok(match rows.next()? {
            Some(r) => Some(row_to_episode(r)?),
            None => None,
        })
    }

    /// What playing a title means right now: the episode left running most
    /// recently, else the first one never seen, else the first one at all. A
    /// movie answers with its own file.
    ///
    /// The last band exists because `watched` is sticky: without it a show that
    /// has been through once would have nothing to play. The first band asks
    /// the position instead, so an episode being watched a second time is
    /// offered where it was left rather than sent to the back.
    pub fn up_next(&self, title_id: i64) -> Result<Option<EpisodeRow>, IndexError> {
        let sql = format!(
            "{EPISODE_SELECT}
             WHERE f.title_id = ?1
             ORDER BY
               CASE WHEN {IN_PROGRESS} THEN 0
                    WHEN COALESCE(w.watched, 0) = 0 THEN 1
                    ELSE 2 END,
               CASE WHEN {IN_PROGRESS}
                    THEN -COALESCE(w.updated_at, 0) ELSE 0 END,
               COALESCE(f.season, 0), COALESCE(f.episode, 0), f.id
             LIMIT 1"
        );
        let mut stmt = self.conn.prepare_cached(&sql)?;
        let mut rows = stmt.query(params![title_id])?;
        Ok(match rows.next()? {
            Some(r) => Some(row_to_episode(r)?),
            None => None,
        })
    }

    /// Every episode of a show, in air order: what its detail screen lists,
    /// season by season. A movie has one file and no reason to call this.
    pub fn episodes(&self, title_id: i64) -> Result<Vec<EpisodeRow>, IndexError> {
        let sql = format!(
            "{EPISODE_SELECT}
             WHERE f.title_id = ?1
             ORDER BY COALESCE(f.season, 0), COALESCE(f.episode, 0), f.id"
        );
        let mut stmt = self.conn.prepare_cached(&sql)?;
        let rows = stmt.query_map(params![title_id], row_to_episode)?;
        Ok(rows.collect::<Result<Vec<_>, _>>()?)
    }

    /// A file id from what a rebuild reproduces: ids are reassigned by a purge,
    /// (source_id, path) is not.
    pub fn file_id(&self, source_id: &str, path: &str) -> Result<Option<i64>, IndexError> {
        let mut stmt = self
            .conn
            .prepare_cached("SELECT id FROM files WHERE source_id = ?1 AND path = ?2")?;
        let mut rows = stmt.query(params![source_id, path])?;
        Ok(match rows.next()? {
            Some(row) => Some(row.get(0)?),
            None => None,
        })
    }

    /// The player's own probe cache: the JSON blob stored for `identity`,
    /// or None when nothing is stored or the stored `mtime` no longer
    /// matches - a stale mtime is exactly as much a miss as no row at all,
    /// since the file underneath `identity` has changed since it was probed.
    pub fn load_analysis(&self, identity: &str, mtime: i64) -> Result<Option<String>, IndexError> {
        let mut stmt = self
            .conn
            .prepare_cached("SELECT json FROM media_analysis WHERE identity = ?1 AND mtime = ?2")?;
        let mut rows = stmt.query(params![identity, mtime])?;
        Ok(match rows.next()? {
            Some(row) => Some(row.get(0)?),
            None => None,
        })
    }

    /// Replaces whatever was stored for `identity` whole: a re-probe after a
    /// mismatch overwrites the stale row rather than leaving two.
    pub fn store_analysis(&self, identity: &str, mtime: i64, json: &str) -> Result<(), IndexError> {
        self.conn.execute(
            "INSERT INTO media_analysis (identity, mtime, json) VALUES (?1, ?2, ?3)
             ON CONFLICT(identity) DO UPDATE SET mtime = excluded.mtime, json = excluded.json",
            params![identity, mtime, json],
        )?;
        Ok(())
    }

    /// Records what TMDB lists as similar to one title, most similar first. The
    /// sentinel row (id 0, which TMDB never issues) is what makes an empty
    /// answer stick: without it, a title nothing resembles would be asked about
    /// on every batch, forever. It ranks last, so a reader that forgets to skip
    /// it trails one dead id instead of leading with it.
    ///
    /// The answer replaces the previous one whole: an id TMDB dropped must not
    /// linger, and reusing its rank would leave `ORDER BY rank` no longer a
    /// total order.
    pub fn upsert_similar(
        &self,
        tmdb_id: i64,
        kind: MediaKind,
        similar: &[i64],
    ) -> Result<(), IndexError> {
        let tx = self.conn.unchecked_transaction()?;
        {
            self.conn.execute(
                "DELETE FROM tmdb_similar WHERE kind = ?1 AND tmdb_id = ?2",
                params![kind.as_str(), tmdb_id],
            )?;
            let mut stmt = self.conn.prepare_cached(
                "INSERT INTO tmdb_similar (kind, tmdb_id, similar_tmdb_id, rank)
                 VALUES (?1, ?2, ?3, ?4)",
            )?;
            stmt.execute(params![kind.as_str(), tmdb_id, 0, SIMILAR_SENTINEL_RANK])?;
            for (rank, id) in similar.iter().enumerate() {
                stmt.execute(params![kind.as_str(), tmdb_id, id, rank as i64])?;
            }
        }
        tx.commit()?;
        Ok(())
    }

    /// What the background pass has done, whether or not one is running right
    /// now: every title in the index, and how many of them are described,
    /// linked to a TMDB neighbour and vectorized by this model. Diagnostics
    /// reads this so the counts hold even at rest, on a process that has just
    /// launched and ticked nothing yet.
    pub fn pass_counts(&self, model_version: i64) -> Result<PassCounts, IndexError> {
        Ok(self.conn.query_row(
            "SELECT
               (SELECT COUNT(*) FROM titles),
               (SELECT COUNT(*) FROM metadata),
               (SELECT COUNT(*) FROM metadata m JOIN titles t ON t.id = m.title_id
                  WHERE m.tmdb_id IS NOT NULL
                    AND EXISTS (SELECT 1 FROM tmdb_similar s
                                WHERE s.kind = t.kind AND s.tmdb_id = m.tmdb_id)),
               (SELECT COUNT(*) FROM embeddings WHERE model_version = ?1)",
            params![model_version],
            |r| {
                Ok(PassCounts {
                    total: r.get(0)?,
                    described: r.get(1)?,
                    linked: r.get(2)?,
                    embedded: r.get(3)?,
                })
            },
        )?)
    }

    /// Matched titles nobody has asked TMDB about yet, in title id order.
    pub fn titles_needing_similar(&self, limit: u32) -> Result<Vec<PendingSimilar>, IndexError> {
        let mut stmt = self.conn.prepare_cached(
            "SELECT m.tmdb_id, t.kind FROM metadata m
             JOIN titles t ON t.id = m.title_id
             WHERE m.tmdb_id IS NOT NULL
               AND NOT EXISTS (SELECT 1 FROM tmdb_similar s
                               WHERE s.kind = t.kind AND s.tmdb_id = m.tmdb_id)
             ORDER BY m.title_id LIMIT ?1",
        )?;
        let rows = stmt.query_map(params![limit], |r| {
            Ok(PendingSimilar {
                tmdb_id: r.get(0)?,
                kind: MediaKind::from_str(&r.get::<_, String>(1)?).unwrap_or(MediaKind::Movie),
            })
        })?;
        Ok(rows.collect::<Result<Vec<_>, _>>()?)
    }

    /// One title's vector. The BLOB is the bytes of the i8 slice: SQLite has
    /// no signed-byte type, and the sign is put back on the way out.
    pub fn upsert_embedding(&self, e: &EmbeddingRecord) -> Result<(), IndexError> {
        let bytes: Vec<u8> = e.vector.iter().map(|v| *v as u8).collect();
        self.conn.execute(
            "INSERT INTO embeddings (title_id, model_version, source_hash, vector, computed_at)
             VALUES (?1, ?2, ?3, ?4, ?5)
             ON CONFLICT (title_id, model_version) DO UPDATE SET
               source_hash = excluded.source_hash,
               vector = excluded.vector,
               computed_at = excluded.computed_at",
            params![
                e.title_id,
                e.model_version,
                e.source_hash,
                bytes,
                e.computed_at
            ],
        )?;
        Ok(())
    }

    /// Records that the description was looked at and had not moved, without
    /// paying for the vector again.
    pub fn touch_embedding(
        &self,
        title_id: i64,
        model_version: i64,
        now: i64,
    ) -> Result<(), IndexError> {
        // The neighbours read off the unchanged vector stand too: moved with
        // it when they were current, or the semantic sweep would take every
        // touched title for a new vector and link the library again.
        self.conn.execute(
            "UPDATE semantic_computed SET computed_at = ?3
             WHERE title_id = ?1 AND model_version = ?2
               AND computed_at >= (SELECT computed_at FROM embeddings
                                   WHERE title_id = ?1 AND model_version = ?2)",
            params![title_id, model_version, now],
        )?;
        self.conn.execute(
            "UPDATE embeddings SET computed_at = ?3 WHERE title_id = ?1 AND model_version = ?2",
            params![title_id, model_version, now],
        )?;
        Ok(())
    }

    /// Described titles whose vector is missing, was computed by another model
    /// or is older than the description it was computed from. A title nothing
    /// has described yet is not owed one: there would be no text to embed.
    ///
    /// The hash comes back only for a row this model wrote, so the caller's
    /// "the description has not moved" can never mean "another model said so".
    pub fn titles_needing_embedding(
        &self,
        model_version: i64,
        limit: u32,
    ) -> Result<Vec<PendingEmbed>, IndexError> {
        let mut stmt = self.conn.prepare_cached(
            "SELECT t.id, t.kind, t.name, t.year, m.genres, m.collections, m.cast_names,
                COALESCE(NULLIF(m.overview_fr, ''), m.overview_en, ''),
                e.source_hash,
                m.director_names, m.writer_names, m.composer_names, m.keywords
             FROM metadata m
             JOIN titles t ON t.id = m.title_id
             LEFT JOIN embeddings e ON e.title_id = t.id AND e.model_version = ?1
             WHERE e.title_id IS NULL OR e.computed_at < m.fetched_at
             ORDER BY t.id LIMIT ?2",
        )?;
        let rows = stmt.query_map(params![model_version, limit], |r| {
            let year: u16 = r.get(3)?;
            Ok(PendingEmbed {
                title_id: r.get(0)?,
                kind: MediaKind::from_str(&r.get::<_, String>(1)?).unwrap_or(MediaKind::Movie),
                name: r.get(2)?,
                year: if year == 0 { None } else { Some(year) },
                genres: r.get(4)?,
                collections: r.get(5)?,
                cast_names: r.get(6)?,
                overview: r.get(7)?,
                source_hash: r.get(8)?,
                director_names: r.get(9)?,
                writer_names: r.get(10)?,
                composer_names: r.get(11)?,
                keywords: r.get(12)?,
            })
        })?;
        Ok(rows.collect::<Result<Vec<_>, _>>()?)
    }

    /// Every title id, oldest first. The tests use it to describe by hand what
    /// the scan indexed.
    #[cfg(test)]
    pub fn list_title_ids_for_test(&self) -> Result<Vec<i64>, IndexError> {
        let mut stmt = self.conn.prepare("SELECT id FROM titles ORDER BY id")?;
        let rows = stmt.query_map([], |r| r.get(0))?;
        Ok(rows.collect::<Result<Vec<_>, _>>()?)
    }

    /// Every vector this model wrote, oldest title first. The neighbour search
    /// reads the whole set: 10 000 titles is 2.6 MB of BLOBs and under a
    /// millisecond, and `limit` is what keeps that promise honest.
    ///
    /// An empty vector is a title the model had no word for. Its row exists so
    /// the queue leaves it alone, and it is not something to compare against.
    /// What the vector table holds, cheaply enough to ask before every batch.
    /// The count catches a title arriving or being pruned; the newest stamp and
    /// the sum of the low half of the source hashes catch a title re-embedded
    /// from changed text, which is the only other way a vector moves without
    /// the model version moving with it.
    ///
    /// The hashes are masked because they are FNV over the embedded text and
    /// use the whole of an i64: summing thousands of them raw overflows, and
    /// SQLite answers a sum of integers that overflows with an error rather
    /// than a number. Reads three integers a row and no blob, so it is a
    /// fraction of what reading the vectors themselves costs.
    pub fn embedding_stamp(&self, model_version: i64) -> Result<(i64, i64, i64), IndexError> {
        let mut stmt = self.conn.prepare_cached(
            "SELECT COUNT(*), IFNULL(SUM(source_hash & 0xFFFFFFFF), 0),
                    IFNULL(MAX(computed_at), 0)
             FROM embeddings WHERE model_version = ?1",
        )?;
        Ok(stmt.query_row(params![model_version], |r| {
            Ok((r.get(0)?, r.get(1)?, r.get(2)?))
        })?)
    }

    pub fn vectors(&self, model_version: i64, limit: u32) -> Result<Vec<TitleVector>, IndexError> {
        let mut stmt = self.conn.prepare_cached(
            "SELECT e.title_id, t.kind, e.vector FROM embeddings e
             JOIN titles t ON t.id = e.title_id
             WHERE e.model_version = ?1 AND LENGTH(e.vector) > 0
             ORDER BY e.title_id LIMIT ?2",
        )?;
        let rows = stmt.query_map(params![model_version, limit], |r| {
            let bytes: Vec<u8> = r.get(2)?;
            Ok(TitleVector {
                title_id: r.get(0)?,
                kind: MediaKind::from_str(&r.get::<_, String>(1)?).unwrap_or(MediaKind::Movie),
                vector: bytes.into_iter().map(|b| b as i8).collect(),
            })
        })?;
        Ok(rows.collect::<Result<Vec<_>, _>>()?)
    }

    /// Every play the index remembers, of a title this model has a vector for:
    /// what the taste fingerprint is built out of. A title nothing vectorised
    /// is left out here rather than by the caller, which has no direction to
    /// put it in anyway.
    pub fn watch_history(&self, model_version: i64) -> Result<Vec<WatchedFile>, IndexError> {
        let mut stmt = self.conn.prepare_cached(
            "SELECT f.title_id, t.kind, w.watched, w.position_secs, w.duration_secs, w.plays,
                    w.updated_at
             FROM watch_state w
             CROSS JOIN files f ON f.id = w.file_id
             CROSS JOIN titles t ON t.id = f.title_id
             CROSS JOIN embeddings e ON e.title_id = f.title_id
             WHERE e.model_version = ?1 AND LENGTH(e.vector) > 0",
        )?;
        let rows = stmt.query_map(params![model_version], |r| {
            Ok(WatchedFile {
                title_id: r.get(0)?,
                kind: MediaKind::from_str(&r.get::<_, String>(1)?).unwrap_or(MediaKind::Movie),
                watched: r.get(2)?,
                position_secs: r.get(3)?,
                duration_secs: r.get(4)?,
                plays: r.get(5)?,
                updated_at: r.get(6)?,
            })
        })?;
        Ok(rows.collect::<Result<Vec<_>, _>>()?)
    }

    /// The titles refused at least `times` times since `since`, most
    /// recently refused first: what a run of "not tonight" says about a title.
    pub fn repeat_deferrals(&self, since: i64, times: u32) -> Result<Vec<i64>, IndexError> {
        let mut stmt = self.conn.prepare_cached(
            "SELECT title_id FROM taste_event
             WHERE kind = ?1 AND at >= ?2
             GROUP BY title_id HAVING COUNT(*) >= ?3
             ORDER BY MAX(at) DESC, title_id",
        )?;
        let rows = stmt.query_map(params![TASTE_DEFERRED, since, times], |r| r.get(0))?;
        Ok(rows.collect::<Result<Vec<_>, _>>()?)
    }

    /// Titles whose page was read on two days or more since `since` and that
    /// nothing has played since the first of them: considered, and declined.
    pub fn passed_over(&self, since: i64) -> Result<HashSet<i64>, IndexError> {
        let mut stmt = self.conn.prepare_cached(
            "SELECT d.title_id FROM (
               SELECT title_id, MIN(at) AS first, COUNT(DISTINCT at / 86400) AS days
               FROM taste_event WHERE kind = ?1 AND at >= ?2 GROUP BY title_id) d
             WHERE d.days >= 2
               AND NOT EXISTS (SELECT 1 FROM files f CROSS JOIN watch_state w ON w.file_id = f.id
                               WHERE f.title_id = d.title_id AND w.updated_at >= d.first)",
        )?;
        let rows = stmt.query_map(params![TASTE_DWELL, since], |r| r.get(0))?;
        Ok(rows.collect::<Result<_, _>>()?)
    }

    /// Every title the viewer showed an interest in since `since`, and whether
    /// one of those gestures was choosing it over another.
    pub fn interests(&self, since: i64) -> Result<Vec<(i64, bool)>, IndexError> {
        let mut stmt = self.conn.prepare_cached(
            "SELECT title_id, MAX(kind = ?1) FROM taste_event
             WHERE kind IN (?2, ?3, ?4, ?1) AND at >= ?5
             GROUP BY title_id ORDER BY title_id",
        )?;
        let rows = stmt.query_map(
            params![
                TASTE_CHOSEN,
                TASTE_QUEUED,
                TASTE_DWELL,
                TASTE_TRAILER,
                since
            ],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )?;
        Ok(rows.collect::<Result<Vec<_>, _>>()?)
    }

    /// One gesture of interest in a title: `kind` is one of TASTE_DWELL,
    /// TASTE_TRAILER or TASTE_CHOSEN.
    pub fn record_interest(&self, title_id: i64, kind: u32, at: i64) -> Result<(), IndexError> {
        self.conn
            .prepare_cached("INSERT INTO taste_event (at, kind, title_id) VALUES (?1, ?2, ?3)")?
            .execute(params![at, kind, title_id])?;
        Ok(())
    }

    /// How many days the taste rows have shown each title since `since_day`,
    /// by title.
    pub fn row_exposure(&self, since_day: i64) -> Result<HashMap<i64, (u32, i64)>, IndexError> {
        let mut stmt = self.conn.prepare_cached(
            "SELECT title_id, shows, last_day FROM row_exposure WHERE last_day >= ?1",
        )?;
        let rows = stmt.query_map(params![since_day], |r| {
            Ok((r.get(0)?, (r.get(1)?, r.get(2)?)))
        })?;
        Ok(rows.collect::<Result<_, _>>()?)
    }

    /// Records that the taste rows show `titles` on `day`, once per title and
    /// day. A title back after more than `window` days away starts from one,
    /// and a row that old is dropped.
    pub fn record_row_exposure(
        &self,
        titles: &[i64],
        day: i64,
        window: i64,
    ) -> Result<(), IndexError> {
        // the home is browsed many times a day: a browse counted already
        // takes no write lock
        {
            let mut counted = self.conn.prepare_cached(
                "SELECT 1 FROM row_exposure WHERE title_id = ?1 AND last_day = ?2",
            )?;
            let mut all = true;
            for title_id in titles {
                if !counted.exists(params![title_id, day])? {
                    all = false;
                    break;
                }
            }
            if all {
                return Ok(());
            }
        }
        let tx = self.conn.unchecked_transaction()?;
        self.conn.execute(
            "DELETE FROM row_exposure WHERE last_day < ?1",
            params![day - window],
        )?;
        {
            let mut shown = self.conn.prepare_cached(
                "INSERT INTO row_exposure (title_id, shows, last_day) VALUES (?1, 1, ?2)
                 ON CONFLICT (title_id) DO UPDATE SET shows = shows + 1, last_day = ?2
                 WHERE last_day <> ?2",
            )?;
            for title_id in titles {
                shown.execute(params![title_id, day])?;
            }
        }
        tx.commit()?;
        Ok(())
    }

    /// What TMDB puts near one title, as local title ids against the rank TMDB
    /// gave them. Empty for a title TMDB never matched, and empty throughout on
    /// a device that has never had a key: the taste row fuses this in where it
    /// has something to say and stands without it otherwise.
    ///
    /// The kind is matched on both sides, as in every read of this table: TMDB
    /// numbers movies and shows in two sequences that overlap.
    pub fn tmdb_ranks(&self, title_id: i64) -> Result<HashMap<i64, i64>, IndexError> {
        let mut stmt = self.conn.prepare_cached(
            "SELECT m.title_id, s.rank
             FROM titles seed
             CROSS JOIN metadata sm ON sm.title_id = seed.id
             CROSS JOIN tmdb_similar s ON s.kind = seed.kind AND s.tmdb_id = sm.tmdb_id
             CROSS JOIN metadata m ON m.tmdb_id = s.similar_tmdb_id
             CROSS JOIN titles x ON x.id = m.title_id AND x.kind = s.kind
             WHERE seed.id = ?1 AND s.similar_tmdb_id <> 0",
        )?;
        let rows = stmt.query_map(params![title_id], |r| Ok((r.get(0)?, r.get(1)?)))?;
        Ok(rows.collect::<Result<HashMap<i64, i64>, _>>()?)
    }

    /// Replaces the whole taste row with `picks`, in rank order, as one
    /// transaction: the row a home screen reads is either the last pass's or
    /// this one's, never half of each. Each pick carries the facet of the
    /// fingerprint that put it there and the watched title that facet was
    /// built around, which is what the row on screen names itself after.
    pub fn replace_taste(&self, out: &TastePassOutput) -> Result<(), IndexError> {
        let tx = self.conn.unchecked_transaction()?;
        for table in [
            "taste_pick",
            "taste_facet",
            "discovery_pick",
            "title_taste",
            "watched_facet",
            "seasonal_pick",
            "title_tone",
        ] {
            self.conn.execute(&format!("DELETE FROM {table}"), [])?;
        }
        {
            let mut ins = self.conn.prepare_cached(
                "INSERT INTO taste_pick (rank, title_id, facet, leader) VALUES (?1, ?2, ?3, ?4)",
            )?;
            for (rank, p) in out.picks.iter().enumerate() {
                ins.execute(params![rank as i64, p.title_id, p.facet, p.leader])?;
            }
            let mut meta = self.conn.prepare_cached(
                "INSERT INTO taste_facet (facet, weight, leader, cos_to_top) VALUES (?1, ?2, ?3, ?4)",
            )?;
            // the pass wipes the facets it replaces, so the snapshot is the
            // only trace left of what the taste weighed before this one. Two
            // passes inside one second are one instant: the later stands.
            let mut keep = self.conn.prepare_cached(
                "INSERT INTO taste_facet_snapshot (at, facet, weight, leader) VALUES (?1, ?2, ?3, ?4)
                 ON CONFLICT (at, facet) DO UPDATE SET
                   weight = excluded.weight,
                   leader = excluded.leader",
            )?;
            for f in &out.facets {
                meta.execute(params![f.facet, f.weight, f.leader, f.cos_to_top])?;
                keep.execute(params![out.now, f.facet, f.weight, f.leader])?;
            }
            let mut far = self.conn.prepare_cached(
                "INSERT INTO discovery_pick (rank, title_id, closeness) VALUES (?1, ?2, ?3)",
            )?;
            for (rank, d) in out.discovery.iter().enumerate() {
                far.execute(params![rank as i64, d.title_id, d.closeness])?;
            }
            let mut spent = self
                .conn
                .prepare_cached("INSERT INTO watched_facet (title_id, facet) VALUES (?1, ?2)")?;
            for (title_id, facet) in &out.watched_facet {
                spent.execute(params![title_id, facet])?;
            }
            let mut why = self.conn.prepare_cached(
                "INSERT INTO title_taste (title_id, facet, affinity, rejected)
                 VALUES (?1, ?2, ?3, ?4)",
            )?;
            for row in &out.title_taste {
                why.execute(params![row.title_id, row.facet, row.affinity, row.rejected])?;
            }
            let mut season = self.conn.prepare_cached(
                "INSERT INTO seasonal_pick (window, rank, title_id) VALUES (?1, ?2, ?3)",
            )?;
            for (window, titles) in &out.seasonal {
                for (rank, title_id) in titles.iter().enumerate() {
                    season.execute(params![window, rank as i64, title_id])?;
                }
            }
            let mut tone = self.conn.prepare_cached(
                "INSERT INTO title_tone (title_id, mood, score) VALUES (?1, ?2, ?3)",
            )?;
            for (title_id, mood, score) in &out.tones {
                tone.execute(params![title_id, mood, score])?;
            }
        }
        tx.commit()?;
        Ok(())
    }

    /// What the fingerprint says about one title, or nothing: no pass has run,
    /// the title has no vector, or it is already spent.
    pub fn title_taste(&self, title_id: i64) -> Result<Option<TitleTasteRow>, IndexError> {
        let mut stmt = self.conn.prepare_cached(
            "SELECT title_id, facet, affinity, rejected FROM title_taste WHERE title_id = ?1",
        )?;
        let mut rows = stmt.query(params![title_id])?;
        let Some(r) = rows.next()? else {
            return Ok(None);
        };
        Ok(Some(TitleTasteRow {
            title_id: r.get(0)?,
            facet: r.get(1)?,
            affinity: r.get(2)?,
            rejected: r.get(3)?,
        }))
    }

    /// Every title the fingerprint claims, and how near its taste it sits.
    pub fn title_affinities(&self) -> Result<Vec<(i64, f32)>, IndexError> {
        let mut stmt = self
            .conn
            .prepare_cached("SELECT title_id, affinity FROM title_taste")?;
        let rows = stmt.query_map([], |r| Ok((r.get(0)?, r.get(1)?)))?;
        Ok(rows.collect::<Result<Vec<_>, _>>()?)
    }

    /// The discovery band, in the order the taste pass ranked it.
    pub fn discovery_titles(&self) -> Result<Vec<i64>, IndexError> {
        let mut stmt = self
            .conn
            .prepare_cached("SELECT title_id FROM discovery_pick ORDER BY rank")?;
        let rows = stmt.query_map([], |r| r.get(0))?;
        Ok(rows.collect::<Result<Vec<_>, _>>()?)
    }

    /// The titles the most others name among their neighbours, most first:
    /// the library's pillars, whatever the viewer has seen.
    pub fn best_connected(&self, limit: u32) -> Result<Vec<i64>, IndexError> {
        let mut stmt = self.conn.prepare_cached(
            "SELECT similar_title_id FROM similar_semantic
             GROUP BY similar_title_id ORDER BY COUNT(*) DESC, similar_title_id LIMIT ?1",
        )?;
        let rows = stmt.query_map(params![limit], |r| r.get(0))?;
        Ok(rows.collect::<Result<Vec<_>, _>>()?)
    }

    /// The titles of the discovery band a guest's taste does not veto, or None
    /// when nothing measured that guest's taste yet.
    pub fn guest_discoveries(&self, guest_id: i64) -> Result<Option<HashSet<i64>>, IndexError> {
        let measured: bool = self.conn.query_row(
            "SELECT EXISTS (SELECT 1 FROM guest_taste WHERE guest_id = ?1)",
            params![guest_id],
            |r| r.get(0),
        )?;
        if !measured {
            return Ok(None);
        }
        let mut stmt = self.conn.prepare_cached(
            "SELECT g.title_id FROM discovery_pick d
             CROSS JOIN guest_taste g ON g.guest_id = ?1 AND g.title_id = d.title_id",
        )?;
        let rows = stmt.query_map(params![guest_id], |r| r.get(0))?;
        Ok(Some(rows.collect::<Result<_, _>>()?))
    }

    /// The moods a title stands out towards, the most marked first. Empty
    /// until a taste pass has run over its vector, and for a title that is
    /// no more one mood than the rest of the library is.
    pub fn title_tones(&self, title_id: i64) -> Result<Vec<String>, IndexError> {
        let mut stmt = self.conn.prepare_cached(
            "SELECT mood FROM title_tone WHERE title_id = ?1 ORDER BY score DESC, mood",
        )?;
        let rows = stmt.query_map(params![title_id], |r| r.get(0))?;
        Ok(rows.collect::<Result<Vec<_>, _>>()?)
    }

    /// The library ranked against one seasonal anchor, best first.
    pub fn seasonal_titles(&self, window: &str) -> Result<Vec<i64>, IndexError> {
        let mut stmt = self
            .conn
            .prepare_cached("SELECT title_id FROM seasonal_pick WHERE window = ?1 ORDER BY rank")?;
        let rows = stmt.query_map(params![window], |r| r.get(0))?;
        Ok(rows.collect::<Result<Vec<_>, _>>()?)
    }

    pub fn put_anchor_vector(
        &self,
        key: &str,
        model_version: i64,
        vector: &[i8],
    ) -> Result<(), IndexError> {
        let bytes: Vec<u8> = vector.iter().map(|v| *v as u8).collect();
        self.conn.execute(
            "INSERT INTO anchor_vector (key, model_version, vector) VALUES (?1, ?2, ?3)
             ON CONFLICT(key, model_version) DO UPDATE SET vector = excluded.vector",
            params![key, model_version, bytes],
        )?;
        Ok(())
    }

    pub fn anchor_vector(
        &self,
        key: &str,
        model_version: i64,
    ) -> Result<Option<Vec<i8>>, IndexError> {
        let mut stmt = self.conn.prepare_cached(
            "SELECT vector FROM anchor_vector WHERE key = ?1 AND model_version = ?2",
        )?;
        let mut rows = stmt.query(params![key, model_version])?;
        let Some(r) = rows.next()? else {
            return Ok(None);
        };
        let bytes: Vec<u8> = r.get(0)?;
        Ok(Some(bytes.into_iter().map(|b| b as i8).collect()))
    }

    /// The anchors this model has no vector for yet, of the keys asked about.
    pub fn anchors_missing(
        &self,
        keys: &[&str],
        model_version: i64,
    ) -> Result<Vec<String>, IndexError> {
        let mut missing = Vec::new();
        for key in keys {
            if self.anchor_vector(key, model_version)?.is_none() {
                missing.push((*key).to_string());
            }
        }
        Ok(missing)
    }

    pub fn setting(&self, key: &str) -> Result<Option<String>, IndexError> {
        let mut stmt = self
            .conn
            .prepare_cached("SELECT value FROM setting WHERE key = ?1")?;
        let mut rows = stmt.query(params![key])?;
        let Some(r) = rows.next()? else {
            return Ok(None);
        };
        Ok(Some(r.get(0)?))
    }

    pub fn set_setting(&self, key: &str, value: &str) -> Result<(), IndexError> {
        self.conn.execute(
            "INSERT INTO setting (key, value) VALUES (?1, ?2)
             ON CONFLICT(key) DO UPDATE SET value = excluded.value",
            params![key, value],
        )?;
        Ok(())
    }

    /// Contests the taste led by `leader_id` until `until`, replacing any
    /// earlier mute of it.
    pub fn mute_taste(&self, leader_id: i64, until: i64) -> Result<(), IndexError> {
        self.conn.execute(
            "INSERT INTO taste_mute (leader_id, until) VALUES (?1, ?2)
             ON CONFLICT (leader_id) DO UPDATE SET until = excluded.until",
            params![leader_id, until],
        )?;
        Ok(())
    }

    pub fn unmute_taste(&self, leader_id: i64) -> Result<(), IndexError> {
        self.conn.execute(
            "DELETE FROM taste_mute WHERE leader_id = ?1",
            params![leader_id],
        )?;
        Ok(())
    }

    /// The leaders whose taste is still contested at `now`.
    pub fn muted_tastes(&self, now: i64) -> Result<Vec<i64>, IndexError> {
        let mut stmt = self.conn.prepare_cached(
            "SELECT leader_id FROM taste_mute WHERE until > ?1 ORDER BY leader_id",
        )?;
        let rows = stmt.query_map(params![now], |r| r.get(0))?;
        Ok(rows.collect::<Result<Vec<_>, _>>()?)
    }

    /// What "after this" accepted, newest last, dropping anything older than
    /// `stale_before`: a proposal nobody watched in three days is not tonight's.
    pub fn queued_tonight(&self, stale_before: i64) -> Result<Vec<(i64, i64)>, IndexError> {
        let mut stmt = self.conn.prepare_cached(
            "SELECT title_id, queued_at FROM tonight_queued WHERE queued_at >= ?1 ORDER BY queued_at",
        )?;
        let rows = stmt.query_map(params![stale_before], |r| Ok((r.get(0)?, r.get(1)?)))?;
        Ok(rows.collect::<Result<Vec<_>, _>>()?)
    }

    pub fn queue_tonight(&self, title_id: i64, now: i64) -> Result<(), IndexError> {
        self.conn.execute(
            "INSERT INTO tonight_queued (title_id, queued_at) VALUES (?1, ?2)
             ON CONFLICT(title_id) DO UPDATE SET queued_at = excluded.queued_at",
            params![title_id, now],
        )?;
        Ok(())
    }

    /// Puts a title on the watchlist, or takes it off. Setting one that is
    /// already there leaves the date it was added alone: the rail is ordered
    /// by it, and a second press on a title already on the list would
    /// otherwise walk it back to the front for nothing.
    pub fn set_watchlisted(&self, title_id: i64, on: bool, now: i64) -> Result<(), IndexError> {
        if on {
            // as in the table below, a title already on the list is not being
            // put on it again
            self.conn.execute(
                "INSERT INTO taste_event (at, kind, title_id)
                 SELECT ?2, ?3, ?1
                 WHERE NOT EXISTS (SELECT 1 FROM watchlist WHERE title_id = ?1)",
                params![title_id, now, TASTE_QUEUED],
            )?;
            self.conn.execute(
                "INSERT INTO watchlist (title_id, added_at) VALUES (?1, ?2)
                 ON CONFLICT(title_id) DO NOTHING",
                params![title_id, now],
            )?;
        } else {
            self.conn.execute(
                "DELETE FROM watchlist WHERE title_id = ?1",
                params![title_id],
            )?;
        }
        Ok(())
    }

    /// Replaces the week's trending of one kind, in TMDB's order.
    pub fn replace_trending(
        &self,
        kind: MediaKind,
        tmdb_ids: &[i64],
        now: i64,
    ) -> Result<(), IndexError> {
        let tx = self.conn.unchecked_transaction()?;
        tx.execute(
            "DELETE FROM tmdb_trending WHERE kind = ?1",
            params![kind.as_str()],
        )?;
        {
            let mut insert = tx.prepare_cached(
                "INSERT OR IGNORE INTO tmdb_trending (kind, tmdb_id, rank, fetched_at) VALUES (?1, ?2, ?3, ?4)",
            )?;
            for (rank, id) in tmdb_ids.iter().enumerate() {
                insert.execute(params![kind.as_str(), id, rank as i64, now])?;
            }
        }
        tx.commit()?;
        Ok(())
    }

    /// When the oldest kind of trending was fetched, None before the first.
    pub fn trending_fetched_at(&self) -> Result<Option<i64>, IndexError> {
        Ok(self.conn.query_row(
            "SELECT CASE WHEN COUNT(*) = 2 THEN MIN(at) END
               FROM (SELECT MAX(fetched_at) AS at FROM tmdb_trending GROUP BY kind)",
            [],
            |r| r.get(0),
        )?)
    }

    /// What TheIntroDB needs to find a file's intro and credits: its title's
    /// TMDB id and kind, the file's season and episode, and how long it runs.
    /// None for a file the index does not hold or whose title TMDB never matched.
    pub fn skip_lookup(&self, file_id: i64) -> Result<Option<SkipLookup>, IndexError> {
        let mut stmt = self.conn.prepare_cached(
            "SELECT m.tmdb_id, t.kind, f.season, f.episode, f.duration_secs
             FROM files f JOIN titles t ON t.id = f.title_id JOIN metadata m ON m.title_id = t.id
             WHERE f.id = ?1 AND m.tmdb_id IS NOT NULL",
        )?;
        let mut rows = stmt.query(params![file_id])?;
        let Some(row) = rows.next()? else {
            return Ok(None);
        };
        let kind: String = row.get(1)?;
        Ok(Some(SkipLookup {
            tmdb_id: row.get(0)?,
            kind: if kind == MediaKind::Show.as_str() {
                MediaKind::Show
            } else {
                MediaKind::Movie
            },
            season_episode: match (row.get::<_, Option<u16>>(2)?, row.get::<_, Option<u16>>(3)?) {
                (Some(season), Some(episode)) => Some((season, episode)),
                _ => None,
            },
            duration_secs: row.get(4)?,
        }))
    }

    pub fn is_watchlisted(&self, title_id: i64) -> Result<bool, IndexError> {
        let mut stmt = self
            .conn
            .prepare_cached("SELECT 1 FROM watchlist WHERE title_id = ?1")?;
        Ok(stmt.exists(params![title_id])?)
    }

    /// A queued title the trio has now shown: the queue is a nudge for one
    /// evening, not a list that accumulates.
    pub fn consume_queued(&self, title_id: i64) -> Result<(), IndexError> {
        self.conn.execute(
            "DELETE FROM tonight_queued WHERE title_id = ?1",
            params![title_id],
        )?;
        Ok(())
    }

    /// The thread with something left to watch, as (leader, facet).
    pub fn active_thread(&self) -> Result<Option<(i64, u32)>, IndexError> {
        let mut stmt = self.conn.prepare_cached(
            "SELECT leader, facet FROM thread ORDER BY created_at DESC, id DESC LIMIT 1",
        )?;
        let mut rows = stmt.query([])?;
        let Some(r) = rows.next()? else {
            return Ok(None);
        };
        Ok(Some((r.get(0)?, r.get(1)?)))
    }

    /// How many of the running thread's titles are still unwatched: zero is a
    /// thread the viewer has been through, and the pass's cue to lay another.
    pub fn thread_unwatched(&self) -> Result<u32, IndexError> {
        let mut stmt = self.conn.prepare_cached(
            "SELECT COUNT(*) FROM thread_item i
             WHERE NOT EXISTS (SELECT 1 FROM watch_state w JOIN files f ON f.id = w.file_id
                               WHERE f.title_id = i.title_id AND w.watched = 1)",
        )?;
        Ok(stmt.query_row([], |r| r.get(0))?)
    }

    /// Replaces the thread: at most one runs at a time.
    pub fn create_thread(
        &self,
        leader: i64,
        facet: u32,
        items: &[i64],
        now: i64,
    ) -> Result<(), IndexError> {
        let tx = self.conn.unchecked_transaction()?;
        self.conn.execute("DELETE FROM thread", [])?;
        self.conn.execute(
            "INSERT INTO thread (leader, facet, created_at) VALUES (?1, ?2, ?3)",
            params![leader, facet, now],
        )?;
        let id = self.conn.last_insert_rowid();
        {
            let mut ins = self.conn.prepare_cached(
                "INSERT INTO thread_item (thread_id, rank, title_id) VALUES (?1, ?2, ?3)",
            )?;
            for (rank, title_id) in items.iter().enumerate() {
                ins.execute(params![id, rank as i64, title_id])?;
            }
        }
        tx.commit()?;
        Ok(())
    }

    /// Replaces the film club's themes with the pass's: `(kind, value,
    /// [(title_id, affinity)])` for each theme that qualifies.
    pub fn replace_club(
        &self,
        themes: &[(&str, String, Vec<(i64, f32)>)],
    ) -> Result<(), IndexError> {
        let tx = self.conn.unchecked_transaction()?;
        self.conn.execute("DELETE FROM club_pick", [])?;
        {
            let mut ins = self.conn.prepare_cached(
                "INSERT INTO club_pick (kind, value, title_id, affinity) VALUES (?1, ?2, ?3, ?4)",
            )?;
            for (kind, value, titles) in themes {
                for (title_id, affinity) in titles {
                    ins.execute(params![kind, value, title_id, affinity])?;
                }
            }
        }
        tx.commit()?;
        Ok(())
    }

    /// Every title's genres, as `(title_id, genre)`: what the taste pass
    /// calibrates its row against, read once per pass off the lookup index.
    pub fn genre_tags(&self) -> Result<Vec<(i64, String)>, IndexError> {
        let mut stmt = self
            .conn
            .prepare_cached("SELECT title_id, value FROM title_tags WHERE kind = 'genre'")?;
        let rows = stmt.query_map([], |r| Ok((r.get(0)?, r.get(1)?)))?;
        Ok(rows.collect::<Result<Vec<_>, _>>()?)
    }

    pub fn taste_facets(&self) -> Result<Vec<TasteFacetMeta>, IndexError> {
        let mut stmt = self.conn.prepare_cached(
            "SELECT facet, weight, leader, cos_to_top FROM taste_facet ORDER BY weight DESC, facet",
        )?;
        let rows = stmt.query_map([], |r| {
            Ok(TasteFacetMeta {
                facet: r.get(0)?,
                weight: r.get(1)?,
                leader: r.get(2)?,
                cos_to_top: r.get(3)?,
            })
        })?;
        Ok(rows.collect::<Result<Vec<_>, _>>()?)
    }

    /// The facets as they stand, each against the last snapshot taken strictly
    /// before `cutoff`: what the taste weighed a month ago, for the screen that
    /// draws the difference. A facet no snapshot that old knows carries None,
    /// which is a taste too young to have moved rather than one that has not.
    pub fn taste_facet_shifts(&self, cutoff: i64) -> Result<Vec<TasteFacetShift>, IndexError> {
        let mut stmt = self.conn.prepare_cached(
            "SELECT f.facet, f.weight, f.leader,
                    (SELECT s.weight FROM taste_facet_snapshot s
                     WHERE s.facet = f.facet AND s.at < ?1
                     ORDER BY s.at DESC LIMIT 1)
             FROM taste_facet f ORDER BY f.weight DESC, f.facet",
        )?;
        let rows = stmt.query_map(params![cutoff], |r| {
            Ok(TasteFacetShift {
                facet: r.get(0)?,
                weight: r.get(1)?,
                leader: r.get(2)?,
                was: r.get(3)?,
            })
        })?;
        Ok(rows.collect::<Result<Vec<_>, _>>()?)
    }

    /// What has moved the taste, newest first. Two events in the same second
    /// come back in the order they were written, which is the order they
    /// happened in. Gestures of interest are left out: a page opened for eight
    /// seconds is too slight a thing to list.
    pub fn taste_ledger(&self, limit: u32) -> Result<Vec<TasteEvent>, IndexError> {
        let mut stmt = self.conn.prepare_cached(
            "SELECT e.at, e.kind, t.name FROM taste_event e
             CROSS JOIN titles t ON t.id = e.title_id
             WHERE e.kind <= ?2
             ORDER BY e.at DESC, e.rowid DESC LIMIT ?1",
        )?;
        let rows = stmt.query_map(params![limit, TASTE_QUEUED], |r| {
            Ok(TasteEvent {
                at: r.get(0)?,
                kind: r.get(1)?,
                title: r.get(2)?,
            })
        })?;
        Ok(rows.collect::<Result<Vec<_>, _>>()?)
    }

    /// When viewing ended, one stamp per touched file: the raw material the
    /// bedtime estimate is quantiled from.
    pub fn watch_ends(&self) -> Result<Vec<i64>, IndexError> {
        let mut stmt = self.conn.prepare_cached(
            "SELECT updated_at FROM watch_state WHERE watched = 1 OR position_secs > 0",
        )?;
        let rows = stmt.query_map([], |r| r.get(0))?;
        Ok(rows.collect::<Result<Vec<_>, _>>()?)
    }

    /// When each spent title was last watched, and which taste it belongs to.
    /// The evening reads this to learn which of its tastes comes out on a
    /// weeknight, and which waits for a Saturday.
    pub fn watched_facet_ends(&self) -> Result<Vec<(u32, i64)>, IndexError> {
        let mut stmt = self.conn.prepare_cached(
            "SELECT wf.facet, MAX(w.updated_at)
             FROM watched_facet wf
             CROSS JOIN files f ON f.title_id = wf.title_id
             CROSS JOIN watch_state w ON w.file_id = f.id
             GROUP BY wf.title_id",
        )?;
        let rows = stmt.query_map([], |r| Ok((r.get(0)?, r.get(1)?)))?;
        Ok(rows.collect::<Result<Vec<_>, _>>()?)
    }

    /// Every file watched to the end since `since`, as whether it is an
    /// episode and when it ended: what tells an hour of series from an hour
    /// of films.
    pub fn finished_kinds(&self, since: i64) -> Result<Vec<(bool, i64)>, IndexError> {
        let mut stmt = self.conn.prepare_cached(
            "SELECT t.kind = 'show', w.updated_at
             FROM watch_state w
             CROSS JOIN files f ON f.id = w.file_id
             CROSS JOIN titles t ON t.id = f.title_id
             WHERE w.watched = 1 AND w.updated_at >= ?1",
        )?;
        let rows = stmt.query_map(params![since], |r| Ok((r.get(0)?, r.get(1)?)))?;
        Ok(rows.collect::<Result<Vec<_>, _>>()?)
    }

    /// The mean of the scores the library holds, on the 0-10 scale, None
    /// when nothing is scored: the prior every score is pulled towards.
    pub fn mean_rating(&self) -> Result<Option<f64>, IndexError> {
        Ok(self
            .conn
            .prepare_cached(
                "SELECT AVG(CASE WHEN audience_source <> '' THEN audience_rating
                             WHEN critic_source <> '' THEN critic_rating END)
             FROM metadata",
            )?
            .query_row([], |r| r.get(0))?)
    }

    /// The taste at least `min` distinct titles opened since `since` belong
    /// to, the most of them first; None when no taste has that many.
    pub fn browsed_facet(&self, since: i64, min: u32) -> Result<Option<u32>, IndexError> {
        let mut stmt = self.conn.prepare_cached(
            "SELECT tt.facet FROM taste_event e
             CROSS JOIN title_taste tt ON tt.title_id = e.title_id
             WHERE e.kind = ?1 AND e.at >= ?2
             GROUP BY tt.facet HAVING COUNT(DISTINCT e.title_id) >= ?3
             ORDER BY COUNT(DISTINCT e.title_id) DESC, MAX(e.at) DESC LIMIT 1",
        )?;
        let mut rows = stmt.query(params![TASTE_DWELL, since, min])?;
        Ok(match rows.next()? {
            Some(r) => Some(r.get(0)?),
            None => None,
        })
    }

    /// The session's frozen cards as (role, title, when the trio froze).
    pub fn tonight_picks(&self, evening: i64) -> Result<Vec<(u32, i64, i64)>, IndexError> {
        let mut stmt = self.conn.prepare_cached(
            "SELECT role, title_id, at FROM tonight_pick WHERE evening = ?1 ORDER BY role",
        )?;
        let rows = stmt.query_map(params![evening], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)))?;
        Ok(rows.collect::<Result<Vec<_>, _>>()?)
    }

    /// What the viewer said about one session, or the defaults when they said
    /// nothing.
    pub fn evening_state(&self, session: i64) -> Result<EveningAnswers, IndexError> {
        let mut stmt = self.conn.prepare_cached(
            "SELECT together, window_min, mood, guest_id FROM evening_state WHERE evening = ?1",
        )?;
        let mut rows = stmt.query(params![session])?;
        match rows.next()? {
            Some(r) => Ok(EveningAnswers {
                together: r.get(0)?,
                window_min: r.get(1)?,
                mood: r.get(2)?,
                guest_id: r.get(3)?,
            }),
            None => Ok(EveningAnswers::default()),
        }
    }

    pub fn set_evening_state(
        &self,
        session: i64,
        answers: &EveningAnswers,
    ) -> Result<(), IndexError> {
        // every other session is dead weight, exactly as the picks are
        self.conn.execute(
            "DELETE FROM evening_state WHERE evening <> ?1",
            params![session],
        )?;
        self.conn.execute(
            "INSERT INTO evening_state (evening, together, window_min, mood, guest_id)
             VALUES (?1, ?2, ?3, ?4, ?5)
             ON CONFLICT (evening) DO UPDATE SET
               together = excluded.together,
               window_min = excluded.window_min,
               mood = excluded.mood,
               guest_id = excluded.guest_id",
            params![
                session,
                answers.together,
                answers.window_min,
                answers.mood,
                answers.guest_id
            ],
        )?;
        Ok(())
    }

    /// Every guest, by name.
    pub fn guests(&self) -> Result<Vec<(i64, String)>, IndexError> {
        let mut stmt = self
            .conn
            .prepare_cached("SELECT id, name FROM guest ORDER BY name COLLATE NOCASE, id")?;
        let rows = stmt.query_map([], |r| Ok((r.get(0)?, r.get(1)?)))?;
        Ok(rows.collect::<Result<Vec<_>, _>>()?)
    }

    /// The guest of that name, added when there is none: a name is a person,
    /// so adding it twice finds the same guest.
    pub fn add_guest(&self, name: &str, now: i64) -> Result<i64, IndexError> {
        self.conn.execute(
            "INSERT INTO guest (name, created_at) VALUES (?1, ?2) ON CONFLICT (name) DO NOTHING",
            params![name, now],
        )?;
        Ok(self
            .conn
            .query_row("SELECT id FROM guest WHERE name = ?1", params![name], |r| {
                r.get(0)
            })?)
    }

    /// The guest, their verdicts and their taste; a session that had them
    /// chosen is left with nobody.
    pub fn remove_guest(&self, guest_id: i64) -> Result<(), IndexError> {
        let tx = self.conn.unchecked_transaction()?;
        self.conn.execute(
            "UPDATE evening_state SET guest_id = NULL WHERE guest_id = ?1",
            params![guest_id],
        )?;
        self.conn
            .execute("DELETE FROM guest WHERE id = ?1", params![guest_id])?;
        tx.commit()?;
        Ok(())
    }

    /// What one guest said about the titles they were shown: true for liked.
    pub fn guest_verdicts(&self, guest_id: i64) -> Result<Vec<(i64, bool)>, IndexError> {
        let mut stmt = self.conn.prepare_cached(
            "SELECT title_id, verdict FROM guest_verdict WHERE guest_id = ?1 ORDER BY stated_at, title_id",
        )?;
        let rows = stmt.query_map(params![guest_id], |r| {
            Ok((r.get(0)?, r.get::<_, i64>(1)? > 0))
        })?;
        Ok(rows.collect::<Result<Vec<_>, _>>()?)
    }

    pub fn set_guest_verdict(
        &self,
        guest_id: i64,
        title_id: i64,
        liked: bool,
        now: i64,
    ) -> Result<(), IndexError> {
        self.conn.execute(
            "INSERT INTO guest_verdict (guest_id, title_id, verdict, stated_at)
             VALUES (?1, ?2, ?3, ?4)
             ON CONFLICT (guest_id, title_id) DO UPDATE SET
               verdict = excluded.verdict,
               stated_at = excluded.stated_at",
            params![guest_id, title_id, if liked { 1 } else { -1 }, now],
        )?;
        Ok(())
    }

    /// Replaces what one guest's taste says of the unseen titles: each one's
    /// centred cosine to it, for those the guest does not veto.
    pub fn replace_guest_taste(
        &self,
        guest_id: i64,
        cosines: &[(i64, f32)],
    ) -> Result<(), IndexError> {
        let tx = self.conn.unchecked_transaction()?;
        self.conn.execute(
            "DELETE FROM guest_taste WHERE guest_id = ?1",
            params![guest_id],
        )?;
        {
            let mut ins = self.conn.prepare_cached(
                "INSERT INTO guest_taste (guest_id, title_id, cos) VALUES (?1, ?2, ?3)",
            )?;
            for (title_id, cos) in cosines {
                ins.execute(params![guest_id, title_id, cos])?;
            }
        }
        tx.commit()?;
        Ok(())
    }

    pub fn replace_tonight_picks(
        &self,
        evening: i64,
        picks: &[(u32, i64)],
        at: i64,
    ) -> Result<(), IndexError> {
        let tx = self.conn.unchecked_transaction()?;
        // every other session is dead weight: the freeze only ever reads the
        // current one
        self.conn.execute("DELETE FROM tonight_pick", [])?;
        {
            let mut ins = self.conn.prepare_cached(
                "INSERT INTO tonight_pick (evening, role, title_id, at) VALUES (?1, ?2, ?3, ?4)",
            )?;
            for (role, title_id) in picks {
                ins.execute(params![evening, role, title_id, at])?;
            }
        }
        tx.commit()?;
        Ok(())
    }

    /// What the evenings have shown, by title.
    pub fn tonight_exposure(&self) -> Result<HashMap<i64, Exposure>, IndexError> {
        let mut stmt = self.conn.prepare_cached(
            "SELECT title_id, cards, lanes, last_card, last_lane FROM tonight_exposure",
        )?;
        let rows = stmt.query_map([], |r| {
            Ok((
                r.get(0)?,
                Exposure {
                    cards: r.get(1)?,
                    lanes: r.get(2)?,
                    last_card: r.get(3)?,
                    last_lane: r.get(4)?,
                },
            ))
        })?;
        Ok(rows.collect::<Result<_, _>>()?)
    }

    /// Records that this session shows `cards`, as `(role, title_id)`, as its
    /// cards and `lane` as the rest of its lane. A card shown again after more
    /// than `window` days away starts counting from one, and a row that old is
    /// dropped. Distances are counted in days (see `tonight::session_day`),
    /// because an afternoon's key is negative and would read as an age.
    pub fn record_tonight_exposure(
        &self,
        session: i64,
        cards: &[(u32, i64)],
        lane: &[i64],
        window: i64,
    ) -> Result<(), IndexError> {
        let day = crate::index::tonight::session_day(session);
        let tx = self.conn.unchecked_transaction()?;
        self.conn.execute(
            &format!(
                "DELETE FROM tonight_exposure WHERE {} < ?1",
                day_of("last_lane")
            ),
            params![day - window],
        )?;
        self.conn.execute(
            &format!("DELETE FROM tonight_shown WHERE {} < ?1", day_of("evening")),
            params![day - crate::index::stats::STATS_REACH_DAYS],
        )?;
        {
            let mut role_of = self.conn.prepare_cached(
                "INSERT INTO tonight_shown (evening, title_id, role) VALUES (?1, ?2, ?3)
                 ON CONFLICT (evening, title_id) DO UPDATE SET role = excluded.role",
            )?;
            for (role, title_id) in cards {
                role_of.execute(params![session, title_id, role])?;
            }
            let mut card = self.conn.prepare_cached(&format!(
                "INSERT INTO tonight_exposure (title_id, cards, last_card, last_lane)
                 VALUES (?1, 1, ?2, ?2)
                 ON CONFLICT (title_id) DO UPDATE SET
                   cards = CASE WHEN last_card = ?2 THEN cards
                                WHEN ?4 - {} > ?3 THEN 1
                                ELSE cards + 1 END,
                   last_card = ?2,
                   last_lane = ?2",
                day_of("last_card")
            ))?;
            for (_, title_id) in cards {
                card.execute(params![title_id, session, window, day])?;
            }
            let mut shown = self.conn.prepare_cached(&format!(
                "INSERT INTO tonight_exposure (title_id, lanes, last_lane) VALUES (?1, 1, ?2)
                 ON CONFLICT (title_id) DO UPDATE SET
                   lanes = CASE WHEN last_lane = ?2 THEN lanes
                                WHEN ?4 - {} > ?3 THEN 1
                                ELSE lanes + 1 END,
                   last_lane = ?2",
                day_of("last_lane")
            ))?;
            for title_id in lane {
                shown.execute(params![title_id, session, window, day])?;
            }
        }
        tx.commit()?;
        Ok(())
    }

    /// One showing more against a title, as if it had been a card this
    /// session and been passed over: what losing a duel costs it, once per
    /// session however many duels it loses. The count weighs from the next
    /// session on, like a card's, and the title counts as on screen this
    /// session, which it was.
    pub fn tire_tonight(&self, title_id: i64, session: i64, window: i64) -> Result<(), IndexError> {
        let day = crate::index::tonight::session_day(session);
        self.conn
            .prepare_cached(&format!(
                "INSERT INTO tonight_exposure (title_id, cards, last_card, last_lane)
                 VALUES (?1, 1, ?2, ?2)
                 ON CONFLICT (title_id) DO UPDATE SET
                   cards = CASE WHEN last_card = ?2 THEN cards
                                WHEN ?4 - {} > ?3 THEN 1
                                ELSE cards + 1 END,
                   last_card = ?2,
                   last_lane = ?2",
                day_of("last_card")
            ))?
            .execute(params![title_id, session, window, day])?;
        Ok(())
    }

    /// The titles this session has shown as cards.
    pub fn tonight_shown(&self, session: i64) -> Result<HashSet<i64>, IndexError> {
        let mut stmt = self
            .conn
            .prepare_cached("SELECT title_id FROM tonight_shown WHERE evening = ?1")?;
        let rows = stmt.query_map(params![session], |r| r.get(0))?;
        Ok(rows.collect::<Result<_, _>>()?)
    }

    /// One launch, and the surface that proposed it: a stable key, and for a
    /// home row the kind of its reason. A launch answers the rows' fatigue, so
    /// the title's count of days shown goes with it.
    pub fn record_launch(
        &self,
        title_id: i64,
        at: i64,
        surface: &str,
        detail: &str,
    ) -> Result<(), IndexError> {
        // an unattributed launch of a title launched shortly before is the
        // player going on (the next episode, a reopen), not a choice
        self.conn
            .prepare_cached(
                "INSERT INTO launch (at, title_id, surface, detail)
                 SELECT ?1, ?2, ?3, ?4
                 WHERE ?3 <> 'other'
                    OR NOT EXISTS (SELECT 1 FROM launch WHERE title_id = ?2 AND at > ?1 - ?5)",
            )?
            .execute(params![at, title_id, surface, detail, LAUNCH_REPEAT_SECS])?;
        self.conn
            .prepare_cached("DELETE FROM row_exposure WHERE title_id = ?1")?
            .execute(params![title_id])?;
        Ok(())
    }

    /// The kinds of row offered on `day`, each once however often the home
    /// is drawn. What the stats can no longer reach goes with the write.
    pub fn record_row_kinds(&self, kinds: &[&str], day: i64) -> Result<(), IndexError> {
        // read first: the home is drawn many times a day, and a write for
        // nothing new is a write the read-only browse could not make
        let mut known = self
            .conn
            .prepare_cached("SELECT kind FROM row_kind_shown WHERE day = ?1")?;
        let counted = known
            .query_map(params![day], |r| r.get::<_, String>(0))?
            .collect::<Result<HashSet<String>, _>>()?;
        drop(known);
        if kinds.iter().all(|k| counted.contains(*k)) {
            return Ok(());
        }
        let tx = self.conn.unchecked_transaction()?;
        self.conn.execute(
            "DELETE FROM row_kind_shown WHERE day < ?1",
            params![day - crate::index::stats::STATS_REACH_DAYS],
        )?;
        let mut stmt = self
            .conn
            .prepare_cached("INSERT OR IGNORE INTO row_kind_shown (day, kind) VALUES (?1, ?2)")?;
        for kind in kinds {
            stmt.execute(params![day, kind])?;
        }
        drop(stmt);
        tx.commit()?;
        Ok(())
    }

    /// Records that the home named these people (tag kind and value), or these
    /// seeds (`rows::SEED_SUBJECT` and a title id), on a row today, once per
    /// day, and lets rest for `SUBJECT_REST_DAYS` whoever it has now named on
    /// `SUBJECT_TRIAL_DAYS` of the last fortnight with nothing of theirs
    /// played since the first of them.
    pub fn record_row_subjects(
        &self,
        subjects: &[(&str, &str)],
        day: i64,
    ) -> Result<(), IndexError> {
        // read first, as for the kinds: most browses of a day write nothing
        {
            let mut counted = self.conn.prepare_cached(
                "SELECT 1 FROM row_subject_shown WHERE kind = ?1 AND value = ?2 AND day = ?3",
            )?;
            let mut all = true;
            for (kind, value) in subjects {
                if !counted.exists(params![kind, value, day])? {
                    all = false;
                    break;
                }
            }
            if all {
                return Ok(());
            }
        }
        let tx = self.conn.unchecked_transaction()?;
        self.conn.execute(
            "DELETE FROM row_subject_shown WHERE day < ?1",
            params![day - SUBJECT_WINDOW_DAYS],
        )?;
        self.conn.execute(
            "DELETE FROM subject_rest WHERE until_day < ?1",
            params![day],
        )?;
        {
            let mut shown = self.conn.prepare_cached(
                "INSERT OR IGNORE INTO row_subject_shown (kind, value, day) VALUES (?1, ?2, ?3)",
            )?;
            let mut tried = self.conn.prepare_cached(
                "SELECT COUNT(*), MIN(day) FROM row_subject_shown
                 WHERE kind = ?1 AND value = ?2 AND day > ?3",
            )?;
            // a seed has no titles of its own: a launch off any "because you
            // watched" row keeps every seed awake
            let mut played = self.conn.prepare_cached(
                "SELECT 1 FROM title_tags g
                 CROSS JOIN files f ON f.title_id = g.title_id
                 CROSS JOIN watch_state w ON w.file_id = f.id
                 WHERE g.kind = ?1 AND g.value = ?2 AND w.updated_at >= ?3
                 UNION ALL
                 SELECT 1 FROM launch
                 WHERE ?1 = 'seed' AND surface = 'row' AND detail = 'because_you_watched'
                   AND at >= ?3",
            )?;
            let mut rest = self.conn.prepare_cached(
                "INSERT OR REPLACE INTO subject_rest (kind, value, until_day) VALUES (?1, ?2, ?3)",
            )?;
            let mut forget = self
                .conn
                .prepare_cached("DELETE FROM row_subject_shown WHERE kind = ?1 AND value = ?2")?;
            for (kind, value) in subjects {
                shown.execute(params![kind, value, day])?;
                let (days, first): (u32, i64) = tried
                    .query_row(params![kind, value, day - SUBJECT_WINDOW_DAYS], |r| {
                        Ok((r.get(0)?, r.get::<_, Option<i64>>(1)?.unwrap_or(day)))
                    })?;
                if days >= SUBJECT_TRIAL_DAYS
                    && !played.exists(params![kind, value, first * 86_400])?
                {
                    rest.execute(params![kind, value, day + SUBJECT_REST_DAYS])?;
                    forget.execute(params![kind, value])?;
                }
            }
        }
        tx.commit()?;
        Ok(())
    }

    /// The people resting on `day`, as (tag kind, value).
    pub fn rested_subjects(&self, day: i64) -> Result<HashSet<(String, String)>, IndexError> {
        let mut stmt = self
            .conn
            .prepare_cached("SELECT kind, value FROM subject_rest WHERE until_day >= ?1")?;
        let rows = stmt.query_map(params![day], |r| Ok((r.get(0)?, r.get(1)?)))?;
        Ok(rows.collect::<Result<_, _>>()?)
    }

    /// Since `from_day`, per kind of row: the days it was offered and the
    /// launches it led to.
    pub fn row_kind_record(
        &self,
        from_day: i64,
    ) -> Result<HashMap<String, (u32, u32)>, IndexError> {
        let mut out: HashMap<String, (u32, u32)> = HashMap::new();
        let mut shown = self.conn.prepare_cached(
            "SELECT kind, COUNT(*) FROM row_kind_shown WHERE day >= ?1 GROUP BY kind",
        )?;
        for row in shown.query_map(params![from_day], |r| {
            Ok((r.get::<_, String>(0)?, r.get::<_, u32>(1)?))
        })? {
            let (kind, days) = row?;
            out.entry(kind).or_default().0 = days;
        }
        let mut launched = self.conn.prepare_cached(
            "SELECT detail, COUNT(*) FROM launch WHERE surface = 'row' AND at >= ?1 GROUP BY detail",
        )?;
        for row in launched.query_map(params![from_day * 86_400], |r| {
            Ok((r.get::<_, String>(0)?, r.get::<_, u32>(1)?))
        })? {
            let (kind, launches) = row?;
            out.entry(kind).or_default().1 = launches;
        }
        Ok(out)
    }

    /// The titles that are a filmed stage show rather than a film.
    pub fn stage_shows(&self) -> Result<HashSet<i64>, IndexError> {
        let mut stmt = self
            .conn
            .prepare_cached("SELECT title_id FROM stage_show")?;
        let ids = stmt.query_map([], |r| r.get(0))?;
        Ok(ids.collect::<Result<HashSet<i64>, _>>()?)
    }

    /// One opening of the home. What the stats can no longer reach goes with
    /// the write, so the table never outgrows the longest window.
    pub fn record_home_open(&self, at: i64) -> Result<(), IndexError> {
        let tx = self.conn.unchecked_transaction()?;
        self.conn.execute(
            "DELETE FROM home_open WHERE at < ?1",
            params![at - crate::index::stats::STATS_REACH_DAYS * 86_400],
        )?;
        self.conn
            .execute("INSERT INTO home_open (at) VALUES (?1)", params![at])?;
        tx.commit()?;
        Ok(())
    }

    /// Every title the home already shows above its rows: what the session's
    /// lane has shown so far, and the watchlist the queue carries. No session
    /// is a time of day with no trio, and so no lane.
    pub fn on_home(&self, session: Option<i64>) -> Result<HashSet<i64>, IndexError> {
        let mut stmt = self.conn.prepare_cached(
            "SELECT title_id FROM tonight_exposure WHERE last_lane = ?1
             UNION SELECT title_id FROM watchlist",
        )?;
        let rows = stmt.query_map(params![session], |r| r.get(0))?;
        Ok(rows.collect::<Result<_, _>>()?)
    }

    /// How many refusals fall inside one span of time.
    pub fn deferrals_between(&self, from: i64, to: i64) -> Result<u32, IndexError> {
        let mut stmt = self.conn.prepare_cached(
            "SELECT COUNT(*) FROM tonight_deferred WHERE deferred_at >= ?1 AND deferred_at < ?2",
        )?;
        Ok(stmt.query_row(params![from, to], |r| r.get(0))?)
    }

    pub fn defer_tonight(&self, title_id: i64, now: i64) -> Result<(), IndexError> {
        let tx = self.conn.unchecked_transaction()?;
        self.conn.execute(
            "INSERT INTO tonight_deferred (title_id, deferred_at) VALUES (?1, ?2)
             ON CONFLICT(title_id) DO UPDATE SET deferred_at = excluded.deferred_at",
            params![title_id, now],
        )?;
        self.conn.execute(
            "DELETE FROM tonight_pick WHERE title_id = ?1",
            params![title_id],
        )?;
        self.conn.execute(
            "INSERT INTO taste_event (at, kind, title_id) VALUES (?1, ?2, ?3)",
            params![now, TASTE_DEFERRED, title_id],
        )?;
        tx.commit()?;
        Ok(())
    }

    /// Vectorised titles whose neighbours in `similar_semantic` are missing or
    /// stale: never computed, computed by another model, or computed before
    /// the vector that stands now. Oldest title id first, the same order
    /// `titles_needing_embedding` walks in, so a sweep stopped mid-way and
    /// resumed does not skip or repeat a title.
    ///
    /// A title with no vector (or an empty one: the model had no word for it)
    /// is not owed a look here either; there is nothing to compare it against.
    pub fn titles_needing_semantic(
        &self,
        model_version: i64,
        limit: u32,
    ) -> Result<Vec<i64>, IndexError> {
        let mut stmt = self.conn.prepare_cached(
            "SELECT e.title_id FROM embeddings e
             LEFT JOIN semantic_computed c ON c.title_id = e.title_id
             WHERE e.model_version = ?1 AND LENGTH(e.vector) > 0
               AND (c.title_id IS NULL OR c.model_version <> ?1 OR c.computed_at < e.computed_at)
             ORDER BY e.title_id LIMIT ?2",
        )?;
        let rows = stmt.query_map(params![model_version, limit], |r| r.get(0))?;
        Ok(rows.collect::<Result<Vec<_>, _>>()?)
    }

    /// Replaces the given titles' own rows in `similar_semantic` and records
    /// each as computed against `model_version`, in one transaction. Titles
    /// outside `links` are untouched, which is what makes a sweep resumable:
    /// unlike a whole-table replace, a batch banked here stays banked whether
    /// or not the next one ever runs. The sentinel row (id 0, which no title
    /// carries) records that a title was searched and nothing passed the
    /// similarity floor, so it reads the same as "computed, no neighbours"
    /// rather than "never looked at".
    pub fn upsert_semantic(
        &self,
        links: &[(i64, Vec<(i64, i32)>)],
        model_version: i64,
        now: i64,
    ) -> Result<(), IndexError> {
        let tx = self.conn.unchecked_transaction()?;
        {
            let mut del = self
                .conn
                .prepare_cached("DELETE FROM similar_semantic WHERE title_id = ?1")?;
            let mut ins = self.conn.prepare_cached(
                "INSERT INTO similar_semantic (title_id, similar_title_id, rank, score)
                 VALUES (?1, ?2, ?3, ?4)",
            )?;
            let mut mark = self.conn.prepare_cached(
                "INSERT INTO semantic_computed (title_id, model_version, computed_at)
                 VALUES (?1, ?2, ?3)
                 ON CONFLICT (title_id) DO UPDATE SET
                   model_version = excluded.model_version, computed_at = excluded.computed_at",
            )?;
            for (title_id, near) in links {
                del.execute(params![title_id])?;
                if near.is_empty() {
                    ins.execute(params![title_id, 0, SIMILAR_SENTINEL_RANK, 0])?;
                } else {
                    for (rank, (similar, score)) in near.iter().enumerate() {
                        ins.execute(params![title_id, similar, rank as i64, score])?;
                    }
                }
                mark.execute(params![title_id, model_version, now])?;
            }
        }
        tx.commit()?;
        Ok(())
    }

    /// Drops every semantic link, so the rows are the ones TMDB and the genre
    /// counts give on their own. Read first: a build with nothing pinned runs
    /// this on every launch and has nothing to drop on all but the first.
    pub fn clear_semantic(&self) -> Result<(), IndexError> {
        let any: bool =
            self.conn
                .query_row("SELECT EXISTS (SELECT 1 FROM similar_semantic)", [], |r| {
                    r.get(0)
                })?;
        if any {
            self.conn.execute("DELETE FROM similar_semantic", [])?;
        }
        Ok(())
    }

    pub(crate) fn conn(&self) -> &Connection {
        &self.conn
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::index::MediaKind;

    fn record(db: &Db, path: &str, gen: i64) -> FileRecord {
        let title_id = db
            .upsert_title(MediaKind::Movie, "Dune", Some(2021))
            .unwrap();
        FileRecord {
            source_id: "s1".into(),
            dir: "Movies".into(),
            path: path.into(),
            size: 10,
            mtime: 1000,
            seen_gen: gen,
            title_id,
            season: None,
            episode: None,
            rating_key: None,
            media: FileMedia::default(),
        }
    }

    /// The artwork cache is filed under the title id, so an id must never
    /// name a second title, nor a file id a second file.
    #[test]
    fn a_deleted_title_and_its_file_never_give_their_ids_away() {
        let db = Db::open_in_memory().unwrap();
        let gone_file = db.upsert_file(&record(&db, "Movies/Dune.mkv", 1)).unwrap();
        let gone = db
            .upsert_title(MediaKind::Movie, "Dune", Some(2021))
            .unwrap();
        assert_eq!(db.delete_files_not_seen("s1", 2).unwrap(), 1);
        assert_eq!(db.prune_orphan_titles().unwrap(), 1);

        let next = db
            .upsert_title(MediaKind::Movie, "Alien", Some(1979))
            .unwrap();
        let next_file = db
            .upsert_file(&record_for("Movies/Alien.mkv", next))
            .unwrap();
        assert!(next > gone, "{next} reuses {gone}");
        assert!(next_file > gone_file, "{next_file} reuses {gone_file}");
    }

    /// Replaying an opinion the index already holds writes nothing.
    #[test]
    fn a_replayed_verdict_rewrites_no_row() {
        let db = Db::open_in_memory().unwrap();
        let title = db
            .upsert_title(MediaKind::Movie, "Dune", Some(2021))
            .unwrap();
        db.set_verdict(title, Some(Verdict::Loved), 100).unwrap();
        db.set_verdict(title, Some(Verdict::Loved), 100).unwrap();
        assert_eq!(db.conn().changes(), 0);
        db.set_verdict(title, Some(Verdict::Loved), 200).unwrap();
        assert_eq!(db.conn().changes(), 1);
    }

    /// A file of `title_id`, on the source every test uses.
    fn record_for(path: &str, title_id: i64) -> FileRecord {
        FileRecord {
            source_id: "s1".into(),
            dir: "Movies".into(),
            path: path.into(),
            size: 1,
            mtime: 0,
            seen_gen: 1,
            title_id,
            season: None,
            episode: None,
            rating_key: None,
            media: FileMedia::default(),
        }
    }

    /// One show of three episodes, inserted out of air order so a query that
    /// walks file ids instead of season and episode numbers fails here.
    /// Returns the title id and the file ids of S01E01, S01E02 and S02E01.
    fn show(db: &Db) -> (i64, [i64; 3]) {
        let title_id = db.upsert_title(MediaKind::Show, "Berserk", None).unwrap();
        let mut ids = [0i64; 3];
        for (slot, season, episode) in [(2usize, 2u16, 1u16), (1, 1, 2), (0, 1, 1)] {
            let path = format!("Shows/Berserk S{season:02}E{episode:02}.mkv");
            db.upsert_file(&FileRecord {
                source_id: "s1".into(),
                dir: "Shows".into(),
                path: path.clone(),
                size: 1,
                mtime: 0,
                seen_gen: 1,
                title_id,
                season: Some(season),
                episode: Some(episode),
                rating_key: None,
                // a source that answers for the media answers for the runtime
                // with it, which is what a list labels an episode from
                media: FileMedia {
                    duration_secs: 1500.0,
                    ..FileMedia::default()
                },
            })
            .unwrap();
            ids[slot] = db.file_id("s1", &path).unwrap().unwrap();
        }
        (title_id, ids)
    }

    fn left_running(db: &Db, file_id: i64, position: f64, at: i64) {
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

    #[test]
    fn the_next_episode_follows_air_order_not_file_ids() {
        let db = Db::open_in_memory().unwrap();
        let (title_id, ids) = show(&db);
        let second = db.next_episode(ids[0]).unwrap().expect("S01E02 follows");
        assert_eq!(second.file_id, ids[1]);
        assert_eq!(second.title_id, title_id);
        assert_eq!(second.name, "Berserk");
        assert_eq!((second.season, second.episode), (Some(1), Some(2)));
        // across the season break, and then nothing
        assert_eq!(db.next_episode(ids[1]).unwrap().unwrap().file_id, ids[2]);
        assert_eq!(db.next_episode(ids[2]).unwrap(), None);
        // an id no row has is not an error
        assert_eq!(db.next_episode(9999).unwrap(), None);
    }

    #[test]
    fn a_seen_episode_is_still_what_comes_next() {
        let db = Db::open_in_memory().unwrap();
        let (_, ids) = show(&db);
        db.set_watched(ids[1], true, 100).unwrap();
        // sticky watched must not make a rewatch skip the middle of the story
        let second = db.next_episode(ids[0]).unwrap().unwrap();
        assert_eq!(second.file_id, ids[1]);
        assert!(second.watched);
    }

    #[test]
    fn up_next_is_the_episode_left_running() {
        let db = Db::open_in_memory().unwrap();
        let (title_id, ids) = show(&db);
        db.set_watched(ids[0], true, 100).unwrap();
        left_running(&db, ids[2], 600.0, 200);
        let up = db.up_next(title_id).unwrap().unwrap();
        assert_eq!(up.file_id, ids[2]);
        assert_eq!(up.position_secs, 600.0);
        assert_eq!(up.duration_secs, 7000.0);
        // two in progress: the one touched last wins
        left_running(&db, ids[1], 300.0, 300);
        assert_eq!(db.up_next(title_id).unwrap().unwrap().file_id, ids[1]);
    }

    #[test]
    fn two_episodes_tied_at_the_same_moment_can_split_from_title_watch() {
        // a batch sync writes both episodes with the same updated_at: title_watch
        // keeps the lowest file id on a tie, up_next keeps the lowest season and
        // episode, and a show recorded out of air order makes those two answers
        // name different files. up_next's own pair must still describe its own
        // file, not title_watch's.
        let db = Db::open_in_memory().unwrap();
        let (title_id, ids) = show(&db);
        // ids[2] (S02E01) was inserted first and so carries the lowest file id;
        // ids[1] (S01E02) carries the earlier season and episode
        left_running(&db, ids[2], 900.0, 500);
        left_running(&db, ids[1], 300.0, 500);

        let watch = db.title_watch(title_id).unwrap();
        let up = db.up_next(title_id).unwrap().unwrap();
        assert_eq!(watch.resume.unwrap().file_id, ids[2]);
        assert_eq!(up.file_id, ids[1]);
        assert_eq!(up.position_secs, 300.0);
        assert_eq!(up.duration_secs, 7000.0);
    }

    #[test]
    fn up_next_is_the_first_unseen_episode_when_nothing_is_running() {
        let db = Db::open_in_memory().unwrap();
        let (title_id, ids) = show(&db);
        assert_eq!(db.up_next(title_id).unwrap().unwrap().file_id, ids[0]);
        db.set_watched(ids[0], true, 100).unwrap();
        assert_eq!(db.up_next(title_id).unwrap().unwrap().file_id, ids[1]);
    }

    #[test]
    fn a_show_watched_through_offers_its_first_episode_again() {
        let db = Db::open_in_memory().unwrap();
        let (title_id, ids) = show(&db);
        for id in ids {
            db.set_watched(id, true, 100).unwrap();
        }
        // watched is sticky, so the last band is what keeps a rewatch possible
        let up = db.up_next(title_id).unwrap().unwrap();
        assert_eq!(up.file_id, ids[0]);
        assert!(up.watched);
        assert_eq!(up.position_secs, 0.0);
        // and a title nothing holds a file for answers nothing
        let empty = db.upsert_title(MediaKind::Show, "Nothing", None).unwrap();
        assert_eq!(db.up_next(empty).unwrap(), None);
    }

    #[test]
    fn up_next_offers_the_episode_being_watched_again() {
        let db = Db::open_in_memory().unwrap();
        let (title_id, ids) = show(&db);
        // two episodes seen, the third never, and the viewer has gone back to
        // the second and left it running: seen and left running are different
        // questions, and a play button opens where the viewer is now rather
        // than skipping ahead to what they have not reached
        db.set_watched(ids[0], true, 100).unwrap();
        db.set_watched(ids[1], true, 100).unwrap();
        left_running(&db, ids[1], 900.0, 200);

        let up = db.up_next(title_id).unwrap().unwrap();
        assert_eq!(up.file_id, ids[1]);
        assert_eq!(up.position_secs, 900.0);
        assert!(up.watched, "the rewatch does not undo the finish");

        // and with the whole show through once, it is still that episode and
        // not the first one over again
        db.set_watched(ids[2], true, 100).unwrap();
        left_running(&db, ids[1], 900.0, 200);
        assert_eq!(db.up_next(title_id).unwrap().unwrap().file_id, ids[1]);
    }

    #[test]
    fn a_title_seen_before_resumes_where_it_is_now() {
        let db = Db::open_in_memory().unwrap();
        let (title_id, ids) = show(&db);
        db.set_watched(ids[1], true, 100).unwrap();
        left_running(&db, ids[1], 900.0, 200);

        let watch = db.title_watch(title_id).unwrap();
        assert_eq!(watch.watched_files, 1, "the flag counts the past");
        assert_eq!(watch.resume.unwrap().file_id, ids[1]);

        // and the same file played on to its end is a finish, not a place to
        // carry on from: nothing clears the position locally, so the rule has
        // to hold it out of the resume
        left_running(&db, ids[1], 6500.0, 300);
        assert_eq!(db.title_watch(title_id).unwrap().resume, None);
    }

    #[test]
    fn the_two_forms_of_in_progress_agree() {
        let db = Db::open_in_memory().unwrap();
        let (_, ids) = show(&db);
        let sql = format!("SELECT {IN_PROGRESS} FROM watch_state w WHERE w.file_id = ?1");
        // never played, just started, halfway, either side of the 90% mark,
        // either side of the tail of a short file, and a runtime nobody knows
        for (pos, dur) in [
            (0.0, 3000.0),
            (1.0, 3000.0),
            (1500.0, 3000.0),
            (2700.0, 3000.0),
            (2701.0, 3000.0),
            (10.0, 45.0),
            (20.0, 45.0),
            (600.0, 0.0),
            (0.0, 0.0),
        ] {
            db.conn()
                .execute(
                    "INSERT INTO watch_state
                       (file_id, position_secs, duration_secs, watched, updated_at)
                     VALUES (?1, ?2, ?3, 0, 1)
                     ON CONFLICT (file_id) DO UPDATE SET
                       position_secs = excluded.position_secs,
                       duration_secs = excluded.duration_secs",
                    params![ids[0], pos, dur],
                )
                .unwrap();
            let in_sql: bool = db
                .conn()
                .query_row(&sql, params![ids[0]], |r| r.get(0))
                .unwrap();
            assert_eq!(in_sql, in_progress(pos, dur), "{pos} of {dur}");
        }
    }

    #[test]
    fn episodes_lists_a_show_in_air_order_regardless_of_file_id() {
        let db = Db::open_in_memory().unwrap();
        let (title_id, ids) = show(&db);
        left_running(&db, ids[1], 400.0, 10);

        let all = db.episodes(title_id).unwrap();
        assert_eq!(
            all.iter().map(|e| e.file_id).collect::<Vec<_>>(),
            vec![ids[0], ids[1], ids[2]]
        );
        assert_eq!(
            all.iter()
                .map(|e| (e.season, e.episode))
                .collect::<Vec<_>>(),
            vec![(Some(1), Some(1)), (Some(1), Some(2)), (Some(2), Some(1))]
        );
        // the one left running carries its own position; the others carry none
        assert_eq!(all[1].position_secs, 400.0);
        assert_eq!(all[0].position_secs, 0.0);

        // a title with no files of its own answers with none, not an error
        let empty = db.upsert_title(MediaKind::Show, "Nothing", None).unwrap();
        assert!(db.episodes(empty).unwrap().is_empty());
    }

    #[test]
    fn an_episode_carries_its_own_title_and_its_shows_name_at_once() {
        let db = Db::open_in_memory().unwrap();
        let (title_id, ids) = show(&db);
        db.upsert_episode_meta(
            ids[0],
            &EpisodeMeta {
                title: "L'Epee du Berserk".into(),
                summary: "Guts arrive a Midland.".into(),
                still_path: "/library/metadata/7/thumb/9".into(),
                ..EpisodeMeta::default()
            },
        )
        .unwrap();

        // named, and the server holds no frame for it: the ordinary shape of
        // this row, and the one an empty path has to answer for
        db.upsert_episode_meta(
            ids[1],
            &EpisodeMeta {
                title: "Le Guerrier Noir".into(),
                ..EpisodeMeta::default()
            },
        )
        .unwrap();

        let all = db.episodes(title_id).unwrap();
        assert_eq!(all[0].name, "Berserk");
        assert_eq!(all[0].title, "L'Epee du Berserk");
        assert_eq!(all[0].summary, "Guts arrive a Midland.");
        assert_eq!(all[1].title, "Le Guerrier Noir");
        // an episode nothing described reads as empty, not as absent
        assert_eq!(all[1].summary, "");
        assert_eq!(all[2].title, "");

        // the runtime is the file's own, not the watch row's: an episode never
        // played has no watch row at all, and is the one a list most needs to
        // put a runtime on
        assert_eq!(all[0].runtime_secs, 1500.0);
        assert_eq!(all[0].duration_secs, 0.0);

        // and the still is answered by the source that enumerated the file
        assert_eq!(
            db.still_source(ids[0]).unwrap(),
            Some(("s1".to_string(), "/library/metadata/7/thumb/9".to_string()))
        );
        // a stored empty path is nothing to fetch, and must not read as one
        assert_eq!(db.still_source(ids[1]).unwrap(), None);
        // and a file with no row of its own is the same answer
        assert_eq!(db.still_source(ids[2]).unwrap(), None);
    }

    #[test]
    fn a_second_writer_that_names_nothing_keeps_what_the_first_named() {
        let db = Db::open_in_memory().unwrap();
        let (title_id, ids) = show(&db);
        db.upsert_episode_meta(
            ids[0],
            &EpisodeMeta {
                title: "L'Epee du Berserk".into(),
                summary: "Guts arrive a Midland.".into(),
                still_path: "/library/metadata/7/thumb/9".into(),
                ..EpisodeMeta::default()
            },
        )
        .unwrap();
        db.upsert_episode_meta(ids[0], &EpisodeMeta::default())
            .unwrap();

        let all = db.episodes(title_id).unwrap();
        assert_eq!(all[0].title, "L'Epee du Berserk");
        assert_eq!(all[0].summary, "Guts arrive a Midland.");
        assert!(db.still_source(ids[0]).unwrap().is_some());
    }

    #[test]
    fn a_v21_cache_migrates_in_place_and_holds_no_episode_metadata_yet() {
        let tmp = tempfile::tempdir().unwrap();
        let path = tmp.path().join("index.sqlite");
        {
            let db = Db::open(&path).unwrap();
            let (_, ids) = show(&db);
            // a cache written before episode_meta existed: the file is put
            // back into the shape v21 left, columns included, so the open
            // below is the migration under test rather than a no-op
            db.conn()
                .execute_batch(
                    "ALTER TABLE episode_meta DROP COLUMN air_year;
                     DROP TABLE row_exposure;
                     ALTER TABLE metadata DROP COLUMN release_date;
                     DROP TRIGGER IF EXISTS episode_search_insert;
                     DROP TRIGGER IF EXISTS episode_search_update;
                     DROP TRIGGER IF EXISTS episode_search_delete;
                     DROP TABLE episode_search;
                     DROP TABLE row_kind_shown;
                     DROP TABLE row_subject_shown;
                     DROP TABLE tmdb_trending;
                     DROP TABLE subject_rest;
                     DROP TABLE taste_mute;
                     DROP TABLE guest_taste;
                     DROP TABLE guest_verdict;
                     DROP TABLE guest;
                     ALTER TABLE evening_state DROP COLUMN guest_id;
                     DROP TABLE title_tone;
                     DROP TABLE club_pick;
                     ALTER TABLE metadata DROP COLUMN audience_votes;
                     ALTER TABLE metadata DROP COLUMN critic_votes;
                     DROP TABLE tonight_exposure;
                     DROP TABLE launch;
                     DROP TABLE home_open;
                     DROP TABLE tonight_shown;
                     ALTER TABLE metadata DROP COLUMN keywords;
                     ALTER TABLE metadata DROP COLUMN keywords_at;
                     ALTER TABLE files DROP COLUMN audio_languages;
                     ALTER TABLE files DROP COLUMN subtitle_languages;
                     DROP TABLE taste_event;
                     DROP TABLE taste_facet_snapshot;
                     DROP TABLE evening_state;
                     ALTER TABLE watch_state DROP COLUMN plays;
                     ALTER TABLE metadata DROP COLUMN billed_at;
                     ALTER TABLE metadata DROP COLUMN cast_characters;
                     DROP TABLE watched_facet;
                     ALTER TABLE metadata DROP COLUMN trailer_key;
                     ALTER TABLE metadata DROP COLUMN trailer_checked_at;
                     DROP TABLE watchlist;
                     DROP TABLE episode_meta;
                     DROP TABLE taste_facet;
                     DROP TABLE discovery_pick;
                     DROP TABLE tonight_pick;
                     DROP TABLE tonight_deferred;
                     DROP TABLE title_taste;
                     DROP TABLE anchor_vector;
                     DROP TABLE seasonal_pick;
                     DROP TABLE thread_item;
                     DROP TABLE thread;
                     DROP TABLE tonight_queued;
                     DROP TABLE setting;
                     ALTER TABLE metadata DROP COLUMN critic_rating;
                     ALTER TABLE metadata DROP COLUMN critic_source;
                     ALTER TABLE metadata DROP COLUMN audience_rating;
                     ALTER TABLE metadata DROP COLUMN audience_source;
                     ALTER TABLE metadata ADD COLUMN rating REAL NOT NULL DEFAULT 0;",
                )
                .unwrap();
            // v51's column, which none of these older shapes had
            db.conn()
                .execute_batch(
                    "DROP INDEX idx_people_last_word; ALTER TABLE people DROP COLUMN last_word;",
                )
                .unwrap();
            db.conn().pragma_update(None, "user_version", 21).unwrap();
            assert!(ids[0] > 0);
        }

        let db = Db::open(&path).unwrap();
        let version: i64 = db
            .conn()
            .query_row("PRAGMA user_version", [], |r| r.get(0))
            .unwrap();
        assert_eq!(version, SCHEMA_VERSION);

        // every episode a v21 cache holds is still there and simply carries
        // nothing of its own: the migration asks no source for anything
        let title_id = db.upsert_title(MediaKind::Show, "Berserk", None).unwrap();
        let all = db.episodes(title_id).unwrap();
        assert_eq!(all.len(), 3);
        assert!(all
            .iter()
            .all(|e| e.title.is_empty() && e.summary.is_empty()));
        assert_eq!(db.still_source(all[0].file_id).unwrap(), None);
    }

    #[test]
    fn a_rewatch_counts_a_second_play_where_the_watched_flag_cannot() {
        let db = Db::open_in_memory().unwrap();
        let title_id = db.upsert_title(MediaKind::Movie, "Heat", None).unwrap();
        db.upsert_file(&record_for("Movies/Heat.mkv", title_id))
            .unwrap();
        let file_id = db.file_id("s1", "Movies/Heat.mkv").unwrap().unwrap();
        let report = |pos: f64| {
            db.upsert_watch_state(
                &WatchRecord {
                    file_id,
                    position_secs: pos,
                    duration_secs: 6000.0,
                    watched: false,
                    plays: 0,
                    updated_at: 1,
                },
                WatchAuthority::Report,
            )
            .unwrap();
        };

        report(60.0);
        assert_eq!(plays_at(&db, file_id), 0);

        report(5500.0);
        assert_eq!(plays_at(&db, file_id), 1);

        // reports past the threshold do not count the same pass again
        report(5800.0);
        report(5999.0);
        assert_eq!(plays_at(&db, file_id), 1);

        // back to the beginning, then across again. The flag never moves
        // here, which is the whole reason it cannot be what counts.
        report(30.0);
        report(5500.0);
        assert_eq!(plays_at(&db, file_id), 2);
        assert!(db.watch_state(file_id).unwrap().unwrap().watched);
    }

    #[test]
    fn a_server_that_answers_for_a_file_answers_for_its_count_too() {
        let db = Db::open_in_memory().unwrap();
        let title_id = db.upsert_title(MediaKind::Movie, "Heat", None).unwrap();
        db.upsert_file(&record_for("Movies/Heat.mkv", title_id))
            .unwrap();
        let file_id = db.file_id("s1", "Movies/Heat.mkv").unwrap().unwrap();
        let sync = |plays: u32| {
            db.upsert_watch_state(
                &WatchRecord {
                    file_id,
                    position_secs: 0.0,
                    duration_secs: 6000.0,
                    watched: true,
                    plays,
                    updated_at: 1,
                },
                WatchAuthority::Owner,
            )
            .unwrap();
        };

        sync(3);
        assert_eq!(plays_at(&db, file_id), 3);
        // a later sync that knows less never takes a play away
        sync(1);
        assert_eq!(plays_at(&db, file_id), 3);
    }

    /// The play count of one file, read straight off the column.
    fn plays_at(db: &Db, file_id: i64) -> u32 {
        db.conn()
            .query_row(
                "SELECT plays FROM watch_state WHERE file_id = ?1",
                params![file_id],
                |r| r.get(0),
            )
            .unwrap()
    }

    #[test]
    fn a_play_across_the_line_enters_the_ledger_once() {
        let db = Db::open_in_memory().unwrap();
        let title_id = db.upsert_title(MediaKind::Movie, "Heat", None).unwrap();
        db.upsert_file(&record_for("Movies/Heat.mkv", title_id))
            .unwrap();
        let file_id = db.file_id("s1", "Movies/Heat.mkv").unwrap().unwrap();

        left_running(&db, file_id, 600.0, 100);
        assert!(db.taste_ledger(10).unwrap().is_empty());

        left_running(&db, file_id, 6500.0, 200);
        assert_eq!(
            db.taste_ledger(10).unwrap(),
            vec![TasteEvent {
                at: 200,
                kind: TASTE_FINISHED,
                title: "Heat".into()
            }]
        );

        // the credits roll on, and the line is not crossed a second time
        left_running(&db, file_id, 6900.0, 300);
        assert_eq!(db.taste_ledger(10).unwrap().len(), 1);
    }

    #[test]
    fn a_verdict_taken_back_says_nothing_to_the_ledger() {
        let db = Db::open_in_memory().unwrap();
        let title_id = db.upsert_title(MediaKind::Movie, "Heat", None).unwrap();
        db.set_verdict(title_id, Some(Verdict::Loved), 100).unwrap();
        // the same opinion restated is the durable copy being replayed, not a
        // second press
        db.set_verdict(title_id, Some(Verdict::Loved), 150).unwrap();
        db.set_verdict(title_id, None, 200).unwrap();

        let ledger = db.taste_ledger(10).unwrap();
        assert_eq!(ledger.len(), 1);
        assert_eq!((ledger[0].at, ledger[0].kind), (100, TASTE_VERDICT));
    }

    /// One pass holding a single taste, stamped with the instant it ran.
    fn one_facet_pass(leader: i64, at: i64, weight: f32) -> TastePassOutput {
        TastePassOutput {
            facets: vec![TasteFacetMeta {
                facet: 0,
                weight,
                leader,
                cos_to_top: 1.0,
            }],
            now: at,
            ..Default::default()
        }
    }

    #[test]
    fn a_pass_keeps_what_the_one_before_it_weighed() {
        let db = Db::open_in_memory().unwrap();
        let leader = db
            .upsert_title(MediaKind::Movie, "Dune", Some(2021))
            .unwrap();
        db.replace_taste(&one_facet_pass(leader, 1_000, 2.0))
            .unwrap();
        db.replace_taste(&one_facet_pass(leader, 2_000, 3.0))
            .unwrap();

        let shifts = db.taste_facet_shifts(1_500).unwrap();
        assert_eq!(shifts.len(), 1);
        assert_eq!(shifts[0].weight, 3.0);
        assert_eq!(shifts[0].was, Some(2.0));
    }

    #[test]
    fn a_taste_with_no_snapshot_old_enough_has_no_shift() {
        let db = Db::open_in_memory().unwrap();
        let leader = db
            .upsert_title(MediaKind::Movie, "Dune", Some(2021))
            .unwrap();
        db.replace_taste(&one_facet_pass(leader, 2_000, 3.0))
            .unwrap();

        // nothing to compare against is not the same answer as no movement
        assert_eq!(db.taste_facet_shifts(1_500).unwrap()[0].was, None);
    }

    #[test]
    fn a_v30_cache_credits_a_watched_row_with_the_play_it_must_have_had() {
        let tmp = tempfile::tempdir().unwrap();
        let path = tmp.path().join("index.sqlite");
        let (seen, unseen) = {
            let db = Db::open(&path).unwrap();
            let heat = db.upsert_title(MediaKind::Movie, "Heat", None).unwrap();
            let collateral = db
                .upsert_title(MediaKind::Movie, "Collateral", None)
                .unwrap();
            db.upsert_file(&record_for("Movies/Heat.mkv", heat))
                .unwrap();
            db.upsert_file(&record_for("Movies/Collateral.mkv", collateral))
                .unwrap();
            let seen = db.file_id("s1", "Movies/Heat.mkv").unwrap().unwrap();
            let unseen = db.file_id("s1", "Movies/Collateral.mkv").unwrap().unwrap();
            // the shape v30 left: rows that remember a flag and no count
            db.conn()
                .execute_batch(&format!(
                    "INSERT INTO watch_state
                       (file_id, position_secs, duration_secs, watched, updated_at)
                     VALUES ({seen}, 5900.0, 6000.0, 1, 100),
                            ({unseen}, 600.0, 6000.0, 0, 100);
                     DROP TABLE row_exposure;
                     ALTER TABLE metadata DROP COLUMN release_date;
                     DROP TRIGGER IF EXISTS episode_search_insert;
                     DROP TRIGGER IF EXISTS episode_search_update;
                     DROP TRIGGER IF EXISTS episode_search_delete;
                     DROP TABLE episode_search;
                     DROP TABLE row_kind_shown;
                     DROP TABLE row_subject_shown;
                     DROP TABLE tmdb_trending;
                     DROP TABLE subject_rest;
                     ALTER TABLE tonight_pick DROP COLUMN at;
                     DROP TABLE taste_mute;
                     DROP TABLE guest_taste;
                     DROP TABLE guest_verdict;
                     DROP TABLE guest;
                     ALTER TABLE evening_state DROP COLUMN guest_id;
                     DROP TABLE title_tone;
                     DROP TABLE club_pick;
                     ALTER TABLE metadata DROP COLUMN audience_votes;
                     ALTER TABLE metadata DROP COLUMN critic_votes;
                     DROP TABLE tonight_exposure;
                     DROP TABLE launch;
                     DROP TABLE home_open;
                     DROP TABLE tonight_shown;
                     ALTER TABLE metadata DROP COLUMN keywords;
                     ALTER TABLE metadata DROP COLUMN keywords_at;
                     ALTER TABLE files DROP COLUMN audio_languages;
                     ALTER TABLE files DROP COLUMN subtitle_languages;
                     DROP TABLE taste_event;
                     DROP TABLE taste_facet_snapshot;
                     DROP TABLE evening_state;
                     ALTER TABLE watch_state DROP COLUMN plays;"
                ))
                .unwrap();
            // v51's column, which none of these older shapes had
            db.conn()
                .execute_batch(
                    "DROP INDEX idx_people_last_word; ALTER TABLE people DROP COLUMN last_word;",
                )
                .unwrap();
            db.conn().pragma_update(None, "user_version", 30).unwrap();
            (seen, unseen)
        };

        let db = Db::open(&path).unwrap();
        let version: i64 = db
            .conn()
            .query_row("PRAGMA user_version", [], |r| r.get(0))
            .unwrap();
        assert_eq!(version, SCHEMA_VERSION);
        assert_eq!(plays_at(&db, seen), 1);
        assert_eq!(plays_at(&db, unseen), 0);
    }

    /// v38 adds the mood and the vote counts, and asks nothing of what is
    /// stored: a score already on disk keeps an unknown count until its title
    /// is described again, and a said evening keeps what it said.
    #[test]
    fn a_v37_cache_keeps_its_scores_with_no_count_and_its_evening_with_no_mood() {
        let tmp = tempfile::tempdir().unwrap();
        let path = tmp.path().join("index.sqlite");
        let title_id = {
            let db = Db::open(&path).unwrap();
            let id = db.upsert_title(MediaKind::Movie, "Heat", None).unwrap();
            db.conn()
                .execute_batch(&format!(
                    "ALTER TABLE metadata DROP COLUMN release_date;
                     DROP TRIGGER IF EXISTS episode_search_insert;
                     DROP TRIGGER IF EXISTS episode_search_update;
                     DROP TRIGGER IF EXISTS episode_search_delete;
                     DROP TABLE episode_search;
                     DROP TABLE row_kind_shown;
                     DROP TABLE row_subject_shown;
                     DROP TABLE tmdb_trending;
                     DROP TABLE subject_rest;
                     ALTER TABLE tonight_pick DROP COLUMN at;
                     DROP TABLE taste_mute;
                     DROP TABLE guest_taste;
                     DROP TABLE guest_verdict;
                     DROP TABLE guest;
                     ALTER TABLE evening_state DROP COLUMN guest_id;
                     DROP TABLE title_tone;
                     DROP TABLE club_pick;
                     ALTER TABLE metadata DROP COLUMN audience_votes;
                     ALTER TABLE metadata DROP COLUMN critic_votes;
                     ALTER TABLE evening_state DROP COLUMN mood;
                     INSERT INTO metadata (title_id, source, fetched_at, audience_rating,
                                           audience_source)
                     VALUES ({id}, 'tmdb', 0, 8.3, 'themoviedb');
                     INSERT INTO evening_state (evening, together, window_min)
                     VALUES (20685, 1, NULL);"
                ))
                .unwrap();
            // v51's column, which none of these older shapes had
            db.conn()
                .execute_batch(
                    "DROP INDEX idx_people_last_word; ALTER TABLE people DROP COLUMN last_word;",
                )
                .unwrap();
            db.conn().pragma_update(None, "user_version", 37).unwrap();
            id
        };

        let db = Db::open(&path).unwrap();
        let audience = db.metadata(title_id).unwrap().unwrap().audience.unwrap();
        assert_eq!((audience.value, audience.votes), (8.3, None));
        let said = db.evening_state(20_685).unwrap();
        assert!(said.together);
        assert_eq!(said.mood, None);
    }

    #[test]
    fn a_v22_score_nobody_sourced_does_not_survive_the_migration() {
        let tmp = tempfile::tempdir().unwrap();
        let path = tmp.path().join("index.sqlite");
        let title_id;
        {
            let db = Db::open(&path).unwrap();
            title_id = db
                .upsert_title(MediaKind::Movie, "Dune", Some(2021))
                .unwrap();
            // the shape v22 left: one column, holding whichever of the two
            // scores that item's agent happened to carry
            db.conn()
                .execute_batch(
                    "ALTER TABLE episode_meta DROP COLUMN air_year;
                     DROP TABLE row_exposure;
                     ALTER TABLE metadata DROP COLUMN release_date;
                     DROP TRIGGER IF EXISTS episode_search_insert;
                     DROP TRIGGER IF EXISTS episode_search_update;
                     DROP TRIGGER IF EXISTS episode_search_delete;
                     DROP TABLE episode_search;
                     DROP TABLE row_kind_shown;
                     DROP TABLE row_subject_shown;
                     DROP TABLE tmdb_trending;
                     DROP TABLE subject_rest;
                     DROP TABLE taste_mute;
                     DROP TABLE guest_taste;
                     DROP TABLE guest_verdict;
                     DROP TABLE guest;
                     ALTER TABLE evening_state DROP COLUMN guest_id;
                     DROP TABLE title_tone;
                     DROP TABLE club_pick;
                     ALTER TABLE metadata DROP COLUMN audience_votes;
                     ALTER TABLE metadata DROP COLUMN critic_votes;
                     DROP TABLE tonight_exposure;
                     DROP TABLE launch;
                     DROP TABLE home_open;
                     DROP TABLE tonight_shown;
                     ALTER TABLE metadata DROP COLUMN keywords;
                     ALTER TABLE metadata DROP COLUMN keywords_at;
                     ALTER TABLE files DROP COLUMN audio_languages;
                     ALTER TABLE files DROP COLUMN subtitle_languages;
                     DROP TABLE taste_event;
                     DROP TABLE taste_facet_snapshot;
                     DROP TABLE evening_state;
                     ALTER TABLE watch_state DROP COLUMN plays;
                     ALTER TABLE metadata DROP COLUMN billed_at;
                     ALTER TABLE metadata DROP COLUMN cast_characters;
                     DROP TABLE watched_facet;
                     ALTER TABLE metadata DROP COLUMN trailer_key;
                     ALTER TABLE metadata DROP COLUMN trailer_checked_at;
                     DROP TABLE watchlist;
                     DROP TABLE taste_facet;
                     DROP TABLE discovery_pick;
                     DROP TABLE tonight_pick;
                     DROP TABLE tonight_deferred;
                     DROP TABLE title_taste;
                     DROP TABLE anchor_vector;
                     DROP TABLE seasonal_pick;
                     DROP TABLE thread_item;
                     DROP TABLE thread;
                     DROP TABLE tonight_queued;
                     DROP TABLE setting;
                     ALTER TABLE metadata DROP COLUMN critic_rating;
                     ALTER TABLE metadata DROP COLUMN critic_source;
                     ALTER TABLE metadata DROP COLUMN audience_rating;
                     ALTER TABLE metadata DROP COLUMN audience_source;
                     ALTER TABLE metadata ADD COLUMN rating REAL NOT NULL DEFAULT 0;",
                )
                .unwrap();
            db.conn()
                .execute(
                    "INSERT INTO metadata (title_id, genres, source, fetched_at, rating)
                     VALUES (?1, 'Science-Fiction', 'plex', 1, 6.6)",
                    params![title_id],
                )
                .unwrap();
            db.conn()
                .execute(
                    "INSERT INTO dirs (source_id, path, mtime) VALUES ('plex1', '1', 1700000000)",
                    [],
                )
                .unwrap();
            // v51's column, which none of these older shapes had
            db.conn()
                .execute_batch(
                    "DROP INDEX idx_people_last_word; ALTER TABLE people DROP COLUMN last_word;",
                )
                .unwrap();
            db.conn().pragma_update(None, "user_version", 22).unwrap();
        }

        let db = Db::open(&path).unwrap();
        let row = db.metadata(title_id).unwrap().unwrap();
        // what the row describes is still there, and the number is not: 6.6 out
        // of what, judged by whom, is a question this file cannot answer, and
        // carrying it over would keep every screen asking it
        assert_eq!(row.genres, "Science-Fiction");
        assert_eq!(row.critics, None);
        assert_eq!(row.audience, None);
        // and the section is owed a full pull, since nothing on disk was ever
        // asked who measured anything
        let dirs: i64 = db
            .conn()
            .query_row("SELECT count(*) FROM dirs", [], |r| r.get(0))
            .unwrap();
        assert_eq!(dirs, 0);
    }

    #[test]
    fn an_episode_row_goes_when_its_file_does() {
        let db = Db::open_in_memory().unwrap();
        let (_, ids) = show(&db);
        db.upsert_episode_meta(
            ids[0],
            &EpisodeMeta {
                title: "L'Epee du Berserk".into(),
                ..EpisodeMeta::default()
            },
        )
        .unwrap();
        db.conn()
            .execute("DELETE FROM files WHERE id = ?1", params![ids[0]])
            .unwrap();
        let left: i64 = db
            .conn()
            .query_row("SELECT COUNT(*) FROM episode_meta", [], |r| r.get(0))
            .unwrap();
        assert_eq!(left, 0);
    }

    /// The stored similar ids of one title, in the order a reader sees them.
    fn ranked(db: &Db, tmdb_id: i64, kind: MediaKind) -> Vec<(i64, i64)> {
        db.conn()
            .prepare(
                "SELECT similar_tmdb_id, rank FROM tmdb_similar
                 WHERE kind = ?1 AND tmdb_id = ?2 ORDER BY rank",
            )
            .unwrap()
            .query_map(params![kind.as_str(), tmdb_id], |r| {
                Ok((r.get(0)?, r.get(1)?))
            })
            .unwrap()
            .collect::<Result<_, _>>()
            .unwrap()
    }

    #[test]
    fn a_corrupt_database_is_recreated_instead_of_bricking_startup() {
        let tmp = tempfile::tempdir().unwrap();
        let path = tmp.path().join("index.sqlite");
        std::fs::write(&path, b"this is not a database").unwrap();
        let db = Db::open(&path).unwrap();
        db.upsert_title(MediaKind::Movie, "Dune", Some(2021))
            .unwrap();
    }

    /// A real sqlite header followed by pages that fail sqlite's own
    /// consistency check, rather than bytes that never looked like a
    /// database at all: the classic shape of on-disk corruption.
    #[test]
    fn a_database_with_a_valid_header_but_corrupt_pages_is_recreated() {
        let tmp = tempfile::tempdir().unwrap();
        let path = tmp.path().join("index.sqlite");
        let mut bytes = b"SQLite format 3\0".to_vec();
        bytes.extend(std::iter::repeat_n(0xAAu8, 4096));
        std::fs::write(&path, &bytes).unwrap();
        let db = Db::open(&path).unwrap();
        db.upsert_title(MediaKind::Movie, "Dune", Some(2021))
            .unwrap();
    }

    /// A schema newer than this build understands is not corruption: an
    /// older build opening a newer file must leave it for the newer build to
    /// read, not run migrations meant for an older shape against it.
    #[test]
    fn a_database_from_a_newer_build_is_left_on_disk_untouched() {
        let tmp = tempfile::tempdir().unwrap();
        let path = tmp.path().join("index.sqlite");
        {
            let conn = Connection::open(&path).unwrap();
            conn.execute_batch(SCHEMA).unwrap();
            conn.pragma_update(None, "user_version", SCHEMA_VERSION + 1)
                .unwrap();
        }
        let before = std::fs::read(&path).unwrap();

        match Db::open(&path) {
            Err(IndexError::SchemaTooNew { found, supported }) => {
                assert_eq!(found, SCHEMA_VERSION + 1);
                assert_eq!(supported, SCHEMA_VERSION);
            }
            Err(e) => panic!("expected SchemaTooNew, got {e}"),
            Ok(_) => panic!("expected an error, a newer schema opened cleanly"),
        }
        assert_eq!(std::fs::read(&path).unwrap(), before, "file was modified");
    }

    /// A file that cannot be read - here, denied by permissions - is not
    /// corruption either: the bytes may well be fine, only unreachable right
    /// now, and deleting them would cost a library nothing about them ever
    /// proved unusable.
    #[test]
    fn an_unreadable_database_is_left_on_disk_and_fails_loudly() {
        use std::os::unix::fs::PermissionsExt;

        let tmp = tempfile::tempdir().unwrap();
        let path = tmp.path().join("index.sqlite");
        {
            let db = Db::open(&path).unwrap();
            db.upsert_title(MediaKind::Movie, "Dune", Some(2021))
                .unwrap();
        }
        let before = std::fs::read(&path).unwrap();

        let mut perms = std::fs::metadata(&path).unwrap().permissions();
        perms.set_mode(0o000);
        std::fs::set_permissions(&path, perms).unwrap();

        let result = Db::open(&path);

        // restored before any assertion can fail the test and skip cleanup
        let mut perms = std::fs::metadata(&path).unwrap().permissions();
        perms.set_mode(0o600);
        std::fs::set_permissions(&path, perms).unwrap();

        assert!(result.is_err(), "an unreadable file must fail loudly");
        assert_eq!(std::fs::read(&path).unwrap(), before, "file was modified");

        // the title written before the permission change is still there:
        // nothing was lost, only briefly unreachable
        let db = Db::open(&path).unwrap();
        assert_eq!(
            db.conn()
                .query_row("SELECT COUNT(*) FROM titles", [], |r| r.get::<_, i64>(0))
                .unwrap(),
            1
        );
    }

    /// The index lives in an OS-purgeable cache directory: a missing file is
    /// routine, not a sign anything went wrong, and must keep opening clean.
    #[test]
    fn a_missing_database_opens_clean_with_no_error() {
        let tmp = tempfile::tempdir().unwrap();
        let path = tmp.path().join("index.sqlite");
        assert!(!path.exists());
        let db = Db::open(&path).unwrap();
        db.upsert_title(MediaKind::Movie, "Dune", Some(2021))
            .unwrap();
    }

    /// The exact v1 schema, as a released build wrote it.
    const SCHEMA_V1: &str = "
CREATE TABLE titles (
  id INTEGER PRIMARY KEY,
  kind TEXT NOT NULL CHECK (kind IN ('movie','show')),
  name TEXT NOT NULL,
  year INTEGER NOT NULL DEFAULT 0,
  UNIQUE (kind, name, year)
);
CREATE INDEX idx_titles_name ON titles(name COLLATE NOCASE);
CREATE INDEX idx_titles_kind_name ON titles(kind, name COLLATE NOCASE, id);
CREATE TABLE files (
  id INTEGER PRIMARY KEY,
  source_id TEXT NOT NULL,
  dir TEXT NOT NULL,
  path TEXT NOT NULL,
  size INTEGER NOT NULL,
  mtime INTEGER NOT NULL,
  seen_gen INTEGER NOT NULL,
  title_id INTEGER NOT NULL REFERENCES titles(id),
  season INTEGER,
  episode INTEGER,
  UNIQUE (source_id, path)
);
CREATE INDEX idx_files_title ON files(title_id);
CREATE INDEX idx_files_dir ON files(source_id, dir);
CREATE TABLE dirs (
  source_id TEXT NOT NULL,
  path TEXT NOT NULL,
  mtime INTEGER NOT NULL,
  PRIMARY KEY (source_id, path)
);
";

    #[test]
    fn a_v1_cache_migrates_in_place_and_keeps_its_rows() {
        let tmp = tempfile::tempdir().unwrap();
        let path = tmp.path().join("index.sqlite");
        {
            let conn = Connection::open(&path).unwrap();
            conn.execute_batch(SCHEMA_V1).unwrap();
            conn.pragma_update(None, "user_version", 1).unwrap();
            conn.execute(
                "INSERT INTO titles (id, kind, name, year) VALUES (1, 'movie', 'Dune', 2021)",
                [],
            )
            .unwrap();
            conn.execute(
                "INSERT INTO files (source_id, dir, path, size, mtime, seen_gen, title_id)
                 VALUES ('s1', 'Movies', 'Movies/a.mkv', 10, 1000, 1, 1)",
                [],
            )
            .unwrap();
        }

        let db = Db::open(&path).unwrap();
        let version: i64 = db
            .conn()
            .query_row("PRAGMA user_version", [], |r| r.get(0))
            .unwrap();
        assert_eq!(version, SCHEMA_VERSION);
        // the scan did not have to start over
        let kept: i64 = db
            .conn()
            .query_row("SELECT COUNT(*) FROM files", [], |r| r.get(0))
            .unwrap();
        assert_eq!(kept, 1);
        let rating_key: Option<String> = db
            .conn()
            .query_row("SELECT rating_key FROM files", [], |r| r.get(0))
            .unwrap();
        assert_eq!(rating_key, None);
        db.upsert_metadata(&MetadataRecord {
            title_id: 1,
            tmdb_id: Some(438631),
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
            fetched_at: 5,
            critics: None,
            audience: None,
            release_date: None,
        })
        .unwrap();

        // reopening an already-migrated cache changes nothing
        drop(db);
        let again = Db::open(&path).unwrap();
        assert_eq!(again.metadata(1).unwrap().unwrap().tmdb_id, Some(438631));
    }

    /// What a v2 build added on top of SCHEMA_V1.
    const SCHEMA_V2_ADD: &str = "
ALTER TABLE files ADD COLUMN rating_key TEXT;
CREATE TABLE metadata (
  title_id INTEGER PRIMARY KEY REFERENCES titles(id) ON DELETE CASCADE,
  tmdb_id INTEGER,
  overview_fr TEXT,
  overview_en TEXT,
  poster_path TEXT,
  backdrop_path TEXT,
  genres TEXT NOT NULL DEFAULT '',
  source TEXT NOT NULL CHECK (source IN ('plex','tmdb')),
  fetched_at INTEGER NOT NULL
);
";

    #[test]
    fn a_v2_cache_migrates_in_place_and_keeps_its_rows() {
        let tmp = tempfile::tempdir().unwrap();
        let path = tmp.path().join("index.sqlite");
        {
            let conn = Connection::open(&path).unwrap();
            conn.execute_batch(SCHEMA_V1).unwrap();
            conn.execute_batch(SCHEMA_V2_ADD).unwrap();
            conn.pragma_update(None, "user_version", 2).unwrap();
            conn.execute(
                "INSERT INTO titles (id, kind, name, year) VALUES (1, 'movie', 'Dune', 2021)",
                [],
            )
            .unwrap();
            conn.execute(
                "INSERT INTO files (id, source_id, dir, path, size, mtime, seen_gen, title_id)
                 VALUES (7, 's1', 'Movies', 'Movies/a.mkv', 10, 1000, 1, 1)",
                [],
            )
            .unwrap();
            conn.execute(
                "INSERT INTO metadata (title_id, genres, source, fetched_at)
                 VALUES (1, 'Science-Fiction', 'tmdb', 5)",
                [],
            )
            .unwrap();
        }

        let db = Db::open(&path).unwrap();
        let version: i64 = db
            .conn()
            .query_row("PRAGMA user_version", [], |r| r.get(0))
            .unwrap();
        assert_eq!(version, SCHEMA_VERSION);
        // the scan and the enrichment did not have to start over
        assert_eq!(db.metadata(1).unwrap().unwrap().genres, "Science-Fiction");
        db.upsert_watch_state(
            &WatchRecord {
                file_id: 7,
                position_secs: 60.0,
                duration_secs: 6000.0,
                watched: false,
                plays: 0,
                updated_at: 100,
            },
            WatchAuthority::Report,
        )
        .unwrap();

        // reopening an already-migrated cache changes nothing
        drop(db);
        let again = Db::open(&path).unwrap();
        assert_eq!(again.watch_state(7).unwrap().unwrap().position_secs, 60.0);
    }

    /// What a v3 build added on top of SCHEMA_V1 and SCHEMA_V2_ADD.
    const SCHEMA_V3_ADD: &str = "
CREATE TABLE watch_state (
  file_id INTEGER PRIMARY KEY REFERENCES files(id) ON DELETE CASCADE,
  position_secs REAL NOT NULL DEFAULT 0,
  duration_secs REAL NOT NULL DEFAULT 0,
  watched INTEGER NOT NULL DEFAULT 0,
  updated_at INTEGER NOT NULL
);
CREATE TABLE tmdb_similar (
  kind TEXT NOT NULL CHECK (kind IN ('movie','show')),
  tmdb_id INTEGER NOT NULL,
  similar_tmdb_id INTEGER NOT NULL,
  rank INTEGER NOT NULL,
  PRIMARY KEY (kind, tmdb_id, similar_tmdb_id)
);
CREATE INDEX idx_metadata_tmdb ON metadata(tmdb_id);
";

    #[test]
    fn a_v3_cache_migrates_in_place_and_keeps_its_rows() {
        let tmp = tempfile::tempdir().unwrap();
        let path = tmp.path().join("index.sqlite");
        {
            let conn = Connection::open(&path).unwrap();
            conn.execute_batch(SCHEMA_V1).unwrap();
            conn.execute_batch(SCHEMA_V2_ADD).unwrap();
            conn.execute_batch(SCHEMA_V3_ADD).unwrap();
            conn.pragma_update(None, "user_version", 3).unwrap();
            conn.execute(
                "INSERT INTO titles (id, kind, name, year) VALUES (1, 'movie', 'Dune', 2021)",
                [],
            )
            .unwrap();
            conn.execute(
                "INSERT INTO metadata (title_id, genres, source, fetched_at)
                 VALUES (1, 'Science-Fiction', 'tmdb', 5)",
                [],
            )
            .unwrap();
        }

        let db = Db::open(&path).unwrap();
        let version: i64 = db
            .conn()
            .query_row("PRAGMA user_version", [], |r| r.get(0))
            .unwrap();
        assert_eq!(version, SCHEMA_VERSION);
        // the enrichment did not have to start over, and the column it never
        // wrote reads as "nobody knows", not as NULL
        let row = db.metadata(1).unwrap().unwrap();
        assert_eq!(row.genres, "Science-Fiction");
        assert_eq!(row.cast_names, "");

        db.upsert_embedding(&EmbeddingRecord {
            title_id: 1,
            model_version: 1,
            source_hash: 42,
            vector: vec![1, -1, 127, -128],
            computed_at: 10,
        })
        .unwrap();
        drop(db);
        let again = Db::open(&path).unwrap();
        assert_eq!(
            again.vectors(1, 10).unwrap()[0].vector,
            vec![1, -1, 127, -128]
        );
    }

    /// What a v4 build added on top of SCHEMA_V1, SCHEMA_V2_ADD and
    /// SCHEMA_V3_ADD.
    const SCHEMA_V4_ADD: &str = "
ALTER TABLE metadata ADD COLUMN cast_names TEXT NOT NULL DEFAULT '';
CREATE TABLE embeddings (
  title_id INTEGER PRIMARY KEY REFERENCES titles(id) ON DELETE CASCADE,
  model_version INTEGER NOT NULL,
  source_hash INTEGER NOT NULL,
  vector BLOB NOT NULL,
  computed_at INTEGER NOT NULL
);
CREATE TABLE similar_semantic (
  title_id INTEGER NOT NULL REFERENCES titles(id) ON DELETE CASCADE,
  similar_title_id INTEGER NOT NULL,
  rank INTEGER NOT NULL,
  score INTEGER NOT NULL,
  PRIMARY KEY (title_id, similar_title_id)
);
CREATE INDEX idx_semantic_similar ON similar_semantic(similar_title_id);
";

    #[test]
    fn a_v4_cache_migrates_in_place_and_keeps_its_rows() {
        let tmp = tempfile::tempdir().unwrap();
        let path = tmp.path().join("index.sqlite");
        {
            let conn = Connection::open(&path).unwrap();
            conn.execute_batch(SCHEMA_V1).unwrap();
            conn.execute_batch(SCHEMA_V2_ADD).unwrap();
            conn.execute_batch(SCHEMA_V3_ADD).unwrap();
            conn.execute_batch(SCHEMA_V4_ADD).unwrap();
            conn.pragma_update(None, "user_version", 4).unwrap();
            conn.execute(
                "INSERT INTO titles (id, kind, name, year) VALUES (1, 'movie', 'Dune', 2021)",
                [],
            )
            .unwrap();
            conn.execute(
                "INSERT INTO metadata (title_id, genres, cast_names, source, fetched_at)
                 VALUES (1, 'Science-Fiction', 'Timothee Chalamet', 'tmdb', 5)",
                [],
            )
            .unwrap();
            conn.execute(
                "INSERT INTO files (source_id, dir, path, size, mtime, seen_gen, title_id)
                 VALUES ('s1', 'Movies', 'Movies/dune.mkv', 1, 700, 1, 1)",
                [],
            )
            .unwrap();
        }

        let db = Db::open(&path).unwrap();
        let version: i64 = db
            .conn()
            .query_row("PRAGMA user_version", [], |r| r.get(0))
            .unwrap();
        assert_eq!(version, SCHEMA_VERSION);

        // the rows a v4 build wrote are still there, and the new column is
        // backfilled from the files that were already indexed
        let added: i64 = db
            .conn()
            .query_row("SELECT added_at FROM titles WHERE id = 1", [], |r| r.get(0))
            .unwrap();
        assert_eq!(added, 700);

        // and the search index is filled from what the tables already held,
        // name and genres and billing together
        assert_eq!(
            indexed(&db),
            vec![(
                1,
                "Dune".to_string(),
                "Science-Fiction".to_string(),
                "Timothee Chalamet".to_string()
            )]
        );
    }

    /// v5 and v6 add no ALTER of a table an earlier build filled (see their own
    /// comments above SCHEMA), so a v6 cache here is built from the live
    /// migration constants rather than a frozen snapshot: nothing about their
    /// shape is under test here, only that a real v6 cache's `metadata` rows
    /// backfill `title_tags` on the way to v7.
    #[test]
    fn a_cache_from_before_the_media_columns_asks_both_scanners_again() {
        let tmp = tempfile::tempdir().unwrap();
        let path = tmp.path().join("index.sqlite");
        {
            let conn = Connection::open(&path).unwrap();
            for batch in [
                SCHEMA,
                MIGRATE_V2,
                MIGRATE_V3,
                MIGRATE_V4,
                MIGRATE_V5,
                MIGRATE_V6,
                MIGRATE_V7,
                MIGRATE_V8,
                MIGRATE_V9,
                MIGRATE_V10,
                MIGRATE_V11,
                MIGRATE_V12,
                MIGRATE_V13,
                MIGRATE_V14,
                MIGRATE_V15,
            ] {
                conn.execute_batch(batch).unwrap();
            }
            conn.pragma_update(None, "user_version", 15).unwrap();
            conn.execute(
                "INSERT INTO dirs (source_id, path, mtime) VALUES ('plex1', '1', 1700000000)",
                [],
            )
            .unwrap();
        }
        // every row on disk was written by a build that filled none of the
        // media columns, and both scanners skip against this table: a stamp
        // left standing is a library that stays empty until something upstream
        // happens to move
        let db = Db::open(&path).unwrap();
        assert_eq!(db.dir_mtime("plex1", "1").unwrap(), None);
    }

    #[test]
    fn a_v14_cache_gains_the_crew_columns_and_a_search_index_that_holds_them() {
        let tmp = tempfile::tempdir().unwrap();
        let path = tmp.path().join("index.sqlite");
        {
            let conn = Connection::open(&path).unwrap();
            for batch in [
                SCHEMA,
                MIGRATE_V2,
                MIGRATE_V3,
                MIGRATE_V4,
                MIGRATE_V5,
                MIGRATE_V6,
                MIGRATE_V7,
                MIGRATE_V8,
                MIGRATE_V9,
                MIGRATE_V10,
                MIGRATE_V11,
                MIGRATE_V12,
                MIGRATE_V13,
                MIGRATE_V14,
            ] {
                conn.execute_batch(batch).unwrap();
            }
            conn.pragma_update(None, "user_version", 14).unwrap();
            conn.execute(
                "INSERT INTO titles (id, kind, name, year) VALUES (1, 'movie', 'Dune', 2021)",
                [],
            )
            .unwrap();
            conn.execute(
                "INSERT INTO metadata (title_id, genres, cast_names, source, fetched_at)
                 VALUES (1, 'Science-Fiction', 'Timothee Chalamet', 'plex', 5)",
                [],
            )
            .unwrap();
            conn.execute(
                "INSERT INTO embeddings (title_id, model_version, source_hash, vector, computed_at)
                 VALUES (1, 1, 42, x'0102', 5)",
                [],
            )
            .unwrap();
        }

        let db = Db::open(&path).unwrap();
        let version: i64 = db
            .conn()
            .query_row("PRAGMA user_version", [], |r| r.get(0))
            .unwrap();
        assert_eq!(version, SCHEMA_VERSION);

        // a row v14 never wrote reads as "nobody knows", not as NULL
        let row = db.metadata(1).unwrap().unwrap();
        assert_eq!(row.director_names, "");
        assert_eq!(row.writer_names, "");
        assert_eq!(row.composer_names, "");

        // the rebuilt index still holds what v14 had, and the triggers that
        // keep it were replaced rather than left writing the old column list
        let hits = crate::index::queries::search_titles(&db, "chalamet", 10).unwrap();
        assert_eq!(hits.hits.len(), 1);
        db.upsert_metadata(&MetadataRecord {
            director_names: "Denis Villeneuve".into(),
            critics: None,
            audience: None,
            release_date: None,
            ..row
        })
        .unwrap();
        let hits = crate::index::queries::search_titles(&db, "villeneuve", 10).unwrap();
        assert_eq!(hits.hits.len(), 1);

        // every vector on disk was computed from a text this build no longer
        // composes, so the queue has to name those titles again
        let vectors: i64 = db
            .conn()
            .query_row("SELECT COUNT(*) FROM embeddings", [], |r| r.get(0))
            .unwrap();
        assert_eq!(vectors, 0);
    }

    /// A library scanned by an older build carries its cast and its directors
    /// in `title_tags` already. Those names have to become people on the way
    /// to v17, or a person could not be opened until the whole library had
    /// been scanned again.
    #[test]
    fn a_v16_cache_backfills_a_person_for_every_name_already_tagged() {
        let tmp = tempfile::tempdir().unwrap();
        let path = tmp.path().join("index.sqlite");
        {
            let conn = Connection::open(&path).unwrap();
            for batch in [
                SCHEMA,
                MIGRATE_V2,
                MIGRATE_V3,
                MIGRATE_V4,
                MIGRATE_V5,
                MIGRATE_V6,
                MIGRATE_V7,
                MIGRATE_V8,
                MIGRATE_V9,
                MIGRATE_V10,
                MIGRATE_V11,
                MIGRATE_V12,
                MIGRATE_V13,
                MIGRATE_V14,
                MIGRATE_V15,
                MIGRATE_V16,
            ] {
                conn.execute_batch(batch).unwrap();
            }
            conn.pragma_update(None, "user_version", 16).unwrap();
            conn.execute(
                "INSERT INTO titles (kind, name, year, added_at) VALUES ('movie', 'Dune', 2021, 700)",
                [],
            )
            .unwrap();
            for (kind, value) in [
                ("cast", "Timothee Chalamet"),
                ("cast", "Rebecca Ferguson"),
                ("director", "Denis Villeneuve"),
                ("genre", "Science-Fiction"),
            ] {
                conn.execute(
                    "INSERT INTO title_tags (title_id, kind, value) VALUES (1, ?1, ?2)",
                    params![kind, value],
                )
                .unwrap();
            }
        }

        let db = Db::open(&path).unwrap();
        let version: i64 = db
            .conn()
            .query_row("PRAGMA user_version", [], |r| r.get(0))
            .unwrap();
        assert_eq!(version, SCHEMA_VERSION);

        // the three credited names are people; the genre is not, because
        // nothing draws a face for one
        let mut names: Vec<String> = db
            .conn()
            .prepare("SELECT name FROM people ORDER BY name")
            .unwrap()
            .query_map([], |r| r.get(0))
            .unwrap()
            .collect::<Result<_, _>>()
            .unwrap();
        names.sort();
        assert_eq!(
            names,
            ["Denis Villeneuve", "Rebecca Ferguson", "Timothee Chalamet"]
        );

        // and each of them has a number to hang a photograph on, with none
        // hung yet: this library has matched nothing to TMDB
        let (id, profile) = db.person("Timothee Chalamet").unwrap().unwrap();
        assert!(id > 0);
        assert_eq!(profile, "");
    }

    /// The state the v17 build leaves a described library in: every title
    /// placed, every credited name known, and not one face - their credits
    /// were fetched before there was anything to read out of them. No other
    /// queue names a placed title, so this one has to.
    #[test]
    fn a_v17_cache_owes_every_placed_title_the_faces_nothing_would_ask_for() {
        let tmp = tempfile::tempdir().unwrap();
        let path = tmp.path().join("index.sqlite");
        {
            let conn = Connection::open(&path).unwrap();
            for batch in [
                SCHEMA,
                MIGRATE_V2,
                MIGRATE_V3,
                MIGRATE_V4,
                MIGRATE_V5,
                MIGRATE_V6,
                MIGRATE_V7,
                MIGRATE_V8,
                MIGRATE_V9,
                MIGRATE_V10,
                MIGRATE_V11,
                MIGRATE_V12,
                MIGRATE_V13,
                MIGRATE_V14,
                MIGRATE_V15,
                MIGRATE_V16,
                MIGRATE_V17,
            ] {
                conn.execute_batch(batch).unwrap();
            }
            conn.pragma_update(None, "user_version", 17).unwrap();
            for (id, name, tmdb) in [(1, "Dune", "438631"), (2, "Anniversaire Mamie", "NULL")] {
                conn.execute(
                    "INSERT INTO titles (id, kind, name, year, added_at)
                     VALUES (?1, 'movie', ?2, 2021, 700)",
                    params![id, name],
                )
                .unwrap();
                conn.execute(
                    &format!(
                        "INSERT INTO metadata (title_id, tmdb_id, genres, cast_names,
                                               collections, source, fetched_at, matched_at)
                         VALUES (?1, {tmdb}, '', 'Timothee Chalamet', '', 'plex', 700, 700)"
                    ),
                    params![id],
                )
                .unwrap();
                conn.execute(
                    "INSERT INTO title_tags (title_id, kind, value)
                     VALUES (?1, 'cast', 'Timothee Chalamet')",
                    params![id],
                )
                .unwrap();
            }
            conn.execute(
                "INSERT OR IGNORE INTO people (name) VALUES ('Timothee Chalamet')",
                [],
            )
            .unwrap();
        }

        let db = Db::open(&path).unwrap();
        // the placed title is owed one request; the one TMDB never placed has
        // no id to ask about and is not in the queue at all
        assert_eq!(
            db.titles_needing_faces(10).unwrap(),
            [PendingFaces {
                title_id: 1,
                kind: MediaKind::Movie,
                tmdb_id: 438631,
            }]
        );

        // and the answer takes it out of the queue for good, photograph or not
        db.set_person("Timothee Chalamet", 1190668, "", 800)
            .unwrap();
        db.mark_faces_checked(1, 800).unwrap();
        assert!(db.titles_needing_faces(10).unwrap().is_empty());
    }

    /// Every credited name gets a person row as its tags are written, so a
    /// library that has only ever been scanned still opens one of them.
    #[test]
    fn writing_a_titles_tags_makes_a_person_of_every_credited_name() {
        let db = Db::open_in_memory().unwrap();
        let id = db
            .upsert_title(MediaKind::Movie, "Dune", Some(2021))
            .unwrap();
        db.upsert_metadata(&MetadataRecord {
            title_id: id,
            tmdb_id: None,
            overview_fr: None,
            overview_en: None,
            poster_path: None,
            backdrop_path: None,
            genres: "Science-Fiction".into(),
            cast_names: "Timothee Chalamet,Rebecca Ferguson".into(),
            collections: "Dune".into(),
            director_names: "Denis Villeneuve".into(),
            writer_names: "Jon Spaihts".into(),
            composer_names: "Hans Zimmer".into(),
            source: MetadataSource::Plex,
            fetched_at: 10,
            critics: None,
            audience: None,
            release_date: None,
        })
        .unwrap();

        for name in [
            "Timothee Chalamet",
            "Rebecca Ferguson",
            "Denis Villeneuve",
            "Jon Spaihts",
            "Hans Zimmer",
        ] {
            assert!(db.person(name).unwrap().is_some(), "{name} is not a person");
        }
        // a genre and a saga are tagged and are nobody
        for not_a_person in ["Science-Fiction", "Dune"] {
            assert!(
                db.person(not_a_person).unwrap().is_none(),
                "{not_a_person} became a person"
            );
        }

        // each credit under its own kind: a tile on the detail screen opens
        // the person, and the page is these rows read back
        let tagged = |kind: &str| -> Vec<String> {
            db.conn()
                .prepare(
                    "SELECT value FROM title_tags
                     WHERE title_id = ?1 AND kind = ?2 ORDER BY value",
                )
                .unwrap()
                .query_map(params![id, kind], |r| r.get(0))
                .unwrap()
                .collect::<Result<_, _>>()
                .unwrap()
        };
        assert_eq!(tagged("writer"), ["Jon Spaihts"]);
        assert_eq!(tagged("composer"), ["Hans Zimmer"]);
        assert_eq!(tagged("director"), ["Denis Villeneuve"]);
    }

    /// TMDB bills the same performer with a photograph on one film and without
    /// on another. Whichever is enriched last must not be the one that decides.
    #[test]
    fn a_credit_that_carries_no_photograph_does_not_erase_one_already_found() {
        let db = Db::open_in_memory().unwrap();
        db.set_person(
            "Rebecca Ferguson",
            933238,
            "/lJloTOheuQSirSLXNA3JHsrMNfH.jpg",
            10,
        )
        .unwrap();
        db.set_person("Rebecca Ferguson", 0, "", 20).unwrap();

        let (id, profile) = db.person("Rebecca Ferguson").unwrap().unwrap();
        assert_eq!(profile, "/lJloTOheuQSirSLXNA3JHsrMNfH.jpg");
        assert_eq!(db.person_profile(id).unwrap().unwrap(), profile);
    }

    #[test]
    fn a_plex_rescan_that_names_no_crew_does_not_erase_the_one_tmdb_found() {
        let db = Db::open_in_memory().unwrap();
        let id = db
            .upsert_title(MediaKind::Movie, "Dune", Some(2021))
            .unwrap();
        let tmdb = MetadataRecord {
            title_id: id,
            tmdb_id: Some(438631),
            overview_fr: None,
            overview_en: None,
            poster_path: None,
            backdrop_path: None,
            genres: "Science-Fiction".into(),
            cast_names: "Timothee Chalamet".into(),
            collections: String::new(),
            director_names: "Denis Villeneuve".into(),
            writer_names: "Jon Spaihts".into(),
            composer_names: "Hans Zimmer".into(),
            source: MetadataSource::Tmdb,
            fetched_at: 10,
            critics: None,
            audience: None,
            release_date: None,
        };
        db.upsert_metadata(&tmdb).unwrap();

        // the owner's server describes the title again and its agent carries
        // no crew at all: that is Plex saying nothing, not Plex saying no
        db.upsert_metadata(&MetadataRecord {
            tmdb_id: None,
            source: MetadataSource::Plex,
            fetched_at: 20,
            director_names: String::new(),
            writer_names: String::new(),
            composer_names: String::new(),
            critics: None,
            audience: None,
            release_date: None,
            ..tmdb
        })
        .unwrap();

        let row = db.metadata(id).unwrap().unwrap();
        assert_eq!(row.director_names, "Denis Villeneuve");
        assert_eq!(row.writer_names, "Jon Spaihts");
        assert_eq!(row.composer_names, "Hans Zimmer");

        // and the tag rows say what the column says: a row query that
        // disagreed with the detail screen would be the worse half of the bug
        let tags: Vec<String> = db
            .conn()
            .prepare("SELECT value FROM title_tags WHERE kind = 'director' AND title_id = ?1")
            .unwrap()
            .query_map([id], |r| r.get(0))
            .unwrap()
            .collect::<Result<_, _>>()
            .unwrap();
        assert_eq!(tags, ["Denis Villeneuve"]);
    }

    #[test]
    fn a_v6_cache_migrates_in_place_and_backfills_title_tags() {
        let tmp = tempfile::tempdir().unwrap();
        let path = tmp.path().join("index.sqlite");
        {
            let conn = Connection::open(&path).unwrap();
            conn.execute_batch(SCHEMA).unwrap();
            conn.execute_batch(MIGRATE_V2).unwrap();
            conn.execute_batch(MIGRATE_V3).unwrap();
            conn.execute_batch(MIGRATE_V4).unwrap();
            conn.execute_batch(MIGRATE_V5).unwrap();
            conn.execute_batch(MIGRATE_V6).unwrap();
            conn.pragma_update(None, "user_version", 6).unwrap();
            conn.execute(
                "INSERT INTO titles (id, kind, name, year) VALUES (1, 'movie', 'Dune', 2021)",
                [],
            )
            .unwrap();
            conn.execute(
                "INSERT INTO metadata (title_id, genres, cast_names, source, fetched_at)
                 VALUES (1, 'Science-Fiction,Aventure', 'Timothee Chalamet', 'plex', 5)",
                [],
            )
            .unwrap();
        }

        let db = Db::open(&path).unwrap();
        let version: i64 = db
            .conn()
            .query_row("PRAGMA user_version", [], |r| r.get(0))
            .unwrap();
        assert_eq!(version, SCHEMA_VERSION);

        // a row v6 never wrote reads as "belongs to nothing", not as NULL
        assert_eq!(db.metadata(1).unwrap().unwrap().collections, "");

        // the genre and cast columns a v6 cache already held are split into
        // title_tags exactly once, without a second sync ever asking for it
        let mut tags: Vec<(String, String)> = db
            .conn()
            .prepare("SELECT kind, value FROM title_tags WHERE title_id = 1 ORDER BY kind, value")
            .unwrap()
            .query_map([], |r| Ok((r.get(0)?, r.get(1)?)))
            .unwrap()
            .collect::<Result<_, _>>()
            .unwrap();
        tags.sort();
        assert_eq!(
            tags,
            vec![
                ("cast".to_string(), "Timothee Chalamet".to_string()),
                ("genre".to_string(), "Aventure".to_string()),
                ("genre".to_string(), "Science-Fiction".to_string()),
            ]
        );
    }

    /// Neither v10 nor v11 changes a shape, so a v9 cache is the current
    /// schema stamped 9, holding what a build with the old similarity floor
    /// and the old embedded text left behind.
    #[test]
    fn a_v47_cache_asks_tmdb_again_for_every_matched_title() {
        let tmp = tempfile::tempdir().unwrap();
        let path = tmp.path().join("index.sqlite");
        {
            let db = Db::open(&path).unwrap();
            db.upsert_similar(63639, MediaKind::Show, &[1668]).unwrap();
            // v51's column, which none of these older shapes had
            db.conn()
                .execute_batch(
                    "DROP INDEX idx_people_last_word; ALTER TABLE people DROP COLUMN last_word;",
                )
                .unwrap();
            db.conn().pragma_update(None, "user_version", 47).unwrap();
        }

        let db = Db::open(&path).unwrap();
        let links: i64 = db
            .conn()
            .query_row("SELECT COUNT(*) FROM tmdb_similar", [], |r| r.get(0))
            .unwrap();
        assert_eq!(links, 0);
    }

    #[test]
    fn a_v9_cache_drops_the_neighbours_the_old_floor_cut() {
        let tmp = tempfile::tempdir().unwrap();
        let path = tmp.path().join("index.sqlite");
        {
            let conn = Connection::open(&path).unwrap();
            for batch in [
                SCHEMA, MIGRATE_V2, MIGRATE_V3, MIGRATE_V4, MIGRATE_V5, MIGRATE_V6, MIGRATE_V7,
                MIGRATE_V8, MIGRATE_V9,
            ] {
                conn.execute_batch(batch).unwrap();
            }
            conn.pragma_update(None, "user_version", 9).unwrap();
            conn.execute_batch(
                "INSERT INTO titles (id, kind, name, year) VALUES
                   (1, 'movie', 'Dune', 2021), (2, 'movie', 'Solaris', 1972);
                 INSERT INTO embeddings (title_id, model_version, source_hash, vector, computed_at)
                   VALUES (1, 1, 7, X'0102', 5), (2, 1, 8, X'0201', 5);
                 INSERT INTO similar_semantic (title_id, similar_title_id, rank, score)
                   VALUES (1, 2, 0, 7000);
                 INSERT INTO semantic_computed (title_id, model_version, computed_at)
                   VALUES (1, 1, 9);",
            )
            .unwrap();
        }

        let db = Db::open(&path).unwrap();
        let version: i64 = db
            .conn()
            .query_row("PRAGMA user_version", [], |r| r.get(0))
            .unwrap();
        assert_eq!(version, SCHEMA_VERSION);

        // the links the old rule cut are gone, and the title is owed a fresh
        // look rather than left holding them
        let links: i64 = db
            .conn()
            .query_row("SELECT COUNT(*) FROM similar_semantic", [], |r| r.get(0))
            .unwrap();
        assert_eq!(links, 0);
        // and nothing is left claiming to have been swept: v11 takes the
        // vectors those rows were computed from, so the queue starts at the
        // embedding again rather than at the neighbours
        let swept: i64 = db
            .conn()
            .query_row("SELECT COUNT(*) FROM semantic_computed", [], |r| r.get(0))
            .unwrap();
        assert_eq!(swept, 0);
        assert!(db.titles_needing_semantic(1, 10).unwrap().is_empty());
        assert!(db.vectors(1, 10).unwrap().is_empty());
    }

    /// v29 adds an episode's year and the billing stamp, and forgets every
    /// directory and section stamp so the next scan writes the years in.
    #[test]
    fn a_v28_cache_owes_its_placed_titles_a_billing_and_its_sections_a_pull() {
        let tmp = tempfile::tempdir().unwrap();
        let path = tmp.path().join("index.sqlite");
        {
            let db = Db::open(&path).unwrap();
            db.conn()
                .execute_batch(
                    "ALTER TABLE episode_meta DROP COLUMN air_year;
                     DROP TABLE row_exposure;
                     ALTER TABLE metadata DROP COLUMN release_date;
                     DROP TRIGGER IF EXISTS episode_search_insert;
                     DROP TRIGGER IF EXISTS episode_search_update;
                     DROP TRIGGER IF EXISTS episode_search_delete;
                     DROP TABLE episode_search;
                     DROP TABLE row_kind_shown;
                     DROP TABLE row_subject_shown;
                     DROP TABLE tmdb_trending;
                     DROP TABLE subject_rest;
                     ALTER TABLE tonight_pick DROP COLUMN at;
                     DROP TABLE taste_mute;
                     DROP TABLE guest_taste;
                     DROP TABLE guest_verdict;
                     DROP TABLE guest;
                     ALTER TABLE evening_state DROP COLUMN guest_id;
                     DROP TABLE title_tone;
                     DROP TABLE club_pick;
                     ALTER TABLE metadata DROP COLUMN audience_votes;
                     ALTER TABLE metadata DROP COLUMN critic_votes;
                     DROP TABLE tonight_exposure;
                     DROP TABLE launch;
                     DROP TABLE home_open;
                     DROP TABLE tonight_shown;
                     ALTER TABLE metadata DROP COLUMN keywords;
                     ALTER TABLE metadata DROP COLUMN keywords_at;
                     ALTER TABLE files DROP COLUMN audio_languages;
                     ALTER TABLE files DROP COLUMN subtitle_languages;
                     DROP TABLE taste_event;
                     DROP TABLE taste_facet_snapshot;
                     DROP TABLE evening_state;
                     ALTER TABLE watch_state DROP COLUMN plays;
                     ALTER TABLE metadata DROP COLUMN billed_at;
                     ALTER TABLE metadata DROP COLUMN cast_characters;
                     INSERT INTO dirs (source_id, path, mtime) VALUES ('plex1', '1', 1700000000);
                     INSERT INTO titles (id, kind, name, year) VALUES (1, 'movie', 'Dune', 2021);
                     INSERT INTO metadata (title_id, tmdb_id, genres, source, fetched_at)
                       VALUES (1, 438631, '', 'plex', 5);",
                )
                .unwrap();
            // v51's column, which none of these older shapes had
            db.conn()
                .execute_batch(
                    "DROP INDEX idx_people_last_word; ALTER TABLE people DROP COLUMN last_word;",
                )
                .unwrap();
            db.conn().pragma_update(None, "user_version", 28).unwrap();
        }
        let db = Db::open(&path).unwrap();
        let dirs: i64 = db
            .conn()
            .query_row("SELECT count(*) FROM dirs", [], |r| r.get(0))
            .unwrap();
        assert_eq!(dirs, 0);
        assert_eq!(
            db.titles_needing_faces(10)
                .unwrap()
                .iter()
                .map(|t| t.title_id)
                .collect::<Vec<_>>(),
            vec![1]
        );
        db.mark_faces_checked(1, 10).unwrap();
        assert!(db.titles_needing_faces(10).unwrap().is_empty());
    }

    /// v25 adds everything the recommendations batch precomputes: the
    /// per-title explanation, the discovery band's closeness, the seasonal
    /// anchors and picks, the thread, the tonight queue and the core's own
    /// settings. A v24 cache migrates in place.
    #[test]
    fn a_v24_cache_gains_the_batch_tables() {
        let tmp = tempfile::tempdir().unwrap();
        let path = tmp.path().join("index.sqlite");
        {
            let db = Db::open(&path).unwrap();
            db.conn()
                .execute_batch(
                    "ALTER TABLE episode_meta DROP COLUMN air_year;
                     DROP TABLE row_exposure;
                     ALTER TABLE metadata DROP COLUMN release_date;
                     DROP TRIGGER IF EXISTS episode_search_insert;
                     DROP TRIGGER IF EXISTS episode_search_update;
                     DROP TRIGGER IF EXISTS episode_search_delete;
                     DROP TABLE episode_search;
                     DROP TABLE row_kind_shown;
                     DROP TABLE row_subject_shown;
                     DROP TABLE tmdb_trending;
                     DROP TABLE subject_rest;
                     ALTER TABLE tonight_pick DROP COLUMN at;
                     DROP TABLE taste_mute;
                     DROP TABLE guest_taste;
                     DROP TABLE guest_verdict;
                     DROP TABLE guest;
                     ALTER TABLE evening_state DROP COLUMN guest_id;
                     DROP TABLE title_tone;
                     DROP TABLE club_pick;
                     ALTER TABLE metadata DROP COLUMN audience_votes;
                     ALTER TABLE metadata DROP COLUMN critic_votes;
                     DROP TABLE tonight_exposure;
                     DROP TABLE launch;
                     DROP TABLE home_open;
                     DROP TABLE tonight_shown;
                     ALTER TABLE metadata DROP COLUMN keywords;
                     ALTER TABLE metadata DROP COLUMN keywords_at;
                     ALTER TABLE files DROP COLUMN audio_languages;
                     ALTER TABLE files DROP COLUMN subtitle_languages;
                     DROP TABLE taste_event;
                     DROP TABLE taste_facet_snapshot;
                     DROP TABLE evening_state;
                     ALTER TABLE watch_state DROP COLUMN plays;
                     ALTER TABLE metadata DROP COLUMN billed_at;
                     ALTER TABLE metadata DROP COLUMN cast_characters;
                     DROP TABLE watched_facet;
                     ALTER TABLE metadata DROP COLUMN trailer_key;
                     ALTER TABLE metadata DROP COLUMN trailer_checked_at;
                     DROP TABLE watchlist;
                     DROP TABLE title_taste;
                     DROP TABLE anchor_vector;
                     DROP TABLE seasonal_pick;
                     DROP TABLE thread;
                     DROP TABLE thread_item;
                     DROP TABLE tonight_queued;
                     DROP TABLE setting;
                     ALTER TABLE discovery_pick DROP COLUMN closeness;",
                )
                .unwrap();
            // v51's column, which none of these older shapes had
            db.conn()
                .execute_batch(
                    "DROP INDEX idx_people_last_word; ALTER TABLE people DROP COLUMN last_word;",
                )
                .unwrap();
            db.conn().pragma_update(None, "user_version", 24).unwrap();
        }
        let db = Db::open(&path).unwrap();
        db.conn()
            .execute(
                "INSERT INTO titles (id, kind, name, year) VALUES (1, 'movie', 'Dune', 2021)",
                [],
            )
            .unwrap();
        db.replace_taste(&TastePassOutput {
            picks: vec![],
            facets: vec![TasteFacetMeta {
                facet: 0,
                weight: 1.0,
                leader: 1,
                cos_to_top: 1.0,
            }],
            discovery: vec![DiscoveryPick {
                title_id: 1,
                closeness: 0.8,
            }],
            title_taste: vec![TitleTasteRow {
                title_id: 1,
                facet: 0,
                affinity: 0.7,
                rejected: "Solaris".into(),
            }],
            watched_facet: vec![],
            seasonal: vec![("oct".into(), vec![1])],
            tones: vec![(1, "gripping", 0.1), (1, "light", 0.3)],
            now: 1,
        })
        .unwrap();
        assert_eq!(db.title_tones(1).unwrap(), ["light", "gripping"]);
        assert_eq!(
            db.title_taste(1).unwrap(),
            Some(TitleTasteRow {
                title_id: 1,
                facet: 0,
                affinity: 0.7,
                rejected: "Solaris".into()
            })
        );
        assert_eq!(db.seasonal_titles("oct").unwrap(), vec![1]);
        db.put_anchor_vector("oct", 3, &[1, 2, 3]).unwrap();
        assert_eq!(db.anchor_vector("oct", 3).unwrap(), Some(vec![1, 2, 3]));
        db.set_setting("step_aside.reach", "far").unwrap();
        assert_eq!(db.setting("step_aside.reach").unwrap(), Some("far".into()));
        db.queue_tonight(1, 100).unwrap();
        assert_eq!(db.queued_tonight(50).unwrap(), vec![(1, 100)]);
        db.consume_queued(1).unwrap();
        assert!(db.queued_tonight(50).unwrap().is_empty());
        db.create_thread(1, 0, &[1], 100).unwrap();
        assert_eq!(db.active_thread().unwrap(), Some((1, 0)));
    }

    /// v24 adds the tonight tables and the facet metadata beside taste_pick;
    /// nothing existing changes shape, so a v23 cache migrates in place.
    #[test]
    fn a_v23_cache_gains_the_tonight_tables() {
        let tmp = tempfile::tempdir().unwrap();
        let path = tmp.path().join("index.sqlite");
        {
            let conn = Connection::open(&path).unwrap();
            for batch in [
                SCHEMA,
                MIGRATE_V2,
                MIGRATE_V3,
                MIGRATE_V4,
                MIGRATE_V5,
                MIGRATE_V6,
                MIGRATE_V7,
                MIGRATE_V8,
                MIGRATE_V9,
                MIGRATE_V10,
                MIGRATE_V11,
                MIGRATE_V12,
                MIGRATE_V13,
                MIGRATE_V14,
                MIGRATE_V15,
                MIGRATE_V16,
                MIGRATE_V17,
                MIGRATE_V18,
                MIGRATE_V19,
                MIGRATE_V20,
                MIGRATE_V21,
                MIGRATE_V22,
                MIGRATE_V23,
            ] {
                conn.execute_batch(batch).unwrap();
            }
            conn.pragma_update(None, "user_version", 23).unwrap();
        }
        let db = Db::open(&path).unwrap();
        db.conn()
            .execute(
                "INSERT INTO titles (id, kind, name, year) VALUES (1, 'movie', 'Dune', 2021)",
                [],
            )
            .unwrap();
        db.replace_taste(&TastePassOutput {
            picks: [].into(),
            facets: [TasteFacetMeta {
                facet: 0,
                weight: 3.0,
                leader: 1,
                cos_to_top: 1.0,
            }]
            .into(),
            discovery: vec![DiscoveryPick {
                title_id: 1,
                closeness: 0.5,
            }],
            ..Default::default()
        })
        .unwrap();
        assert_eq!(db.taste_facets().unwrap().len(), 1);
        db.replace_tonight_picks(20_000, &[(0, 1)], 5).unwrap();
        assert_eq!(db.tonight_picks(20_000).unwrap(), vec![(0, 1, 5)]);
        db.defer_tonight(1, 1_000).unwrap();
        assert!(db.tonight_picks(20_000).unwrap().is_empty());
    }

    /// A v13 cache is the shape the owner's library is on disk right now, rows
    /// and all: it migrates without asking TMDB for anything, and every title
    /// in it reads as "never asked" rather than as "has no logo".
    #[test]
    fn a_v13_cache_migrates_in_place_and_owes_every_title_a_logo() {
        let tmp = tempfile::tempdir().unwrap();
        let path = tmp.path().join("index.sqlite");
        {
            let conn = Connection::open(&path).unwrap();
            for batch in [
                SCHEMA,
                MIGRATE_V2,
                MIGRATE_V3,
                MIGRATE_V4,
                MIGRATE_V5,
                MIGRATE_V6,
                MIGRATE_V7,
                MIGRATE_V8,
                MIGRATE_V9,
                MIGRATE_V10,
                MIGRATE_V11,
                MIGRATE_V12,
                MIGRATE_V13,
            ] {
                conn.execute_batch(batch).unwrap();
            }
            conn.pragma_update(None, "user_version", 13).unwrap();
            conn.execute(
                "INSERT INTO titles (id, kind, name, year) VALUES (1, 'movie', 'Dune', 2021)",
                [],
            )
            .unwrap();
            conn.execute(
                "INSERT INTO metadata (title_id, tmdb_id, genres, source, fetched_at)
                 VALUES (1, 438631, 'Science-Fiction', 'plex', 5)",
                [],
            )
            .unwrap();
        }

        let db = Db::open(&path).unwrap();
        let version: i64 = db
            .conn()
            .query_row("PRAGMA user_version", [], |r| r.get(0))
            .unwrap();
        assert_eq!(version, SCHEMA_VERSION);

        let state = db.logo_state(1).unwrap().unwrap();
        assert_eq!(state.kind, MediaKind::Movie);
        assert_eq!(state.tmdb_id, Some(438631));
        assert_eq!(state.path, None);
        // 0, not "asked and found nothing": a migrated row has never been asked
        assert_eq!(state.checked_at, 0);
    }

    #[test]
    fn a_rescan_cannot_erase_the_logo_it_knows_nothing_about() {
        let db = Db::open_in_memory().unwrap();
        let id = db
            .upsert_title(MediaKind::Movie, "Dune", Some(2021))
            .unwrap();
        let plex_row = MetadataRecord {
            title_id: id,
            tmdb_id: Some(438631),
            overview_fr: Some("Dans un futur lointain.".into()),
            overview_en: None,
            poster_path: Some("/library/metadata/1/thumb/1".into()),
            backdrop_path: None,
            genres: "Science-Fiction".into(),
            cast_names: String::new(),
            collections: String::new(),
            director_names: String::new(),
            writer_names: String::new(),
            composer_names: String::new(),
            source: MetadataSource::Plex,
            fetched_at: 5,
            critics: None,
            audience: None,
            release_date: None,
        };
        db.upsert_metadata(&plex_row).unwrap();
        db.set_logo(id, Some("/dune-fr-logo.png"), 3.5, 900)
            .unwrap();

        // the sync that runs every launch rewrites the row from what the
        // server said, and the server has never heard of a logo
        db.upsert_metadata(&plex_row).unwrap();

        let state = db.logo_state(id).unwrap().unwrap();
        assert_eq!(state.path.as_deref(), Some("/dune-fr-logo.png"));
        assert_eq!(state.aspect, 3.5);
        assert_eq!(state.checked_at, 900);
    }

    #[test]
    fn a_title_tmdb_holds_no_logo_for_is_recorded_as_asked() {
        let db = Db::open_in_memory().unwrap();
        let id = db
            .upsert_title(MediaKind::Show, "The Expanse", None)
            .unwrap();
        db.upsert_metadata(&MetadataRecord {
            title_id: id,
            tmdb_id: Some(63639),
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
            fetched_at: 5,
            critics: None,
            audience: None,
            release_date: None,
        })
        .unwrap();
        db.set_logo(id, None, 0.0, 900).unwrap();

        let state = db.logo_state(id).unwrap().unwrap();
        assert_eq!(state.kind, MediaKind::Show);
        assert_eq!(state.path, None);
        // the whole point of the column: "asked, none" is not "never asked"
        assert_eq!(state.checked_at, 900);
    }

    /// v12 changes no shape a reader depends on, so a v11 cache is the current
    /// schema stamped 11, holding what a Plex sync leaves: rows in the owner's
    /// own language, with no tmdb_id anywhere.
    #[test]
    fn a_v11_cache_offers_every_row_plex_wrote_to_the_matcher() {
        let tmp = tempfile::tempdir().unwrap();
        let path = tmp.path().join("index.sqlite");
        {
            let conn = Connection::open(&path).unwrap();
            for batch in [
                SCHEMA,
                MIGRATE_V2,
                MIGRATE_V3,
                MIGRATE_V4,
                MIGRATE_V5,
                MIGRATE_V6,
                MIGRATE_V7,
                MIGRATE_V8,
                MIGRATE_V9,
                MIGRATE_V10,
                MIGRATE_V11,
            ] {
                conn.execute_batch(batch).unwrap();
            }
            conn.pragma_update(None, "user_version", 11).unwrap();
            conn.execute_batch(
                "INSERT INTO titles (id, kind, name, year) VALUES
                   (1, 'movie', 'Dune', 2021), (2, 'show', 'The Expanse', 0),
                   (3, 'movie', 'Solaris', 1972);
                 INSERT INTO metadata (title_id, tmdb_id, overview_fr, genres, cast_names,
                                       collections, source, fetched_at)
                   VALUES (1, NULL, 'Sur Arrakis.', 'Science-Fiction', '', '', 'plex', 5),
                          (2, NULL, 'Au 23e siecle.', '', '', '', 'plex', 5),
                          (3, 762, 'Une station.', '', '', '', 'tmdb', 5);",
            )
            .unwrap();
        }

        let db = Db::open(&path).unwrap();
        let version: i64 = db
            .conn()
            .query_row("PRAGMA user_version", [], |r| r.get(0))
            .unwrap();
        assert_eq!(version, SCHEMA_VERSION);

        // nothing on disk was ever offered to TMDB, and the rows say so
        let never: i64 = db
            .conn()
            .query_row(
                "SELECT COUNT(*) FROM metadata WHERE matched_at = 0",
                [],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(never, 3);

        // the two Plex rows are the queue; the matched TMDB row is not owed a
        // second look, and neither is anything Plex is still authoritative for
        let pending = db.titles_needing_match(1000, 100, 10).unwrap();
        assert_eq!(
            pending.iter().map(|t| t.id).collect::<Vec<_>>(),
            [1, 2],
            "{pending:#?}"
        );
        assert_eq!(pending[0].year, Some(2021));
        assert_eq!(pending[1].year, None);
        // and the words Plex wrote are still the words on the row
        assert_eq!(
            db.metadata(1).unwrap().unwrap().overview_fr.as_deref(),
            Some("Sur Arrakis.")
        );
    }

    #[test]
    fn a_matched_plex_row_leaves_the_queue_and_survives_the_next_sync() {
        let db = Db::open_in_memory().unwrap();
        let dune = db
            .upsert_title(MediaKind::Movie, "Dune", Some(2021))
            .unwrap();
        let plex = MetadataRecord {
            title_id: dune,
            tmdb_id: None,
            overview_fr: Some("Sur Arrakis.".into()),
            overview_en: None,
            poster_path: Some("/library/metadata/1/thumb/1".into()),
            backdrop_path: None,
            genres: "Science-Fiction".into(),
            cast_names: "Timothee Chalamet".into(),
            collections: String::new(),
            director_names: String::new(),
            writer_names: String::new(),
            composer_names: String::new(),
            source: MetadataSource::Plex,
            fetched_at: 5,
            critics: None,
            audience: None,
            release_date: None,
        };
        db.upsert_metadata(&plex).unwrap();
        assert_eq!(db.titles_needing_match(1000, 100, 10).unwrap().len(), 1);

        db.attach_tmdb_match(
            &MetadataRecord {
                tmdb_id: Some(438631),
                collections: "Dune - Saga".into(),
                fetched_at: 1000,
                critics: None,
                audience: None,
                release_date: None,
                ..plex.clone()
            },
            1000,
        )
        .unwrap();
        assert!(db.titles_needing_match(1000, 100, 10).unwrap().is_empty());
        // and no age is a reason to look again: this one is placed
        assert!(db.titles_needing_match(10_000, 100, 10).unwrap().is_empty());

        // the sync that comes after describes the item as Plex always did,
        // which says nothing about a saga and nothing about a tmdb_id: both
        // stand, and the row is the server's again in every other respect
        db.upsert_metadata(&MetadataRecord {
            overview_fr: Some("Sur Arrakis, une planete de sable.".into()),
            fetched_at: 200,
            critics: None,
            audience: None,
            release_date: None,
            ..plex
        })
        .unwrap();
        let row = db.metadata(dune).unwrap().unwrap();
        assert_eq!(row.tmdb_id, Some(438631));
        assert_eq!(row.collections, "Dune - Saga");
        assert_eq!(
            row.overview_fr.as_deref(),
            Some("Sur Arrakis, une planete de sable.")
        );
        assert_eq!(row.source, MetadataSource::Plex);
        // and a server that does tag its items answers for them: what it
        // sends replaces what TMDB guessed at
        db.upsert_metadata(&MetadataRecord {
            title_id: dune,
            tmdb_id: None,
            overview_fr: Some("Sur Arrakis.".into()),
            overview_en: None,
            poster_path: None,
            backdrop_path: None,
            genres: String::new(),
            cast_names: String::new(),
            collections: "Saga Dune".into(),
            director_names: String::new(),
            writer_names: String::new(),
            composer_names: String::new(),
            source: MetadataSource::Plex,
            fetched_at: 300,
            critics: None,
            audience: None,
            release_date: None,
        })
        .unwrap();
        assert_eq!(db.metadata(dune).unwrap().unwrap().collections, "Saga Dune");
    }

    #[test]
    fn a_plex_row_tmdb_could_not_place_waits_a_month_for_the_next_search() {
        let db = Db::open_in_memory().unwrap();
        let home = db
            .upsert_title(MediaKind::Movie, "Anniversaire Mamie", Some(2019))
            .unwrap();
        let plex = MetadataRecord {
            title_id: home,
            tmdb_id: None,
            overview_fr: Some("Le gateau.".into()),
            overview_en: None,
            poster_path: None,
            backdrop_path: None,
            genres: String::new(),
            cast_names: String::new(),
            collections: String::new(),
            director_names: String::new(),
            writer_names: String::new(),
            composer_names: String::new(),
            source: MetadataSource::Plex,
            fetched_at: 5,
            critics: None,
            audience: None,
            release_date: None,
        };
        db.upsert_metadata(&plex).unwrap();

        // the attempt is what is recorded, not a match: the row is untouched
        db.attach_tmdb_match(&plex, 1000).unwrap();
        assert_eq!(db.metadata(home).unwrap().unwrap(), plex);
        assert!(db.titles_needing_match(1000, 100, 10).unwrap().is_empty());
        assert_eq!(db.titles_needing_match(1101, 100, 10).unwrap().len(), 1);
    }

    #[test]
    fn a_v10_cache_drops_its_vectors_so_the_saga_is_read_into_them() {
        let tmp = tempfile::tempdir().unwrap();
        let path = tmp.path().join("index.sqlite");
        {
            let conn = Connection::open(&path).unwrap();
            for batch in [
                SCHEMA,
                MIGRATE_V2,
                MIGRATE_V3,
                MIGRATE_V4,
                MIGRATE_V5,
                MIGRATE_V6,
                MIGRATE_V7,
                MIGRATE_V8,
                MIGRATE_V9,
                MIGRATE_V10,
            ] {
                conn.execute_batch(batch).unwrap();
            }
            conn.pragma_update(None, "user_version", 10).unwrap();
            conn.execute_batch(
                "INSERT INTO titles (id, kind, name, year) VALUES
                   (1, 'movie', 'Dune', 2021), (2, 'movie', 'Dune Part Two', 2024);
                 INSERT INTO metadata (title_id, genres, collections, cast_names, source, fetched_at)
                   VALUES (1, 'Science-Fiction', 'Dune Saga', '', 'plex', 5),
                          (2, 'Science-Fiction', 'Dune Saga', '', 'plex', 5);
                 INSERT INTO embeddings (title_id, model_version, source_hash, vector, computed_at)
                   VALUES (1, 1, 7, X'0102', 6), (2, 1, 8, X'0201', 6);
                 INSERT INTO similar_semantic (title_id, similar_title_id, rank, score)
                   VALUES (1, 2, 0, 7000);
                 INSERT INTO semantic_computed (title_id, model_version, computed_at)
                   VALUES (1, 1, 9);",
            )
            .unwrap();
        }

        let db = Db::open(&path).unwrap();
        let version: i64 = db
            .conn()
            .query_row("PRAGMA user_version", [], |r| r.get(0))
            .unwrap();
        assert_eq!(version, SCHEMA_VERSION);

        // no vector on disk was computed from a text carrying the saga, so
        // every title is owed one again, saga in hand
        assert!(db.vectors(1, 10).unwrap().is_empty());
        let pending = db.titles_needing_embedding(1, 10).unwrap();
        assert_eq!(
            pending.iter().map(|p| p.title_id).collect::<Vec<_>>(),
            vec![1, 2]
        );
        assert_eq!(pending[0].collections, "Dune Saga");
        assert_eq!(pending[0].genres, "Science-Fiction");
        assert_eq!(pending[0].source_hash, None);

        // and the neighbours the old vectors named stand until the new ones
        // replace them, so no row goes blank across the sweep
        let links: i64 = db
            .conn()
            .query_row("SELECT COUNT(*) FROM similar_semantic", [], |r| r.get(0))
            .unwrap();
        assert_eq!(links, 1);
    }

    /// Every row of the search index, so a test can say what the whole table is
    /// rather than that one row of it exists.
    fn indexed(db: &Db) -> Vec<(i64, String, String, String)> {
        db.conn()
            .prepare("SELECT rowid, name, genres, cast_names FROM title_search ORDER BY rowid")
            .unwrap()
            .query_map([], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?)))
            .unwrap()
            .collect::<Result<_, _>>()
            .unwrap()
    }

    #[test]
    fn the_search_index_follows_the_title_and_what_describes_it() {
        let db = Db::open_in_memory().unwrap();
        let dune = db
            .upsert_title(MediaKind::Movie, "Dune", Some(2021))
            .unwrap();
        // a title is searchable by name before anything has described it
        assert_eq!(
            indexed(&db),
            vec![(dune, "Dune".to_string(), String::new(), String::new())]
        );

        db.upsert_metadata(&MetadataRecord {
            title_id: dune,
            tmdb_id: Some(438631),
            overview_fr: None,
            overview_en: None,
            poster_path: None,
            backdrop_path: None,
            genres: "Science-Fiction".into(),
            cast_names: "Timothee Chalamet".into(),
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
        assert_eq!(
            indexed(&db),
            vec![(
                dune,
                "Dune".to_string(),
                "Science-Fiction".to_string(),
                "Timothee Chalamet".to_string()
            )]
        );

        // a second description replaces the row rather than adding one
        db.upsert_metadata(&MetadataRecord {
            title_id: dune,
            tmdb_id: Some(438631),
            overview_fr: None,
            overview_en: None,
            poster_path: None,
            backdrop_path: None,
            genres: "Science-Fiction,Aventure".into(),
            cast_names: "Timothee Chalamet,Rebecca Ferguson".into(),
            collections: String::new(),
            director_names: String::new(),
            writer_names: String::new(),
            composer_names: String::new(),
            source: MetadataSource::Tmdb,
            fetched_at: 2,
            critics: None,
            audience: None,
            release_date: None,
        })
        .unwrap();
        assert_eq!(indexed(&db).len(), 1);
        assert_eq!(indexed(&db)[0].2, "Science-Fiction,Aventure");

        // re-scanning the same title writes nothing and leaves one row
        assert_eq!(
            db.upsert_title(MediaKind::Movie, "Dune", Some(2021))
                .unwrap(),
            dune
        );
        assert_eq!(indexed(&db).len(), 1);
    }

    #[test]
    fn a_title_that_goes_takes_its_search_row_with_it() {
        let db = Db::open_in_memory().unwrap();
        let dune = db
            .upsert_title(MediaKind::Movie, "Dune", Some(2021))
            .unwrap();
        db.upsert_file(&FileRecord {
            source_id: "s1".into(),
            dir: "Movies".into(),
            path: "Movies/dune.mkv".into(),
            size: 1,
            mtime: 700,
            seen_gen: 1,
            title_id: dune,
            season: None,
            episode: None,
            rating_key: None,
            media: FileMedia::default(),
        })
        .unwrap();
        db.upsert_metadata(&MetadataRecord {
            title_id: dune,
            tmdb_id: None,
            overview_fr: None,
            overview_en: None,
            poster_path: None,
            backdrop_path: None,
            genres: "Science-Fiction".into(),
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

        db.delete_files_not_seen("s1", 2).unwrap();
        db.prune_orphan_titles().unwrap();
        // the metadata row cascades with the title, and the trigger that hears
        // it must not put the row back: ids are handed out again after a
        // delete, and a stale row would describe whatever takes the number
        assert!(indexed(&db).is_empty());
    }

    #[test]
    fn a_title_is_added_when_its_newest_file_was() {
        let db = Db::open_in_memory().unwrap();
        let dune = db
            .upsert_title(MediaKind::Movie, "Dune", Some(2021))
            .unwrap();
        let added = |db: &Db| -> i64 {
            db.conn()
                .query_row("SELECT added_at FROM titles WHERE id = ?1", [dune], |r| {
                    r.get(0)
                })
                .unwrap()
        };
        // a title nothing holds a file for was never added
        assert_eq!(added(&db), 0);

        let mut file = FileRecord {
            source_id: "s1".into(),
            dir: "Movies".into(),
            path: "Movies/dune.mkv".into(),
            size: 1,
            mtime: 500,
            seen_gen: 1,
            title_id: dune,
            season: None,
            episode: None,
            rating_key: None,
            media: FileMedia::default(),
        };
        db.upsert_file(&file).unwrap();
        assert_eq!(added(&db), 500);

        // an older second version does not move the date
        file.path = "Movies/dune.1984.mkv".into();
        file.mtime = 300;
        db.upsert_file(&file).unwrap();
        assert_eq!(added(&db), 500);

        // a rescan of the same files does not either
        file.path = "Movies/dune.mkv".into();
        file.mtime = 500;
        file.seen_gen = 2;
        db.upsert_file(&file).unwrap();
        assert_eq!(added(&db), 500);

        // a newer one does
        file.path = "Movies/dune.2160p.mkv".into();
        file.mtime = 900;
        db.upsert_file(&file).unwrap();
        assert_eq!(added(&db), 900);
    }

    #[test]
    fn retitling_a_file_raises_the_new_titles_added_at_not_the_old_ones() {
        let db = Db::open_in_memory().unwrap();
        let dune = db
            .upsert_title(MediaKind::Movie, "Dune", Some(2021))
            .unwrap();
        let alien = db
            .upsert_title(MediaKind::Movie, "Alien", Some(1979))
            .unwrap();
        let added = |db: &Db, id: i64| -> i64 {
            db.conn()
                .query_row("SELECT added_at FROM titles WHERE id = ?1", [id], |r| {
                    r.get(0)
                })
                .unwrap()
        };

        let mut file = FileRecord {
            source_id: "s1".into(),
            dir: "Movies".into(),
            path: "Movies/dune.mkv".into(),
            size: 1,
            mtime: 500,
            seen_gen: 1,
            title_id: dune,
            season: None,
            episode: None,
            rating_key: None,
            media: FileMedia::default(),
        };
        db.upsert_file(&file).unwrap();
        assert_eq!(added(&db, dune), 500);
        assert_eq!(added(&db, alien), 0);

        // the same file row is retitled to Alien with a newer mtime: the
        // trigger's title_id branch must move Alien's added_at, not Dune's
        file.title_id = alien;
        file.mtime = 900;
        file.seen_gen = 2;
        db.upsert_file(&file).unwrap();
        assert_eq!(added(&db, alien), 900);
        assert_eq!(added(&db, dune), 500);
    }

    #[test]
    fn a_metadata_row_purged_on_its_own_leaves_the_title_searchable_by_name() {
        let db = Db::open_in_memory().unwrap();
        let dune = db
            .upsert_title(MediaKind::Movie, "Dune", Some(2021))
            .unwrap();
        let mut plex_file = record_for("Movies/dune.mkv", dune);
        plex_file.rating_key = Some("101".into());
        db.upsert_file(&plex_file).unwrap();
        // a second source keeps the title alive once the Plex one is purged
        let mut local_file = record_for("Movies/dune.mp4", dune);
        local_file.source_id = "s2".into();
        db.upsert_file(&local_file).unwrap();
        db.upsert_metadata(&MetadataRecord {
            title_id: dune,
            tmdb_id: None,
            overview_fr: None,
            overview_en: None,
            poster_path: None,
            backdrop_path: None,
            genres: "Science-Fiction".into(),
            cast_names: "Timothee Chalamet".into(),
            collections: String::new(),
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
        assert_eq!(indexed(&db)[0].2, "Science-Fiction");

        // purge_source deletes the metadata row on its own, with the title
        // still standing on the other source's file: the title-delete trigger
        // never fires, only the one on metadata does
        db.purge_source("s1").unwrap();
        assert!(db.metadata(dune).unwrap().is_none());
        assert_eq!(
            indexed(&db),
            vec![(dune, "Dune".to_string(), String::new(), String::new())]
        );
    }

    #[test]
    fn a_vector_round_trips_and_leaves_with_the_title_it_describes() {
        let db = Db::open_in_memory().unwrap();
        let dune = db
            .upsert_title(MediaKind::Movie, "Dune", Some(2021))
            .unwrap();
        let expanse = db
            .upsert_title(MediaKind::Show, "The Expanse", None)
            .unwrap();
        for (title_id, vector) in [(dune, vec![10i8, -10, 0, 5]), (expanse, vec![0, 0, 1, 1])] {
            db.upsert_embedding(&EmbeddingRecord {
                title_id,
                model_version: 1,
                source_hash: title_id * 7,
                vector,
                computed_at: 100,
            })
            .unwrap();
        }

        let vectors = db.vectors(1, 10).unwrap();
        assert_eq!(vectors.len(), 2);
        assert_eq!(vectors[0].title_id, dune);
        assert_eq!(vectors[0].kind, MediaKind::Movie);
        // the sign survives the round trip through a BLOB of bytes
        assert_eq!(vectors[0].vector, vec![10, -10, 0, 5]);
        assert_eq!(vectors[1].kind, MediaKind::Show);
        // another model's vectors are not this model's
        assert!(db.vectors(2, 10).unwrap().is_empty());
        // and the whole library is never read unbounded
        assert_eq!(db.vectors(1, 1).unwrap().len(), 1);

        // a rewrite replaces the row instead of failing on the primary key
        db.upsert_embedding(&EmbeddingRecord {
            title_id: dune,
            model_version: 2,
            source_hash: 9,
            vector: vec![1, 2, 3, 4],
            computed_at: 200,
        })
        .unwrap();
        assert_eq!(db.vectors(2, 10).unwrap()[0].vector, vec![1, 2, 3, 4]);

        // the title goes, the vector goes with it: the cache is disposable and
        // an embedding is recomputed in milliseconds
        db.conn()
            .execute("DELETE FROM titles WHERE id = ?1", params![dune])
            .unwrap();
        assert_eq!(db.vectors(2, 10).unwrap().len(), 0);
    }

    #[test]
    fn a_title_is_owed_an_embedding_until_one_matches_its_description() {
        let db = Db::open_in_memory().unwrap();
        let dune = db
            .upsert_title(MediaKind::Movie, "Dune", Some(2021))
            .unwrap();
        let home = db
            .upsert_title(MediaKind::Movie, "Home Movie", None)
            .unwrap();
        db.upsert_metadata(&MetadataRecord {
            title_id: dune,
            tmdb_id: Some(438631),
            overview_fr: Some("Dans un futur lointain.".into()),
            overview_en: Some("A far future.".into()),
            poster_path: None,
            backdrop_path: None,
            genres: "Science-Fiction,Aventure".into(),
            cast_names: "Timothee Chalamet,Rebecca Ferguson".into(),
            collections: String::new(),
            director_names: String::new(),
            writer_names: String::new(),
            composer_names: String::new(),
            source: MetadataSource::Tmdb,
            fetched_at: 100,
            critics: None,
            audience: None,
            release_date: None,
        })
        .unwrap();
        // TMDB knew nothing about this one: a row all the same, and no French
        db.upsert_metadata(&MetadataRecord {
            title_id: home,
            tmdb_id: None,
            overview_fr: None,
            overview_en: Some("A birthday.".into()),
            poster_path: None,
            backdrop_path: None,
            genres: String::new(),
            cast_names: String::new(),
            collections: String::new(),
            director_names: String::new(),
            writer_names: String::new(),
            composer_names: String::new(),
            source: MetadataSource::Tmdb,
            fetched_at: 100,
            critics: None,
            audience: None,
            release_date: None,
        })
        .unwrap();

        let pending = db.titles_needing_embedding(1, 10).unwrap();
        assert_eq!(pending.len(), 2);
        assert_eq!(pending[0].title_id, dune);
        assert_eq!(pending[0].kind, MediaKind::Movie);
        assert_eq!(pending[0].name, "Dune");
        assert_eq!(pending[0].year, Some(2021));
        assert_eq!(pending[0].genres, "Science-Fiction,Aventure");
        assert_eq!(pending[0].cast_names, "Timothee Chalamet,Rebecca Ferguson");
        // French first, English when there is no French (spec: Metadata)
        assert_eq!(pending[0].overview, "Dans un futur lointain.");
        assert_eq!(pending[1].overview, "A birthday.");
        assert_eq!(pending[0].source_hash, None);

        for title_id in [dune, home] {
            db.upsert_embedding(&EmbeddingRecord {
                title_id,
                model_version: 1,
                source_hash: 77,
                vector: vec![1, 2],
                computed_at: 150,
            })
            .unwrap();
        }
        assert!(db.titles_needing_embedding(1, 10).unwrap().is_empty());
        // another model owes every title a vector again, and hands back no
        // hash: its rows say nothing about what this model would compute
        let other_model = db.titles_needing_embedding(2, 10).unwrap();
        assert_eq!(other_model.len(), 2);
        assert!(other_model.iter().all(|p| p.source_hash.is_none()));

        // a description refreshed after the vector was computed is owed a look,
        // and hands the pass the hash it can decide with
        db.upsert_metadata(&MetadataRecord {
            title_id: dune,
            tmdb_id: Some(438631),
            overview_fr: Some("Dans un futur lointain.".into()),
            overview_en: None,
            poster_path: None,
            backdrop_path: None,
            genres: "Science-Fiction,Aventure".into(),
            cast_names: "Timothee Chalamet,Rebecca Ferguson".into(),
            collections: String::new(),
            director_names: String::new(),
            writer_names: String::new(),
            composer_names: String::new(),
            source: MetadataSource::Plex,
            fetched_at: 300,
            critics: None,
            audience: None,
            release_date: None,
        })
        .unwrap();
        let pending = db.titles_needing_embedding(1, 10).unwrap();
        assert_eq!(pending.len(), 1);
        assert_eq!(pending[0].title_id, dune);
        assert_eq!(pending[0].source_hash, Some(77));

        // and a title nothing has described yet is not in the queue at all:
        // there is no text to embed
        db.upsert_title(MediaKind::Movie, "Undescribed", None)
            .unwrap();
        assert_eq!(db.titles_needing_embedding(1, 10).unwrap().len(), 1);
        db.touch_embedding(dune, 1, 400).unwrap();
        assert!(db.titles_needing_embedding(1, 10).unwrap().is_empty());
    }

    #[test]
    fn touching_an_unchanged_vector_keeps_its_current_neighbours_current() {
        let db = Db::open_in_memory().unwrap();
        let dune = db
            .upsert_title(MediaKind::Movie, "Dune", Some(2021))
            .unwrap();
        let alien = db
            .upsert_title(MediaKind::Movie, "Alien", Some(1979))
            .unwrap();
        for title_id in [dune, alien] {
            db.upsert_embedding(&EmbeddingRecord {
                title_id,
                model_version: 1,
                source_hash: 1,
                vector: vec![1, 2],
                computed_at: 10,
            })
            .unwrap();
        }
        db.upsert_semantic(&[(dune, Vec::new())], 1, 100).unwrap();
        // the description was read again and had not moved
        db.touch_embedding(dune, 1, 400).unwrap();
        db.touch_embedding(alien, 1, 400).unwrap();
        // dune's neighbours were current and stay so; alien never had any
        assert_eq!(db.titles_needing_semantic(1, 10).unwrap(), vec![alien]);
    }

    #[test]
    fn titles_needing_semantic_is_missing_stale_or_another_models_and_nothing_else() {
        let db = Db::open_in_memory().unwrap();
        let dune = db
            .upsert_title(MediaKind::Movie, "Dune", Some(2021))
            .unwrap();
        let solaris = db
            .upsert_title(MediaKind::Movie, "Solaris", Some(1972))
            .unwrap();
        let alien = db
            .upsert_title(MediaKind::Movie, "Alien", Some(1979))
            .unwrap();
        for (title_id, at) in [(dune, 10), (solaris, 20), (alien, 30)] {
            db.upsert_embedding(&EmbeddingRecord {
                title_id,
                model_version: 1,
                source_hash: 1,
                vector: vec![1, 2],
                computed_at: at,
            })
            .unwrap();
        }

        // nothing has been looked at yet: every vectorised title is owed a look
        assert_eq!(
            db.titles_needing_semantic(1, 10).unwrap(),
            vec![dune, solaris, alien]
        );

        db.upsert_semantic(
            &[
                (dune, Vec::new()),
                (solaris, Vec::new()),
                (alien, Vec::new()),
            ],
            1,
            100,
        )
        .unwrap();
        // a title whose neighbours are already fresh is not handed back
        assert!(db.titles_needing_semantic(1, 10).unwrap().is_empty());

        // dune's vector moves after its neighbours were computed: it alone is
        // owed another look
        db.upsert_embedding(&EmbeddingRecord {
            title_id: dune,
            model_version: 1,
            source_hash: 2,
            vector: vec![3, 4],
            computed_at: 200,
        })
        .unwrap();
        assert_eq!(db.titles_needing_semantic(1, 10).unwrap(), vec![dune]);
        db.upsert_semantic(&[(dune, Vec::new())], 1, 300).unwrap();
        assert!(db.titles_needing_semantic(1, 10).unwrap().is_empty());

        // a row another model computed the neighbours against is owed a look
        // under this model's version too
        db.conn()
            .execute(
                "UPDATE semantic_computed SET model_version = 99 WHERE title_id = ?1",
                params![solaris],
            )
            .unwrap();
        assert_eq!(db.titles_needing_semantic(1, 10).unwrap(), vec![solaris]);
    }

    #[test]
    fn upsert_semantic_touches_only_the_titles_it_is_given() {
        let db = Db::open_in_memory().unwrap();
        let dune = db
            .upsert_title(MediaKind::Movie, "Dune", Some(2021))
            .unwrap();
        let solaris = db
            .upsert_title(MediaKind::Movie, "Solaris", Some(1972))
            .unwrap();
        let alien = db
            .upsert_title(MediaKind::Movie, "Alien", Some(1979))
            .unwrap();

        db.upsert_semantic(
            &[
                (dune, vec![(solaris, 9000), (alien, 8000)]),
                (solaris, Vec::new()),
            ],
            1,
            100,
        )
        .unwrap();

        let ranked: Vec<(i64, i64, i64)> = db
            .conn()
            .prepare(
                "SELECT similar_title_id, rank, score FROM similar_semantic
                 WHERE title_id = ?1 ORDER BY rank",
            )
            .unwrap()
            .query_map(params![dune], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)))
            .unwrap()
            .collect::<Result<_, _>>()
            .unwrap();
        assert_eq!(ranked, vec![(solaris, 0, 9000), (alien, 1, 8000)]);

        // a title nothing resembles still records that it was searched
        let empty: i64 = db
            .conn()
            .query_row(
                "SELECT COUNT(*) FROM similar_semantic WHERE title_id = ?1",
                params![solaris],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(empty, 1);

        // a second batch replaces only alien's own rows: dune's stand exactly
        // as the first batch left them, which is what makes a sweep resumable
        db.upsert_semantic(&[(alien, vec![(dune, 7000)])], 1, 200)
            .unwrap();
        let still_dune: Vec<i64> = db
            .conn()
            .prepare(
                "SELECT similar_title_id FROM similar_semantic
                 WHERE title_id = ?1 ORDER BY rank",
            )
            .unwrap()
            .query_map(params![dune], |r| r.get(0))
            .unwrap()
            .collect::<Result<_, _>>()
            .unwrap();
        assert_eq!(still_dune, vec![solaris, alien]);

        // and a purged title takes its own rows with it
        db.conn()
            .execute("DELETE FROM titles WHERE id = ?1", params![alien])
            .unwrap();
        let left: i64 = db
            .conn()
            .query_row(
                "SELECT COUNT(*) FROM similar_semantic WHERE title_id = ?1",
                params![alien],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(left, 0);
    }

    #[test]
    fn a_watch_row_round_trips_and_watches_itself_past_ninety_percent() {
        let db = Db::open_in_memory().unwrap();
        db.upsert_file(&record(&db, "Movies/a.mkv", 1)).unwrap();
        let file_id = db.file_id("s1", "Movies/a.mkv").unwrap().unwrap();
        assert_eq!(db.watch_state(file_id).unwrap(), None);

        db.upsert_watch_state(
            &WatchRecord {
                file_id,
                position_secs: 600.0,
                duration_secs: 7000.0,
                watched: false,
                plays: 0,
                updated_at: 100,
            },
            WatchAuthority::Report,
        )
        .unwrap();
        let row = db.watch_state(file_id).unwrap().unwrap();
        assert_eq!(row.position_secs, 600.0);
        assert_eq!(row.duration_secs, 7000.0);
        assert!(!row.watched);
        assert_eq!(row.updated_at, 100);

        // 89% is still in progress
        db.upsert_watch_state(
            &WatchRecord {
                file_id,
                position_secs: 6230.0,
                duration_secs: 7000.0,
                watched: false,
                plays: 0,
                updated_at: 200,
            },
            WatchAuthority::Report,
        )
        .unwrap();
        assert!(!db.watch_state(file_id).unwrap().unwrap().watched);

        // past 90% it is seen, without anyone deciding so a second time
        db.upsert_watch_state(
            &WatchRecord {
                file_id,
                position_secs: 6301.0,
                duration_secs: 7000.0,
                watched: false,
                plays: 0,
                updated_at: 300,
            },
            WatchAuthority::Report,
        )
        .unwrap();
        assert!(db.watch_state(file_id).unwrap().unwrap().watched);

        // a report from the start of a rewatch moves the position and leaves
        // the flag: a position only ever raises it, and set_watched lowers it
        db.upsert_watch_state(
            &WatchRecord {
                file_id,
                position_secs: 12.0,
                duration_secs: 0.0,
                watched: false,
                plays: 0,
                updated_at: 400,
            },
            WatchAuthority::Report,
        )
        .unwrap();
        let row = db.watch_state(file_id).unwrap().unwrap();
        assert!(row.watched);
        assert_eq!(row.position_secs, 12.0);

        // the owner of an item answers for it in full, "not watched" included
        db.upsert_watch_state(
            &WatchRecord {
                file_id,
                position_secs: 300.0,
                duration_secs: 7000.0,
                watched: false,
                plays: 0,
                updated_at: 500,
            },
            WatchAuthority::Owner,
        )
        .unwrap();
        assert!(!db.watch_state(file_id).unwrap().unwrap().watched);

        // on a file nothing has seen, an unknown duration is not a division by
        // zero, and decides nothing
        db.upsert_file(&record(&db, "Movies/b.mkv", 1)).unwrap();
        let fresh = db.file_id("s1", "Movies/b.mkv").unwrap().unwrap();
        db.upsert_watch_state(
            &WatchRecord {
                file_id: fresh,
                position_secs: 12.0,
                duration_secs: 0.0,
                watched: false,
                plays: 0,
                updated_at: 400,
            },
            WatchAuthority::Report,
        )
        .unwrap();
        assert!(!db.watch_state(fresh).unwrap().unwrap().watched);
        let rows: i64 = db
            .conn()
            .query_row("SELECT COUNT(*) FROM watch_state", [], |r| r.get(0))
            .unwrap();
        assert_eq!(rows, 2);
    }

    #[test]
    fn marking_watched_clears_the_position_and_keeps_the_duration() {
        let db = Db::open_in_memory().unwrap();
        db.upsert_file(&record(&db, "Movies/a.mkv", 1)).unwrap();
        let file_id = db.file_id("s1", "Movies/a.mkv").unwrap().unwrap();
        db.upsert_watch_state(
            &WatchRecord {
                file_id,
                position_secs: 600.0,
                duration_secs: 7000.0,
                watched: false,
                plays: 0,
                updated_at: 100,
            },
            WatchAuthority::Report,
        )
        .unwrap();

        db.set_watched(file_id, true, 500).unwrap();
        let row = db.watch_state(file_id).unwrap().unwrap();
        assert_eq!(row.position_secs, 0.0);
        // the runtime is worth keeping: nothing else knows it
        assert_eq!(row.duration_secs, 7000.0);
        assert!(row.watched);
        assert_eq!(row.updated_at, 500);

        db.set_watched(file_id, false, 600).unwrap();
        let row = db.watch_state(file_id).unwrap().unwrap();
        assert!(!row.watched);
        assert_eq!(row.position_secs, 0.0);

        // a file nothing ever played can be marked too
        db.upsert_file(&record(&db, "Movies/b.mkv", 1)).unwrap();
        let other = db.file_id("s1", "Movies/b.mkv").unwrap().unwrap();
        db.set_watched(other, true, 700).unwrap();
        assert!(db.watch_state(other).unwrap().unwrap().watched);
    }

    #[test]
    fn a_title_reports_its_files_and_the_one_left_running_last() {
        let db = Db::open_in_memory().unwrap();
        let show = db
            .upsert_title(MediaKind::Show, "The Expanse", None)
            .unwrap();
        for path in ["S01E01.mkv", "S01E02.mkv", "S01E03.mkv"] {
            let mut file = record(&db, path, 1);
            file.title_id = show;
            db.upsert_file(&file).unwrap();
        }
        let e1 = db.file_id("s1", "S01E01.mkv").unwrap().unwrap();
        let e2 = db.file_id("s1", "S01E02.mkv").unwrap().unwrap();
        let e3 = db.file_id("s1", "S01E03.mkv").unwrap().unwrap();

        // nothing played yet: three files, none seen, nothing to resume
        let watch = db.title_watch(show).unwrap();
        assert_eq!(watch.files, 3);
        assert_eq!(watch.watched_files, 0);
        assert_eq!(watch.resume, None);

        db.set_watched(e1, true, 100).unwrap();
        db.upsert_watch_state(
            &WatchRecord {
                file_id: e2,
                position_secs: 600.0,
                duration_secs: 3000.0,
                watched: false,
                plays: 0,
                updated_at: 200,
            },
            WatchAuthority::Report,
        )
        .unwrap();
        db.upsert_watch_state(
            &WatchRecord {
                file_id: e3,
                position_secs: 900.0,
                duration_secs: 3000.0,
                watched: false,
                plays: 0,
                updated_at: 300,
            },
            WatchAuthority::Report,
        )
        .unwrap();

        // the episode left running last is the one a resume offers
        let watch = db.title_watch(show).unwrap();
        assert_eq!(watch.files, 3);
        assert_eq!(watch.watched_files, 1);
        let resume = watch.resume.unwrap();
        assert_eq!(resume.file_id, e3);
        assert_eq!(resume.position_secs, 900.0);
        assert_eq!(resume.duration_secs, 3000.0);

        // and a file finished after that one leaves the earlier one to resume
        db.set_watched(e3, true, 400).unwrap();
        let watch = db.title_watch(show).unwrap();
        assert_eq!(watch.watched_files, 2);
        assert_eq!(watch.resume.unwrap().file_id, e2);
    }

    #[test]
    fn a_title_that_is_finished_has_nothing_left_to_resume() {
        let db = Db::open_in_memory().unwrap();
        let file = record(&db, "Movies/a.mkv", 1);
        let title_id = file.title_id;
        db.upsert_file(&file).unwrap();
        let file_id = db.file_id("s1", "Movies/a.mkv").unwrap().unwrap();

        db.set_watched(file_id, true, 100).unwrap();
        let watch = db.title_watch(title_id).unwrap();
        assert_eq!(watch.files, 1);
        assert_eq!(watch.watched_files, 1);
        assert_eq!(watch.resume, None);

        // a title id nothing holds is empty, not an error
        let none = db.title_watch(999_999).unwrap();
        assert_eq!(none.files, 0);
        assert_eq!(none.watched_files, 0);
        assert_eq!(none.resume, None);
    }

    #[test]
    fn a_restored_row_never_overwrites_a_fresher_one() {
        let db = Db::open_in_memory().unwrap();
        db.upsert_file(&record(&db, "Movies/a.mkv", 1)).unwrap();
        let file_id = db.file_id("s1", "Movies/a.mkv").unwrap().unwrap();

        // nothing there yet: the durable copy is all there is
        db.restore_watch_state(
            &WatchRecord {
                file_id,
                position_secs: 300.0,
                duration_secs: 7000.0,
                watched: false,
                plays: 0,
                updated_at: 100,
            },
            true,
        )
        .unwrap();
        assert_eq!(
            db.watch_state(file_id).unwrap().unwrap().position_secs,
            300.0
        );

        // the server already said something newer, so the copy stays out of it
        db.upsert_watch_state(
            &WatchRecord {
                file_id,
                position_secs: 900.0,
                duration_secs: 7000.0,
                watched: false,
                plays: 0,
                updated_at: 200,
            },
            WatchAuthority::Report,
        )
        .unwrap();
        db.restore_watch_state(
            &WatchRecord {
                file_id,
                position_secs: 300.0,
                duration_secs: 7000.0,
                watched: false,
                plays: 0,
                updated_at: 100,
            },
            true,
        )
        .unwrap();
        assert_eq!(
            db.watch_state(file_id).unwrap().unwrap().position_secs,
            900.0
        );
    }

    #[test]
    fn a_restore_without_a_runtime_keeps_the_one_the_row_has() {
        let db = Db::open_in_memory().unwrap();
        db.upsert_file(&record(&db, "Movies/a.mkv", 1)).unwrap();
        let file_id = db.file_id("s1", "Movies/a.mkv").unwrap().unwrap();
        db.upsert_watch_state(
            &WatchRecord {
                file_id,
                position_secs: 600.0,
                duration_secs: 7000.0,
                watched: false,
                plays: 0,
                updated_at: 100,
            },
            WatchAuthority::Report,
        )
        .unwrap();

        // a title marked watched by hand knows no duration, and the row's is
        // what the 90% rule is decided against
        db.restore_watch_state(
            &WatchRecord {
                file_id,
                position_secs: 0.0,
                duration_secs: 0.0,
                watched: true,
                plays: 0,
                updated_at: 200,
            },
            true,
        )
        .unwrap();

        let row = db.watch_state(file_id).unwrap().unwrap();
        assert_eq!(row.duration_secs, 7000.0);
        assert_eq!(row.position_secs, 0.0);
        assert!(row.watched);
    }

    #[test]
    fn a_restore_that_owns_no_flag_takes_the_position_and_leaves_the_flag() {
        let db = Db::open_in_memory().unwrap();
        db.upsert_file(&record(&db, "Movies/a.mkv", 1)).unwrap();
        let file_id = db.file_id("s1", "Movies/a.mkv").unwrap().unwrap();
        db.set_watched(file_id, true, 100).unwrap();

        db.restore_watch_state(
            &WatchRecord {
                file_id,
                position_secs: 3000.0,
                duration_secs: 9000.0,
                watched: false,
                plays: 0,
                updated_at: 200,
            },
            false,
        )
        .unwrap();

        let row = db.watch_state(file_id).unwrap().unwrap();
        assert_eq!(row.position_secs, 3000.0);
        assert!(row.watched);
    }

    #[test]
    fn watch_state_leaves_with_the_file_it_describes() {
        let db = Db::open_in_memory().unwrap();
        db.upsert_file(&record(&db, "Movies/a.mkv", 1)).unwrap();
        let file_id = db.file_id("s1", "Movies/a.mkv").unwrap().unwrap();
        db.upsert_watch_state(
            &WatchRecord {
                file_id,
                position_secs: 10.0,
                duration_secs: 100.0,
                watched: false,
                plays: 0,
                updated_at: 1,
            },
            WatchAuthority::Report,
        )
        .unwrap();

        // the file is gone from the source; the durable copy is what remembers
        db.upsert_file(&record(&db, "Movies/b.mkv", 2)).unwrap();
        assert_eq!(db.delete_files_not_seen("s1", 2).unwrap(), 1);
        let left: i64 = db
            .conn()
            .query_row("SELECT COUNT(*) FROM watch_state", [], |r| r.get(0))
            .unwrap();
        assert_eq!(left, 0);
    }

    #[test]
    fn a_file_names_its_source_its_path_and_its_plex_key() {
        let db = Db::open_in_memory().unwrap();
        let mut plex = record(&db, "/library/parts/1/1/a.mkv", 1);
        let title_id = plex.title_id;
        plex.source_id = "plex1".into();
        plex.rating_key = Some("101".into());
        db.upsert_file(&plex).unwrap();
        let mut local = record(&db, "Movies/a.mkv", 1);
        local.title_id = title_id;
        db.upsert_file(&local).unwrap();

        let file_id = db
            .file_id("plex1", "/library/parts/1/1/a.mkv")
            .unwrap()
            .unwrap();
        let one = db.file_ref(file_id).unwrap().unwrap();
        assert_eq!(one.id, file_id);
        assert_eq!(one.source_id, "plex1");
        assert_eq!(one.path, "/library/parts/1/1/a.mkv");
        assert_eq!(one.rating_key.as_deref(), Some("101"));

        // every file of a title, so marking one marks the whole season
        let all = db.title_file_refs(title_id).unwrap();
        assert_eq!(all.len(), 2);
        assert!(all
            .iter()
            .any(|f| f.source_id == "s1" && f.rating_key.is_none()));
        assert!(db.file_ref(9999).unwrap().is_none());
        assert!(db.file_id("s1", "nothing").unwrap().is_none());
        assert!(db.title_file_refs(9999).unwrap().is_empty());
    }

    #[test]
    fn pass_counts_read_the_index_at_rest_not_a_sessions_own_delta() {
        let db = Db::open_in_memory().unwrap();
        let dune = db
            .upsert_title(MediaKind::Movie, "Dune", Some(2021))
            .unwrap();
        let expanse = db
            .upsert_title(MediaKind::Show, "The Expanse", None)
            .unwrap();
        assert_eq!(
            db.pass_counts(1).unwrap(),
            PassCounts {
                total: 2,
                described: 0,
                linked: 0,
                embedded: 0
            }
        );

        db.upsert_metadata(&MetadataRecord {
            title_id: dune,
            tmdb_id: Some(438631),
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
            audience: None,
            release_date: None,
        })
        .unwrap();
        // described with no tmdb_id: Plex matched nothing, so it cannot be
        // linked yet either
        db.upsert_metadata(&MetadataRecord {
            title_id: expanse,
            tmdb_id: None,
            overview_fr: Some("A crew on the edge of the solar system.".into()),
            overview_en: None,
            poster_path: None,
            backdrop_path: None,
            genres: String::new(),
            cast_names: String::new(),
            collections: String::new(),
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
        assert_eq!(
            db.pass_counts(1).unwrap(),
            PassCounts {
                total: 2,
                described: 2,
                linked: 0,
                embedded: 0
            }
        );

        db.upsert_similar(438631, MediaKind::Movie, &[78]).unwrap();
        db.upsert_embedding(&EmbeddingRecord {
            title_id: dune,
            model_version: 1,
            source_hash: 1,
            vector: vec![1, 2, 3],
            computed_at: 1,
        })
        .unwrap();
        // a vector another model wrote does not count for this one
        db.upsert_embedding(&EmbeddingRecord {
            title_id: expanse,
            model_version: 2,
            source_hash: 1,
            vector: vec![1, 2, 3],
            computed_at: 1,
        })
        .unwrap();
        assert_eq!(
            db.pass_counts(1).unwrap(),
            PassCounts {
                total: 2,
                described: 2,
                linked: 1,
                embedded: 1
            }
        );
    }

    #[test]
    fn similar_ids_keep_their_order_and_an_empty_answer_sticks() {
        let db = Db::open_in_memory().unwrap();
        let dune = db
            .upsert_title(MediaKind::Movie, "Dune", Some(2021))
            .unwrap();
        let expanse = db
            .upsert_title(MediaKind::Show, "The Expanse", None)
            .unwrap();
        for (title_id, tmdb_id) in [(dune, 438631), (expanse, 63639)] {
            db.upsert_metadata(&MetadataRecord {
                title_id,
                tmdb_id: Some(tmdb_id),
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
                audience: None,
                release_date: None,
            })
            .unwrap();
        }

        let pending = db.titles_needing_similar(10).unwrap();
        assert_eq!(
            pending,
            vec![
                PendingSimilar {
                    tmdb_id: 438631,
                    kind: MediaKind::Movie
                },
                PendingSimilar {
                    tmdb_id: 63639,
                    kind: MediaKind::Show
                },
            ]
        );

        db.upsert_similar(438631, MediaKind::Movie, &[78, 762])
            .unwrap();
        // TMDB knows nothing similar to this one, and must not be asked again
        db.upsert_similar(63639, MediaKind::Show, &[]).unwrap();
        assert!(db.titles_needing_similar(10).unwrap().is_empty());

        // TMDB's own order, then the sentinel: a reader that forgets to skip it
        // still gets the real recommendations first
        assert_eq!(
            ranked(&db, 438631, MediaKind::Movie),
            vec![(78, 0), (762, 1), (0, SIMILAR_SENTINEL_RANK)]
        );

        // a second answer replaces the previous one whole: the id it dropped is
        // gone, and no two rows share a rank
        db.upsert_similar(438631, MediaKind::Movie, &[900, 78])
            .unwrap();
        assert_eq!(
            ranked(&db, 438631, MediaKind::Movie),
            vec![(900, 0), (78, 1), (0, SIMILAR_SENTINEL_RANK)]
        );
    }

    #[test]
    fn a_movie_and_a_show_sharing_a_tmdb_id_keep_their_own_neighbours() {
        // TMDB numbers movies and shows separately, and the sequences overlap
        let db = Db::open_in_memory().unwrap();
        let movie = db
            .upsert_title(MediaKind::Movie, "Dune", Some(2021))
            .unwrap();
        let show = db.upsert_title(MediaKind::Show, "Firefly", None).unwrap();
        for title_id in [movie, show] {
            db.upsert_metadata(&MetadataRecord {
                title_id,
                tmdb_id: Some(1437),
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
                audience: None,
                release_date: None,
            })
            .unwrap();
        }

        db.upsert_similar(1437, MediaKind::Movie, &[78]).unwrap();
        // the show still has to be asked: the movie's answer says nothing about it
        assert_eq!(
            db.titles_needing_similar(10).unwrap(),
            vec![PendingSimilar {
                tmdb_id: 1437,
                kind: MediaKind::Show
            }]
        );

        db.upsert_similar(1437, MediaKind::Show, &[762]).unwrap();
        assert!(db.titles_needing_similar(10).unwrap().is_empty());
        assert_eq!(
            ranked(&db, 1437, MediaKind::Movie),
            vec![(78, 0), (0, SIMILAR_SENTINEL_RANK)]
        );
        assert_eq!(
            ranked(&db, 1437, MediaKind::Show),
            vec![(762, 0), (0, SIMILAR_SENTINEL_RANK)]
        );
    }

    #[test]
    fn a_row_written_without_a_tmdb_id_does_not_erase_the_one_stored() {
        let db = Db::open_in_memory().unwrap();
        let id = db
            .upsert_title(MediaKind::Movie, "Dune", Some(2021))
            .unwrap();
        db.upsert_metadata(&MetadataRecord {
            title_id: id,
            tmdb_id: Some(438631),
            overview_fr: None,
            overview_en: Some("A far future.".into()),
            poster_path: None,
            backdrop_path: None,
            genres: "Science Fiction".into(),
            cast_names: String::new(),
            collections: String::new(),
            director_names: String::new(),
            writer_names: String::new(),
            composer_names: String::new(),
            source: MetadataSource::Tmdb,
            fetched_at: 100,
            critics: None,
            audience: None,
            release_date: None,
        })
        .unwrap();

        // the Plex sync describes the same title, and knows no TMDB id: the
        // recommendations join on that id, so losing it costs the title its row
        db.upsert_metadata(&MetadataRecord {
            title_id: id,
            tmdb_id: None,
            overview_fr: Some("Dans un futur.".into()),
            overview_en: None,
            poster_path: Some("/library/metadata/101/thumb/1".into()),
            backdrop_path: None,
            genres: "Science-Fiction".into(),
            cast_names: String::new(),
            collections: String::new(),
            director_names: String::new(),
            writer_names: String::new(),
            composer_names: String::new(),
            source: MetadataSource::Plex,
            fetched_at: 200,
            critics: None,
            audience: None,
            release_date: None,
        })
        .unwrap();

        let row = db.metadata(id).unwrap().unwrap();
        assert_eq!(row.tmdb_id, Some(438631));
        assert_eq!(row.source, MetadataSource::Plex);
        assert_eq!(row.overview_fr.as_deref(), Some("Dans un futur."));
        assert_eq!(row.overview_en, None);

        // a TMDB write is the search's own verdict: a null there means the
        // title no longer matches, and the stale id has to go with it
        db.upsert_metadata(&MetadataRecord {
            title_id: id,
            tmdb_id: None,
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
            fetched_at: 300,
            critics: None,
            audience: None,
            release_date: None,
        })
        .unwrap();
        assert_eq!(db.metadata(id).unwrap().unwrap().tmdb_id, None);
    }

    #[test]
    fn a_metadata_row_round_trips_and_is_replaced_in_place() {
        let db = Db::open_in_memory().unwrap();
        let id = db
            .upsert_title(MediaKind::Movie, "Dune", Some(2021))
            .unwrap();
        assert_eq!(db.metadata(id).unwrap(), None);

        let plex = MetadataRecord {
            title_id: id,
            tmdb_id: None,
            overview_fr: Some("Dans un futur.".into()),
            overview_en: None,
            poster_path: Some("/library/metadata/101/thumb/1".into()),
            backdrop_path: None,
            genres: "Science-Fiction,Aventure".into(),
            cast_names: String::new(),
            collections: String::new(),
            director_names: String::new(),
            writer_names: String::new(),
            composer_names: String::new(),
            source: MetadataSource::Plex,
            fetched_at: 100,
            critics: None,
            audience: None,
            release_date: None,
        };
        db.upsert_metadata(&plex).unwrap();
        assert_eq!(db.metadata(id).unwrap().as_ref(), Some(&plex));

        let tmdb = MetadataRecord {
            tmdb_id: Some(438631),
            overview_en: Some("A far future.".into()),
            collections: String::new(),
            director_names: String::new(),
            writer_names: String::new(),
            composer_names: String::new(),
            source: MetadataSource::Tmdb,
            fetched_at: 200,
            critics: None,
            audience: None,
            release_date: None,
            ..plex.clone()
        };
        db.upsert_metadata(&tmdb).unwrap();
        assert_eq!(db.metadata(id).unwrap().as_ref(), Some(&tmdb));
        let rows: i64 = db
            .conn()
            .query_row("SELECT COUNT(*) FROM metadata", [], |r| r.get(0))
            .unwrap();
        assert_eq!(rows, 1);
    }

    #[test]
    fn metadata_leaves_with_the_title_it_describes() {
        let db = Db::open_in_memory().unwrap();
        let orphan = db.upsert_title(MediaKind::Show, "Firefly", None).unwrap();
        db.upsert_metadata(&MetadataRecord {
            title_id: orphan,
            tmdb_id: Some(1437),
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
            audience: None,
            release_date: None,
        })
        .unwrap();
        assert_eq!(db.prune_orphan_titles().unwrap(), 1);
        let left: i64 = db
            .conn()
            .query_row("SELECT COUNT(*) FROM metadata", [], |r| r.get(0))
            .unwrap();
        assert_eq!(left, 0);
    }

    #[test]
    fn pending_titles_are_the_ones_with_no_fresh_row() {
        let db = Db::open_in_memory().unwrap();
        let fresh = db
            .upsert_title(MediaKind::Movie, "Dune", Some(2021))
            .unwrap();
        let stale = db
            .upsert_title(MediaKind::Movie, "Alien", Some(1979))
            .unwrap();
        let plex = db.upsert_title(MediaKind::Show, "Firefly", None).unwrap();
        let bare = db.upsert_title(MediaKind::Movie, "Solaris", None).unwrap();
        for (id, source, fetched_at) in [
            (fresh, MetadataSource::Tmdb, 1000),
            (stale, MetadataSource::Tmdb, 10),
            (plex, MetadataSource::Plex, 10),
        ] {
            db.upsert_metadata(&MetadataRecord {
                title_id: id,
                tmdb_id: None,
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
                source,
                fetched_at,
                critics: None,
                audience: None,
                release_date: None,
            })
            .unwrap();
        }

        let pending = db.titles_needing_metadata(1000, 100, 10).unwrap();
        let ids: Vec<i64> = pending.iter().map(|t| t.id).collect();
        // the stale TMDB row and the title with no row at all; the Plex row is
        // the server's and never expires here
        assert_eq!(ids, vec![stale, bare]);
        assert_eq!(pending[1].name, "Solaris");
        assert_eq!(pending[1].year, None);
        assert_eq!(pending[0].year, Some(1979));
        assert_eq!(pending[0].kind, MediaKind::Movie);
        // the limit is what makes the batch resumable
        assert_eq!(db.titles_needing_metadata(1000, 100, 1).unwrap().len(), 1);
    }

    #[test]
    fn a_titles_sources_are_listed_by_how_many_files_they_hold() {
        let db = Db::open_in_memory().unwrap();
        let mut a = record(&db, "Movies/a.mkv", 1);
        let title_id = a.title_id;
        a.source_id = "plex1".into();
        db.upsert_file(&a).unwrap();
        let mut b = record(&db, "Movies/b.mkv", 1);
        b.title_id = title_id;
        b.source_id = "local1".into();
        db.upsert_file(&b).unwrap();
        let mut c = record(&db, "Movies/c.mkv", 1);
        c.title_id = title_id;
        c.source_id = "local1".into();
        db.upsert_file(&c).unwrap();

        assert_eq!(db.title_source_ids(title_id).unwrap(), ["local1", "plex1"]);
        assert!(db.title_source_ids(9999).unwrap().is_empty());
    }

    #[test]
    fn source_counts_are_distinct_titles_and_every_file() {
        let db = Db::open_in_memory().unwrap();
        let t1 = db
            .upsert_title(MediaKind::Movie, "Dune", Some(2021))
            .unwrap();
        let t2 = db.upsert_title(MediaKind::Show, "Alien", None).unwrap();
        db.upsert_file(&FileRecord {
            source_id: "s1".to_string(),
            dir: String::new(),
            path: "dune.mkv".to_string(),
            size: 1,
            mtime: 1,
            seen_gen: 1,
            title_id: t1,
            season: None,
            episode: None,
            rating_key: None,
            media: FileMedia::default(),
        })
        .unwrap();
        db.upsert_file(&FileRecord {
            source_id: "s1".to_string(),
            dir: String::new(),
            path: "alien_s1e1.mkv".to_string(),
            size: 1,
            mtime: 1,
            seen_gen: 1,
            title_id: t2,
            season: Some(1),
            episode: Some(1),
            rating_key: None,
            media: FileMedia::default(),
        })
        .unwrap();
        db.upsert_file(&FileRecord {
            source_id: "s1".to_string(),
            dir: String::new(),
            path: "alien_s1e2.mkv".to_string(),
            size: 1,
            mtime: 1,
            seen_gen: 1,
            title_id: t2,
            season: Some(1),
            episode: Some(2),
            rating_key: None,
            media: FileMedia::default(),
        })
        .unwrap();

        let counts = db.source_counts("s1").unwrap();
        assert_eq!(counts.titles, 2);
        assert_eq!(counts.files, 3);
        assert_eq!(
            db.source_counts("nothing").unwrap(),
            SourceCounts::default()
        );
    }

    #[test]
    fn a_read_only_connection_sees_committed_writes() {
        let tmp = tempfile::tempdir().unwrap();
        let path = tmp.path().join("index.sqlite");
        let writer = Db::open(&path).unwrap();
        let reader = Db::open_read_only(&path).unwrap();
        writer
            .upsert_title(MediaKind::Movie, "Dune", Some(2021))
            .unwrap();
        let n: i64 = reader
            .conn()
            .query_row("SELECT COUNT(*) FROM titles", [], |r| r.get(0))
            .unwrap();
        assert_eq!(n, 1);
    }

    #[test]
    fn a_read_only_connection_carries_its_pragmas() {
        let tmp = tempfile::tempdir().unwrap();
        let path = tmp.path().join("index.sqlite");
        Db::open(&path).unwrap();
        let reader = Db::open_read_only(&path).unwrap();
        let mmap: i64 = reader
            .conn()
            .query_row("PRAGMA mmap_size", [], |r| r.get(0))
            .unwrap();
        assert_eq!(mmap, 134217728);
    }

    #[test]
    fn a_file_cannot_reference_a_missing_title() {
        let db = Db::open_in_memory().unwrap();
        let mut f = record(&db, "Movies/a.mkv", 1);
        f.title_id = 9999;
        assert!(db.upsert_file(&f).is_err());
    }

    #[test]
    fn upsert_title_is_idempotent() {
        let db = Db::open_in_memory().unwrap();
        let a = db
            .upsert_title(MediaKind::Movie, "Dune", Some(2021))
            .unwrap();
        let b = db
            .upsert_title(MediaKind::Movie, "Dune", Some(2021))
            .unwrap();
        assert_eq!(a, b);
        // unknown years must not create duplicates either
        let c = db.upsert_title(MediaKind::Show, "Firefly", None).unwrap();
        let d = db.upsert_title(MediaKind::Show, "Firefly", None).unwrap();
        assert_eq!(c, d);
        assert_ne!(a, c);
    }

    #[test]
    fn a_show_is_one_title_whichever_pass_knows_its_year() {
        let db = Db::open_in_memory().unwrap();
        let year = |id: i64| -> u16 {
            db.conn()
                .query_row("SELECT year FROM titles WHERE id = ?1", params![id], |r| {
                    r.get(0)
                })
                .unwrap()
        };

        // the show-level pass knows the year, the episode pass does not, and
        // the two must not file the series under separate rows
        let shown = db
            .upsert_title(MediaKind::Show, "The Expanse", Some(2015))
            .unwrap();
        let episodes = db
            .upsert_title(MediaKind::Show, "The Expanse", None)
            .unwrap();
        assert_eq!(shown, episodes);
        // and the pass that knows nothing leaves the year standing
        assert_eq!(year(shown), 2015);

        // the same the other way round: the episodes land first on a rescan
        let bare = db.upsert_title(MediaKind::Show, "Firefly", None).unwrap();
        assert_eq!(year(bare), 0);
        assert_eq!(
            db.upsert_title(MediaKind::Show, "Firefly", Some(2002))
                .unwrap(),
            bare
        );
        assert_eq!(year(bare), 2002);

        // a movie keeps its year in its identity: a remake is another title
        let first = db
            .upsert_title(MediaKind::Movie, "Dune", Some(1984))
            .unwrap();
        let remake = db
            .upsert_title(MediaKind::Movie, "Dune", Some(2021))
            .unwrap();
        assert_ne!(first, remake);
    }

    #[test]
    fn file_upsert_and_generation_cleanup() {
        let db = Db::open_in_memory().unwrap();
        db.upsert_file(&record(&db, "Movies/a.mkv", 1)).unwrap();
        db.upsert_file(&record(&db, "Movies/b.mkv", 1)).unwrap();
        assert_eq!(db.next_scan_gen("s1").unwrap(), 2);
        // second scan only sees a.mkv
        db.upsert_file(&record(&db, "Movies/a.mkv", 2)).unwrap();
        assert_eq!(db.delete_files_not_seen("s1", 2).unwrap(), 1);
        assert_eq!(db.prune_orphan_titles().unwrap(), 0); // a.mkv still holds the title
    }

    #[test]
    fn purging_a_source_takes_its_dirs_and_orphan_titles_with_it() {
        let db = Db::open_in_memory().unwrap();
        db.upsert_file(&record(&db, "Movies/a.mkv", 1)).unwrap();
        // a title only this source holds, so the purge leaves it orphaned
        let alone = db.upsert_title(MediaKind::Show, "Firefly", None).unwrap();
        let mut show = record(&db, "Shows/b.mkv", 1);
        show.title_id = alone;
        db.upsert_file(&show).unwrap();
        let mut other = record(&db, "Movies/c.mkv", 1);
        other.source_id = "s2".into();
        db.upsert_file(&other).unwrap();
        db.set_dir_mtime("s1", "Movies", 1000).unwrap();
        db.set_dir_mtime("s2", "Movies", 1000).unwrap();

        assert_eq!(db.purge_source("s1").unwrap(), 2);
        assert!(!db.has_files("s1").unwrap());
        assert!(db.has_files("s2").unwrap());
        // a re-added id must rescan from scratch, not skip every settled dir
        assert_eq!(db.dir_mtime("s1", "Movies").unwrap(), None);
        assert_eq!(db.dir_mtime("s2", "Movies").unwrap(), Some(1000));
        // Firefly went with it; Dune stays, s2 still holds a file for it
        let titles: Vec<String> = db
            .conn()
            .prepare("SELECT name FROM titles ORDER BY name")
            .unwrap()
            .query_map([], |r| r.get(0))
            .unwrap()
            .collect::<Result<_, _>>()
            .unwrap();
        assert_eq!(titles, vec!["Dune".to_string()]);
    }

    #[test]
    fn purging_a_plex_source_drops_the_rows_it_described() {
        let db = Db::open_in_memory().unwrap();
        // Dune survives the purge: another source holds a file for it
        let dune = db
            .upsert_title(MediaKind::Movie, "Dune", Some(2021))
            .unwrap();
        let mut plex_file = record(&db, "Movies/dune.mkv", 1);
        plex_file.rating_key = Some("101".into());
        db.upsert_file(&plex_file).unwrap();
        let mut local = record(&db, "Movies/dune.mp4", 1);
        local.source_id = "s2".into();
        db.upsert_file(&local).unwrap();

        // Alien keeps a Plex file of its own, on a source the purge spares
        let alien = db
            .upsert_title(MediaKind::Movie, "Alien", Some(1979))
            .unwrap();
        let mut kept = record(&db, "Movies/alien.mkv", 1);
        kept.source_id = "s3".into();
        kept.title_id = alien;
        kept.rating_key = Some("202".into());
        db.upsert_file(&kept).unwrap();

        for id in [dune, alien] {
            db.upsert_metadata(&MetadataRecord {
                title_id: id,
                tmdb_id: None,
                overview_fr: Some("Dans l'espace.".into()),
                overview_en: None,
                poster_path: Some("/library/metadata/1/thumb/1".into()),
                backdrop_path: None,
                genres: "Horreur".into(),
                cast_names: String::new(),
                collections: String::new(),
                director_names: String::new(),
                writer_names: String::new(),
                composer_names: String::new(),
                source: MetadataSource::Plex,
                fetched_at: 10,
                critics: None,
                audience: None,
                release_date: None,
            })
            .unwrap();
        }

        db.purge_source("s1").unwrap();

        // nothing describes Dune anymore, so TMDB may
        assert!(db.metadata(dune).unwrap().is_none());
        assert!(db
            .titles_needing_metadata(1000, 100, 10)
            .unwrap()
            .iter()
            .any(|t| t.id == dune));
        // Alien still has its Plex file, and its row is still the server's
        assert_eq!(db.metadata(alien).unwrap().unwrap().genres, "Horreur");
    }

    #[test]
    fn prune_removes_only_orphan_titles() {
        let db = Db::open_in_memory().unwrap();
        let kept = db
            .upsert_title(MediaKind::Movie, "Dune", Some(2021))
            .unwrap();
        let orphan = db.upsert_title(MediaKind::Show, "Firefly", None).unwrap();
        db.upsert_file(&record(&db, "Movies/a.mkv", 1)).unwrap();
        let mut f = record(&db, "Shows/b.mkv", 1);
        f.title_id = orphan;
        db.upsert_file(&f).unwrap();

        // second scan only sees a.mkv, so b.mkv goes and leaves Firefly orphaned
        db.upsert_file(&record(&db, "Movies/a.mkv", 2)).unwrap();
        assert_eq!(db.delete_files_not_seen("s1", 2).unwrap(), 1);
        assert_eq!(db.prune_orphan_titles().unwrap(), 1);

        let mut stmt = db
            .conn()
            .prepare("SELECT id FROM titles ORDER BY id")
            .unwrap();
        let remaining: Vec<i64> = stmt
            .query_map([], |r| r.get(0))
            .unwrap()
            .collect::<Result<_, _>>()
            .unwrap();
        assert_eq!(remaining, vec![kept]);
    }

    /// dir, size, mtime, seen_gen, title_id, season, episode, rating_key
    type StoredFile = (
        String,
        i64,
        i64,
        i64,
        i64,
        Option<u16>,
        Option<u16>,
        Option<String>,
    );

    #[test]
    fn a_file_scan_leaves_the_media_a_plex_sync_wrote() {
        let db = Db::open_in_memory().unwrap();
        let mut synced = record(&db, "Movies/a.mkv", 1);
        synced.media = FileMedia {
            duration_secs: 8220.0,
            video_resolution: "4k".into(),
            video_codec: "hevc".into(),
            dynamic_range: "dolby_vision".into(),
            audio_codec: "truehd".into(),
            audio_channels: 8,
            atmos: true,
            audio_languages: "fr,en".into(),
            subtitle_languages: "fr".into(),
            edition: String::new(),
        };
        let title = synced.title_id;
        db.upsert_file(&synced).unwrap();

        // the same file, seen again by a scanner that opens nothing
        db.upsert_file(&record(&db, "Movies/a.mkv", 2)).unwrap();

        let media = db.title_media(title).unwrap().unwrap();
        assert_eq!(media.video_resolution, "4k");
        // SDR and no-Atmos read the same as "not said", so both have to follow
        // the field that says whether the writer answered for media at all
        assert_eq!(media.dynamic_range, "dolby_vision");
        assert!(media.atmos);
        assert_eq!(media.duration_secs, 8220.0);
        assert_eq!(media.audio_languages, "fr,en");
        assert_eq!(media.subtitle_languages, "fr");
    }

    #[test]
    fn a_title_advertises_one_copy_and_never_a_mix_of_two() {
        let db = Db::open_in_memory().unwrap();
        let title = db
            .upsert_title(MediaKind::Movie, "Dune", Some(2021))
            .unwrap();

        let mut sd = record_for("Movies/dune-sd.mkv", title);
        sd.media = FileMedia {
            duration_secs: 9000.0,
            video_resolution: "1080".into(),
            video_codec: "h264".into(),
            dynamic_range: String::new(),
            audio_codec: "truehd".into(),
            // the louder soundtrack sits on the lesser picture on purpose
            audio_channels: 8,
            atmos: true,
            ..FileMedia::default()
        };
        db.upsert_file(&sd).unwrap();
        let mut uhd = record_for("Movies/dune-uhd.mkv", title);
        uhd.media = FileMedia {
            duration_secs: 9000.0,
            video_resolution: "4k".into(),
            video_codec: "hevc".into(),
            dynamic_range: "hdr10".into(),
            audio_codec: "eac3".into(),
            audio_channels: 6,
            atmos: false,
            ..FileMedia::default()
        };
        db.upsert_file(&uhd).unwrap();

        let media = db.title_media(title).unwrap().unwrap();
        assert_eq!(media.video_resolution, "4k");
        // a 4K badge beside an Atmos one taken off the other file would promise
        // a copy nobody can play
        assert_eq!(media.audio_channels, 6);
        assert!(!media.atmos);
    }

    #[test]
    fn a_film_opens_on_its_best_copy_and_lists_every_cut() {
        use crate::index::queries::{list_titles, Filter, SortOrder};

        let db = Db::open_in_memory().unwrap();
        let title = db
            .upsert_title(MediaKind::Movie, "Harry Potter", Some(2001))
            .unwrap();
        // scanned first, so the lowest id: the lesser picture must not win on that
        let mut extended = record_for("Movies/hp-extended.mkv", title);
        extended.size = 14_000_000_000;
        extended.media = FileMedia {
            duration_secs: 9540.0,
            video_resolution: "1080".into(),
            edition: "Extended Edition".into(),
            ..FileMedia::default()
        };
        let extended = db.upsert_file(&extended).unwrap();
        let mut light = record_for("Movies/hp-light.mkv", title);
        light.size = 5_000_000_000;
        light.media = FileMedia {
            duration_secs: 9140.0,
            video_resolution: "4k".into(),
            dynamic_range: "hdr10".into(),
            ..FileMedia::default()
        };
        let light = db.upsert_file(&light).unwrap();
        let mut uhd = record_for("Movies/hp-uhd.mkv", title);
        uhd.size = 28_000_000_000;
        uhd.media = FileMedia {
            duration_secs: 9140.0,
            video_resolution: "4k".into(),
            dynamic_range: "hdr10".into(),
            ..FileMedia::default()
        };
        let uhd = db.upsert_file(&uhd).unwrap();

        let listed = list_titles(
            &db,
            MediaKind::Movie,
            &Filter::default(),
            SortOrder::Name,
            0,
            10,
        )
        .unwrap();
        assert_eq!(listed[0].first_file_id, Some(uhd));

        let versions = db.title_versions(title).unwrap();
        let ids: Vec<i64> = versions.iter().map(|(id, _, _)| *id).collect();
        // the same picture at more bytes per second ranks above the lighter one
        assert_eq!(ids, [uhd, light, extended]);
        assert_eq!(versions[2].2.edition, "Extended Edition");
        assert_eq!(versions[0].1, 28_000_000_000);
    }

    #[test]
    fn a_title_no_source_describes_the_files_of_has_no_media_at_all() {
        let db = Db::open_in_memory().unwrap();
        let file = record(&db, "Movies/a.mkv", 1);
        let title = file.title_id;
        db.upsert_file(&file).unwrap();
        assert_eq!(db.title_media(title).unwrap(), None);
    }

    #[test]
    fn upsert_file_conflict_updates_every_column() {
        let db = Db::open_in_memory().unwrap();
        db.upsert_file(&record(&db, "Shows/b.mkv", 1)).unwrap();

        let show = db.upsert_title(MediaKind::Show, "Firefly", None).unwrap();
        let mut f = record(&db, "Shows/b.mkv", 2);
        f.dir = "Shows".into();
        f.size = 99;
        f.mtime = 2000;
        f.title_id = show;
        f.season = Some(3);
        f.episode = Some(4);
        f.rating_key = Some("101".into());
        db.upsert_file(&f).unwrap();

        let count: i64 = db
            .conn()
            .query_row("SELECT COUNT(*) FROM files", [], |r| r.get(0))
            .unwrap();
        assert_eq!(count, 1);

        let row: StoredFile = db
            .conn()
            .query_row(
                "SELECT dir, size, mtime, seen_gen, title_id, season, episode, rating_key
                 FROM files WHERE source_id = ?1 AND path = ?2",
                params!["s1", "Shows/b.mkv"],
                |r| {
                    Ok((
                        r.get(0)?,
                        r.get(1)?,
                        r.get(2)?,
                        r.get(3)?,
                        r.get(4)?,
                        r.get(5)?,
                        r.get(6)?,
                        r.get(7)?,
                    ))
                },
            )
            .unwrap();
        assert_eq!(
            row,
            (
                "Shows".to_string(),
                99,
                2000,
                2,
                show,
                Some(3),
                Some(4),
                Some("101".to_string())
            )
        );
    }

    #[test]
    fn touch_marks_whole_dir_seen() {
        let db = Db::open_in_memory().unwrap();
        db.upsert_file(&record(&db, "Movies/a.mkv", 1)).unwrap();
        db.touch_dir_files("s1", "Movies", 2).unwrap();
        assert_eq!(db.delete_files_not_seen("s1", 2).unwrap(), 0);
    }

    #[test]
    fn dir_mtimes_roundtrip() {
        let db = Db::open_in_memory().unwrap();
        assert_eq!(db.dir_mtime("s1", "Movies").unwrap(), None);
        db.set_dir_mtime("s1", "Movies", 42).unwrap();
        assert_eq!(db.dir_mtime("s1", "Movies").unwrap(), Some(42));
        db.set_dir_mtime("s1", "Movies", 43).unwrap();
        assert_eq!(db.dir_mtime("s1", "Movies").unwrap(), Some(43));
    }

    #[test]
    fn analysis_roundtrips_by_identity_and_misses_on_a_stale_mtime() {
        let db = Db::open_in_memory().unwrap();
        assert_eq!(db.load_analysis("plex1:501", 1000).unwrap(), None);

        db.store_analysis("plex1:501", 1000, "{\"duration\":9000}")
            .unwrap();
        assert_eq!(
            db.load_analysis("plex1:501", 1000).unwrap(),
            Some("{\"duration\":9000}".to_string())
        );
        // the file changed since it was probed: a stale mtime is a miss,
        // exactly like nothing ever having been stored
        assert_eq!(db.load_analysis("plex1:501", 1001).unwrap(), None);

        // a later store for the same identity replaces the row whole,
        // never leaves the old one behind under a different mtime
        db.store_analysis("plex1:501", 2000, "{\"duration\":9500}")
            .unwrap();
        assert_eq!(db.load_analysis("plex1:501", 1000).unwrap(), None);
        assert_eq!(
            db.load_analysis("plex1:501", 2000).unwrap(),
            Some("{\"duration\":9500}".to_string())
        );
    }

    #[test]
    fn the_player_going_on_with_a_title_is_not_another_launch_of_it() {
        let db = Db::open_in_memory().unwrap();
        let show = db.upsert_title(MediaKind::Show, "Adele", None).unwrap();
        db.record_launch(show, 1_000, "queue", "").unwrap();
        db.record_launch(show, 3_000, "other", "").unwrap();
        db.record_launch(show, 1_000 + LAUNCH_REPEAT_SECS + 1, "other", "")
            .unwrap();
        let surfaces: Vec<String> = db
            .conn()
            .prepare("SELECT surface FROM launch ORDER BY at")
            .unwrap()
            .query_map([], |r| r.get(0))
            .unwrap()
            .collect::<Result<_, _>>()
            .unwrap();
        assert_eq!(surfaces, ["queue", "other"]);
    }

    #[test]
    fn a_launch_is_kept_with_the_surface_that_proposed_it_and_goes_with_its_title() {
        let db = Db::open_in_memory().unwrap();
        let dune = db
            .upsert_title(MediaKind::Movie, "Dune", Some(2021))
            .unwrap();
        db.upsert_file(&record_for("Movies/Dune.mkv", dune))
            .unwrap();
        db.record_launch(dune, 1_000, "row", "taste_facet").unwrap();
        db.record_launch(dune, 2_000, "tonight.safe", "").unwrap();
        db.record_tonight_exposure(20_000, &[(1, dune)], &[], 30)
            .unwrap();
        let launches: Vec<(i64, i64, String, String)> = db
            .conn()
            .prepare("SELECT at, title_id, surface, detail FROM launch ORDER BY at")
            .unwrap()
            .query_map([], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?)))
            .unwrap()
            .collect::<Result<_, _>>()
            .unwrap();
        assert_eq!(
            launches,
            [
                (1_000, dune, "row".to_string(), "taste_facet".to_string()),
                (2_000, dune, "tonight.safe".to_string(), String::new()),
            ]
        );

        db.conn()
            .execute("DELETE FROM files WHERE title_id = ?1", [dune])
            .unwrap();
        db.prune_orphan_titles().unwrap();
        let left: (i64, i64) = db
            .conn()
            .query_row(
                "SELECT (SELECT COUNT(*) FROM launch), (SELECT COUNT(*) FROM tonight_shown)",
                [],
                |r| Ok((r.get(0)?, r.get(1)?)),
            )
            .unwrap();
        assert_eq!(left, (0, 0));
    }

    #[test]
    fn a_home_open_older_than_the_stats_reach_is_pruned_at_the_next_write() {
        let db = Db::open_in_memory().unwrap();
        let now = 200 * 86_400;
        db.record_home_open(now - 91 * 86_400).unwrap();
        db.record_home_open(now - 89 * 86_400).unwrap();
        db.record_home_open(now).unwrap();
        let opens: Vec<i64> = db
            .conn()
            .prepare("SELECT at FROM home_open ORDER BY at")
            .unwrap()
            .query_map([], |r| r.get(0))
            .unwrap()
            .collect::<Result<_, _>>()
            .unwrap();
        assert_eq!(opens, [now - 89 * 86_400, now]);
    }

    #[test]
    fn a_title_removed_from_the_library_takes_its_tones_with_it() {
        let db = Db::open_in_memory().unwrap();
        let id = db
            .upsert_title(MediaKind::Movie, "Dune", Some(2021))
            .unwrap();
        db.replace_taste(&TastePassOutput {
            tones: vec![(id, "mind", 0.2)],
            ..Default::default()
        })
        .unwrap();
        assert_eq!(db.title_tones(id).unwrap(), ["mind"]);
        db.conn()
            .execute("DELETE FROM titles WHERE id = ?1", [id])
            .unwrap();
        let left: i64 = db
            .conn()
            .query_row("SELECT COUNT(*) FROM title_tone", [], |r| r.get(0))
            .unwrap();
        assert_eq!(left, 0);
    }

    #[test]
    fn a_v39_vector_survives_the_migration_and_a_second_encoder_sits_beside_it() {
        let tmp = tempfile::tempdir().unwrap();
        let path = tmp.path().join("index.sqlite");
        let id = {
            let db = Db::open(&path).unwrap();
            let id = db
                .upsert_title(MediaKind::Movie, "Dune", Some(2021))
                .unwrap();
            db.conn()
                .execute_batch(
                    "DROP TRIGGER IF EXISTS episode_search_insert;
                     DROP TRIGGER IF EXISTS episode_search_update;
                     DROP TRIGGER IF EXISTS episode_search_delete;
                     DROP TABLE episode_search;
                     DROP TABLE row_kind_shown;
                     DROP TABLE row_subject_shown;
                     DROP TABLE tmdb_trending;
                     DROP TABLE subject_rest;
                     ALTER TABLE tonight_pick DROP COLUMN at;
                     DROP TABLE taste_mute;
                     DROP TABLE guest_taste;
                     DROP TABLE guest_verdict;
                     DROP TABLE guest;
                     ALTER TABLE evening_state DROP COLUMN guest_id;
                     DROP TABLE title_tone;
                     DROP TABLE embeddings;
                     CREATE TABLE embeddings (
                       title_id INTEGER PRIMARY KEY REFERENCES titles(id) ON DELETE CASCADE,
                       model_version INTEGER NOT NULL,
                       source_hash INTEGER NOT NULL,
                       vector BLOB NOT NULL,
                       computed_at INTEGER NOT NULL
                     );",
                )
                .unwrap();
            db.conn()
                .execute("INSERT INTO embeddings VALUES (?1, 2, 7, x'0102', 1)", [id])
                .unwrap();
            // v51's column, which none of these older shapes had
            db.conn()
                .execute_batch(
                    "DROP INDEX idx_people_last_word; ALTER TABLE people DROP COLUMN last_word;",
                )
                .unwrap();
            db.conn().pragma_update(None, "user_version", 39).unwrap();
            id
        };
        let db = Db::open(&path).unwrap();
        db.upsert_embedding(&EmbeddingRecord {
            title_id: id,
            model_version: 3,
            source_hash: 8,
            vector: vec![3, 4, 5],
            computed_at: 2,
        })
        .unwrap();
        assert_eq!(db.vectors(2, 10).unwrap()[0].vector, vec![1, 2]);
        assert_eq!(db.vectors(3, 10).unwrap()[0].vector, vec![3, 4, 5]);
        db.conn()
            .execute("DELETE FROM titles WHERE id = ?1", [id])
            .unwrap();
        let left: i64 = db
            .conn()
            .query_row("SELECT COUNT(*) FROM embeddings", [], |r| r.get(0))
            .unwrap();
        assert_eq!(left, 0);
    }

    #[test]
    fn a_deleted_title_cascades_through_indexes_and_the_minute_s_history_read_has_one() {
        let db = Db::open_in_memory().unwrap();
        let plan = |sql: &str| -> String {
            let mut stmt = db
                .conn()
                .prepare(&format!("EXPLAIN QUERY PLAN {sql}"))
                .unwrap();
            let rows = stmt.query_map([], |r| r.get::<_, String>(3)).unwrap();
            rows.collect::<Result<Vec<_>, _>>().unwrap().join("; ")
        };
        for table in [
            "launch",
            "tonight_shown",
            "club_pick",
            "guest_verdict",
            "guest_taste",
        ] {
            let found = plan(&format!("SELECT 1 FROM {table} WHERE title_id = 1"));
            assert!(found.contains("INDEX"), "{table}: {found}");
        }
        let found = plan(
            "SELECT t.kind = 'show', w.updated_at
             FROM watch_state w
             CROSS JOIN files f ON f.id = w.file_id
             CROSS JOIN titles t ON t.id = f.title_id
             WHERE w.watched = 1 AND w.updated_at >= 1",
        );
        assert!(found.contains("watch_state_updated"), "{found}");
    }

    #[test]
    fn a_contested_taste_goes_with_its_leader() {
        let db = Db::open_in_memory().unwrap();
        let leader = db
            .upsert_title(MediaKind::Movie, "Heat", Some(1995))
            .unwrap();
        db.mute_taste(leader, 100).unwrap();
        assert_eq!(db.muted_tastes(99).unwrap(), [leader]);
        assert!(db.muted_tastes(100).unwrap().is_empty());
        db.conn()
            .execute("DELETE FROM titles WHERE id = ?1", [leader])
            .unwrap();
        let left: i64 = db
            .conn()
            .query_row("SELECT COUNT(*) FROM taste_mute", [], |r| r.get(0))
            .unwrap();
        assert_eq!(left, 0);
    }
}
