use super::db::{Db, IndexError, IN_PROGRESS};
use super::tonight;
use super::MediaKind;
use rusqlite::params;
use std::sync::LazyLock;
use unicode_normalization::char::is_combining_mark;
use unicode_normalization::UnicodeNormalization;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TitleRow {
    pub id: i64,
    pub kind: MediaKind,
    pub name: String,
    pub year: Option<u16>,
    pub file_count: u32,
    /// The file the UI plays when the title is picked. None once every file a
    /// title had has gone.
    pub first_file_id: Option<i64>,
}

const SELECT: &str = "SELECT t.id, t.kind, t.name, t.year,
    (SELECT COUNT(*) FROM files f WHERE f.title_id = t.id) AS file_count,
    (SELECT f.id FROM files f WHERE f.title_id = t.id ORDER BY f.quality DESC, f.id LIMIT 1) AS first_file_id
  FROM titles t";

pub(crate) fn row_to_title(r: &rusqlite::Row) -> rusqlite::Result<TitleRow> {
    let year: u16 = r.get(3)?;
    Ok(TitleRow {
        id: r.get(0)?,
        kind: MediaKind::from_str(&r.get::<_, String>(1)?).unwrap_or(MediaKind::Movie),
        name: r.get(2)?,
        year: if year == 0 { None } else { Some(year) },
        file_count: r.get(4)?,
        first_file_id: r.get(5)?,
    })
}

/// One title by the three columns that identify it, which is what a caller
/// holding nothing but a name has: `titles` is UNIQUE on them, so this matches
/// at most one row. `year` is 0 for a title nothing dated, the same encoding
/// the column uses.
///
/// Deliberately not by id. `titles.id` is an autoincrement rowid that a purged
/// and rescanned index hands out again from the start, so an id kept outside
/// the index - on a shelf tvOS drew before the purge, say - can come back
/// naming a different film. These three columns cannot: they either find the
/// title they were written for or find nothing.
pub fn title_by_key(
    db: &Db,
    kind: MediaKind,
    name: &str,
    year: u16,
) -> Result<Option<TitleRow>, IndexError> {
    let sql = format!("{SELECT} WHERE t.kind = ?1 AND t.name = ?2 AND t.year = ?3");
    let mut stmt = db.conn().prepare_cached(&sql)?;
    let mut rows = stmt.query_map(params![kind.as_str(), name, year], row_to_title)?;
    rows.next().transpose().map_err(IndexError::from)
}

/// What the viewer put aside for later, newest first.
///
/// Newest first because a watchlist is a stack, not an archive: the thing
/// added last is the thing still on the viewer's mind, and a rail that opened
/// on the oldest entry would show whatever they have been avoiding for months.
pub fn watchlist(db: &Db, limit: u32) -> Result<Vec<TitleRow>, IndexError> {
    let sql = format!(
        "{SELECT} JOIN watchlist w ON w.title_id = t.id
         WHERE EXISTS (SELECT 1 FROM files f WHERE f.title_id = t.id)
         ORDER BY w.added_at DESC, t.id DESC LIMIT ?1"
    );
    let mut stmt = db.conn().prepare_cached(&sql)?;
    let rows = stmt.query_map(params![limit], row_to_title)?;
    Ok(rows.collect::<Result<Vec<_>, _>>()?)
}

/// Where "later" on the morning review is kept: the moment it was pressed,
/// which puts aside every evening that had ended by then.
const REVIEW_DISMISSED: &str = "review.dismissed_evening";

/// What was finished during the last evening and not yet judged, from the
/// end of that evening until the next one starts, in the order it was
/// finished. Empty during an evening, once "later" was pressed for it, and
/// on a morning after an evening with nothing finished.
pub fn evening_review(db: &Db, now: i64, tz_offset_secs: i32) -> Result<Vec<TitleRow>, IndexError> {
    if tonight::evening_of(now, tz_offset_secs).is_some() {
        return Ok(Vec::new());
    }
    // outside an evening, the last one started on the local day before
    let evening = (now + i64::from(tz_offset_secs)).div_euclid(86_400) - 1;
    let (start, end) = tonight::session_span(evening, tz_offset_secs);
    let dismissed = db
        .setting(REVIEW_DISMISSED)?
        .and_then(|v| v.parse::<i64>().ok());
    if dismissed.is_some_and(|at| at >= end) {
        return Ok(Vec::new());
    }
    let mut stmt = db.conn().prepare_cached(
        "SELECT t.id, t.kind, t.name, t.year,
                (SELECT COUNT(*) FROM files c WHERE c.title_id = t.id),
                (SELECT c.id FROM files c WHERE c.title_id = t.id ORDER BY c.quality DESC, c.id LIMIT 1)
         FROM watch_state w
         CROSS JOIN files f ON f.id = w.file_id
         CROSS JOIN titles t ON t.id = f.title_id
         WHERE w.watched = 1 AND w.updated_at >= ?1 AND w.updated_at < ?2
           AND NOT EXISTS (SELECT 1 FROM title_verdict v WHERE v.title_id = t.id)
         GROUP BY t.id
         ORDER BY MAX(w.updated_at), t.id",
    )?;
    let rows = stmt.query_map(params![start, end], row_to_title)?;
    Ok(rows.collect::<Result<Vec<_>, _>>()?)
}

pub fn dismiss_review(db: &Db, now: i64) -> Result<(), IndexError> {
    db.set_setting(REVIEW_DISMISSED, &now.to_string())
}

/// One entry of the queue under the trio. A resume file means the card wears
/// a progress bar; its absence means the title was only ever wanted.
#[derive(Debug, Clone, PartialEq)]
pub struct QueueRow {
    pub title: TitleRow,
    pub resume_file_id: Option<i64>,
    pub position_secs: f64,
    pub duration_secs: f64,
}

/// Everything the viewer is in the middle of, as one row: titles left
/// running, the episode after one just finished, a series set down a while
/// ago, and the new season of one finished. Ranked by when each last moved,
/// the viewer's or the shelf's, which is the likeliest to be played next; a
/// title reached twice is kept at its first appearance.
pub fn up_next(db: &Db, limit: u32, now: i64) -> Result<Vec<QueueRow>, IndexError> {
    let mut found: Vec<(i64, QueueRow)> = Vec::new();
    let mut read = |sql: &str, args: &[&dyn rusqlite::ToSql], at: usize, running: bool| {
        let mut stmt = db.conn().prepare_cached(sql)?;
        let rows = stmt.query_map(args, |r| {
            Ok((
                r.get::<_, i64>(at)?,
                QueueRow {
                    title: row_to_title(r)?,
                    resume_file_id: r.get(5)?,
                    position_secs: if running { r.get(6)? } else { 0.0 },
                    duration_secs: if running { r.get(7)? } else { 0.0 },
                },
            ))
        })?;
        for row in rows {
            found.push(row?);
        }
        Ok::<_, IndexError>(())
    };
    // what was left running stays however old; a next episode only while the
    // show is recent (see `QUEUE_REST_SECS`), and a pick-up from there on
    read(&RESUMING, &[&limit], 8, true)?;
    read(&NEXT_EPISODE, &[&limit, &(now - QUEUE_REST_SECS)], 8, false)?;
    read(
        &PICK_UP,
        &[
            &PICK_UP_EPISODES,
            &PICK_UP_SHARE,
            &(now - PICK_UP_BEFORE_SECS),
            &(now - PICK_UP_AFTER_SECS),
            &limit,
        ],
        6,
        false,
    )?;
    read(
        &NEW_SEASON,
        &[&(now - NEW_SEASON_SECS), &(now - QUEUE_REST_SECS), &limit],
        6,
        false,
    )?;
    // stable: at one instant the reads keep their own order
    found.sort_by_key(|(at, _)| std::cmp::Reverse(*at));
    let mut seen = std::collections::HashSet::new();
    Ok(found
        .into_iter()
        .map(|(_, row)| row)
        .filter(|row| seen.insert(row.title.id))
        .take(limit as usize)
        .collect())
}

/// Titles with a file left running, most recently touched first. The bare
/// columns beside MAX come from the row that holds the maximum, which is how
/// the resume file and its position arrive together.
static RESUMING: LazyLock<String> = LazyLock::new(|| {
    format!(
        "SELECT t.id, t.kind, t.name, t.year,
    (SELECT COUNT(*) FROM files c WHERE c.title_id = t.id) AS file_count,
    w.file_id, w.position_secs, w.duration_secs,
    MAX(w.updated_at) AS last
  FROM watch_state w
  JOIN files f ON f.id = w.file_id
  JOIN titles t ON t.id = f.title_id
  LEFT JOIN resume_dismissed d ON d.title_id = t.id
  WHERE {IN_PROGRESS}
  GROUP BY t.id
  HAVING COALESCE(d.dismissed_at, -1) < last
  ORDER BY last DESC, t.id
  LIMIT ?1"
    )
});

/// How long a show can lie untouched and still be next. Past a month it has
/// been set down rather than paused, and the home's pick-up row offers it.
pub const QUEUE_REST_SECS: i64 = 30 * 86_400;

/// Shows with an episode finished and another never started, touched inside
/// `QUEUE_REST_SECS` (`?2` is its start), resuming at the
/// earliest episode nothing has played. A show with a file left running is
/// not here: it is above, and the two would otherwise offer the same show
/// twice, once mid-episode and once at the start of the next.
static NEXT_EPISODE: LazyLock<String> = LazyLock::new(|| {
    format!(
        "SELECT t.id, t.kind, t.name, t.year,
    (SELECT COUNT(*) FROM files c WHERE c.title_id = t.id) AS file_count,
    (SELECT n.id FROM files n
       WHERE n.title_id = t.id
         AND NOT EXISTS (SELECT 1 FROM watch_state s WHERE s.file_id = n.id)
       ORDER BY COALESCE(n.season, 0), COALESCE(n.episode, 0), n.id
       LIMIT 1) AS first_file_id,
    0.0, 0.0,
    MAX(w.updated_at) AS last
  FROM watch_state w
  CROSS JOIN files f ON f.id = w.file_id
  CROSS JOIN titles t ON t.id = f.title_id
  WHERE w.watched = 1 AND t.kind = 'show'
  GROUP BY t.id
  HAVING first_file_id IS NOT NULL AND last > ?2
     AND NOT EXISTS (SELECT 1 FROM files p
                     CROSS JOIN watch_state w ON w.file_id = p.id
                     WHERE p.title_id = t.id AND {IN_PROGRESS})
  ORDER BY last DESC, t.id
  LIMIT ?1"
    )
});

/// How long a series must have lain untouched before it is set down rather
/// than paused (the queue lets it go at the same age), and after how long it
/// is forgotten rather than set down.
const PICK_UP_AFTER_SECS: i64 = QUEUE_REST_SECS;
const PICK_UP_BEFORE_SECS: i64 = 365 * 86_400;

/// Episodes finished before a series was being followed at all, and the
/// share of those started that were finished: a series abandoned episode
/// after episode is not one to be brought back to.
const PICK_UP_EPISODES: u32 = 3;
const PICK_UP_SHARE: f64 = 0.8;

/// Series with enough finished, a finishing habit, the last episode finished
/// and nothing left running, set down inside the span, with an episode never
/// started and not dismissed since. The file is the next episode's, as in the
/// queue's own `NEXT_EPISODE`.
static PICK_UP: LazyLock<String> = LazyLock::new(|| {
    format!(
        "SELECT t.id, t.kind, t.name, t.year,
    (SELECT COUNT(*) FROM files c WHERE c.title_id = t.id) AS file_count,
    (SELECT n.id FROM files n
       WHERE n.title_id = t.id
         AND NOT EXISTS (SELECT 1 FROM watch_state s WHERE s.file_id = n.id)
       ORDER BY COALESCE(n.season, 0), COALESCE(n.episode, 0), n.id
       LIMIT 1) AS first_file_id,
    MAX(w.updated_at) AS last
  FROM watch_state w
  CROSS JOIN files f ON f.id = w.file_id
  CROSS JOIN titles t ON t.id = f.title_id
  LEFT JOIN resume_dismissed d ON d.title_id = t.id
  WHERE t.kind = 'show' AND (w.watched = 1 OR w.position_secs > 0)
  GROUP BY t.id
  HAVING SUM(w.watched) >= ?1 AND SUM(w.watched) >= ?2 * COUNT(*)
     AND last >= ?3 AND last <= ?4
     AND first_file_id IS NOT NULL
     AND COALESCE(d.dismissed_at, -1) < last
     AND NOT EXISTS (SELECT 1 FROM files p
                     CROSS JOIN watch_state w ON w.file_id = p.id
                     WHERE p.title_id = t.id AND {IN_PROGRESS})
     AND (SELECT n.mtime FROM files n WHERE n.id = first_file_id) <= last
  ORDER BY last DESC, t.id
  LIMIT ?5"
    )
});

/// How long a new season stays news once its first episode is on the shelf.
const NEW_SEASON_SECS: i64 = 60 * 86_400;

/// Series whose next episode opens a season that reached the shelf after the
/// last episode played, inside `NEW_SEASON_SECS` (`?1`), set down before the
/// queue's own reach (`?2`): a show touched since is next in the queue. The
/// file is that season's first unplayed episode, newest season first.
static NEW_SEASON: LazyLock<String> = LazyLock::new(|| {
    format!(
        "SELECT s.id, s.kind, s.name, s.year, s.file_count, s.first_file_id, n.mtime FROM (
  SELECT t.id, t.kind, t.name, t.year,
    (SELECT COUNT(*) FROM files c WHERE c.title_id = t.id) AS file_count,
    (SELECT n.id FROM files n
       WHERE n.title_id = t.id
         AND NOT EXISTS (SELECT 1 FROM watch_state s WHERE s.file_id = n.id)
       ORDER BY COALESCE(n.season, 0), COALESCE(n.episode, 0), n.id
       LIMIT 1) AS first_file_id,
    MAX(w.updated_at) AS last,
    MAX(f.season) AS last_season
  FROM watch_state w
  CROSS JOIN files f ON f.id = w.file_id
  CROSS JOIN titles t ON t.id = f.title_id
  WHERE t.kind = 'show' AND w.watched = 1
  GROUP BY t.id
  HAVING first_file_id IS NOT NULL AND last <= ?2
     AND NOT EXISTS (SELECT 1 FROM files p
                     CROSS JOIN watch_state w ON w.file_id = p.id
                     WHERE p.title_id = t.id AND {IN_PROGRESS})) s
  CROSS JOIN files n ON n.id = s.first_file_id
  WHERE n.season > s.last_season AND n.mtime > s.last AND n.mtime >= ?1
  ORDER BY n.mtime DESC, s.id
  LIMIT ?3"
    )
});

/// Which shelf the library is browsed as. Each order has an index built for
/// it, and the query pins that index: the order is a walk that stops at the
/// page, never a sort of the shelf.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SortOrder {
    Name,
    Year,
    RecentlyAdded,
}

/// What the shelf is narrowed to. Every field absent is the whole library.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Filter {
    /// One genre tag, matched whole against the comma-joined list.
    pub genre: Option<String>,
    pub min_year: Option<u16>,
    pub max_year: Option<u16>,
    /// Nothing of it marked watched: no film seen, no episode of a show.
    pub unwatched: bool,
    /// A copy of it in 4K: one episode is enough for a show.
    pub uhd: bool,
}

/// What `unwatched` and `uhd` add to the WHERE, bound to the two parameter
/// numbers given: each a lookup through the files' title index, run only when
/// its flag is set.
fn flags_sql(unwatched: u8, uhd: u8) -> String {
    format!(
        "AND (?{unwatched} = 0 OR NOT EXISTS (SELECT 1 FROM files c
          JOIN watch_state w ON w.file_id = c.id WHERE c.title_id = t.id AND w.watched = 1))
    AND (?{uhd} = 0 OR EXISTS (SELECT 1 FROM files c
          WHERE c.title_id = t.id AND c.video_resolution = '4k'))"
    )
}

/// The browse query for one order. The index is pinned rather than chosen:
/// with a year range in the WHERE, SQLite drops the name index for the year one
/// and sorts what it finds, which is a pass over every title of the kind per
/// page. INDEXED BY also means a dropped index fails to prepare instead of
/// quietly costing a sort.
///
/// The genre is matched with INSTR over the comma-fenced list, not LIKE: a Plex
/// tag is whatever the user typed, and a "%" in one would make a LIKE pattern
/// match everything. An absent filter is the empty string, which the OR takes
/// before the subquery is ever run.
///
/// t.id breaks the ties: names are not unique, years are not either, and OFFSET
/// paging across separate statements would otherwise duplicate or skip rows
/// that share one.
fn browse_sql(sort: SortOrder) -> String {
    let (index, order) = match sort {
        SortOrder::Name => ("idx_titles_kind_name", "t.name COLLATE NOCASE, t.id"),
        SortOrder::Year => (
            "idx_titles_kind_year",
            "t.year DESC, t.name COLLATE NOCASE, t.id",
        ),
        SortOrder::RecentlyAdded => ("idx_titles_kind_added", "t.added_at DESC, t.id DESC"),
    };
    format!(
        "{SELECT} INDEXED BY {index}
  WHERE t.kind = ?1
    AND (?2 = '' OR EXISTS (SELECT 1 FROM metadata m WHERE m.title_id = t.id
          AND INSTR(',' || m.genres || ',', ',' || ?2 || ',') > 0))
    AND t.year BETWEEN ?3 AND ?4
    {flags}
  ORDER BY {order} LIMIT ?5 OFFSET ?6",
        flags = flags_sql(7, 8)
    )
}

pub fn list_titles(
    db: &Db,
    kind: MediaKind,
    filter: &Filter,
    sort: SortOrder,
    offset: u32,
    limit: u32,
) -> Result<Vec<TitleRow>, IndexError> {
    let sql = browse_sql(sort);
    let mut stmt = db.conn().prepare_cached(&sql)?;
    // year 0 is "unknown", so an unfiltered browse has to include it and a
    // decade must not
    let rows = stmt.query_map(
        params![
            kind.as_str(),
            filter.genre.as_deref().unwrap_or(""),
            filter.min_year.unwrap_or(0),
            filter.max_year.unwrap_or(u16::MAX),
            limit,
            offset,
            filter.unwatched,
            filter.uhd
        ],
        row_to_title,
    )?;
    Ok(rows.collect::<Result<Vec<_>, _>>()?)
}

/// How many titles the same WHERE matches, with no order and no page. The
/// order is left out because a count has none, so one answer serves all three
/// shelves; the year index is pinned instead of the name one because its
/// (kind, year) prefix makes an unnarrowed count a range scan of index entries
/// rather than a row read per title.
static COUNT: LazyLock<String> = LazyLock::new(|| {
    format!(
        "SELECT COUNT(*) FROM titles t INDEXED BY idx_titles_kind_year
  WHERE t.kind = ?1
    AND (?2 = '' OR EXISTS (SELECT 1 FROM metadata m WHERE m.title_id = t.id
          AND INSTR(',' || m.genres || ',', ',' || ?2 || ',') > 0))
    AND t.year BETWEEN ?3 AND ?4
    {}",
        flags_sql(5, 6)
    )
});

/// How many titles one kind holds under a filter. The predicates are
/// list_titles' own, character for character, which is what lets a grid page
/// against this count without the two ever disagreeing.
pub fn count_titles(db: &Db, kind: MediaKind, filter: &Filter) -> Result<u32, IndexError> {
    let mut stmt = db.conn().prepare_cached(&COUNT)?;
    Ok(stmt.query_row(
        params![
            kind.as_str(),
            filter.genre.as_deref().unwrap_or(""),
            filter.min_year.unwrap_or(0),
            filter.max_year.unwrap_or(u16::MAX),
            filter.unwatched,
            filter.uhd
        ],
        |r| r.get(0),
    )?)
}

/// The names of the shelf in title order, under the same WHERE as the
/// browse: the name index alone, so no title row is read.
static NAMES: LazyLock<String> = LazyLock::new(|| {
    format!(
        "SELECT t.name FROM titles t INDEXED BY idx_titles_kind_name
  WHERE t.kind = ?1
    AND (?2 = '' OR EXISTS (SELECT 1 FROM metadata m WHERE m.title_id = t.id
          AND INSTR(',' || m.genres || ',', ',' || ?2 || ',') > 0))
    AND t.year BETWEEN ?3 AND ?4
    {}
  ORDER BY t.name COLLATE NOCASE, t.id",
        flags_sql(5, 6)
    )
});

/// Where each initial starts on the shelf in title order: the letter, its
/// accent dropped, or "#" for a name that opens on anything else, and the
/// offset of its first title. In letter order, "#" first.
pub fn title_initials(
    db: &Db,
    kind: MediaKind,
    filter: &Filter,
) -> Result<Vec<(char, u32)>, IndexError> {
    let mut stmt = db.conn().prepare_cached(&NAMES)?;
    let mut rows = stmt.query(params![
        kind.as_str(),
        filter.genre.as_deref().unwrap_or(""),
        filter.min_year.unwrap_or(0),
        filter.max_year.unwrap_or(u16::MAX),
        filter.unwatched,
        filter.uhd
    ])?;
    // a name whose accent sorts it past "Z" files under a letter already met,
    // so the first offset of each letter is the one kept
    let mut first = std::collections::BTreeMap::new();
    let mut offset = 0u32;
    while let Some(row) = rows.next()? {
        let name: String = row.get(0)?;
        let initial = name
            .nfd()
            .find(|c| !is_combining_mark(*c))
            .map(|c| c.to_ascii_uppercase())
            .filter(char::is_ascii_alphabetic)
            .unwrap_or('#');
        first.entry(initial).or_insert(offset);
        offset += 1;
    }
    Ok(first.into_iter().collect())
}

/// What a filter bar can offer for one kind.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Facets {
    /// Every genre tag the kind carries, deduplicated, in order.
    pub genres: Vec<String>,
    /// The oldest and newest year the kind holds, ignoring the unknown ones.
    /// None when nothing in it has a year.
    pub min_year: Option<u16>,
    pub max_year: Option<u16>,
}

/// One walk of one kind, joined to what describes it. This is the only query
/// here that reads a whole kind rather than a page: the distinct values of a
/// comma-joined tag column are what no index can hold, and a filter bar with
/// no filters in it is not an option. It is read once, when the library screen
/// mounts, not once per page.
const FACETS: &str = "SELECT t.year, COALESCE(m.genres, '')
  FROM titles t INDEXED BY idx_titles_kind_name
  LEFT JOIN metadata m ON m.title_id = t.id
  WHERE t.kind = ?1";

/// A tag is kept exactly as its source wrote it: no case-folding, no merging
/// "Sci-Fi" into "Science Fiction". The browse filter (list_titles) matches a
/// genre whole and literally against the same comma list, so every chip this
/// returns is guaranteed at least the title it came from; folding tags here
/// without folding them at write time would only let a chip claim titles the
/// filter then fails to find.
pub fn library_facets(db: &Db, kind: MediaKind) -> Result<Facets, IndexError> {
    let mut stmt = db.conn().prepare_cached(FACETS)?;
    let rows = stmt.query_map(params![kind.as_str()], |r| {
        Ok((r.get::<_, u16>(0)?, r.get::<_, String>(1)?))
    })?;
    let mut genres = std::collections::BTreeSet::new();
    let mut facets = Facets::default();
    for row in rows {
        let (year, tags) = row?;
        // 0 is the "unknown" year every title without one carries
        if year > 0 {
            facets.min_year = Some(facets.min_year.map_or(year, |m| m.min(year)));
            facets.max_year = Some(facets.max_year.map_or(year, |m| m.max(year)));
        }
        for tag in tags.split(',').filter(|t| !t.is_empty()) {
            genres.insert(tag.to_string());
        }
    }
    facets.genres = genres.into_iter().collect();
    Ok(facets)
}

/// Where one file lives: the source that holds it, its path inside that
/// source, and the mtime the scan last saw. None when no row has that id.
///
/// The mtime is what the player's analysis cache keys a probe result by,
/// beside the file's identity: a file rewritten under the same path has a
/// container the cached probe no longer describes.
pub fn file_location(db: &Db, file_id: i64) -> Result<Option<(String, String, i64)>, IndexError> {
    let mut stmt = db
        .conn()
        .prepare_cached("SELECT source_id, path, mtime FROM files WHERE id = ?1")?;
    let mut rows = stmt.query(params![file_id])?;
    Ok(match rows.next()? {
        Some(row) => Some((row.get(0)?, row.get(1)?, row.get(2)?)),
        None => None,
    })
}

/// Which of the indexed columns a hit matched, and what it matched there. The
/// index searches names, genres, billing and the crew alike, and without this a
/// viewer who typed an actor gets a grid of posters with nothing to say why any
/// of them is on it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum MatchField {
    Name,
    /// The billed person, spelled the way the metadata spells them.
    Cast(String),
    /// Who directed it. Its own answer rather than one crew answer, because
    /// "réalisé par" and "avec" are different sentences to put over a shelf.
    Director(String),
    /// Who wrote or scored it.
    Crew(String),
    Genre(String),
    /// One of its episodes is called this; the hit is the series.
    Episode {
        name: String,
        season: Option<u16>,
        episode: Option<u16>,
    },
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SearchHit {
    pub title: TitleRow,
    pub reason: MatchField,
}

/// The answer to one search.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct SearchResults {
    pub hits: Vec<SearchHit>,
    /// True when nothing carried every word typed and these carry some of
    /// them. Never a correction: each hit still holds something typed.
    pub relaxed: bool,
}

/// The hits for one query, best first. CROSS JOIN pins the order the two are
/// walked in: it is not a cartesian product, it is "do not reorder", and
/// without it SQLite may drive from the titles table and test each row against
/// the index.
///
/// The name is weighted ten times the genre and five times the billing: a
/// viewer typing "ford" wants the film called Ford before every film he is in.
/// A director outweighs the billing in turn: there are far fewer of them than
/// there are actors, so a word that lands on one is far more likely to be the
/// word that was meant. The writer and the composer weigh least of the people,
/// being the credit a viewer is least often searching for.
///
/// The order is the ranking, then the name and the id, so two hits scoring
/// alike come back in the same order every time. Sorting the hits is a sort of
/// what the MATCH returned, which the query bounds, not of the library.
///
/// The highlight() calls are what says which column answered: it runs the same
/// tokenizer the index was built with, so a word marked there is one this query
/// really matched, accents, case and prefixes included, which no second
/// comparison in Rust could promise.
const SEARCH: &str = "SELECT t.id, t.kind, t.name, t.year,
    (SELECT COUNT(*) FROM files f WHERE f.title_id = t.id) AS file_count,
    (SELECT f.id FROM files f WHERE f.title_id = t.id ORDER BY f.quality DESC, f.id LIMIT 1) AS first_file_id,
    highlight(title_search, 0, char(2), ''),
    highlight(title_search, 1, char(2), ''),
    highlight(title_search, 2, char(2), ''),
    highlight(title_search, 3, char(2), ''),
    highlight(title_search, 4, char(2), '')
  FROM title_search
  CROSS JOIN titles t ON t.id = title_search.rowid
  WHERE title_search MATCH ?1
  ORDER BY bm25(title_search, 10.0, 1.0, 2.0, 3.0, 1.5), t.name COLLATE NOCASE, t.id
  LIMIT ?2";

/// Episodes whose name carries the words, under the series they belong to,
/// best match first.
const EPISODES: &str = "SELECT t.id, t.kind, t.name, t.year,
    (SELECT COUNT(*) FROM files c WHERE c.title_id = t.id) AS file_count,
    (SELECT c.id FROM files c WHERE c.title_id = t.id ORDER BY c.quality DESC, c.id LIMIT 1) AS first_file_id,
    e.title, f.season, f.episode
  FROM episode_search
  CROSS JOIN episode_meta e ON e.file_id = episode_search.rowid
  CROSS JOIN files f ON f.id = e.file_id
  CROSS JOIN titles t ON t.id = f.title_id
  WHERE episode_search MATCH ?1
  ORDER BY bm25(episode_search), f.season, f.episode
  LIMIT ?2";

/// What SEARCH wraps a matched word in. A control character, so a marker in
/// the text that comes back is always this query's own and never a title.
const MARK: char = '\u{2}';

/// Every run of letters and digits in what was typed. Splitting on everything
/// else is what makes the input text rather than syntax: an operator, a star,
/// a quote or a bracket a viewer typed never reaches the parser, so no query
/// is a syntax error and none of them means something the viewer did not ask
/// for.
fn words(query: &str) -> Vec<&str> {
    query
        .split(|c: char| !c.is_alphanumeric())
        .filter(|word| !word.is_empty())
        .collect()
}

/// Those words as an FTS5 expression: each quoted and given a trailing star,
/// so every one of them is a prefix of something. `all` is the ordinary
/// search, where a word that matches nothing matches nothing at all; without
/// it any one word is enough.
fn match_expr(words: &[&str], all: bool) -> String {
    words
        .iter()
        .map(|word| format!("\"{word}\"*"))
        .collect::<Vec<_>>()
        .join(if all { " " } else { " OR " })
}

/// Which column answered, name first: a title carrying the word is why it is
/// here even when its billing carries it too. The director comes before the
/// billing for the same reason bm25 weighs it higher, and the rest of the crew
/// comes last of the people.
fn reason_of(name: &str, genres: &str, cast: &str, directors: &str, crew: &str) -> MatchField {
    if name.contains(MARK) {
        return MatchField::Name;
    }
    if let Some(who) = marked(directors) {
        return MatchField::Director(who);
    }
    if let Some(who) = marked(cast) {
        return MatchField::Cast(who);
    }
    if let Some(who) = marked(crew) {
        return MatchField::Crew(who);
    }
    match marked(genres) {
        Some(what) => MatchField::Genre(what),
        // MATCH answered, so something in the row matched: a hit whose column
        // this cannot name is still a hit, and the name is what says least.
        None => MatchField::Name,
    }
}

/// The entry of a comma-joined list carrying the most marked words, unmarked:
/// the one person both halves of "kristen stewart" landed in, rather than
/// whoever is billed first with either half of it.
fn marked(list: &str) -> Option<String> {
    let mut best: Option<(usize, &str)> = None;
    for entry in list.split(',') {
        let hits = entry.matches(MARK).count();
        if hits > 0 && best.is_none_or(|(most, _)| hits > most) {
            best = Some((hits, entry));
        }
    }
    best.map(|(_, entry)| entry.replace(MARK, ""))
}

fn matching(db: &Db, expr: &str, limit: u32) -> Result<Vec<SearchHit>, IndexError> {
    let mut stmt = db.conn().prepare_cached(SEARCH)?;
    let rows = stmt.query_map(params![expr, limit], |row| {
        Ok(SearchHit {
            title: row_to_title(row)?,
            reason: reason_of(
                &row.get::<_, String>(6)?,
                &row.get::<_, String>(7)?,
                &row.get::<_, String>(8)?,
                &row.get::<_, String>(9)?,
                &row.get::<_, String>(10)?,
            ),
        })
    })?;
    Ok(rows.collect::<Result<Vec<_>, _>>()?)
}

/// The series whose episodes carry every word, once each by its best
/// episode, left out where the series is already among `hits`.
fn episode_hits(
    db: &Db,
    expr: &str,
    limit: u32,
    hits: &mut Vec<SearchHit>,
) -> Result<(), IndexError> {
    let mut stmt = db.conn().prepare_cached(EPISODES)?;
    let rows = stmt.query_map(params![expr, limit], |row| {
        Ok(SearchHit {
            title: row_to_title(row)?,
            reason: MatchField::Episode {
                name: row.get(6)?,
                season: row.get(7)?,
                episode: row.get(8)?,
            },
        })
    })?;
    for hit in rows {
        let hit = hit?;
        if hits.len() >= limit as usize {
            break;
        }
        if !hits.iter().any(|h| h.title.id == hit.title.id) {
            hits.push(hit);
        }
    }
    Ok(())
}

pub fn search_titles(db: &Db, query: &str, limit: u32) -> Result<SearchResults, IndexError> {
    let words = words(query);
    if words.is_empty() {
        return Ok(SearchResults::default());
    }
    let strict = match_expr(&words, true);
    let mut hits = matching(db, &strict, limit)?;
    episode_hits(db, &strict, limit, &mut hits)?;
    // one word ORed with nothing is the same expression: asking it again would
    // cost a second query and answer exactly what this one did
    if !hits.is_empty() || words.len() < 2 {
        return Ok(SearchResults {
            hits,
            relaxed: false,
        });
    }
    // Nothing carries every word. On a remote that is usually one word of
    // several mistyped, and what the others match beats a blank screen. No
    // spelling is guessed at and no word is replaced: every title this returns
    // still carries something the viewer typed, and the screen says the query
    // was not matched whole.
    let hits = matching(db, &match_expr(&words, false), limit)?;
    Ok(SearchResults {
        relaxed: !hits.is_empty(),
        hits,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::index::db::{Db, FileMedia, FileRecord, MetadataRecord, MetadataSource};
    use crate::index::{MediaKind, Verdict};

    fn seed(db: &Db) {
        for (i, name) in ["alpha", "Beta", "gamma"].iter().enumerate() {
            let id = db.upsert_title(MediaKind::Movie, name, Some(2000)).unwrap();
            db.upsert_file(&FileRecord {
                source_id: "s1".into(),
                dir: "Movies".into(),
                path: format!("Movies/{name}.mkv"),
                size: 1,
                mtime: i as i64,
                seen_gen: 1,
                title_id: id,
                season: None,
                episode: None,
                rating_key: None,
                media: FileMedia::default(),
            })
            .unwrap();
        }
        db.upsert_title(MediaKind::Show, "Berserk", None).unwrap();
    }

    use crate::index::db::{WatchAuthority, WatchRecord};

    fn one_film(db: &Db, name: &str) -> i64 {
        let id = db.upsert_title(MediaKind::Movie, name, Some(2000)).unwrap();
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

    fn partway(db: &Db, title_id: i64, pos: f64, at: i64) {
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
                position_secs: pos,
                duration_secs: 6000.0,
                watched: false,
                plays: 0,
                updated_at: at,
            },
            WatchAuthority::Report,
        )
        .unwrap();
    }

    fn episode(db: &Db, title_id: i64, season: u16, ep: u16) -> i64 {
        let path = format!("Shows/s{season:02}e{ep:02}.mkv");
        db.upsert_file(&FileRecord {
            source_id: "s1".into(),
            dir: "Shows".into(),
            path: path.clone(),
            size: 1,
            mtime: 0,
            seen_gen: 1,
            title_id,
            season: Some(season),
            episode: Some(ep),
            rating_key: None,
            media: FileMedia::default(),
        })
        .unwrap();
        db.file_id("s1", &path).unwrap().unwrap()
    }

    fn watched_at(db: &Db, file_id: i64, at: i64) {
        db.upsert_watch_state(
            &WatchRecord {
                file_id,
                position_secs: 0.0,
                duration_secs: 7000.0,
                watched: true,
                plays: 1,
                updated_at: at,
            },
            WatchAuthority::Report,
        )
        .unwrap();
    }

    fn running(db: &Db, file_id: i64, position: f64, at: i64) {
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

    /// Where the queue tests read it from: long enough after their stamps
    /// that nothing in them is recent, well inside the month the queue keeps.
    const NOW: i64 = 86_400;

    fn queue_names(db: &Db) -> Vec<String> {
        up_next(db, 20, NOW)
            .unwrap()
            .into_iter()
            .map(|q| q.title.name)
            .collect()
    }

    /// An episode found by its own name brings its series up once, saying
    /// which episode it was.
    #[test]
    fn an_episode_name_finds_its_series_once() {
        let db = Db::open_in_memory().unwrap();
        let show = db
            .upsert_title(MediaKind::Show, "Breaking Bad", None)
            .unwrap();
        for (episode, name) in [(14u16, "Ozymandias"), (15, "Granite State")] {
            let path = format!("Shows/Breaking Bad/S05E{episode}.mkv");
            db.upsert_file(&FileRecord {
                source_id: "s1".into(),
                dir: "Shows".into(),
                path: path.clone(),
                size: 1,
                mtime: 0,
                seen_gen: 1,
                title_id: show,
                season: Some(5),
                episode: Some(episode),
                rating_key: None,
                media: FileMedia::default(),
            })
            .unwrap();
            let file = db.file_id("s1", &path).unwrap().unwrap();
            db.upsert_episode_meta(
                file,
                &crate::index::db::EpisodeMeta {
                    title: name.to_string(),
                    summary: String::new(),
                    still_path: String::new(),
                    air_year: 0,
                },
            )
            .unwrap();
        }
        let found = search_titles(&db, "ozymand", 10).unwrap();
        assert_eq!(found.hits.len(), 1);
        assert_eq!(found.hits[0].title.id, show);
        assert_eq!(
            found.hits[0].reason,
            MatchField::Episode {
                name: "Ozymandias".into(),
                season: Some(5),
                episode: Some(14)
            }
        );
        // the series by its own name is a name hit, and its episodes add nothing
        let named = search_titles(&db, "breaking", 10).unwrap();
        assert_eq!(named.hits.len(), 1);
        assert_eq!(named.hits[0].reason, MatchField::Name);
    }

    #[test]
    fn a_film_seen_before_and_running_again_is_still_one_to_carry_on_with() {
        let db = Db::open_in_memory().unwrap();
        one_film(&db, "Severance");
        let f = db.file_id("s1", "Movies/Severance.mkv").unwrap().unwrap();
        // finished once, and running again since: what the queue exists for
        // is the position, and the flag is only what the past holds
        watched_at(&db, f, 100);
        running(&db, f, 5_530.0, 200);
        assert_eq!(queue_names(&db), ["Severance"]);
        assert_eq!(up_next(&db, 20, NOW).unwrap()[0].resume_file_id, Some(f));

        // and played on past the finish mark it drops out again: nothing
        // clears the position locally, so the queue must not offer the
        // credits of something that ended
        running(&db, f, 6_400.0, 300);
        assert!(queue_names(&db).is_empty());
    }

    #[test]
    fn a_dismissed_title_leaves_the_queue_and_comes_back_when_it_is_played_again() {
        let db = Db::open_in_memory().unwrap();
        let film = one_film(&db, "Dune");
        let f = db.file_id("s1", "Movies/Dune.mkv").unwrap().unwrap();
        running(&db, f, 1_000.0, 100);
        assert_eq!(queue_names(&db), ["Dune"]);

        db.dismiss_resume(film, 150).unwrap();
        assert!(queue_names(&db).is_empty());

        // playing it again answers for progress the dismissal never saw
        running(&db, f, 2_000.0, 200);
        assert_eq!(queue_names(&db), ["Dune"]);
    }

    #[test]
    fn the_episode_after_the_one_that_ended_is_what_the_queue_offers() {
        let db = Db::open_in_memory().unwrap();
        let show = db.upsert_title(MediaKind::Show, "Berserk", None).unwrap();
        let first = episode(&db, show, 1, 1);
        let second = episode(&db, show, 1, 2);
        watched_at(&db, first, 100);

        let queue = up_next(&db, 20, NOW).unwrap();
        assert_eq!(queue.len(), 1);
        assert_eq!(queue[0].title.name, "Berserk");
        assert_eq!(queue[0].resume_file_id, Some(second));
        // never started, so there is no progress to draw
        assert_eq!(queue[0].position_secs, 0.0);

        // and a show with a file left running is the running one, not the
        // next: the two would otherwise offer the same show twice
        running(&db, second, 900.0, 200);
        let queue = up_next(&db, 20, NOW).unwrap();
        assert_eq!(queue.len(), 1);
        assert_eq!(queue[0].resume_file_id, Some(second));
        assert_eq!(queue[0].position_secs, 900.0);
    }

    #[test]
    fn a_show_resumes_on_the_episode_touched_last_of_several() {
        let db = Db::open_in_memory().unwrap();
        let show = db.upsert_title(MediaKind::Show, "Berserk", None).unwrap();
        let first = episode(&db, show, 1, 1);
        let second = episode(&db, show, 1, 2);
        running(&db, first, 500.0, 100);
        running(&db, second, 900.0, 300);

        let queue = up_next(&db, 20, NOW).unwrap();
        assert_eq!(queue.len(), 1);
        assert_eq!(queue[0].resume_file_id, Some(second));
        assert_eq!(queue[0].position_secs, 900.0);
    }

    #[test]
    fn the_queue_holds_what_was_started_and_not_what_was_only_wanted() {
        let db = Db::open_in_memory().unwrap();
        let started = one_film(&db, "Heat");
        let wanted = one_film(&db, "Collateral");
        partway(&db, started, 1_200.0, 100);
        db.set_watchlisted(wanted, true, 200).unwrap();

        let queue = up_next(&db, 20, NOW).unwrap();
        assert_eq!(
            queue
                .iter()
                .map(|q| q.title.name.as_str())
                .collect::<Vec<_>>(),
            ["Heat"]
        );
        assert!(queue[0].resume_file_id.is_some());
        assert_eq!(queue[0].position_secs, 1_200.0);
        assert_eq!(queue[0].duration_secs, 6_000.0);
    }

    #[test]
    fn a_title_both_started_and_wanted_is_shown_once_as_started() {
        let db = Db::open_in_memory().unwrap();
        let both = one_film(&db, "Heat");
        partway(&db, both, 1_200.0, 100);
        db.set_watchlisted(both, true, 200).unwrap();

        let queue = up_next(&db, 20, NOW).unwrap();
        assert_eq!(queue.len(), 1);
        assert!(queue[0].resume_file_id.is_some());
    }

    /// A show nobody has touched for a month is no longer next: the queue lets
    /// it go, and the home's pick-up row is where it is offered from then on.
    #[test]
    fn a_show_left_a_month_ago_leaves_the_queue() {
        let db = Db::open_in_memory().unwrap();
        let show = db.upsert_title(MediaKind::Show, "Berserk", None).unwrap();
        let first = episode(&db, show, 1, 1);
        episode(&db, show, 1, 2);
        let now = 100 * 86_400;
        watched_at(&db, first, now - 29 * 86_400);
        assert_eq!(up_next(&db, 20, now).unwrap().len(), 1);
        watched_at(&db, first, now - 30 * 86_400);
        assert!(up_next(&db, 20, now).unwrap().is_empty());
    }

    #[test]
    fn a_queue_with_nothing_in_it_is_empty_rather_than_absent() {
        let db = Db::open_in_memory().unwrap();
        one_film(&db, "Heat");
        assert!(up_next(&db, 20, NOW).unwrap().is_empty());
    }

    #[test]
    fn lists_paged_case_insensitive_by_name() {
        let db = Db::open_in_memory().unwrap();
        seed(&db);
        let page = list_titles(
            &db,
            MediaKind::Movie,
            &Filter::default(),
            SortOrder::Name,
            0,
            2,
        )
        .unwrap();
        let names: Vec<&str> = page.iter().map(|t| t.name.as_str()).collect();
        assert_eq!(names, ["alpha", "Beta"]);
        assert_eq!(page[0].file_count, 1);
        assert_eq!(page[0].year, Some(2000));
        let page2 = list_titles(
            &db,
            MediaKind::Movie,
            &Filter::default(),
            SortOrder::Name,
            2,
            2,
        )
        .unwrap();
        assert_eq!(page2.len(), 1);
        assert_eq!(page2[0].name, "gamma");
    }

    #[test]
    fn pages_are_stable_across_titles_sharing_a_name() {
        let db = Db::open_in_memory().unwrap();
        // inserted newest first, so id order and year order disagree
        let newer = db
            .upsert_title(MediaKind::Movie, "Dune", Some(2021))
            .unwrap();
        let older = db
            .upsert_title(MediaKind::Movie, "Dune", Some(1984))
            .unwrap();
        let first = list_titles(
            &db,
            MediaKind::Movie,
            &Filter::default(),
            SortOrder::Name,
            0,
            1,
        )
        .unwrap();
        let second = list_titles(
            &db,
            MediaKind::Movie,
            &Filter::default(),
            SortOrder::Name,
            1,
            1,
        )
        .unwrap();
        assert_eq!(first.len(), 1);
        assert_eq!(second.len(), 1);
        assert_eq!(first[0].id, newer);
        assert_eq!(second[0].id, older);
    }

    #[test]
    fn a_title_names_a_file_the_player_can_open() {
        let db = Db::open_in_memory().unwrap();
        seed(&db);
        let movies = list_titles(
            &db,
            MediaKind::Movie,
            &Filter::default(),
            SortOrder::Name,
            0,
            10,
        )
        .unwrap();
        let first = movies[0]
            .first_file_id
            .expect("a title with a file names it");
        let (source_id, path, _mtime) = file_location(&db, first).unwrap().unwrap();
        assert_eq!(
            (source_id.as_str(), path.as_str()),
            ("s1", "Movies/alpha.mkv")
        );
        // a title nothing holds a file for names none
        let shows = list_titles(
            &db,
            MediaKind::Show,
            &Filter::default(),
            SortOrder::Name,
            0,
            10,
        )
        .unwrap();
        assert_eq!(shows[0].first_file_id, None);
        // and an id no row has is not an error
        assert_eq!(file_location(&db, 9999).unwrap(), None);
    }

    /// Four films whose name order, year order and arrival order all disagree,
    /// two of them sharing a genre, so an order or a filter that did nothing
    /// would still be visible.
    fn shelf() -> Db {
        let db = Db::open_in_memory().unwrap();
        for (name, year, mtime, genres) in [
            ("Alien", 1979u16, 300i64, "Horreur,Science-Fiction"),
            ("Blade Runner", 1982, 100, "Science-Fiction,Thriller"),
            ("Dune", 2021, 200, "Science-Fiction,Aventure"),
            ("Solaris", 1972, 400, "Drame"),
        ] {
            let id = db.upsert_title(MediaKind::Movie, name, Some(year)).unwrap();
            db.upsert_file(&FileRecord {
                source_id: "s1".into(),
                dir: "Movies".into(),
                path: format!("Movies/{name}.mkv"),
                size: 1,
                mtime,
                seen_gen: 1,
                title_id: id,
                season: None,
                episode: None,
                rating_key: None,
                media: FileMedia::default(),
            })
            .unwrap();
            db.upsert_metadata(&MetadataRecord {
                title_id: id,
                tmdb_id: None,
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
        db
    }

    fn browsed(db: &Db, filter: &Filter, sort: SortOrder) -> Vec<String> {
        list_titles(db, MediaKind::Movie, filter, sort, 0, 10)
            .unwrap()
            .into_iter()
            .map(|t| t.name)
            .collect()
    }

    #[test]
    fn the_three_orders_are_three_different_shelves() {
        let db = shelf();
        assert_eq!(
            browsed(&db, &Filter::default(), SortOrder::Name),
            ["Alien", "Blade Runner", "Dune", "Solaris"]
        );
        // newest first, which is neither the name order nor the arrival one
        assert_eq!(
            browsed(&db, &Filter::default(), SortOrder::Year),
            ["Dune", "Blade Runner", "Alien", "Solaris"]
        );
        assert_eq!(
            browsed(&db, &Filter::default(), SortOrder::RecentlyAdded),
            ["Solaris", "Alien", "Dune", "Blade Runner"]
        );
    }

    #[test]
    fn a_filter_narrows_the_shelf_and_keeps_its_order() {
        let db = shelf();
        let sf = Filter {
            genre: Some("Science-Fiction".to_string()),
            ..Filter::default()
        };
        assert_eq!(
            browsed(&db, &sf, SortOrder::Name),
            ["Alien", "Blade Runner", "Dune"]
        );
        assert_eq!(
            browsed(&db, &sf, SortOrder::Year),
            ["Dune", "Blade Runner", "Alien"]
        );

        let eighties = Filter {
            min_year: Some(1980),
            max_year: Some(1989),
            ..Filter::default()
        };
        assert_eq!(browsed(&db, &eighties, SortOrder::Name), ["Blade Runner"]);

        // the two narrow together, not one or the other
        let both = Filter {
            genre: Some("Thriller".to_string()),
            min_year: Some(1970),
            max_year: Some(1979),
            ..Filter::default()
        };
        assert!(browsed(&db, &both, SortOrder::Name).is_empty());
    }

    /// The count and the shelf are one query answered two ways: a grid pages
    /// against the count and would draw a hole past the last title, or stop
    /// short of it, the moment the two stopped agreeing.
    #[test]
    fn the_count_is_the_length_of_the_shelf_it_counts() {
        let db = shelf();
        for filter in [
            Filter::default(),
            Filter {
                genre: Some("Science-Fiction".to_string()),
                ..Filter::default()
            },
            Filter {
                min_year: Some(1980),
                max_year: Some(1989),
                ..Filter::default()
            },
            Filter {
                genre: Some("Thriller".to_string()),
                min_year: Some(1970),
                max_year: Some(1979),
                ..Filter::default()
            },
        ] {
            let counted = count_titles(&db, MediaKind::Movie, &filter).unwrap();
            assert_eq!(
                counted as usize,
                browsed(&db, &filter, SortOrder::Name).len(),
                "{filter:?}"
            );
        }
        // a kind that holds nothing counts nothing rather than failing
        assert_eq!(
            count_titles(&db, MediaKind::Show, &Filter::default()).unwrap(),
            0
        );
    }

    /// Unwatched and 4K narrow the shelf like the genre does, and the count
    /// follows them.
    #[test]
    fn unwatched_and_4k_narrow_the_shelf() {
        let db = shelf();
        let file = |name: &str| -> i64 {
            db.conn()
                .query_row(
                    "SELECT f.id FROM files f JOIN titles t ON t.id = f.title_id WHERE t.name = ?1",
                    params![name],
                    |r| r.get(0),
                )
                .unwrap()
        };
        db.set_watched(file("Alien"), true, 1).unwrap();
        db.conn()
            .execute(
                "UPDATE files SET video_resolution = '4k' WHERE id IN (?1, ?2)",
                params![file("Alien"), file("Dune")],
            )
            .unwrap();
        let unwatched = Filter {
            unwatched: true,
            ..Filter::default()
        };
        assert_eq!(
            browsed(&db, &unwatched, SortOrder::Name),
            ["Blade Runner", "Dune", "Solaris"]
        );
        let uhd = Filter {
            uhd: true,
            ..Filter::default()
        };
        assert_eq!(browsed(&db, &uhd, SortOrder::Name), ["Alien", "Dune"]);
        let both = Filter {
            unwatched: true,
            uhd: true,
            ..Filter::default()
        };
        assert_eq!(browsed(&db, &both, SortOrder::Year), ["Dune"]);
        for filter in [unwatched, uhd, both] {
            assert_eq!(
                count_titles(&db, MediaKind::Movie, &filter).unwrap() as usize,
                browsed(&db, &filter, SortOrder::Name).len(),
                "{filter:?}"
            );
        }
    }

    /// Each initial points at its first title in name order, an accent
    /// files under its letter, and anything but a letter under "#".
    #[test]
    fn the_initials_point_at_the_first_title_of_each_letter() {
        let db = shelf();
        for name in ["2001", "Écran", "eXistenZ"] {
            db.upsert_title(MediaKind::Movie, name, Some(1999)).unwrap();
        }
        // 2001, Alien, Blade Runner, Dune, eXistenZ, Solaris, Écran
        assert_eq!(
            title_initials(&db, MediaKind::Movie, &Filter::default()).unwrap(),
            [('#', 0), ('A', 1), ('B', 2), ('D', 3), ('E', 4), ('S', 5)]
        );
        let sf = Filter {
            genre: Some("Science-Fiction".to_string()),
            ..Filter::default()
        };
        assert_eq!(
            title_initials(&db, MediaKind::Movie, &sf).unwrap(),
            [('A', 0), ('B', 1), ('D', 2)]
        );
    }

    /// A title with no year carries 0, which an unnarrowed shelf lists and a
    /// decade must not: the count reads the same column the same way.
    #[test]
    fn an_undated_title_counts_where_it_is_listed() {
        let db = shelf();
        db.upsert_title(MediaKind::Movie, "Home Movie", None)
            .unwrap();
        assert_eq!(
            count_titles(&db, MediaKind::Movie, &Filter::default()).unwrap(),
            5
        );
        let seventies = Filter {
            min_year: Some(1970),
            max_year: Some(1979),
            ..Filter::default()
        };
        // Solaris and Alien, and not the undated one: a decade is a range the
        // 0 a title without a year carries falls outside of
        assert_eq!(count_titles(&db, MediaKind::Movie, &seventies).unwrap(), 2);
    }

    /// The whole point of counting rather than listing: what this costs must
    /// not grow with the width of a title row, and it must never become the
    /// walk of the table that `.length` of a listing was.
    #[test]
    fn the_count_is_a_walk_of_index_entries_and_nothing_else() {
        let db = shelf();
        let steps = plan(&db, &COUNT, params!["movie", "", 0, u16::MAX, false, false]);
        assert!(
            steps[0].contains("SEARCH t USING COVERING INDEX"),
            "{steps:#?}"
        );
        assert!(steps[0].contains("idx_titles_kind_year"), "{steps:#?}");
        assert!(!steps.iter().any(|s| s.contains("SCAN")), "{steps:#?}");
    }

    #[test]
    fn a_genre_filter_is_matched_whole_and_literally() {
        let db = Db::open_in_memory().unwrap();
        for (name, genres) in [
            ("Exact", "Drame,Doc_100%"),
            ("Prefixed", "DocX100Y"),
            ("Compound", "Science-Fiction"),
        ] {
            let id = db.upsert_title(MediaKind::Movie, name, Some(2000)).unwrap();
            db.upsert_metadata(&MetadataRecord {
                title_id: id,
                tmdb_id: None,
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
        // a Plex tag is whatever the user typed, wildcards included
        let filter = Filter {
            genre: Some("Doc_100%".to_string()),
            ..Filter::default()
        };
        assert_eq!(browsed(&db, &filter, SortOrder::Name), ["Exact"]);

        // "Fiction" is a substring of the "Science-Fiction" tag, not a tag
        // of its own, so it must match nothing
        let substring = Filter {
            genre: Some("Fiction".to_string()),
            ..Filter::default()
        };
        assert!(browsed(&db, &substring, SortOrder::Name).is_empty());
    }

    #[test]
    fn a_page_is_a_page_whatever_the_order() {
        let db = shelf();
        for sort in [SortOrder::Name, SortOrder::Year, SortOrder::RecentlyAdded] {
            let whole =
                list_titles(&db, MediaKind::Movie, &Filter::default(), sort, 0, 10).unwrap();
            let first = list_titles(&db, MediaKind::Movie, &Filter::default(), sort, 0, 2).unwrap();
            let second =
                list_titles(&db, MediaKind::Movie, &Filter::default(), sort, 2, 2).unwrap();
            let paged: Vec<i64> = first.iter().chain(second.iter()).map(|t| t.id).collect();
            let ids: Vec<i64> = whole.iter().map(|t| t.id).collect();
            // nothing duplicated across the pages and nothing skipped between
            // them, which is what the id tie-break is for
            assert_eq!(paged, ids, "{sort:?}");
        }
    }

    fn plan(db: &Db, sql: &str, args: impl rusqlite::Params) -> Vec<String> {
        let mut stmt = db
            .conn()
            .prepare(&format!("EXPLAIN QUERY PLAN {sql}"))
            .unwrap();
        let steps = stmt.query_map(args, |r| r.get(3)).unwrap();
        steps.collect::<Result<_, _>>().unwrap()
    }

    /// Each order walks the index built for it and stops at the limit. A sort
    /// would visit every title of the kind before the first page could be
    /// drawn, and would do it again for every page after that: on a 10 000
    /// title library that is the difference between browsing and waiting.
    #[test]
    fn every_order_is_a_walk_of_its_own_index_and_never_a_sort() {
        let db = shelf();
        for (sort, index) in [
            (SortOrder::Name, "idx_titles_kind_name"),
            (SortOrder::Year, "idx_titles_kind_year"),
            (SortOrder::RecentlyAdded, "idx_titles_kind_added"),
        ] {
            // the filters are the hard case: left to choose, SQLite takes the
            // year index for the year range and sorts the result by name
            let steps = plan(
                &db,
                &browse_sql(sort),
                params!["movie", "Science-Fiction", 1980, 1989, 10, 0, true, true],
            );
            assert!(steps[0].contains("SEARCH t USING"), "{steps:#?}");
            assert!(steps[0].contains(index), "{steps:#?}");
            assert!(
                !steps.iter().any(|s| s.contains("TEMP B-TREE")),
                "{steps:#?}"
            );
            // and nothing reaches a whole table on the way
            assert!(!steps.iter().any(|s| s.contains("SCAN")), "{steps:#?}");
        }
    }

    #[test]
    fn the_facets_are_what_the_kind_carries_and_nothing_else() {
        let db = shelf();
        // one show, so the two kinds cannot be confused for each other
        let expanse = db
            .upsert_title(MediaKind::Show, "The Expanse", Some(2015))
            .unwrap();
        db.upsert_metadata(&MetadataRecord {
            title_id: expanse,
            tmdb_id: None,
            overview_fr: None,
            overview_en: None,
            poster_path: None,
            backdrop_path: None,
            genres: "Drame".into(),
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

        let movies = library_facets(&db, MediaKind::Movie).unwrap();
        // every tag once, whatever the number of films carrying it
        assert_eq!(
            movies.genres,
            [
                "Aventure",
                "Drame",
                "Horreur",
                "Science-Fiction",
                "Thriller"
            ]
        );
        assert_eq!(movies.min_year, Some(1972));
        assert_eq!(movies.max_year, Some(2021));

        let shows = library_facets(&db, MediaKind::Show).unwrap();
        assert_eq!(shows.genres, ["Drame"]);
        assert_eq!(shows.min_year, Some(2015));
        assert_eq!(shows.max_year, Some(2015));
    }

    #[test]
    fn a_kind_with_nothing_in_it_offers_no_filters() {
        let db = Db::open_in_memory().unwrap();
        let facets = library_facets(&db, MediaKind::Movie).unwrap();
        assert!(facets.genres.is_empty());
        assert_eq!(facets.min_year, None);
        assert_eq!(facets.max_year, None);

        // a title nothing has described, and no year: it is still browsable,
        // and it contributes no chip
        db.upsert_title(MediaKind::Movie, "Home Movie", None)
            .unwrap();
        let facets = library_facets(&db, MediaKind::Movie).unwrap();
        assert!(facets.genres.is_empty());
        assert_eq!(facets.min_year, None);
    }

    /// The one query here that reads a whole kind. A comma-joined tag column
    /// has no index that can yield its distinct values, so this is a walk by
    /// construction; what it must not become is a walk plus a sort, or a walk
    /// of the file table.
    #[test]
    fn the_facets_are_one_walk_of_one_kind() {
        let db = shelf();
        let steps = plan(&db, FACETS, params!["movie"]);
        assert!(steps[0].contains("SEARCH t USING"), "{steps:#?}");
        assert!(steps[0].contains("idx_titles_kind_name"), "{steps:#?}");
        assert!(
            steps
                .iter()
                .any(|s| s.contains("SEARCH m USING INTEGER PRIMARY KEY")),
            "{steps:#?}"
        );
        assert!(
            !steps.iter().any(|s| s.contains("TEMP B-TREE")),
            "{steps:#?}"
        );
        assert!(!steps.iter().any(|s| s.contains("SCAN")), "{steps:#?}");
    }

    /// A library with something to find by each of the three things a viewer
    /// types: a name, a billing and a genre.
    fn searchable() -> Db {
        let db = Db::open_in_memory().unwrap();
        for (name, year, genres, cast) in [
            ("Blade Runner", 1982u16, "Science-Fiction", "Harrison Ford"),
            ("Am\u{e9}lie", 2001, "Comedie", "Audrey Tautou"),
            ("Solaris", 1972, "Drame", "Natalya Bondarchuk"),
        ] {
            let id = db.upsert_title(MediaKind::Movie, name, Some(year)).unwrap();
            db.upsert_file(&FileRecord {
                source_id: "s1".into(),
                dir: "Movies".into(),
                path: format!("Movies/{year}.mkv"),
                size: 1,
                mtime: 1,
                seen_gen: 1,
                title_id: id,
                season: None,
                episode: None,
                rating_key: None,
                media: FileMedia::default(),
            })
            .unwrap();
            db.upsert_metadata(&MetadataRecord {
                title_id: id,
                tmdb_id: None,
                overview_fr: None,
                overview_en: None,
                poster_path: None,
                backdrop_path: None,
                genres: genres.to_string(),
                cast_names: cast.to_string(),
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
        db
    }

    fn found(db: &Db, query: &str) -> Vec<String> {
        search_titles(db, query, 10)
            .unwrap()
            .hits
            .into_iter()
            .map(|hit| hit.title.name)
            .collect()
    }

    fn why(db: &Db, query: &str) -> Vec<MatchField> {
        search_titles(db, query, 10)
            .unwrap()
            .hits
            .into_iter()
            .map(|hit| hit.reason)
            .collect()
    }

    #[test]
    fn a_search_finds_a_name_a_billing_and_a_genre() {
        let db = searchable();
        // a prefix of the first word, and of a later one
        assert_eq!(found(&db, "bla"), ["Blade Runner"]);
        assert_eq!(found(&db, "runn"), ["Blade Runner"]);
        // the top billing, which is what a viewer looking for an actor types
        assert_eq!(found(&db, "harri"), ["Blade Runner"]);
        // and the genre
        assert_eq!(found(&db, "comedie"), ["Am\u{e9}lie"]);
        // two words narrow rather than widen: both have to match
        assert_eq!(found(&db, "blade harrison"), ["Blade Runner"]);
        // nothing carries both of these, and what says so is the relaxed pass
        // having to answer at all
        assert!(search_titles(&db, "blade tautou", 10).unwrap().relaxed);
    }

    #[test]
    fn an_accent_is_not_something_a_viewer_has_to_type() {
        let db = searchable();
        assert_eq!(found(&db, "amelie"), ["Am\u{e9}lie"]);
        assert_eq!(found(&db, "am\u{e9}lie"), ["Am\u{e9}lie"]);
    }

    #[test]
    fn what_a_viewer_types_is_never_read_as_syntax() {
        let db = searchable();
        // every one of these is an FTS5 operator or a quote, and every one of
        // them here is text somebody typed
        for query in ["AND", "OR", "NOT", "NEAR", "*", "\"", "^ - ( ) :", "%"] {
            assert!(found(&db, query).is_empty(), "{query}");
        }
        // and a query with nothing in it asks nothing at all
        assert!(found(&db, "   ").is_empty());
        assert!(found(&db, "").is_empty());
    }

    #[test]
    fn a_hit_carries_what_a_tile_draws_and_the_file_it_plays() {
        let db = searchable();
        let found = search_titles(&db, "solaris", 10).unwrap();
        assert_eq!(found.hits.len(), 1);
        assert_eq!(found.hits[0].title.year, Some(1972));
        assert_eq!(found.hits[0].title.file_count, 1);
        assert!(found.hits[0].title.first_file_id.is_some());
        assert_eq!(found.hits[0].title.kind, MediaKind::Movie);
    }

    #[test]
    fn a_hit_says_which_of_the_three_columns_answered() {
        let db = searchable();
        assert_eq!(why(&db, "bla"), [MatchField::Name]);
        // an actor's name, spelled as the billing spells it rather than as it
        // was typed: this is what the screen says the row of posters is
        assert_eq!(
            why(&db, "harri"),
            [MatchField::Cast("Harrison Ford".into())]
        );
        assert_eq!(why(&db, "comedie"), [MatchField::Genre("Comedie".into())]);
        // a title carrying the word is why it is here, whatever else does too
        let ford = db
            .upsert_title(MediaKind::Movie, "Ford v Ferrari", Some(2019))
            .unwrap();
        db.upsert_metadata(&MetadataRecord {
            title_id: ford,
            tmdb_id: None,
            overview_fr: None,
            overview_en: None,
            poster_path: None,
            backdrop_path: None,
            genres: "Drame".into(),
            cast_names: "Harrison Ford".into(),
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
            why(&db, "ford"),
            [MatchField::Name, MatchField::Cast("Harrison Ford".into())]
        );
    }

    #[test]
    fn a_search_finds_the_people_behind_the_camera() {
        let db = searchable();
        let prophete = db
            .upsert_title(MediaKind::Movie, "Un prophete", Some(2009))
            .unwrap();
        db.upsert_metadata(&MetadataRecord {
            title_id: prophete,
            tmdb_id: None,
            overview_fr: None,
            overview_en: None,
            poster_path: None,
            backdrop_path: None,
            genres: "Drame".into(),
            cast_names: "Tahar Rahim".into(),
            collections: String::new(),
            director_names: "Jacques Audiard".into(),
            writer_names: "Thomas Bidegain".into(),
            composer_names: "Alexandre Desplat".into(),
            source: MetadataSource::Tmdb,
            fetched_at: 1,
            critics: None,
            audience: None,
            release_date: None,
        })
        .unwrap();

        // the word the owner asked for, and the surname alone is what gets
        // typed from a sofa
        assert_eq!(found(&db, "audiard"), ["Un prophete"]);
        assert_eq!(
            why(&db, "audiard"),
            [MatchField::Director("Jacques Audiard".into())]
        );
        // the writer and the composer answer too, and say so as crew rather
        // than as the director
        assert_eq!(
            why(&db, "bidegain"),
            [MatchField::Crew("Thomas Bidegain".into())]
        );
        assert_eq!(
            why(&db, "desplat"),
            [MatchField::Crew("Alexandre Desplat".into())]
        );
        // a prefix, which is every keystroke of a search that has just started
        assert_eq!(found(&db, "audi"), ["Un prophete"]);
    }

    #[test]
    fn a_director_outranks_a_billing_carrying_the_same_word() {
        let db = searchable();
        for (name, cast, director) in [
            ("Le fils du chef", "Bruno Podalydes", ""),
            ("Sur mes levres", "Vincent Cassel", "Bruno Podalydes"),
        ] {
            let id = db.upsert_title(MediaKind::Movie, name, Some(2001)).unwrap();
            db.upsert_metadata(&MetadataRecord {
                title_id: id,
                tmdb_id: None,
                overview_fr: None,
                overview_en: None,
                poster_path: None,
                backdrop_path: None,
                genres: "Drame".into(),
                cast_names: cast.into(),
                collections: String::new(),
                director_names: director.into(),
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
        // both carry the word; the one he directed comes first, because there
        // are far fewer directors than actors and a word landing on one is
        // likelier to be the word that was meant
        assert_eq!(
            found(&db, "podalydes"),
            ["Sur mes levres", "Le fils du chef"]
        );
    }

    #[test]
    fn the_billing_a_hit_names_is_the_one_the_typed_words_landed_in() {
        let db = searchable();
        let id = db
            .upsert_title(MediaKind::Movie, "Personal Shopper", Some(2016))
            .unwrap();
        db.upsert_metadata(&MetadataRecord {
            title_id: id,
            tmdb_id: None,
            overview_fr: None,
            overview_en: None,
            poster_path: None,
            backdrop_path: None,
            genres: "Drame".into(),
            // one name carries half of what was typed and is billed first
            cast_names: "Jon Stewart,Kristen Stewart".into(),
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
            why(&db, "kristen stewart"),
            [MatchField::Cast("Kristen Stewart".into())]
        );
    }

    #[test]
    fn one_word_of_several_mistyped_still_finds_what_the_others_match() {
        let db = searchable();
        // "blade tautou" carries no title: on a remote that is a word typed
        // wrong, and what the rest matches beats a blank screen
        let found = search_titles(&db, "blade tautou", 10).unwrap();
        assert!(found.relaxed);
        let names: Vec<&str> = found
            .hits
            .iter()
            .map(|hit| hit.title.name.as_str())
            .collect();
        assert_eq!(names, ["Blade Runner", "Am\u{e9}lie"]);
        // a query that matched whole is never presented as anything less
        assert!(!search_titles(&db, "blade harrison", 10).unwrap().relaxed);
    }

    #[test]
    fn one_word_on_its_own_is_never_answered_with_a_different_one() {
        let db = searchable();
        // no correction is guessed at: a wrong one reads as the library
        // holding something it does not
        let found = search_titles(&db, "bladde", 10).unwrap();
        assert!(found.hits.is_empty());
        assert!(!found.relaxed);
        // and neither is a pair of words that match nothing at all
        let found = search_titles(&db, "bladde tautoux", 10).unwrap();
        assert!(found.hits.is_empty());
        assert!(!found.relaxed);
    }

    #[test]
    fn a_name_outranks_what_is_only_a_genre_or_a_billing() {
        let db = searchable();
        let ford = db
            .upsert_title(MediaKind::Movie, "Ford v Ferrari", Some(2019))
            .unwrap();
        db.upsert_metadata(&MetadataRecord {
            title_id: ford,
            tmdb_id: None,
            overview_fr: None,
            overview_en: None,
            poster_path: None,
            backdrop_path: None,
            genres: "Drame".into(),
            cast_names: "Matt Damon".into(),
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
        // one carries the word in its name, the other in its billing
        assert_eq!(found(&db, "ford"), ["Ford v Ferrari", "Blade Runner"]);
    }

    #[test]
    fn the_index_follows_a_title_that_is_described_later() {
        let db = Db::open_in_memory().unwrap();
        let dune = db
            .upsert_title(MediaKind::Movie, "Dune", Some(2021))
            .unwrap();
        assert_eq!(found(&db, "dune"), ["Dune"]);
        // nothing described it yet, so nothing else finds it
        assert!(found(&db, "chalamet").is_empty());

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
            source: MetadataSource::Tmdb,
            fetched_at: 1,
            critics: None,
            audience: None,
            release_date: None,
        })
        .unwrap();
        assert_eq!(found(&db, "chalamet"), ["Dune"]);
    }

    /// The search must be a lookup in the FTS index, not a filter over a scan
    /// of it. "0:M" is what says so: the M is the MATCH constraint handed to
    /// the virtual table, and without it SQLite reads every row of the index
    /// and tests them one by one.
    #[test]
    fn the_search_is_driven_by_the_index_and_not_by_the_library() {
        let db = searchable();
        let steps = plan(&db, SEARCH, params!["\"bla\"*", 10]);
        assert!(
            steps[0].contains("title_search VIRTUAL TABLE INDEX 0:M"),
            "{steps:#?}"
        );
        assert!(
            steps
                .iter()
                .any(|s| s.contains("SEARCH t USING INTEGER PRIMARY KEY")),
            "{steps:#?}"
        );
        // the titles table is joined into, never walked; "t" must be a whole
        // word here, since "title_search" also starts with "SCAN t"
        assert!(
            !steps.iter().any(|s| {
                let mut words = s.split_whitespace();
                words.next() == Some("SCAN") && words.next() == Some("t")
            }),
            "{steps:#?}"
        );
    }

    /// Scratch: how long the owner's own index takes to deal a home screen.
    #[test]
    #[ignore]
    fn owner_home_rows_probe() {
        let path = std::env::var("LEXIS_PROBE_DB").unwrap();
        let db = Db::open_read_only(std::path::Path::new(&path)).unwrap();
        for _ in 0..3 {
            let start = std::time::Instant::now();
            let rows = crate::index::rows::browse_rows(
                &db,
                Some(MediaKind::Movie),
                1_755_000_000,
                0,
                &std::collections::HashSet::new(),
            )
            .unwrap();
            println!("home_rows in {:?}", start.elapsed());
            for row in &rows {
                println!("    {:?} ({})", row.reason, row.items.len());
            }
        }
    }

    const TZ: i32 = 3_600;
    /// A Friday: the evening that starts on it runs into Saturday morning.
    const FRIDAY: i64 = 20_000;

    /// Unix seconds for a local day, hour and minute.
    fn local(day: i64, hour: i64, minute: i64) -> i64 {
        day * 86_400 + hour * 3_600 + minute * 60 - i64::from(TZ)
    }

    fn finished(db: &Db, title_id: i64, at: i64) {
        let file_id: i64 = db
            .conn()
            .query_row(
                "SELECT id FROM files WHERE title_id = ?1",
                [title_id],
                |r| r.get(0),
            )
            .unwrap();
        watched_at(db, file_id, at);
    }

    fn reviewed(db: &Db, now: i64) -> Vec<String> {
        evening_review(db, now, TZ)
            .unwrap()
            .into_iter()
            .map(|t| t.name)
            .collect()
    }

    #[test]
    fn a_film_finished_at_ten_last_night_is_reviewed_in_the_morning_and_not_at_seven_pm() {
        let db = Db::open_in_memory().unwrap();
        let heat = one_film(&db, "Heat");
        finished(&db, heat, local(FRIDAY, 22, 0));
        let late = one_film(&db, "Late");
        finished(&db, late, local(FRIDAY + 1, 1, 30));
        let before = one_film(&db, "Before");
        finished(&db, before, local(FRIDAY, 17, 0));

        // still the evening it was watched in
        assert!(reviewed(&db, local(FRIDAY + 1, 2, 0)).is_empty());
        assert_eq!(reviewed(&db, local(FRIDAY + 1, 6, 0)), ["Heat", "Late"]);
        assert_eq!(reviewed(&db, local(FRIDAY + 1, 10, 0)), ["Heat", "Late"]);
        assert!(reviewed(&db, local(FRIDAY + 1, 19, 0)).is_empty());

        db.set_verdict(heat, Some(Verdict::Loved), local(FRIDAY + 1, 10, 1))
            .unwrap();
        assert_eq!(reviewed(&db, local(FRIDAY + 1, 10, 2)), ["Late"]);
    }

    #[test]
    fn later_puts_one_evening_aside_and_not_the_next() {
        let db = Db::open_in_memory().unwrap();
        let heat = one_film(&db, "Heat");
        finished(&db, heat, local(FRIDAY, 22, 0));
        dismiss_review(&db, local(FRIDAY + 1, 10, 0)).unwrap();
        assert!(reviewed(&db, local(FRIDAY + 1, 11, 0)).is_empty());

        let next = one_film(&db, "Next");
        finished(&db, next, local(FRIDAY + 1, 23, 0));
        assert_eq!(reviewed(&db, local(FRIDAY + 2, 10, 0)), ["Next"]);
    }

    #[test]
    fn a_weekend_afternoon_is_not_the_evening_before() {
        let db = Db::open_in_memory().unwrap();
        let matinee = one_film(&db, "Matinee");
        finished(&db, matinee, local(FRIDAY + 1, 15, 0));
        let night = one_film(&db, "Night");
        finished(&db, night, local(FRIDAY + 1, 21, 0));
        assert_eq!(reviewed(&db, local(FRIDAY + 2, 10, 0)), ["Night"]);
        // and a morning after an evening with nothing finished has nothing
        assert!(reviewed(&db, local(FRIDAY + 3, 10, 0)).is_empty());
    }
}
