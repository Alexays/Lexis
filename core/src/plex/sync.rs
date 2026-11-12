use super::client::{ItemsPage, PlexClient, PlexError, TYPE_EPISODE, TYPE_MOVIE, TYPE_SHOW};
use super::models::{Media, Metadata, Part, Section};
use crate::index::db::{
    crew_column, Db, EpisodeMeta, FileMedia, FileRecord, IndexError, MetadataRecord,
    MetadataSource, Score, WatchAuthority, WatchRecord, MAX_CAST, MAX_DIRECTORS, MAX_WRITERS,
};
use crate::index::scan::ScanStats;
use crate::index::MediaKind;

/// Plex caps container size server-side anyway; 200 keeps one page small.
const PAGE_SIZE: u32 = 200;

/// How many pages of one section are in flight at once. A scan's wall clock
/// is round trips before it is anything else - 69 pages for the owner's
/// library - and no page depends on the one before it once the first has
/// reported the total. Eight hides the round trip behind the indexing
/// without asking a home server for more sockets than it wants to hold.
const PAGE_FETCHERS: usize = 8;

/// How many times one page is asked for before the walk gives up on it. Eight
/// sockets at once is more than a NAS or a Pi always has to spare, and the
/// answer to a refused one is the same request again on a fresh connection.
const PAGE_ATTEMPTS: u32 = 3;

/// Waited before asking again, multiplied by the attempts already spent. Long
/// enough for a server that ran out of sockets to have closed one, short
/// enough that three attempts stay under a third of a second.
const RETRY_BACKOFF: std::time::Duration = std::time::Duration::from_millis(100);

/// The first page of a sort read newest first. A few minutes between two
/// sweeps rarely move more than a handful of items, and every sweep asks for
/// this page, so it stays small; the pages after it are full ones.
const DELTA_FIRST_PAGE: u32 = 20;

/// How long a section goes on its changes alone before it is walked whole
/// again: only a walk sees a removal that left the count where it was, or a
/// watch another client took back.
const FULL_WALK_EVERY: i64 = 24 * 60 * 60;

/// A sort a section is read newest first through, and the field it orders by.
type Sort = (&'static str, fn(&Metadata) -> Option<i64>);

/// The sorts a changed section is read through: an arrival shows in either,
/// an edit, a match or a refresh in updatedAt alone.
const CHANGE_SORTS: [Sort; 2] = [
    ("addedAt:desc", |m| m.added_at),
    ("updatedAt:desc", |m| m.updated_at),
];

/// What a watch on any client moves, viewOffset and viewCount alike, while
/// the item's own record and the section's stamps stay where they were.
const WATCH_SORT: Sort = ("lastViewedAt:desc", |m| m.last_viewed_at);

#[derive(Debug, thiserror::Error)]
pub enum SyncError {
    #[error("plex error: {0}")]
    Plex(#[from] PlexError),
    #[error("index error: {0}")]
    Index(#[from] IndexError),
    #[error("the plex library came back empty; the cached files are kept")]
    EmptyLibrary,
}

/// The writes of one page of items, committed together.
///
/// A page, and not the whole sync: a transaction over the sync is a
/// transaction held across every page request the walk makes, which on a
/// first pull of a large library is tens of seconds - and every other writer,
/// a watch position reported mid-film above all, waits behind it for all of
/// it. A page is the largest unit with no network inside it.
///
/// What one transaction per sync was for still holds. A walk that fails
/// partway stores no section's own updatedAt, so the next sync pulls that
/// section whole again; and the sweep that removes what the walk did not see
/// runs only once every page of every section has landed, so a half-finished
/// pull never deletes a file it simply had not reached.
fn committed<T>(
    db: &parking_lot::Mutex<Db>,
    body: impl FnOnce(&Db) -> Result<T, SyncError>,
) -> Result<T, SyncError> {
    let db = db.lock();
    db.conn()
        .execute_batch("BEGIN IMMEDIATE")
        .map_err(IndexError::from)?;
    let result = body(&db).and_then(|value| {
        db.conn()
            .execute_batch("COMMIT")
            .map_err(IndexError::from)?;
        Ok(value)
    });
    // a COMMIT that fails leaves the transaction open, and every later write
    // would then fail to BEGIN on the same connection
    if result.is_err() {
        let _ = db.conn().execute_batch("ROLLBACK");
    }
    result
}

/// Pulls the Plex library into the index. Plex metadata is authoritative: no
/// filename parsing happens here. `dirs_skipped` is always 0, Plex has no
/// directory tree. A section whose stamp has not moved since the last sync
/// is only asked about watches, and one whose stamp moved is read for what
/// changed alone; either is walked whole when its count disagrees, and once a
/// day: see the gate below.
///
/// The write connection arrives behind its mutex and stays there: the guard
/// is taken per transaction, never across a page request. A sync of a large
/// library spends most of its wall clock on the network, and every other
/// writer - a watch position reported mid-film above all - waits only for
/// the page currently committing, not for the walk.
/// `full` pulls every section whole, whatever its own stamps say has changed:
/// a viewer pressing Scan is saying they do not believe the server, and the
/// server has already been wrong once about exactly this.
pub fn sync(
    db: &parking_lot::Mutex<Db>,
    client: &PlexClient,
    source_id: &str,
    paused: &crate::source::Pause,
    full: bool,
) -> Result<ScanStats, SyncError> {
    // the brake gates the whole source before its first request, not just
    // the pages after it: a paused scan owes the server nothing at all
    paused.wait();
    let gen = {
        let db = db.lock();
        db.next_scan_gen(source_id)?
    };
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0);
    let mut stats = ScanStats::default();
    let mut items = 0u32;
    // Sections whose rows this sync did not walk whole: the sweep leaves their
    // unseen rows alone rather than rewriting every row to mark it seen.
    let mut kept: Vec<String> = Vec::new();

    for section in client.sections()? {
        let (item_type, kind) = match section.kind.as_str() {
            "movie" => (TYPE_MOVIE, MediaKind::Movie),
            "show" => (TYPE_EPISODE, MediaKind::Show),
            // music and photo sections are not ours
            _ => continue,
        };

        // Beside the stamp, two more numbers per section in the same table,
        // under keys no section key can take: when it was last walked whole,
        // on this clock, and the newest lastViewedAt read from it, on the
        // server's.
        let walked_key = format!("{}:walked", section.key);
        let viewed_key = format!("{}:viewed", section.key);
        let stamp = section.stamp();
        let (stored, walked, viewed) = {
            let db = db.lock();
            (
                db.dir_mtime(source_id, &section.key)?,
                db.dir_mtime(source_id, &walked_key)?,
                db.dir_mtime(source_id, &viewed_key)?,
            )
        };
        // A server that sends no stamp at all (0) is never trusted and always
        // walked, and so is a section never pulled, one a viewer asked for and
        // one a day has gone by without a walk.
        let mut walk = full
            || stamp == 0
            || stored.is_none()
            || walked.is_none_or(|w| now - w >= FULL_WALK_EVERY);
        if !walk {
            paused.wait();
            // Only what moved is read, newest first. Every item indexed here
            // is a change, and the files it leaves unread stay out of the
            // sweep once the count below agrees.
            let mut indexed = std::collections::HashSet::new();
            let mut parts = 0;
            let mut index_page = |items: &[Metadata]| -> Result<(), SyncError> {
                parts += committed(db, |db| {
                    let mut parts = 0;
                    for item in items {
                        // the sorts overlap: a new film is both added and updated
                        if indexed.insert(item.rating_key.clone()) {
                            parts += index_item(db, source_id, &section, kind, item, gen, now)?;
                            // a replaced file keeps its ratingKey under a new part key,
                            // and only a walk would otherwise sweep the old part
                            db.conn()
                                .prepare_cached(
                                    "DELETE FROM files
                                     WHERE source_id = ?1 AND rating_key = ?2 AND seen_gen < ?3",
                                )
                                .and_then(|mut stmt| {
                                    stmt.execute(rusqlite::params![source_id, item.rating_key, gen])
                                })
                                .map_err(IndexError::from)?;
                        }
                    }
                    Ok(parts)
                })?;
                Ok(())
            };
            // a section whose stamp still matches has neither been scanned
            // nor edited since: nothing in it can have been added, edited or
            // removed, and only a watch is left to ask about
            if stored != Some(stamp) {
                let since = stored.unwrap_or(0);
                if kind == MediaKind::Show {
                    for sort in CHANGE_SORTS {
                        if walk {
                            break;
                        }
                        walk = walk_newest(
                            client,
                            &section.key,
                            TYPE_SHOW,
                            sort,
                            since,
                            paused,
                            |items| {
                                committed(db, |db| {
                                    items
                                        .iter()
                                        .try_for_each(|item| index_show(db, &section, item, now))
                                })
                            },
                        )?
                        .is_none();
                    }
                }
                let mut total = None;
                for sort in CHANGE_SORTS {
                    if walk {
                        break;
                    }
                    total = walk_newest(
                        client,
                        &section.key,
                        item_type,
                        sort,
                        since,
                        paused,
                        &mut index_page,
                    )?
                    .map(|(total, _)| total);
                    walk = total.is_none();
                }
                if let Some(total) = total {
                    // A removal moves no item, so the count is where it shows:
                    // a server holding a different number of items than the
                    // index has lost one, or has one this read did not reach.
                    let local: u32 = db.lock().conn()
                        .query_row(
                            "SELECT COUNT(DISTINCT rating_key) FROM files WHERE source_id = ?1 AND dir = ?2",
                            rusqlite::params![source_id, section.key],
                            |r| r.get(0),
                        )
                        .map_err(IndexError::from)?;
                    walk = local != total;
                }
            }
            let newest_view = if walk {
                None
            } else {
                walk_newest(
                    client,
                    &section.key,
                    item_type,
                    WATCH_SORT,
                    viewed.unwrap_or(0),
                    paused,
                    &mut index_page,
                )?
            };
            if let Some((_, newest_view)) = newest_view {
                let db = db.lock();
                let held: u32 = db
                    .conn()
                    .query_row(
                        "SELECT COUNT(*) FROM files WHERE source_id = ?1 AND dir = ?2",
                        rusqlite::params![source_id, section.key],
                        |r| r.get(0),
                    )
                    .map_err(IndexError::from)?;
                db.set_dir_mtime(source_id, &section.key, stamp)?;
                db.set_dir_mtime(source_id, &viewed_key, newest_view)?;
                stats.files_seen += held;
                stats.files_upserted += parts;
                items += held;
                kept.push(section.key.clone());
                continue;
            }
        }
        paused.wait();

        if kind == MediaKind::Show {
            // the series' own summary, poster and genres live on the show
            // itself, one level above every episode the loop below walks; an
            // episode's own fields describe the episode, never the show it
            // belongs to
            pull_show_summaries(db, client, &section, now, paused)?;
        }
        let mut answered = Answered::default();
        let mut newest_view = 0;
        let (walked, total) = walk_pages(client, &section.key, item_type, paused, |page| {
            for item in &page.items {
                answered.count(item);
                newest_view = newest_view.max(item.last_viewed_at.unwrap_or(0));
            }
            let parts = committed(db, |db| {
                let mut parts = 0;
                for item in &page.items {
                    parts += index_item(db, source_id, &section, kind, item, gen, now)?;
                }
                Ok(parts)
            })?;
            stats.files_seen += parts;
            stats.files_upserted += parts;
            Ok(())
        })?;
        items += walked;
        answered.report(&section.title);
        let db = db.lock();
        if walked < total {
            // An item removed mid-walk shifts every later offset, so one item
            // went unread: keep the section's rows and claim no stamp, and the
            // count check walks it again on the next sync.
            kept.push(section.key.clone());
            continue;
        }
        if stamp != 0 {
            db.set_dir_mtime(source_id, &section.key, stamp)?;
        }
        db.set_dir_mtime(source_id, &walked_key, now)?;
        db.set_dir_mtime(source_id, &viewed_key, newest_view)?;
    }

    // a server answering nothing at all for a library it filled before is
    // degraded, not emptied: sweeping here would wipe the whole cache
    let has_files = {
        let db = db.lock();
        db.has_files(source_id)?
    };
    if items == 0 && has_files {
        return Err(SyncError::EmptyLibrary);
    }

    paused.wait();
    let kept = serde_json::to_string(&kept).unwrap_or_else(|_| "[]".to_string());
    stats.files_removed = committed(db, |db| {
        let removed = db
            .conn()
            .execute(
                "DELETE FROM files WHERE source_id = ?1 AND seen_gen < ?2
                   AND dir NOT IN (SELECT value FROM json_each(?3))",
                rusqlite::params![source_id, gen, kept],
            )
            .map_err(IndexError::from)? as u32;
        db.prune_orphan_titles()?;
        Ok(removed)
    })?;
    Ok(stats)
}

/// Pulls the show-level items of a "show" section (type=2, not the episodes
/// type=4 walks): each one is a series' own summary, poster and genres, kept
/// once per show rather than once per episode. A show with nothing to say
/// here gets no row and is left for TMDB, the same way a bare movie is.
fn pull_show_summaries(
    db: &parking_lot::Mutex<Db>,
    client: &PlexClient,
    section: &Section,
    now: i64,
    paused: &crate::source::Pause,
) -> Result<(), SyncError> {
    walk_pages(client, &section.key, TYPE_SHOW, paused, |page| {
        committed(db, |db| {
            page.items
                .iter()
                .try_for_each(|item| index_show(db, section, item, now))
        })
    })?;
    Ok(())
}

/// Writes one show-level item as its series' title and Plex metadata.
fn index_show(db: &Db, section: &Section, item: &Metadata, now: i64) -> Result<(), SyncError> {
    // a nameless item would otherwise collapse with every other one
    let name = if item.title.is_empty() {
        section.title.as_str()
    } else {
        item.title.as_str()
    };
    // the one item that carries the series' own year: an episode only knows
    // the year it aired
    let title_id = db.upsert_title(MediaKind::Show, name, item.year)?;
    write_plex_metadata(db, title_id, item, now)
}

/// Whether asking again could answer differently. A socket that was refused
/// or dropped is worth another request, and so are the three statuses a
/// server sends to say it is busy rather than broken: 502, 503 and 504. A
/// rejected token needs a new token rather than eight more tries, and a 4xx,
/// a 500 or a body that would not parse give the same answer however many
/// times they are asked.
fn is_transient(e: &PlexError) -> bool {
    matches!(e, PlexError::Transport(_) | PlexError::Status(502..=504))
}

/// One page, asked for again when the server was busy rather than answering.
/// Every page of a walk comes through here: the first, the parallel ones and
/// the serial tail alike.
fn fetch_page(
    client: &PlexClient,
    section_key: &str,
    item_type: u8,
    sort: Option<&str>,
    start: u32,
    size: u32,
) -> Result<ItemsPage, PlexError> {
    for spent in 1..PAGE_ATTEMPTS {
        match client.items_page(section_key, item_type, sort, start, size) {
            Err(e) if is_transient(&e) => std::thread::sleep(RETRY_BACKOFF * spent),
            answered => return answered,
        }
    }
    client.items_page(section_key, item_type, sort, start, size)
}

/// Hands `index` the items of one section whose field `sort` orders by moved
/// past `since`, newest first, and stops at the first that did not. Answers
/// the section's total and the newest value read, `since` when none moved.
/// Serial on purpose: each page is what says whether there is a next. None
/// once the changes run past two pages: a parallel walk reads the rest faster.
fn walk_newest<F>(
    client: &PlexClient,
    section_key: &str,
    item_type: u8,
    (sort, field): Sort,
    since: i64,
    paused: &crate::source::Pause,
    mut index: F,
) -> Result<Option<(u32, i64)>, SyncError>
where
    F: FnMut(&[Metadata]) -> Result<(), SyncError>,
{
    let mut start = 0;
    let mut newest = since;
    loop {
        let size = if start == 0 {
            DELTA_FIRST_PAGE
        } else {
            PAGE_SIZE
        };
        let page = fetch_page(client, section_key, item_type, Some(sort), start, size)?;
        let moved = page
            .items
            .iter()
            .take_while(|m| field(m).is_some_and(|v| v > since))
            .count();
        if moved > 0 {
            newest = page.items[..moved]
                .iter()
                .filter_map(field)
                .fold(newest, i64::max);
            index(&page.items[..moved])?;
        }
        start += page.items.len() as u32;
        if moved < page.items.len() || page.items.is_empty() || start >= page.total {
            return Ok(Some((page.total, newest)));
        }
        if start >= DELTA_FIRST_PAGE + PAGE_SIZE {
            return Ok(None);
        }
        paused.wait();
    }
}

/// Hands every page of one section's items to `index`, in order. The first
/// page is fetched alone because only it can report the total and the stride
/// the server actually answers at; the rest are asked for `PAGE_FETCHERS` at
/// a time while the caller indexes what has already landed, because a scan
/// spends far more of its wall clock waiting for pages than writing them.
/// Answers how many items were walked and the total the first page reported.
///
/// Width is an optimisation, never a requirement: a page the server will not
/// give up at eight sockets costs the pages after it a second fetch on one
/// connection, not the scan. Only a failure that would repeat serially ends
/// the walk.
///
/// Indexing stays on this thread: it runs inside the sync's one transaction,
/// on the one connection.
fn walk_pages<F>(
    client: &PlexClient,
    section_key: &str,
    item_type: u8,
    paused: &crate::source::Pause,
    mut index: F,
) -> Result<(u32, u32), SyncError>
where
    F: FnMut(&ItemsPage) -> Result<(), SyncError>,
{
    let first = fetch_page(client, section_key, item_type, None, 0, PAGE_SIZE)?;
    // the server's own page size, which it may cap below what was asked for:
    // striding by anything else would ask past items it never sent
    let stride = first.items.len() as u32;
    let total = first.total;
    index(&first)?;
    let mut items = stride;
    // stride == 0 also guards a server that reports a total it never fills
    if stride == 0 || items >= total {
        return Ok((items, total));
    }
    paused.wait();

    let pages = total.div_ceil(stride);
    // outside the scope: a fetcher borrows it, and a borrow of one of the
    // scope closure's own locals cannot outlive that closure
    let next = std::sync::atomic::AtomicU32::new(1);
    let indexed = std::thread::scope(|scope| -> Result<u32, SyncError> {
        let (tx, rx) =
            std::sync::mpsc::sync_channel::<(u32, Result<ItemsPage, PlexError>)>(PAGE_FETCHERS);
        for _ in 0..PAGE_FETCHERS.min(pages as usize - 1) {
            let tx = tx.clone();
            let next = &next;
            scope.spawn(move || loop {
                let n = next.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
                if n >= pages {
                    return;
                }
                let page = fetch_page(client, section_key, item_type, None, n * stride, PAGE_SIZE);
                // the receiver is gone: an error or a short page ended the walk
                if tx.send((n, page)).is_err() {
                    return;
                }
            });
        }
        // the loop below ends on the channel closing, which needs every
        // sender gone, and this one is the scope's own
        drop(tx);

        // pages land out of order and are indexed in it: the caller writes
        // rows a later pass reads back by position
        let mut held: std::collections::BTreeMap<u32, ItemsPage> =
            std::collections::BTreeMap::new();
        let mut want = 1u32;
        for (n, page) in rx {
            match page {
                Ok(page) => {
                    held.insert(n, page);
                    while let Some(page) = held.remove(&want) {
                        paused.wait();
                        index(&page)?;
                        items += page.items.len() as u32;
                        want += 1;
                    }
                }
                // A page still refused after `PAGE_ATTEMPTS` is a hole, and
                // the walk knows exactly where it starts: `items` counts what
                // has been indexed without a gap, so the serial pass below
                // asks for everything from there again. Stopping the other
                // fetchers is what makes that a back-off rather than a
                // retry at the same width - pages past the hole cannot be
                // indexed anyway, because order is what `index` is owed.
                Err(e) if is_transient(&e) => {
                    next.store(pages, std::sync::atomic::Ordering::Relaxed);
                }
                Err(e) => return Err(e.into()),
            }
        }
        Ok(items)
    })?;

    // A server that answered one page short mid-walk left a hole the strided
    // offsets never asked for, one that grew has items past the total the
    // first page reported, and one that ran out of sockets left the hole
    // above. All three finish here the way the whole walk used to, one page
    // at a time on one connection.
    let mut items = indexed;
    while items < total {
        let page = fetch_page(client, section_key, item_type, None, items, PAGE_SIZE)?;
        let got = page.items.len() as u32;
        if got == 0 {
            break;
        }
        index(&page)?;
        items += got;
    }
    Ok((items, total))
}

/// Writes this item's summary, artwork and tags as its title's Plex metadata,
/// when it actually describes something. An item that describes nothing gets
/// no row: an empty one would take the title off the queue TMDB fills in
/// behind Plex.
fn write_plex_metadata(db: &Db, title_id: i64, item: &Metadata, now: i64) -> Result<(), SyncError> {
    let describes_something =
        !item.summary.trim().is_empty() || item.thumb.is_some() || !item.genre.is_empty();
    if !describes_something {
        return Ok(());
    }
    // the writers are deduped against the directors, so an auteur who wrote his
    // own film is one name and not two. Plex has no composer: no stock agent
    // carries one, so that column is TMDB's alone.
    let director_names = crew_column(
        item.director.iter().map(|d| d.tag.as_str()),
        MAX_DIRECTORS,
        "",
    );
    let writer_names = crew_column(
        item.writer.iter().map(|w| w.tag.as_str()),
        MAX_WRITERS,
        &director_names,
    );
    let cast_names = item
        .role
        .iter()
        .take(MAX_CAST)
        .map(|r| r.tag.replace(',', " "))
        .collect::<Vec<_>>()
        .join(",");
    db.upsert_metadata(&MetadataRecord {
        title_id,
        tmdb_id: None,
        // the server's language, whatever it is; Lexis does not translate
        overview_fr: Some(item.summary.clone()).filter(|s| !s.trim().is_empty()),
        overview_en: None,
        // paths on the Plex server, fetched with the token, not TMDB paths
        poster_path: item.thumb.clone(),
        backdrop_path: item.art.clone(),
        genres: item
            .genre
            .iter()
            .map(|g| g.tag.as_str())
            .collect::<Vec<_>>()
            .join(","),
        // the top billing only, and a comma is the separator, so a name
        // carrying one would read as two
        cast_names: cast_names.clone(),
        collections: item
            .collection
            .iter()
            .map(|c| c.tag.replace(',', " "))
            .collect::<Vec<_>>()
            .join(","),
        director_names,
        writer_names,
        composer_names: String::new(),
        // two measurements of two populations, kept apart: one standing in for
        // the other leaves a number whose scale and whose population nothing
        // downstream can name
        critics: measured(item.rating, item.rating_image.as_deref()),
        audience: measured(item.audience_rating, item.audience_rating_image.as_deref()),
        release_date: None,
        source: MetadataSource::Plex,
        fetched_at: now,
    })?;
    if let Some(logo) = item.clear_logo() {
        db.set_source_logo(title_id, logo, now)?;
    }
    let characters = item
        .role
        .iter()
        .take(MAX_CAST)
        .map(|r| r.role.as_deref().unwrap_or("").replace(',', " "))
        .collect::<Vec<_>>()
        .join(",");
    db.set_cast_characters(title_id, &cast_names, &characters)?;
    Ok(())
}

/// One score, kept only where the server said who measured it.
///
/// The image URI is the only thing on the wire that names the provider, and
/// the provider is both the scale and the population: without it the number is
/// a bare quantity nothing can label, which is worse on a screen than no
/// number at all. So a score whose image is missing is not stored, and the
/// scheme alone is kept - what follows it ("image.rating.ripe" against
/// "image.rating.rotten") only repeats what the number already says.
///
/// No version of this server has been read here, and Plex has been seen to
/// state a percentage agent's score both ways: a value above 10 is a
/// percentage and is put back on the mark out of 10 the column holds, rather
/// than stored as 93 out of 10.
fn measured(value: Option<f32>, image: Option<&str>) -> Option<Score> {
    let value = value?;
    let source = image?
        .split("://")
        .next()
        .unwrap_or_default()
        .to_ascii_lowercase();
    let value = if value > 10.0 { value / 10.0 } else { value };
    // NaN fails both, which is the answer it deserves
    (!source.is_empty() && value > 0.0 && value <= 10.0).then_some(Score {
        value,
        source,
        votes: None,
    })
}

/// How much of a section the server actually answered for, reported once per
/// section it pulled.
///
/// Nothing here changes what is indexed. Every one of these fields is optional
/// on the wire and several Plex versions answer for none of them, and the app's
/// only symptom is a hero that quietly says less: this is the line that tells
/// a missing badge apart from a server that never mentioned one.
#[derive(Default)]
struct Answered {
    items: u32,
    timed: u32,
    rated: u32,
    /// Of those, the ones whose score came with the provider that measured it.
    /// A server that rates everything and sources nothing draws no score at
    /// all, and this is the line that says so before anyone opens a screen.
    sourced: u32,
    described: u32,
    uhd: u32,
    /// Items whose parts carried tracks, which is where the dynamic range is.
    with_tracks: u32,
    hdr: u32,
    atmos: u32,
}

impl Answered {
    fn count(&mut self, item: &Metadata) {
        self.items += 1;
        self.timed += u32::from(item.duration.is_some());
        self.rated += u32::from(item.rating.is_some() || item.audience_rating.is_some());
        self.sourced += u32::from(
            measured(item.rating, item.rating_image.as_deref()).is_some()
                || measured(item.audience_rating, item.audience_rating_image.as_deref()).is_some(),
        );
        let Some(media) = item.media.first() else {
            return;
        };
        self.described += u32::from(media.video_resolution.is_some());
        self.uhd += u32::from(media.video_resolution.as_deref() == Some("4k"));
        let Some(part) = media.part.first() else {
            return;
        };
        self.with_tracks += u32::from(!part.stream.is_empty());
        let shape = file_media(item, media, part);
        self.hdr += u32::from(!shape.dynamic_range.is_empty());
        self.atmos += u32::from(shape.atmos);
    }

    fn report(&self, section: &str) {
        eprintln!(
            "[lexis-core] plex \"{}\": {} items, {} timed, {} rated ({} sourced), \
             {} with media ({} 4k), {} with tracks ({} hdr, {} atmos)",
            section,
            self.items,
            self.timed,
            self.rated,
            self.sourced,
            self.described,
            self.uhd,
            self.with_tracks,
            self.hdr,
            self.atmos
        );
    }
}

/// What one copy of an item is, as the listing describes it.
///
/// A server that puts the tracks in a section listing says the dynamic range
/// outright; one that does not sends the `Media` attributes alone, and SDR is
/// then indistinguishable from an HDR file whose tracks were not listed. That
/// is the honest reading either way: a badge is only drawn for what the server
/// actually asserted, never for what it left out.
fn file_media(item: &Metadata, media: &Media, part: &Part) -> FileMedia {
    let video = part.stream.iter().find(|s| s.stream_type == Some(1));
    let dynamic_range = match video {
        Some(v) if v.dovi_present == Some(true) => "dolby_vision",
        Some(v) => match v.color_trc.as_deref() {
            Some("smpte2084") => "hdr10",
            Some("arib-std-b67") => "hlg",
            _ => "",
        },
        None => "",
    };
    // "atmos" on the Media object where the server carries it there, and the
    // track's own label where it does not: Plex spells it in one place or the
    // other depending on its version, never in neither when it knows.
    let atmos = media
        .audio_profile
        .as_deref()
        .is_some_and(|p| p.eq_ignore_ascii_case("atmos"))
        || part.stream.iter().any(|s| {
            s.stream_type == Some(2)
                && s.extended_display_title
                    .as_deref()
                    .is_some_and(|t| t.to_ascii_lowercase().contains("atmos"))
        });
    // the primary subtag alone: "en-US" and "en-GB" are one language to a viewer
    let languages = |kind: u32| {
        let mut out: Vec<String> = Vec::new();
        for s in part.stream.iter().filter(|s| s.stream_type == Some(kind)) {
            let Some(tag) = s.language_tag.as_deref() else {
                continue;
            };
            let code = tag.split('-').next().unwrap_or("").to_ascii_lowercase();
            if !code.is_empty() && !out.contains(&code) {
                out.push(code);
            }
        }
        out.join(",")
    };
    FileMedia {
        duration_secs: item.duration.unwrap_or(0) as f64 / 1000.0,
        video_resolution: media.video_resolution.clone().unwrap_or_default(),
        video_codec: media.video_codec.clone().unwrap_or_default(),
        dynamic_range: dynamic_range.to_string(),
        audio_codec: media.audio_codec.clone().unwrap_or_default(),
        audio_channels: media.audio_channels.unwrap_or(0),
        atmos,
        audio_languages: languages(2),
        subtitle_languages: languages(3),
        edition: item.edition_title.clone().unwrap_or_default(),
    }
}

/// Writes one item's parts. Returns how many file rows it wrote.
fn index_item(
    db: &Db,
    source_id: &str,
    section: &Section,
    kind: MediaKind,
    item: &Metadata,
    gen: i64,
    now: i64,
) -> Result<u32, SyncError> {
    let (name, year, season, episode) = match kind {
        // the year on an episode is its air year, not the show's: using it
        // would split one show into a title per season
        MediaKind::Show => (
            item.grandparent_title
                .as_deref()
                .filter(|t| !t.is_empty())
                .unwrap_or(&section.title),
            None,
            item.parent_index,
            item.index,
        ),
        // a nameless item would otherwise collapse with every other one
        MediaKind::Movie => {
            let name = if item.title.is_empty() {
                section.title.as_str()
            } else {
                item.title.as_str()
            };
            (name, item.year, None, None)
        }
    };
    let title_id = db.upsert_title(kind, name, year)?;

    // Plex is authoritative for its own items (spec: Storage model), so what it
    // sent with the item is the metadata, and TMDB enrichment skips this title.
    // A movie is its own leaf and describes itself here; a show's own summary,
    // poster and genres come from the section's separate show-level pass
    // above, since an episode's fields describe the episode, never the show.
    if kind == MediaKind::Movie {
        write_plex_metadata(db, title_id, item, now)?;
    }

    // the server's own answer for this item, if it has played at all. Plex is
    // authoritative for its items (spec: Storage model), so a sync refreshes
    // the table from it; an item it says nothing about keeps whatever row is
    // there, which may be a report this device has not written back yet.
    let played = item.view_offset.is_some() || item.view_count.unwrap_or(0) > 0;

    // The episode's own three fields, off the same page that named the show.
    // They cost no request: `title`, `summary` and `thumb` arrive with every
    // item, and the show pass above reads `grandparentTitle` off this same
    // object. A movie's own three are already in `metadata`, keyed by title.
    let episode_meta = (kind == MediaKind::Show).then(|| EpisodeMeta {
        title: item.title.clone(),
        summary: item.summary.clone(),
        still_path: item.thumb.clone().unwrap_or_default(),
        air_year: item
            .year
            .or_else(|| {
                item.originally_available_at
                    .as_deref()?
                    .get(..4)?
                    .parse()
                    .ok()
            })
            .unwrap_or(0),
    });

    let mut written = 0;
    for media in &item.media {
        for part in &media.part {
            let file_id = db.upsert_file(&FileRecord {
                source_id: source_id.to_string(),
                // Plex has no directories; the section is the closest grouping
                dir: section.key.clone(),
                path: part.key.clone(),
                size: part.size,
                // the server exposes no file mtime; its own added date is what
                // the library orders "recently added" on
                mtime: item.added_at.unwrap_or(0),
                seen_gen: gen,
                title_id,
                season,
                episode,
                rating_key: Some(item.rating_key.clone()),
                media: file_media(item, media, part),
            })?;
            if let Some(meta) = &episode_meta {
                db.upsert_episode_meta(file_id, meta)?;
            }
            if played {
                db.upsert_watch_state(
                    &WatchRecord {
                        file_id,
                        position_secs: item.view_offset.unwrap_or(0) as f64 / 1000.0,
                        duration_secs: item.duration.unwrap_or(0) as f64 / 1000.0,
                        watched: item.view_count.unwrap_or(0) > 0,
                        plays: item.view_count.unwrap_or(0),
                        // continue watching orders on this column, so the row
                        // takes the server's own date, not this sync's clock
                        updated_at: item.last_viewed_at.unwrap_or(now),
                    },
                    WatchAuthority::Owner,
                )?;
            }
            written += 1;
        }
    }
    Ok(written)
}

#[cfg(test)]
mod tests {
    use crate::source::Pause;

    /// The brake every test runs under: never paused, but part of every call.
    static NOT_PAUSED: Pause = Pause::new();

    use super::*;
    use crate::index::queries::up_next;
    use crate::metadata::client::TmdbClient;
    use crate::metadata::enrich::{enrich_pending, MAX_AGE_SECS};
    use crate::metadata::fake::tmdb;
    use crate::plex::fake::{
        library, query, shelf_library, FakeServer, Reply, Shelf, ShelfItem, EPISODES_JSON,
        MOVIES_JSON, SECTIONS_JSON,
    };
    use crate::slice::Slice;
    use parking_lot::Mutex;
    use std::sync::atomic::{AtomicI64, AtomicU32, Ordering};
    use std::sync::Arc;

    const NOW: i64 = 1_800_000_000;

    /// (kind, name, year) for every title, 0 meaning unknown.
    fn titles(db: &Db) -> Vec<(String, String, u16)> {
        let conn = db.conn();
        let mut stmt = conn
            .prepare("SELECT kind, name, year FROM titles ORDER BY kind, name")
            .unwrap();
        let rows = stmt
            .query_map([], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)))
            .unwrap();
        rows.map(|r| r.unwrap()).collect()
    }

    #[test]
    fn a_sync_indexes_movies_and_episodes() {
        let server = library();
        let db = parking_lot::Mutex::new(Db::open_in_memory().unwrap());
        let client = PlexClient::new(&server.base_url, "tok", "install");

        let stats = sync(&db, &client, "plex1", &NOT_PAUSED, false).unwrap();
        assert_eq!(stats.files_seen, 3);
        assert_eq!(stats.files_upserted, 3);
        assert_eq!(stats.files_removed, 0);
        assert_eq!(stats.dirs_skipped, 0);

        // the two episodes share one show title, and it carries the year off
        // the show item rather than either episode's air year (2015 and 2016)
        assert_eq!(
            titles(&db.lock()),
            vec![
                ("movie".to_string(), "Dune".to_string(), 2021),
                ("show".to_string(), "The Expanse".to_string(), 2015),
            ]
        );

        let row: (String, i64, i64, Option<u16>, Option<u16>) = db
            .lock()
            .conn()
            .query_row(
                "SELECT path, size, mtime, season, episode FROM files
                 WHERE path = '/library/parts/602/1/S02E03.mkv'",
                [],
                |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?, r.get(4)?)),
            )
            .unwrap();
        assert_eq!(
            row,
            (
                "/library/parts/602/1/S02E03.mkv".to_string(),
                11,
                0,
                Some(2),
                Some(3)
            )
        );

        // the music section is not ours and must not be requested
        assert!(!server
            .requests()
            .iter()
            .any(|r| r.url.starts_with("/library/sections/3/all")));
    }

    #[test]
    fn a_movie_and_a_show_each_carry_the_servers_own_metadata() {
        let server = library();
        let db = parking_lot::Mutex::new(Db::open_in_memory().unwrap());
        sync(
            &db,
            &PlexClient::new(&server.base_url, "tok", "install"),
            "plex1",
            &NOT_PAUSED,
            false,
        )
        .unwrap();

        let dune: i64 = db
            .lock()
            .conn()
            .query_row("SELECT id FROM titles WHERE name = 'Dune'", [], |r| {
                r.get(0)
            })
            .unwrap();
        let row = db.lock().metadata(dune).unwrap().unwrap();
        assert_eq!(row.source, MetadataSource::Plex);
        assert_eq!(row.tmdb_id, None);
        assert_eq!(row.overview_fr.as_deref(), Some("Dans un futur lointain."));
        assert_eq!(
            row.poster_path.as_deref(),
            Some("/library/metadata/101/thumb/1")
        );
        assert_eq!(
            row.backdrop_path.as_deref(),
            Some("/library/metadata/101/art/1")
        );
        assert_eq!(row.genres, "Science-Fiction,Aventure");
        assert!(row.fetched_at > 0);
        // the server's own lettering is the logo, before TMDB is asked
        let logo = db.lock().logo_state(dune).unwrap().unwrap();
        assert_eq!(
            logo.path.as_deref(),
            Some("/library/metadata/101/clearLogo/1")
        );

        // the show's own type=2 item describes it, not either episode: its
        // summary and poster carry ids of their own, not an episode's
        let show: i64 = db
            .lock()
            .conn()
            .query_row(
                "SELECT id FROM titles WHERE name = 'The Expanse'",
                [],
                |r| r.get(0),
            )
            .unwrap();
        let row = db.lock().metadata(show).unwrap().unwrap();
        assert_eq!(row.source, MetadataSource::Plex);
        assert_eq!(row.tmdb_id, None);
        assert_eq!(
            row.overview_fr.as_deref(),
            Some("L'humanite a colonise le systeme solaire.")
        );
        assert_eq!(
            row.poster_path.as_deref(),
            Some("/library/metadata/200/thumb/1")
        );
        assert_eq!(
            row.backdrop_path.as_deref(),
            Some("/library/metadata/200/art/1")
        );
        assert_eq!(row.genres, "Science-Fiction");
        assert_eq!(row.cast_names, "Steven Strait");
        // no lettering on the server: the logo is left for TMDB to answer
        let logo = db.lock().logo_state(show).unwrap().unwrap();
        assert_eq!((logo.path, logo.checked_at), (None, 0));

        // the ratingKey follows the file: watch state is written back with it
        let key: Option<String> = db
            .lock()
            .conn()
            .query_row(
                "SELECT rating_key FROM files WHERE path = '/library/parts/602/1/S02E03.mkv'",
                [],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(key.as_deref(), Some("202"));
    }

    #[test]
    fn a_show_the_server_describes_nothing_about_is_left_to_tmdb() {
        // the show-level item exists but says nothing: no summary, no thumb,
        // no genre, the series equivalent of a movie no agent ever matched
        let bare = FakeServer::start(|req| {
            if req.url == "/library/sections" {
                return Reply::json(SECTIONS_JSON);
            }
            if req.url.starts_with("/library/sections/1/all") {
                return Reply::json(r#"{"MediaContainer":{"size":0,"totalSize":0}}"#);
            }
            if req.url.starts_with("/library/sections/2/all") {
                return Reply::json(if query(&req.url, "type").as_deref() == Some("2") {
                    r#"{"MediaContainer":{"size":1,"totalSize":1,"Metadata":[
                        {"ratingKey":"200","title":"The Expanse"}]}}"#
                } else {
                    EPISODES_JSON
                });
            }
            Reply::status(404)
        });
        let db = parking_lot::Mutex::new(Db::open_in_memory().unwrap());
        sync(
            &db,
            &PlexClient::new(&bare.base_url, "tok", "install"),
            "plex1",
            &NOT_PAUSED,
            false,
        )
        .unwrap();

        let show: i64 = db
            .lock()
            .conn()
            .query_row(
                "SELECT id FROM titles WHERE name = 'The Expanse'",
                [],
                |r| r.get(0),
            )
            .unwrap();
        // an empty row would take the title off the queue for good
        assert_eq!(db.lock().metadata(show).unwrap(), None);
        assert!(db
            .lock()
            .titles_needing_metadata(NOW, MAX_AGE_SECS, 100)
            .unwrap()
            .iter()
            .any(|t| t.id == show));
    }

    #[test]
    fn a_file_takes_the_date_the_server_added_the_item_on() {
        let server = library();
        let db = parking_lot::Mutex::new(Db::open_in_memory().unwrap());
        sync(
            &db,
            &PlexClient::new(&server.base_url, "tok", "install"),
            "plex1",
            &NOT_PAUSED,
            false,
        )
        .unwrap();

        // the server exposes no file mtime, and addedAt is the only date it has
        // for the item: it is what "recently added" orders the library on
        let mtime: i64 = db
            .lock()
            .conn()
            .query_row(
                "SELECT mtime FROM files WHERE path = '/library/parts/501/1/Dune.mkv'",
                [],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(mtime, 1690000000);

        let added: i64 = db
            .lock()
            .conn()
            .query_row("SELECT added_at FROM titles WHERE name = 'Dune'", [], |r| {
                r.get(0)
            })
            .unwrap();
        assert_eq!(added, 1690000000);
    }

    #[test]
    fn a_plex_item_carries_the_roles_the_server_lists() {
        let server = library();
        let db = parking_lot::Mutex::new(Db::open_in_memory().unwrap());
        sync(
            &db,
            &PlexClient::new(&server.base_url, "tok", "install"),
            "plex1",
            &NOT_PAUSED,
            false,
        )
        .unwrap();

        let dune: i64 = db
            .lock()
            .conn()
            .query_row("SELECT id FROM titles WHERE name = 'Dune'", [], |r| {
                r.get(0)
            })
            .unwrap();
        let row = db.lock().metadata(dune).unwrap().unwrap();
        assert_eq!(row.cast_names, "Timothee Chalamet,Rebecca Ferguson");
        assert_eq!(row.source, MetadataSource::Plex);
    }

    #[test]
    fn a_plex_item_carries_the_crew_the_server_lists() {
        let server = library();
        let db = parking_lot::Mutex::new(Db::open_in_memory().unwrap());
        sync(
            &db,
            &PlexClient::new(&server.base_url, "tok", "install"),
            "plex1",
            &NOT_PAUSED,
            false,
        )
        .unwrap();

        let dune: i64 = db
            .lock()
            .conn()
            .query_row("SELECT id FROM titles WHERE name = 'Dune'", [], |r| {
                r.get(0)
            })
            .unwrap();
        let row = db.lock().metadata(dune).unwrap().unwrap();
        assert_eq!(row.director_names, "Denis Villeneuve");
        // the server lists him as a writer of his own film too, and the column
        // holds him once: the same name twice is the same signal counted twice
        assert_eq!(row.writer_names, "Jon Spaihts,Eric Roth");
        // no stock Plex agent carries a composer, so that column stays TMDB's
        assert_eq!(row.composer_names, "");

        // the director is the one crew credit that gets tag rows, because the
        // home row is the only reader that asks "who else carries this value"
        let tags: Vec<String> = db
            .lock()
            .conn()
            .prepare("SELECT value FROM title_tags WHERE kind = 'director' AND title_id = ?1")
            .unwrap()
            .query_map([dune], |r| r.get(0))
            .unwrap()
            .collect::<Result<_, _>>()
            .unwrap();
        assert_eq!(tags, ["Denis Villeneuve"]);
    }

    #[test]
    fn a_plex_item_carries_the_shape_of_the_copy_the_server_holds() {
        let server = library();
        let db = parking_lot::Mutex::new(Db::open_in_memory().unwrap());
        sync(
            &db,
            &PlexClient::new(&server.base_url, "tok", "install"),
            "plex1",
            &NOT_PAUSED,
            false,
        )
        .unwrap();

        let dune: i64 = db
            .lock()
            .conn()
            .query_row("SELECT id FROM titles WHERE name = 'Dune'", [], |r| {
                r.get(0)
            })
            .unwrap();
        let media = db.lock().title_media(dune).unwrap().unwrap();
        assert_eq!(media.duration_secs, 9000.0);
        assert_eq!(media.video_resolution, "4k");
        assert_eq!(media.video_codec, "hevc");
        // read off the video track's transfer function, not guessed from the
        // codec: a 10-bit HEVC file is not an HDR one
        assert_eq!(media.dynamic_range, "hdr10");
        assert_eq!(media.audio_codec, "eac3");
        assert_eq!(media.audio_channels, 6);
        assert!(media.atmos);
        // a region is not a language, and an untagged track names none
        assert_eq!(media.audio_languages, "en,fr");
        assert_eq!(media.subtitle_languages, "fr");

        // two populations and two providers, kept apart all the way down: one
        // number here would be a score whose scale and whose voters nothing
        // could name
        let row = db.lock().metadata(dune).unwrap().unwrap();
        assert_eq!(
            row.critics,
            Some(Score {
                value: 8.0,
                source: "imdb".into(),
                votes: None
            })
        );
        assert_eq!(
            row.audience,
            Some(Score {
                value: 9.1,
                source: "themoviedb".into(),
                votes: None
            })
        );
    }

    #[test]
    fn a_score_the_server_names_nobody_for_is_not_stored() {
        // the whole point: a number with no provider has no scale and no
        // population, and standing behind nothing it is worse on a screen than
        // the blank it leaves
        let server = FakeServer::start(|req| {
            if req.url == "/library/sections" {
                return Reply::json(
                    r#"{"MediaContainer":{"Directory":[
                        {"key":"1","type":"movie","title":"Films","updatedAt":1}]}}"#,
                );
            }
            Reply::json(
                r#"{"MediaContainer":{"size":2,"totalSize":2,"Metadata":[
                    {"ratingKey":"1","title":"Alien","year":1979,"summary":"Dans l'espace.",
                     "rating":8.4,"audienceRating":7.9,
                     "Media":[{"Part":[{"id":1,"key":"/p/1","size":1}]}]},
                    {"ratingKey":"2","title":"Solaris","year":1972,"summary":"Une station.",
                     "rating":93,"ratingImage":"rottentomatoes://image.rating.ripe",
                     "Media":[{"Part":[{"id":2,"key":"/p/2","size":1}]}]}
                ]}}"#,
            )
        });
        let db = parking_lot::Mutex::new(Db::open_in_memory().unwrap());
        sync(
            &db,
            &PlexClient::new(&server.base_url, "tok", "install"),
            "plex1",
            &NOT_PAUSED,
            false,
        )
        .unwrap();

        let id = |conn: &Db, name: &str| -> i64 {
            conn.conn()
                .query_row("SELECT id FROM titles WHERE name = ?1", [name], |r| {
                    r.get(0)
                })
                .unwrap()
        };
        // one guard for both lookups: the id closure takes the same lock it is
        // handed, so nothing here may hold a guard across its own re-entry
        let alien = {
            let conn = db.lock();
            conn.metadata(id(&conn, "Alien")).unwrap().unwrap()
        };
        assert_eq!(alien.critics, None);
        assert_eq!(alien.audience, None);

        // and a percentage agent lands on the mark this column holds, whichever
        // of the two ways the server spells it
        let critics = {
            let conn = db.lock();
            conn.metadata(id(&conn, "Solaris"))
                .unwrap()
                .unwrap()
                .critics
        };
        assert_eq!(
            critics,
            Some(Score {
                value: 9.3,
                source: "rottentomatoes".into(),
                votes: None
            })
        );
    }

    #[test]
    fn a_server_that_lists_no_tracks_asserts_no_dynamic_range() {
        let server = FakeServer::start(|req| {
            if req.url == "/library/sections" {
                return Reply::json(
                    r#"{"MediaContainer":{"Directory":[
                        {"key":"1","type":"movie","title":"Films","updatedAt":1}]}}"#,
                );
            }
            Reply::json(
                r#"{"MediaContainer":{"size":1,"totalSize":1,"Metadata":[
                    {"ratingKey":"1","title":"Alien","year":1979,"summary":"Dans l'espace.",
                     "audienceRating":8.4,
                     "audienceRatingImage":"themoviedb://image.rating",
                     "Media":[{"videoResolution":"1080","videoCodec":"h264",
                               "audioCodec":"dca","audioChannels":8,
                               "Part":[{"id":1,"key":"/library/parts/1/1/a.mkv","size":1}]}]}
                ]}}"#,
            )
        });
        let db = parking_lot::Mutex::new(Db::open_in_memory().unwrap());
        sync(
            &db,
            &PlexClient::new(&server.base_url, "tok", "install"),
            "plex1",
            &NOT_PAUSED,
            false,
        )
        .unwrap();

        let alien: i64 = db
            .lock()
            .conn()
            .query_row("SELECT id FROM titles WHERE name = 'Alien'", [], |r| {
                r.get(0)
            })
            .unwrap();
        let media = db.lock().title_media(alien).unwrap().unwrap();
        assert_eq!(media.video_resolution, "1080");
        assert_eq!(media.audio_channels, 8);
        // nothing said HDR and nothing said Atmos, so neither is asserted
        assert_eq!(media.dynamic_range, "");
        assert!(!media.atmos);
        // the agent carries no critics' score, and the audience's does not step
        // into the empty column: it is drawn as the audience's or not at all
        let row = db.lock().metadata(alien).unwrap().unwrap();
        assert_eq!(row.critics, None);
        assert_eq!(
            row.audience,
            Some(Score {
                value: 8.4,
                source: "themoviedb".into(),
                votes: None
            })
        );
    }

    #[test]
    fn a_server_that_spells_these_fields_differently_costs_a_badge_and_not_the_sync() {
        // no two Plex versions have spelled the copy's fields alike, and this
        // library's own server has never been read: a page that fails to
        // deserialize costs the whole section, so a shape nothing here expects
        // has to read as "the server did not say"
        let server = FakeServer::start(|req| {
            if req.url == "/library/sections" {
                return Reply::json(
                    r#"{"MediaContainer":{"Directory":[
                        {"key":"1","type":"movie","title":"Films","updatedAt":1}]}}"#,
                );
            }
            Reply::json(
                r#"{"MediaContainer":{"size":2,"totalSize":2,"Metadata":[
                    {"ratingKey":"1","title":"Alien","year":1979,"summary":"Dans l'espace.",
                     "rating":"8.4","ratingImage":"imdb://image.rating","duration":6900000,
                     "Media":[{"videoResolution":1080,"videoCodec":"h264",
                               "audioCodec":"ac3","audioChannels":"6",
                               "Part":[{"id":1,"key":"/library/parts/1/1/a.mkv","size":1,
                                        "Stream":[{"streamType":"1","DOVIPresent":1}]}]}]},
                    {"ratingKey":"2","title":"Solaris","year":1972,"summary":"Une station.",
                     "rating":{"value":7.9},"audienceRating":[],"ratingImage":{},
                     "Media":[{"videoResolution":{},"audioChannels":"lots",
                               "Part":[{"id":2,"key":"/library/parts/2/1/b.mkv","size":1,
                                        "Stream":[{"streamType":1,"colorTrc":99}]}]}]}
                ]}}"#,
            )
        });
        let db = parking_lot::Mutex::new(Db::open_in_memory().unwrap());
        // the whole section still indexes rather than failing on one field
        sync(
            &db,
            &PlexClient::new(&server.base_url, "tok", "install"),
            "plex1",
            &NOT_PAUSED,
            false,
        )
        .unwrap();

        let alien: i64 = db
            .lock()
            .conn()
            .query_row("SELECT id FROM titles WHERE name = 'Alien'", [], |r| {
                r.get(0)
            })
            .unwrap();
        let media = db.lock().title_media(alien).unwrap().unwrap();
        // a number where a token was expected, a string where a count was, and
        // 1 where a flag was: all three read
        assert_eq!(media.video_resolution, "1080");
        assert_eq!(media.audio_channels, 6);
        assert_eq!(media.dynamic_range, "dolby_vision");
        // a score written as the string next to the number, sourced normally
        assert_eq!(
            db.lock().metadata(alien).unwrap().unwrap().critics,
            Some(Score {
                value: 8.4,
                source: "imdb".into(),
                votes: None
            })
        );

        let solaris: i64 = db
            .lock()
            .conn()
            .query_row("SELECT id FROM titles WHERE name = 'Solaris'", [], |r| {
                r.get(0)
            })
            .unwrap();
        // and a shape nothing can read is silence, not a badge and not an
        // error: a score inside an object, an empty list where a number goes,
        // and an object where the provider goes all read as "nothing said"
        let row = db.lock().metadata(solaris).unwrap().unwrap();
        assert_eq!(row.critics, None);
        assert_eq!(row.audience, None);
        let shape = db.lock().title_media(solaris).unwrap();
        assert!(shape.is_none_or(|m| m.video_resolution.is_empty()
            && m.audio_channels == 0
            && m.dynamic_range.is_empty()));
    }

    #[test]
    fn a_long_director_list_is_cut_where_the_column_cuts() {
        // a show carries the director of every episode it has, which names
        // nobody: the column takes the first two and stops
        let server = FakeServer::start(|req| {
            if req.url == "/library/sections" {
                return Reply::json(
                    r#"{"MediaContainer":{"Directory":[{"key":"1","type":"movie","title":"Movies"}]}}"#,
                );
            }
            Reply::json(
                r#"{"MediaContainer":{"size":1,"totalSize":1,"Metadata":[
                    {"ratingKey":"1","title":"Alien","year":1979,"summary":"Dans l'espace.",
                     "Director":[{"tag":"A"},{"tag":"B"},{"tag":"C"},{"tag":"D"}],
                     "Writer":[{"tag":"W"},{"tag":"X"},{"tag":"Y"}],
                     "Media":[{"Part":[{"key":"/p/1","size":1}]}]}]}}"#,
            )
        });
        let db = parking_lot::Mutex::new(Db::open_in_memory().unwrap());
        sync(
            &db,
            &PlexClient::new(&server.base_url, "tok", "install"),
            "plex1",
            &NOT_PAUSED,
            false,
        )
        .unwrap();

        let alien: i64 = db
            .lock()
            .conn()
            .query_row("SELECT id FROM titles WHERE name = 'Alien'", [], |r| {
                r.get(0)
            })
            .unwrap();
        let row = db.lock().metadata(alien).unwrap().unwrap();
        assert_eq!(row.director_names, "A,B");
        assert_eq!(row.writer_names, "W,X");
    }

    #[test]
    fn a_plex_item_carries_the_collections_the_server_tags_it_with() {
        let server = FakeServer::start(|req| {
            if req.url == "/library/sections" {
                return Reply::json(
                    r#"{"MediaContainer":{"Directory":[{"key":"1","type":"movie","title":"Movies"}]}}"#,
                );
            }
            Reply::json(
                r#"{"MediaContainer":{"size":2,"totalSize":2,"Metadata":[
                    {"ratingKey":"1","title":"Dune","year":2021,"summary":"Dans un futur lointain.",
                     "Collection":[{"tag":"Dune Saga"}],
                     "Media":[{"Part":[{"key":"/p/1","size":1}]}]},
                    {"ratingKey":"2","title":"Alien","year":1979,"summary":"Dans l'espace.",
                     "Media":[{"Part":[{"key":"/p/2","size":1}]}]}]}}"#,
            )
        });
        let db = parking_lot::Mutex::new(Db::open_in_memory().unwrap());
        sync(
            &db,
            &PlexClient::new(&server.base_url, "tok", "install"),
            "plex1",
            &NOT_PAUSED,
            false,
        )
        .unwrap();

        let dune: i64 = db
            .lock()
            .conn()
            .query_row("SELECT id FROM titles WHERE name = 'Dune'", [], |r| {
                r.get(0)
            })
            .unwrap();
        assert_eq!(
            db.lock().metadata(dune).unwrap().unwrap().collections,
            "Dune Saga"
        );

        // the ordinary case: nothing named, and the column reads as "", not NULL
        let alien: i64 = db
            .lock()
            .conn()
            .query_row("SELECT id FROM titles WHERE name = 'Alien'", [], |r| {
                r.get(0)
            })
            .unwrap();
        assert_eq!(db.lock().metadata(alien).unwrap().unwrap().collections, "");
    }

    #[test]
    fn a_long_role_list_is_cut_where_the_column_cuts() {
        // a full Plex cast runs to dozens of tags, and both writers cut at MAX_CAST
        let server = FakeServer::start(|req| {
            if req.url == "/library/sections" {
                return Reply::json(
                    r#"{"MediaContainer":{"Directory":[{"key":"1","type":"movie","title":"Movies"}]}}"#,
                );
            }
            Reply::json(
                r#"{"MediaContainer":{"size":1,"totalSize":1,"Metadata":[
                    {"ratingKey":"1","title":"Alien","year":1979,"summary":"Dans l'espace.",
                     "Role":[{"tag":"A","role":"Ripley, Ellen"},{"tag":"B"},{"tag":"C"},{"tag":"D"},{"tag":"E"},
                             {"tag":"F"},{"tag":"G"},{"tag":"H"},{"tag":"I"},{"tag":"J"},
                             {"tag":"K"},{"tag":"L"},{"tag":"M"},{"tag":"N"},{"tag":"O"},
                             {"tag":"P"},{"tag":"Q"},{"tag":"R"},{"tag":"S"},{"tag":"T"},
                             {"tag":"U"},{"tag":"V"}],
                     "Media":[{"Part":[{"key":"/p/1","size":1}]}]}]}}"#,
            )
        });
        let db = parking_lot::Mutex::new(Db::open_in_memory().unwrap());
        sync(
            &db,
            &PlexClient::new(&server.base_url, "tok", "install"),
            "plex1",
            &NOT_PAUSED,
            false,
        )
        .unwrap();

        let alien: i64 = db
            .lock()
            .conn()
            .query_row("SELECT id FROM titles WHERE name = 'Alien'", [], |r| {
                r.get(0)
            })
            .unwrap();
        let row = db.lock().metadata(alien).unwrap().unwrap();
        assert_eq!(row.cast_names.split(',').count(), MAX_CAST);
        assert_eq!(row.cast_names, "A,B,C,D,E,F,G,H,I,J,K,L,M,N,O,P,Q,R,S,T");
        // each part beside its name, a comma in one taken out like a name's
        let parts = db.lock().cast_characters(alien).unwrap();
        assert_eq!(parts.split(',').count(), MAX_CAST);
        assert!(parts.starts_with("Ripley  Ellen,,"));
    }

    #[test]
    fn a_sync_brings_back_what_the_server_knows_about_watching() {
        let server = library();
        let db = parking_lot::Mutex::new(Db::open_in_memory().unwrap());
        sync(
            &db,
            &PlexClient::new(&server.base_url, "tok", "install"),
            "plex1",
            &NOT_PAUSED,
            false,
        )
        .unwrap();

        // the movie was left in progress: 1200s of 9000s
        let dune = db
            .lock()
            .file_id("plex1", "/library/parts/501/1/Dune.mkv")
            .unwrap()
            .unwrap();
        let row = db.lock().watch_state(dune).unwrap().unwrap();
        assert_eq!(row.position_secs, 1200.0);
        assert_eq!(row.duration_secs, 9000.0);
        assert!(!row.watched);
        assert!(row.updated_at > 0);

        // the second episode was played to the end: viewCount, no offset
        let seen = db
            .lock()
            .file_id("plex1", "/library/parts/602/1/S02E03.mkv")
            .unwrap()
            .unwrap();
        let row = db.lock().watch_state(seen).unwrap().unwrap();
        assert!(row.watched);
        assert_eq!(row.position_secs, 0.0);

        // and the first episode is where it was left
        let started = db
            .lock()
            .file_id("plex1", "/library/parts/601/1/S01E01.mkv")
            .unwrap()
            .unwrap();
        assert_eq!(
            db.lock()
                .watch_state(started)
                .unwrap()
                .unwrap()
                .position_secs,
            600.0
        );
    }

    #[test]
    fn an_item_the_server_never_played_gets_no_row() {
        let server = FakeServer::start(|req| {
            if req.url == "/library/sections" {
                return Reply::json(
                    r#"{"MediaContainer":{"Directory":[{"key":"1","type":"movie","title":"Movies"}]}}"#,
                );
            }
            Reply::json(
                r#"{"MediaContainer":{"size":1,"totalSize":1,"Metadata":[
                    {"ratingKey":"1","title":"Alien","year":1979,
                     "Media":[{"Part":[{"key":"/p/1","size":1}]}]}]}}"#,
            )
        });
        let db = parking_lot::Mutex::new(Db::open_in_memory().unwrap());
        sync(
            &db,
            &PlexClient::new(&server.base_url, "tok", "install"),
            "plex1",
            &NOT_PAUSED,
            false,
        )
        .unwrap();
        let rows: i64 = db
            .lock()
            .conn()
            .query_row("SELECT COUNT(*) FROM watch_state", [], |r| r.get(0))
            .unwrap();
        assert_eq!(rows, 0);
    }

    #[test]
    fn a_mirrored_row_is_stamped_when_the_server_last_played_it() {
        let server = library();
        let db = parking_lot::Mutex::new(Db::open_in_memory().unwrap());
        sync(
            &db,
            &PlexClient::new(&server.base_url, "tok", "install"),
            "plex1",
            &NOT_PAUSED,
            false,
        )
        .unwrap();

        let started = db
            .lock()
            .file_id("plex1", "/library/parts/601/1/S01E01.mkv")
            .unwrap()
            .unwrap();
        let seen = db
            .lock()
            .file_id("plex1", "/library/parts/602/1/S02E03.mkv")
            .unwrap()
            .unwrap();
        let started = db.lock().watch_state(started).unwrap().unwrap();
        let seen = db.lock().watch_state(seen).unwrap().unwrap();
        assert_eq!(started.updated_at, 1_700_000_000);
        assert_eq!(seen.updated_at, 1_700_086_400);
        // continue watching orders on this column: two items the server played
        // a day apart must not come out of a sync tied on the sync's own clock
        assert!(seen.updated_at > started.updated_at);
    }

    #[test]
    fn an_item_the_server_dates_nowhere_is_stamped_with_the_sync() {
        let server = FakeServer::start(|req| {
            if req.url == "/library/sections" {
                return Reply::json(
                    r#"{"MediaContainer":{"Directory":[{"key":"1","type":"movie","title":"Movies"}]}}"#,
                );
            }
            Reply::json(
                r#"{"MediaContainer":{"size":2,"totalSize":2,"Metadata":[
                    {"ratingKey":"1","title":"Alien","year":1979,
                     "viewOffset":60000,"duration":6000000,"lastViewedAt":1500000000,
                     "Media":[{"Part":[{"key":"/p/1","size":1}]}]},
                    {"ratingKey":"2","title":"Aliens","year":1986,
                     "viewOffset":60000,"duration":6000000,
                     "Media":[{"Part":[{"key":"/p/2","size":2}]}]}]}}"#,
            )
        });
        let db = parking_lot::Mutex::new(Db::open_in_memory().unwrap());
        sync(
            &db,
            &PlexClient::new(&server.base_url, "tok", "install"),
            "plex1",
            &NOT_PAUSED,
            false,
        )
        .unwrap();

        let dated = db.lock().file_id("plex1", "/p/1").unwrap().unwrap();
        let undated = db.lock().file_id("plex1", "/p/2").unwrap().unwrap();
        assert_eq!(
            db.lock().watch_state(dated).unwrap().unwrap().updated_at,
            1_500_000_000
        );
        // the sync's clock is this decade, the stamp above is 2017
        assert!(
            db.lock().watch_state(undated).unwrap().unwrap().updated_at > 1_700_000_000,
            "a server that dates nothing falls back to the sync's own clock"
        );
    }

    #[test]
    fn the_server_says_how_many_times_a_film_was_played_and_the_index_keeps_it() {
        let server = FakeServer::start(|req| {
            if req.url == "/library/sections" {
                return Reply::json(
                    r#"{"MediaContainer":{"Directory":[{"key":"1","type":"movie","title":"Movies"}]}}"#,
                );
            }
            Reply::json(
                r#"{"MediaContainer":{"size":2,"totalSize":2,"Metadata":[
                    {"ratingKey":"1","title":"Heat","year":1995,
                     "viewCount":3,"duration":6000000,"lastViewedAt":1740656858,
                     "Media":[{"Part":[{"key":"/p/1","size":1}]}]},
                    {"ratingKey":"2","title":"Collateral","year":2004,
                     "viewOffset":600000,"duration":6000000,"lastViewedAt":1740656858,
                     "Media":[{"Part":[{"key":"/p/2","size":1}]}]}]}}"#,
            )
        });
        let db = parking_lot::Mutex::new(Db::open_in_memory().unwrap());
        sync(
            &db,
            &PlexClient::new(&server.base_url, "tok", "install"),
            "plex1",
            &NOT_PAUSED,
            false,
        )
        .unwrap();

        let guard = db.lock();
        let heat = guard.file_id("plex1", "/p/1").unwrap().unwrap();
        let collateral = guard.file_id("plex1", "/p/2").unwrap().unwrap();
        assert_eq!(guard.watch_state(heat).unwrap().unwrap().plays, 3);
        // started and never finished: the server counted no pass at all
        assert_eq!(guard.watch_state(collateral).unwrap().unwrap().plays, 0);
    }

    #[test]
    fn an_item_played_before_and_left_running_is_one_to_continue() {
        // the shape a rewatch takes on the server: a viewCount from the time it
        // was finished and a viewOffset from where the viewer is now. Plex
        // keeps the two apart, and the resume row is about the second of them.
        let server = FakeServer::start(|req| {
            if req.url == "/library/sections" {
                return Reply::json(
                    r#"{"MediaContainer":{"Directory":[{"key":"1","type":"movie","title":"Movies"}]}}"#,
                );
            }
            Reply::json(
                r#"{"MediaContainer":{"size":1,"totalSize":1,"Metadata":[
                    {"ratingKey":"1","title":"Severance","year":2022,
                     "viewCount":1,"viewOffset":2331000,"duration":2934000,
                     "lastViewedAt":1740656858,
                     "Media":[{"Part":[{"key":"/p/1","size":1}]}]}]}}"#,
            )
        });
        let db = parking_lot::Mutex::new(Db::open_in_memory().unwrap());
        sync(
            &db,
            &PlexClient::new(&server.base_url, "tok", "install"),
            "plex1",
            &NOT_PAUSED,
            false,
        )
        .unwrap();

        let file_id = db.lock().file_id("plex1", "/p/1").unwrap().unwrap();
        let row = db.lock().watch_state(file_id).unwrap().unwrap();
        assert!(row.watched, "the server counted it played");
        assert_eq!(row.position_secs, 2331.0, "and holds a live offset");

        let queue = up_next(&db.lock(), 20, 0).unwrap();
        let resume = queue.first().expect("79% through is what the queue is for");
        assert_eq!(resume.resume_file_id, Some(file_id));
        assert_eq!(resume.position_secs, 2331.0);
        // and the detail screen agrees with the card: pressing it resumes
        let watch = db.lock().title_watch(resume.title.id).unwrap();
        assert_eq!(watch.resume.unwrap().position_secs, 2331.0);
    }

    #[test]
    fn a_later_sync_follows_the_position_the_server_moved() {
        let db = parking_lot::Mutex::new(Db::open_in_memory().unwrap());
        {
            let first = library();
            sync(
                &db,
                &PlexClient::new(&first.base_url, "tok", "install"),
                "plex1",
                &NOT_PAUSED,
                false,
            )
            .unwrap();
        }
        let dune = db
            .lock()
            .file_id("plex1", "/library/parts/501/1/Dune.mkv")
            .unwrap()
            .unwrap();
        assert_eq!(
            db.lock().watch_state(dune).unwrap().unwrap().position_secs,
            1200.0
        );

        // the same library, watched to the end on another client since
        let moved = FakeServer::start(|req| {
            if req.url == "/library/sections" {
                return Reply::json(SECTIONS_JSON);
            }
            if req.url.starts_with("/library/sections/1/all") {
                return Reply::json(
                    r#"{"MediaContainer":{"size":1,"totalSize":1,"Metadata":[
                        {"ratingKey":"101","title":"Dune","year":2021,
                         "summary":"Dans un futur lointain.",
                         "viewOffset":8700000,"duration":9000000,
                         "lastViewedAt":1700200000,
                         "Media":[{"Part":[{"id":501,"key":"/library/parts/501/1/Dune.mkv","size":42}]}]}]}}"#,
                );
            }
            Reply::json(EPISODES_JSON)
        });
        sync(
            &db,
            &PlexClient::new(&moved.base_url, "tok", "install"),
            "plex1",
            &NOT_PAUSED,
            false,
        )
        .unwrap();

        let row = db.lock().watch_state(dune).unwrap().unwrap();
        assert_eq!(row.position_secs, 8700.0);
        assert_eq!(row.updated_at, 1_700_200_000);
        // and past ninety percent the row watches itself, with no viewCount
        assert!(row.watched);
    }

    #[test]
    fn the_server_owns_the_flag_and_may_take_it_back() {
        let db = parking_lot::Mutex::new(Db::open_in_memory().unwrap());
        {
            let first = library();
            sync(
                &db,
                &PlexClient::new(&first.base_url, "tok", "install"),
                "plex1",
                &NOT_PAUSED,
                false,
            )
            .unwrap();
        }
        let seen = db
            .lock()
            .file_id("plex1", "/library/parts/602/1/S02E03.mkv")
            .unwrap()
            .unwrap();
        assert!(db.lock().watch_state(seen).unwrap().unwrap().watched);

        // marked unplayed on the server, and started again there since: a
        // position, and a view count back to nothing
        let restarted = FakeServer::start(|req| {
            if req.url == "/library/sections" {
                return Reply::json(SECTIONS_JSON);
            }
            if req.url.starts_with("/library/sections/1/all") {
                return Reply::json(MOVIES_JSON);
            }
            Reply::json(
                r#"{"MediaContainer":{"size":1,"totalSize":1,"Metadata":[
                    {"ratingKey":"202","title":"Home","grandparentTitle":"The Expanse",
                     "parentIndex":2,"index":3,"year":2016,
                     "viewOffset":300000,"duration":3000000,"lastViewedAt":1700200000,
                     "Media":[{"Part":[{"id":602,"key":"/library/parts/602/1/S02E03.mkv","size":11}]}]}]}}"#,
            )
        });
        sync(
            &db,
            &PlexClient::new(&restarted.base_url, "tok", "install"),
            "plex1",
            &NOT_PAUSED,
            false,
        )
        .unwrap();

        // a report of this device's own could only ever raise the flag; the
        // server that owns the item is the one allowed to lower it
        let row = db.lock().watch_state(seen).unwrap().unwrap();
        assert!(!row.watched);
        assert_eq!(row.position_secs, 300.0);
    }

    #[test]
    fn a_row_survives_a_sync_the_server_says_nothing_about() {
        let server = FakeServer::start(|req| {
            if req.url == "/library/sections" {
                return Reply::json(
                    r#"{"MediaContainer":{"Directory":[{"key":"1","type":"movie","title":"Movies"}]}}"#,
                );
            }
            Reply::json(
                r#"{"MediaContainer":{"size":1,"totalSize":1,"Metadata":[
                    {"ratingKey":"1","title":"Alien","year":1979,
                     "Media":[{"Part":[{"key":"/p/1","size":1}]}]}]}}"#,
            )
        });
        let db = parking_lot::Mutex::new(Db::open_in_memory().unwrap());
        let client = PlexClient::new(&server.base_url, "tok", "install");
        sync(&db, &client, "plex1", &NOT_PAUSED, false).unwrap();

        // a report this device has made and not written back to the server yet
        let file_id = db.lock().file_id("plex1", "/p/1").unwrap().unwrap();
        db.lock()
            .upsert_watch_state(
                &WatchRecord {
                    file_id,
                    position_secs: 300.0,
                    duration_secs: 1800.0,
                    watched: false,
                    plays: 0,
                    updated_at: NOW,
                },
                WatchAuthority::Report,
            )
            .unwrap();

        sync(&db, &client, "plex1", &NOT_PAUSED, false).unwrap();

        let row = db.lock().watch_state(file_id).unwrap().unwrap();
        assert_eq!(row.position_secs, 300.0);
        assert_eq!(row.duration_secs, 1800.0);
        assert_eq!(row.updated_at, NOW);
    }

    #[test]
    fn a_plex_row_keeps_the_tmdb_id_the_enrichment_found() {
        let server = library();
        let db = parking_lot::Mutex::new(Db::open_in_memory().unwrap());
        // the same title also lives on a file source, and TMDB matched it there
        let dune = db
            .lock()
            .upsert_title(MediaKind::Movie, "Dune", Some(2021))
            .unwrap();
        db.lock()
            .upsert_metadata(&MetadataRecord {
                title_id: dune,
                tmdb_id: Some(438631),
                overview_fr: None,
                overview_en: Some("A far future.".into()),
                poster_path: Some("/dune.jpg".into()),
                backdrop_path: None,
                genres: "Science Fiction".into(),
                cast_names: String::new(),
                collections: String::new(),
                director_names: String::new(),
                writer_names: String::new(),
                composer_names: String::new(),
                source: MetadataSource::Tmdb,
                fetched_at: NOW,
                critics: None,
                audience: None,
                release_date: None,
            })
            .unwrap();

        sync(
            &db,
            &PlexClient::new(&server.base_url, "tok", "install"),
            "plex1",
            &NOT_PAUSED,
            false,
        )
        .unwrap();

        let row = db.lock().metadata(dune).unwrap().unwrap();
        // the server's description wins, as it should
        assert_eq!(row.source, MetadataSource::Plex);
        assert_eq!(row.overview_fr.as_deref(), Some("Dans un futur lointain."));
        // but the id the recommendations join on is not collateral damage
        assert_eq!(row.tmdb_id, Some(438631));
    }

    #[test]
    fn a_movie_the_server_describes_nothing_about_is_left_to_tmdb() {
        // an item no Plex agent ever matched: a title, a file, and nothing else
        let bare = FakeServer::start(|req| {
            if req.url == "/library/sections" {
                return Reply::json(SECTIONS_JSON);
            }
            if req.url.starts_with("/library/sections/1/all") {
                return Reply::json(
                    r#"{"MediaContainer":{"size":1,"totalSize":1,"Metadata":[
                        {"ratingKey":"101","title":"Dune","year":2021,"summary":" \n ",
                         "Media":[{"Part":[{"key":"/library/parts/501/1/Dune.mkv","size":42}]}]}]}}"#,
                );
            }
            Reply::json(r#"{"MediaContainer":{"size":0,"totalSize":0}}"#)
        });
        let db = parking_lot::Mutex::new(Db::open_in_memory().unwrap());
        sync(
            &db,
            &PlexClient::new(&bare.base_url, "tok", "install"),
            "plex1",
            &NOT_PAUSED,
            false,
        )
        .unwrap();

        let dune: i64 = db
            .lock()
            .conn()
            .query_row("SELECT id FROM titles WHERE name = 'Dune'", [], |r| {
                r.get(0)
            })
            .unwrap();
        // an empty row would take the title off the queue for good
        assert_eq!(db.lock().metadata(dune).unwrap(), None);
        assert!(db
            .lock()
            .titles_needing_metadata(NOW, MAX_AGE_SECS, 100)
            .unwrap()
            .iter()
            .any(|t| t.id == dune));

        let tmdb_server = tmdb();
        let tmdb_client = TmdbClient::new(&tmdb_server.base_url, "k");
        assert_eq!(
            enrich_pending(&db, &tmdb_client, 10, NOW, &Slice::open())
                .unwrap()
                .matched,
            1
        );
        let row = db.lock().metadata(dune).unwrap().unwrap();
        assert_eq!(row.source, MetadataSource::Tmdb);
        assert_eq!(row.tmdb_id, Some(438631));

        // and a server that describes it later takes precedence back
        let full = library();
        sync(
            &db,
            &PlexClient::new(&full.base_url, "tok", "install"),
            "plex1",
            &NOT_PAUSED,
            false,
        )
        .unwrap();
        let row = db.lock().metadata(dune).unwrap().unwrap();
        assert_eq!(row.source, MetadataSource::Plex);
        // the server knows no TMDB id, and the match already found survives it:
        // the recommendations join titles on that id
        assert_eq!(row.tmdb_id, Some(438631));
        assert_eq!(
            row.poster_path.as_deref(),
            Some("/library/metadata/101/thumb/1")
        );
    }

    #[test]
    fn a_sync_pages_until_the_total_is_reached() {
        let server = FakeServer::start(|req| {
            if req.url == "/library/sections" {
                return Reply::json(
                    r#"{"MediaContainer":{"Directory":[{"key":"1","type":"movie","title":"Movies"}]}}"#,
                );
            }
            if req.url.contains("X-Plex-Container-Start=0") {
                return Reply::json(
                    r#"{"MediaContainer":{"size":1,"totalSize":2,"Metadata":[
                        {"ratingKey":"1","title":"Alien","year":1979,
                         "Media":[{"Part":[{"key":"/p/1","size":1}]}]}]}}"#,
                );
            }
            if req.url.contains("X-Plex-Container-Start=1") {
                return Reply::json(
                    r#"{"MediaContainer":{"size":1,"totalSize":2,"Metadata":[
                        {"ratingKey":"2","title":"Blade Runner","year":1982,
                         "Media":[{"Part":[{"key":"/p/2","size":2}]}]}]}}"#,
                );
            }
            Reply::status(500)
        });
        let db = parking_lot::Mutex::new(Db::open_in_memory().unwrap());
        let stats = sync(
            &db,
            &PlexClient::new(&server.base_url, "tok", "install"),
            "plex1",
            &NOT_PAUSED,
            false,
        )
        .unwrap();
        assert_eq!(stats.files_upserted, 2);
        assert_eq!(
            titles(&db.lock()),
            vec![
                ("movie".to_string(), "Alien".to_string(), 1979),
                ("movie".to_string(), "Blade Runner".to_string(), 1982),
            ]
        );
    }

    /// How many file rows a source holds.
    fn file_count(db: &Db, source_id: &str) -> i64 {
        db.conn()
            .query_row(
                "SELECT COUNT(*) FROM files WHERE source_id = ?1",
                [source_id],
                |r| r.get(0),
            )
            .unwrap()
    }

    #[test]
    fn a_vanished_item_is_removed_and_its_title_pruned() {
        let db = parking_lot::Mutex::new(Db::open_in_memory().unwrap());
        {
            let full = library();
            sync(
                &db,
                &PlexClient::new(&full.base_url, "tok", "install"),
                "plex1",
                &NOT_PAUSED,
                false,
            )
            .unwrap();
        }
        // the movie is gone and the show has lost an episode, but the pull
        // itself is not empty
        let shrunk = FakeServer::start(|req| {
            if req.url == "/library/sections" {
                return Reply::json(SECTIONS_JSON);
            }
            if req.url.starts_with("/library/sections/2/all") {
                return Reply::json(
                    r#"{"MediaContainer":{"size":1,"totalSize":1,"Metadata":[
                        {"ratingKey":"201","title":"Dulcinea","grandparentTitle":"The Expanse",
                         "parentIndex":1,"index":1,
                         "Media":[{"Part":[{"key":"/library/parts/601/1/S01E01.mkv","size":10}]}]}]}}"#,
                );
            }
            Reply::json(r#"{"MediaContainer":{"size":0,"totalSize":0}}"#)
        });
        let stats = sync(
            &db,
            &PlexClient::new(&shrunk.base_url, "tok", "install"),
            "plex1",
            &NOT_PAUSED,
            false,
        )
        .unwrap();
        assert_eq!(stats.files_upserted, 1);
        assert_eq!(stats.files_removed, 2); // the movie and the second episode

        // the show survives on its remaining episode, and keeps the year the
        // first sync learned: this answer carries no show-level item at all,
        // and a pass that knows no year does not erase one
        assert_eq!(
            titles(&db.lock()),
            vec![("show".to_string(), "The Expanse".to_string(), 2015)]
        );
    }

    #[test]
    fn an_empty_answer_keeps_a_library_that_had_files() {
        let empty = FakeServer::start(|req| {
            if req.url == "/library/sections" {
                return Reply::json(SECTIONS_JSON);
            }
            Reply::json(r#"{"MediaContainer":{"size":0,"totalSize":0}}"#)
        });

        let db = parking_lot::Mutex::new(Db::open_in_memory().unwrap());
        {
            let full = library();
            sync(
                &db,
                &PlexClient::new(&full.base_url, "tok", "install"),
                "plex1",
                &NOT_PAUSED,
                false,
            )
            .unwrap();
        }
        let err = sync(
            &db,
            &PlexClient::new(&empty.base_url, "tok", "install"),
            "plex1",
            &NOT_PAUSED,
            false,
        )
        .unwrap_err();
        assert!(matches!(err, SyncError::EmptyLibrary));
        // the cache survives: the sweep and the prune never ran
        assert_eq!(file_count(&db.lock(), "plex1"), 3);
        assert_eq!(titles(&db.lock()).len(), 2);

        // a source that never had files is simply an empty library
        let fresh = parking_lot::Mutex::new(Db::open_in_memory().unwrap());
        let stats = sync(
            &fresh,
            &PlexClient::new(&empty.base_url, "tok", "install"),
            "plex2",
            &NOT_PAUSED,
            false,
        )
        .unwrap();
        assert_eq!(stats.files_upserted, 0);
        assert_eq!(file_count(&fresh.lock(), "plex2"), 0);
    }

    #[test]
    fn an_item_without_a_name_falls_back_to_its_section_title() {
        let server = FakeServer::start(|req| {
            if req.url == "/library/sections" {
                return Reply::json(SECTIONS_JSON);
            }
            if req.url.starts_with("/library/sections/1/all") {
                return Reply::json(
                    r#"{"MediaContainer":{"size":1,"totalSize":1,"Metadata":[
                        {"ratingKey":"1","title":"",
                         "Media":[{"Part":[{"key":"/p/1","size":1}]}]}]}}"#,
                );
            }
            Reply::json(
                r#"{"MediaContainer":{"size":1,"totalSize":1,"Metadata":[
                    {"ratingKey":"2","title":"Pilot","parentIndex":1,"index":1,
                     "Media":[{"Part":[{"key":"/p/2","size":2}]}]}]}}"#,
            )
        });
        let db = parking_lot::Mutex::new(Db::open_in_memory().unwrap());
        let stats = sync(
            &db,
            &PlexClient::new(&server.base_url, "tok", "install"),
            "plex1",
            &NOT_PAUSED,
            false,
        )
        .unwrap();
        assert_eq!(stats.files_upserted, 2);
        // a nameless movie and an episode with no show name would otherwise
        // collapse into one empty title
        assert_eq!(
            titles(&db.lock()),
            vec![
                ("movie".to_string(), "Movies".to_string(), 0),
                ("show".to_string(), "TV Shows".to_string(), 0),
            ]
        );
    }

    #[test]
    fn an_episodes_own_title_summary_and_still_are_kept_off_the_page_that_named_the_show() {
        let server = FakeServer::start(|req| {
            if req.url == "/library/sections" {
                return Reply::json(SECTIONS_JSON);
            }
            if req.url.starts_with("/library/sections/1/all") {
                return Reply::json(MOVIES_JSON);
            }
            Reply::json(EPISODES_JSON)
        });
        let db = parking_lot::Mutex::new(Db::open_in_memory().unwrap());
        sync(
            &db,
            &PlexClient::new(&server.base_url, "tok", "install"),
            "plex1",
            &NOT_PAUSED,
            false,
        )
        .unwrap();

        let title_id = db
            .lock()
            .upsert_title(MediaKind::Show, "The Expanse", None)
            .unwrap();
        let episodes = db.lock().episodes(title_id).unwrap();
        assert_eq!(
            episodes
                .iter()
                .map(|e| (e.title.as_str(), e.summary.as_str()))
                .collect::<Vec<_>>(),
            // the second episode's page carries a title and no sentence, which
            // is stored as the empty answer it is
            vec![("Dulcinea", "Une inspectrice."), ("Home", "")]
        );
        // the second carries no year of its own, only the day it aired
        assert_eq!(
            episodes.iter().map(|e| e.air_year).collect::<Vec<_>>(),
            vec![Some(2015), Some(2016)]
        );
        assert_eq!(
            db.lock().still_source(episodes[0].file_id).unwrap(),
            Some((
                "plex1".to_string(),
                "/library/metadata/201/thumb/1".to_string()
            ))
        );
        // and an episode the server holds no frame for asks for none
        assert_eq!(db.lock().still_source(episodes[1].file_id).unwrap(), None);

        // a movie describes itself in `metadata`, keyed by its title, and
        // writes no episode row at all
        let rows: i64 = db
            .lock()
            .conn()
            .query_row("SELECT COUNT(*) FROM episode_meta", [], |r| r.get(0))
            .unwrap();
        assert_eq!(rows, 2);
    }

    /// A sync writes page by page, so a failure partway keeps the pages that
    /// landed - what it must never do is remove anything, or claim a section
    /// it never finished. Both are what makes the next sync converge instead
    /// of the failure costing the whole library.
    #[test]
    fn a_failed_sync_removes_nothing_and_claims_no_section_it_did_not_finish() {
        // the movie section answers, the show section does not
        let server = FakeServer::start(|req| {
            if req.url == "/library/sections" {
                return Reply::json(SECTIONS_JSON);
            }
            if req.url.starts_with("/library/sections/1/all") {
                return Reply::json(MOVIES_JSON);
            }
            Reply::status(500)
        });
        let db = parking_lot::Mutex::new(Db::open_in_memory().unwrap());
        let err = sync(
            &db,
            &PlexClient::new(&server.base_url, "tok", "install"),
            "plex1",
            &NOT_PAUSED,
            false,
        )
        .unwrap_err();
        assert!(matches!(err, SyncError::Plex(PlexError::Status(500))));
        // the section that answered is indexed, whole: a page is what commits
        assert_eq!(
            titles(&db.lock()),
            vec![("movie".to_string(), "Dune".to_string(), 2021)]
        );
        // and the one that did not stored no updatedAt, so the next sync
        // pulls it rather than carrying nothing forward by generation
        assert_eq!(db.lock().dir_mtime("plex1", "2").unwrap(), None);

        // a retry against a server that answers both converges, with nothing
        // duplicated and nothing left over
        let whole = library();
        sync(
            &db,
            &PlexClient::new(&whole.base_url, "tok", "install"),
            "plex1",
            &NOT_PAUSED,
            false,
        )
        .unwrap();
        assert_eq!(titles(&db.lock()).len(), 2);
        assert_eq!(file_count(&db.lock(), "plex1"), 3);
    }

    #[test]
    fn a_second_sync_removes_nothing_and_duplicates_no_title() {
        let server = library();
        let db = parking_lot::Mutex::new(Db::open_in_memory().unwrap());
        let client = PlexClient::new(&server.base_url, "tok", "install");
        sync(&db, &client, "plex1", &NOT_PAUSED, false).unwrap();
        let stats = sync(&db, &client, "plex1", &NOT_PAUSED, false).unwrap();
        assert_eq!(stats.files_upserted, 3);
        assert_eq!(stats.files_removed, 0);
        assert_eq!(titles(&db.lock()).len(), 2);
    }

    // ---- incremental sync: a section's own updatedAt gates the pull ----

    /// A two-section server whose sections carry a real `updatedAt`, unlike
    /// `library()`'s fixed fixture: the movie section's body and both
    /// sections' `updatedAt` are driven by the handles a test holds, so a
    /// second sync can be pointed at the same server with only what changed
    /// actually changed. The show section always answers `SHOWS_JSON` and
    /// `EPISODES_JSON`: no test here needs it to move.
    fn incremental_library(
        movie_updated: Arc<AtomicI64>,
        show_updated: Arc<AtomicI64>,
        movie_body: Arc<Mutex<String>>,
    ) -> FakeServer {
        FakeServer::start(move |req| {
            if req.url == "/library/sections" {
                return Reply::json(&format!(
                    r#"{{"MediaContainer":{{"size":2,"Directory":[
                      {{"key":"1","type":"movie","title":"Movies","updatedAt":{}}},
                      {{"key":"2","type":"show","title":"TV Shows","updatedAt":{}}}
                    ]}}}}"#,
                    movie_updated.load(Ordering::SeqCst),
                    show_updated.load(Ordering::SeqCst),
                ));
            }
            if req.url.starts_with("/library/sections/1/all") {
                return Reply::json(&movie_body.lock());
            }
            if req.url.starts_with("/library/sections/2/all") {
                return Reply::json(if query(&req.url, "type").as_deref() == Some("2") {
                    crate::plex::fake::SHOWS_JSON
                } else {
                    EPISODES_JSON
                });
            }
            Reply::status(404)
        })
    }

    const TWO_MOVIES: &str = r#"{"MediaContainer":{"size":2,"totalSize":2,"Metadata":[
        {"ratingKey":"101","title":"Dune","year":2021,"addedAt":1690000000,
         "Media":[{"Part":[{"id":501,"key":"/library/parts/501/1/Dune.mkv","size":42}]}]},
        {"ratingKey":"999","title":"Alien","year":1979,
         "Media":[{"Part":[{"key":"/p/999","size":9}]}]}]}}"#;

    #[test]
    fn an_unchanged_section_is_only_asked_about_watches() {
        let movie_updated = Arc::new(AtomicI64::new(5000));
        let show_updated = Arc::new(AtomicI64::new(5000));
        let movie_body = Arc::new(Mutex::new(MOVIES_JSON.to_string()));
        let server = incremental_library(movie_updated, show_updated, movie_body);
        let db = parking_lot::Mutex::new(Db::open_in_memory().unwrap());
        let client = PlexClient::new(&server.base_url, "tok", "install");

        sync(&db, &client, "plex1", &NOT_PAUSED, false).unwrap();
        let after_first = server.requests().len();

        let second = sync(&db, &client, "plex1", &NOT_PAUSED, false).unwrap();
        assert_eq!(
            second.files_upserted, 0,
            "nothing changed on the server, nothing is rewritten"
        );
        assert_eq!(
            second.files_seen, 3,
            "the files are still there, only carried forward"
        );
        assert_eq!(second.files_removed, 0);
        // the one request every section shares, and one watch page per section
        assert_eq!(server.requests().len(), after_first + 3);
    }

    #[test]
    fn a_changed_sections_updated_at_triggers_a_repull_and_the_change_is_picked_up() {
        let movie_updated = Arc::new(AtomicI64::new(5000));
        let show_updated = Arc::new(AtomicI64::new(5000));
        let movie_body = Arc::new(Mutex::new(MOVIES_JSON.to_string()));
        let server = incremental_library(
            movie_updated.clone(),
            show_updated.clone(),
            movie_body.clone(),
        );
        let db = parking_lot::Mutex::new(Db::open_in_memory().unwrap());
        let client = PlexClient::new(&server.base_url, "tok", "install");
        sync(&db, &client, "plex1", &NOT_PAUSED, false).unwrap();

        // a new movie appears, and the server's own scan bumped the section's
        // updatedAt to say so; the show section did not move
        *movie_body.lock() = TWO_MOVIES.to_string();
        movie_updated.store(6000, Ordering::SeqCst);

        let stats = sync(&db, &client, "plex1", &NOT_PAUSED, false).unwrap();
        assert_eq!(stats.files_upserted, 2, "both movies are repulled");
        assert_eq!(stats.files_seen, 4, "2 repulled movies, 2 carried episodes");
        assert_eq!(stats.files_removed, 0);
        assert_eq!(db.lock().dir_mtime("plex1", "1").unwrap(), Some(6000));
        assert_eq!(db.lock().dir_mtime("plex1", "2").unwrap(), Some(5000));
        assert!(titles(&db.lock()).contains(&("movie".to_string(), "Alien".to_string(), 1979)));
    }

    #[test]
    fn a_section_that_gained_a_film_is_repulled_on_its_scan_stamp_alone() {
        // The bug this covers: a Plex that takes in a film scans the section
        // and moves `scannedAt`, and often leaves the section's own record -
        // and so `updatedAt` - exactly where it was. Gated on `updatedAt`
        // alone the section is skipped, and the film never arrives however
        // many times a viewer presses Scan.
        let movie_scanned = Arc::new(AtomicI64::new(5000));
        let movie_body = Arc::new(Mutex::new(MOVIES_JSON.to_string()));
        let scanned = movie_scanned.clone();
        let body = movie_body.clone();
        let server = FakeServer::start(move |req| {
            if req.url == "/library/sections" {
                // updatedAt frozen at 4000 throughout: only the scan moves
                return Reply::json(&format!(
                    r#"{{"MediaContainer":{{"size":1,"Directory":[
                      {{"key":"1","type":"movie","title":"Movies",
                        "updatedAt":4000,"scannedAt":{}}}
                    ]}}}}"#,
                    scanned.load(Ordering::SeqCst),
                ));
            }
            if req.url.starts_with("/library/sections/1/all") {
                return Reply::json(&body.lock());
            }
            Reply::status(404)
        });
        let db = parking_lot::Mutex::new(Db::open_in_memory().unwrap());
        let client = PlexClient::new(&server.base_url, "tok", "install");
        sync(&db, &client, "plex1", &NOT_PAUSED, false).unwrap();
        let stamp = |db: &parking_lot::Mutex<Db>| db.lock().dir_mtime("plex1", "1").unwrap();
        assert_eq!(stamp(&db), Some(5000));

        // the server takes in Alien and scans; its record never moves
        *movie_body.lock() = TWO_MOVIES.to_string();
        movie_scanned.store(6000, Ordering::SeqCst);

        let stats = sync(&db, &client, "plex1", &NOT_PAUSED, false).unwrap();
        assert_eq!(stats.files_upserted, 2, "the section is pulled again");
        let listed = titles(&db.lock());
        assert!(listed.contains(&("movie".to_string(), "Alien".to_string(), 1979)));
        assert_eq!(stamp(&db), Some(6000));

        // and with neither stamp moving it is skipped, as it was before
        let quiet = sync(&db, &client, "plex1", &NOT_PAUSED, false).unwrap();
        assert_eq!(quiet.files_upserted, 0);
    }

    #[test]
    fn a_scan_the_viewer_asked_for_believes_no_stamp_at_all() {
        // The gate is an optimisation for the sweep this app runs on its own.
        // A viewer pressing Scan is saying they do not believe what they have,
        // and a server that answers "nothing changed" to that is answering a
        // question nobody asked. This one has already been wrong about exactly
        // that, which is why the recourse has to exist.
        let movie_updated = Arc::new(AtomicI64::new(5000));
        let show_updated = Arc::new(AtomicI64::new(5000));
        let movie_body = Arc::new(Mutex::new(MOVIES_JSON.to_string()));
        let server = incremental_library(
            movie_updated.clone(),
            show_updated.clone(),
            movie_body.clone(),
        );
        let db = parking_lot::Mutex::new(Db::open_in_memory().unwrap());
        let client = PlexClient::new(&server.base_url, "tok", "install");
        sync(&db, &client, "plex1", &NOT_PAUSED, false).unwrap();

        // the film lands and the server says nothing about it: no stamp moves
        *movie_body.lock() = TWO_MOVIES.to_string();

        // the sweep believes the server and finds nothing
        let swept = sync(&db, &client, "plex1", &NOT_PAUSED, false).unwrap();
        assert_eq!(swept.files_upserted, 0);
        assert!(!titles(&db.lock())
            .iter()
            .any(|(_, name, _)| name == "Alien"));

        // and a scan the viewer asked for does not: every section is pulled
        // whole, the two films and the two episodes alike
        let asked = sync(&db, &client, "plex1", &NOT_PAUSED, true).unwrap();
        assert_eq!(asked.files_upserted, 4);
        let listed = titles(&db.lock());
        assert!(listed.contains(&("movie".to_string(), "Alien".to_string(), 1979)));
    }

    #[test]
    fn a_file_removed_from_a_changed_section_is_still_detected() {
        let movie_updated = Arc::new(AtomicI64::new(5000));
        let show_updated = Arc::new(AtomicI64::new(5000));
        let movie_body = Arc::new(Mutex::new(TWO_MOVIES.to_string()));
        let server = incremental_library(
            movie_updated.clone(),
            show_updated.clone(),
            movie_body.clone(),
        );
        let db = parking_lot::Mutex::new(Db::open_in_memory().unwrap());
        let client = PlexClient::new(&server.base_url, "tok", "install");
        sync(&db, &client, "plex1", &NOT_PAUSED, false).unwrap();
        assert_eq!(titles(&db.lock()).len(), 3); // Alien, Dune, The Expanse

        // Alien leaves the library; a removal is itself a scan, so the
        // server's own updatedAt moves along with it
        *movie_body.lock() = MOVIES_JSON.to_string();
        movie_updated.store(6000, Ordering::SeqCst);

        let stats = sync(&db, &client, "plex1", &NOT_PAUSED, false).unwrap();
        assert_eq!(stats.files_removed, 1);
        assert!(!titles(&db.lock()).contains(&("movie".to_string(), "Alien".to_string(), 1979)));
    }

    #[test]
    fn an_incremental_sync_interrupted_partway_removes_nothing_and_keeps_what_landed() {
        let movie_updated = Arc::new(AtomicI64::new(5000));
        let show_updated = Arc::new(AtomicI64::new(5000));
        let movie_body = Arc::new(Mutex::new(MOVIES_JSON.to_string()));
        let server = incremental_library(
            movie_updated.clone(),
            show_updated.clone(),
            movie_body.clone(),
        );
        let db = parking_lot::Mutex::new(Db::open_in_memory().unwrap());
        let client = PlexClient::new(&server.base_url, "tok", "install");
        sync(&db, &client, "plex1", &NOT_PAUSED, false).unwrap();
        let before = file_count(&db.lock(), "plex1");
        assert_eq!(before, 3);

        // the movie section changed and repulls fine, but the show section
        // then fails outright, mid transaction
        let failing = FakeServer::start(|req| {
            if req.url == "/library/sections" {
                return Reply::json(
                    r#"{"MediaContainer":{"size":2,"Directory":[
                      {"key":"1","type":"movie","title":"Movies","updatedAt":6000},
                      {"key":"2","type":"show","title":"TV Shows","updatedAt":6000}
                    ]}}"#,
                );
            }
            if req.url.starts_with("/library/sections/1/all") {
                return Reply::json(MOVIES_JSON);
            }
            Reply::status(500)
        });
        let err = sync(
            &db,
            &PlexClient::new(&failing.base_url, "tok", "install"),
            "plex1",
            &NOT_PAUSED,
            false,
        )
        .unwrap_err();
        assert!(matches!(err, SyncError::Plex(PlexError::Status(500))));
        assert_eq!(
            file_count(&db.lock(), "plex1"),
            before,
            "a failure removes nothing: the sweep runs only after every page"
        );
        assert_eq!(
            db.lock().dir_mtime("plex1", "1").unwrap(),
            Some(6000),
            "the movie section did finish, and keeping its updatedAt is what \
             lets the next sync skip it instead of pulling it again"
        );

        // a clean retry against the original, unchanged-since server succeeds
        // and duplicates nothing
        let stats = sync(&db, &client, "plex1", &NOT_PAUSED, false).unwrap();
        assert_eq!(file_count(&db.lock(), "plex1"), before);
        assert_eq!(stats.files_removed, 0);
        assert_eq!(titles(&db.lock()).len(), 2);
    }

    // ---- a changed section is read for its changes alone ----

    /// Two films and a show of two episodes, every stamp at 5000.
    fn shelf() -> Arc<Mutex<Shelf>> {
        Arc::new(Mutex::new(Shelf {
            movie_stamp: 5000,
            show_stamp: 5000,
            movies: vec![ShelfItem::film(1, 4000), ShelfItem::film(2, 4500)],
            shows: vec![ShelfItem::of("Andor", 10, 4000)],
            episodes: vec![
                ShelfItem::of("Andor", 11, 4000),
                ShelfItem::of("Andor", 12, 4000),
            ],
        }))
    }

    /// The listings asked for since request `from`, as (section, type, sort);
    /// an empty sort is a walk.
    fn listings(server: &FakeServer, from: usize) -> Vec<(String, String, String)> {
        server.requests()[from..]
            .iter()
            .filter_map(|r| {
                let section = r
                    .url
                    .strip_prefix("/library/sections/")?
                    .split_once("/all")?
                    .0;
                Some((
                    section.to_string(),
                    query(&r.url, "type").unwrap_or_default(),
                    query(&r.url, "sort")
                        .unwrap_or_default()
                        .replace("%3A", ":"),
                ))
            })
            .collect()
    }

    fn listing(section: &str, kind: &str, sort: &str) -> (String, String, String) {
        (section.to_string(), kind.to_string(), sort.to_string())
    }

    #[test]
    fn a_film_added_to_a_changed_section_is_indexed_without_walking_it() {
        let shelf = shelf();
        let server = shelf_library(shelf.clone());
        let db = Mutex::new(Db::open_in_memory().unwrap());
        let client = PlexClient::new(&server.base_url, "tok", "install");
        sync(&db, &client, "plex1", &NOT_PAUSED, false).unwrap();
        let before = server.requests().len();

        {
            let mut shelf = shelf.lock();
            shelf.movies.push(ShelfItem::film(3, 6000));
            shelf.movie_stamp = 6000;
        }
        let stats = sync(&db, &client, "plex1", &NOT_PAUSED, false).unwrap();

        assert_eq!(
            stats.files_upserted, 1,
            "the new film and nothing else is written"
        );
        assert_eq!(stats.files_seen, 5);
        assert_eq!(stats.files_removed, 0);
        assert!(titles(&db.lock()).contains(&("movie".into(), "Film 3".into(), 2000)));
        // the sections list, then one page per sort: no section is walked
        assert_eq!(server.requests().len(), before + 5);
        assert_eq!(
            listings(&server, before),
            [
                listing("1", "1", "addedAt:desc"),
                listing("1", "1", "updatedAt:desc"),
                listing("1", "1", "lastViewedAt:desc"),
                listing("2", "4", "lastViewedAt:desc"),
            ]
        );
        assert_eq!(db.lock().dir_mtime("plex1", "1").unwrap(), Some(6000));
    }

    #[test]
    fn a_film_deleted_on_the_server_is_removed_by_the_walk_its_count_starts() {
        let shelf = shelf();
        let server = shelf_library(shelf.clone());
        let db = Mutex::new(Db::open_in_memory().unwrap());
        let client = PlexClient::new(&server.base_url, "tok", "install");
        sync(&db, &client, "plex1", &NOT_PAUSED, false).unwrap();
        let before = server.requests().len();

        // a removal moves no item, only the section's scan stamp
        {
            let mut shelf = shelf.lock();
            shelf.movies.remove(0);
            shelf.movie_stamp = 6000;
        }
        let stats = sync(&db, &client, "plex1", &NOT_PAUSED, false).unwrap();

        assert_eq!(stats.files_removed, 1);
        assert!(!titles(&db.lock()).contains(&("movie".into(), "Film 1".into(), 2000)));
        // the two sorts found nothing, the count disagreed and the movie
        // section alone was walked
        assert_eq!(
            listings(&server, before),
            [
                listing("1", "1", "addedAt:desc"),
                listing("1", "1", "updatedAt:desc"),
                listing("1", "1", ""),
                listing("2", "4", "lastViewedAt:desc"),
            ]
        );
    }

    #[test]
    fn a_replaced_file_takes_the_place_of_the_old_one_without_a_walk() {
        let shelf = shelf();
        let server = shelf_library(shelf.clone());
        let db = Mutex::new(Db::open_in_memory().unwrap());
        let client = PlexClient::new(&server.base_url, "tok", "install");
        sync(&db, &client, "plex1", &NOT_PAUSED, false).unwrap();
        let before = server.requests().len();

        // an upgrade keeps the item and its ratingKey, and moves its part
        {
            let mut shelf = shelf.lock();
            shelf.movies[0].part = 99;
            shelf.movies[0].updated = 6000;
            shelf.movie_stamp = 6000;
        }
        let stats = sync(&db, &client, "plex1", &NOT_PAUSED, false).unwrap();

        assert!(!listings(&server, before).contains(&listing("1", "1", "")));
        assert_eq!(stats.files_seen, 4);
        let paths: Vec<String> = db
            .lock()
            .conn()
            .prepare("SELECT path FROM files WHERE rating_key = '1'")
            .unwrap()
            .query_map([], |r| r.get(0))
            .unwrap()
            .map(|r| r.unwrap())
            .collect();
        assert_eq!(paths, ["/library/parts/99/1/f.mkv"]);
    }

    #[test]
    fn an_item_skipped_by_a_walk_the_server_shrank_under_is_not_removed() {
        // three films served two to a page; once `shrunk`, film 1 is gone and
        // the second page starts past film 3, which no page then names
        let shrunk = Arc::new(std::sync::atomic::AtomicBool::new(false));
        let gone = shrunk.clone();
        let server = FakeServer::start(move |req| {
            if req.url == "/library/sections" {
                return Reply::json(
                    r#"{"MediaContainer":{"size":1,"Directory":[
                      {"key":"1","type":"movie","title":"Movies","scannedAt":5000}]}}"#,
                );
            }
            let film = |key: u32| {
                format!(
                    r#"{{"ratingKey":"{key}","title":"Film {key}","year":2000,
                       "Media":[{{"Part":[{{"key":"/library/parts/{key}/1/f.mkv","size":1}}]}}]}}"#
                )
            };
            let start = query(&req.url, "X-Plex-Container-Start").unwrap_or_default();
            let (total, page) = match (gone.load(Ordering::SeqCst), start.as_str()) {
                (false, "0") => (3, vec![film(1), film(2)]),
                (false, _) => (3, vec![film(3)]),
                // the deletion lands between the first page and the next
                (true, "0") => (3, vec![film(1), film(2)]),
                (true, _) => (2, Vec::new()),
            };
            Reply::json(&format!(
                r#"{{"MediaContainer":{{"size":{},"totalSize":{total},"Metadata":[{}]}}}}"#,
                page.len(),
                page.join(",")
            ))
        });
        let db = Mutex::new(Db::open_in_memory().unwrap());
        let client = PlexClient::new(&server.base_url, "tok", "install");
        sync(&db, &client, "plex1", &NOT_PAUSED, false).unwrap();
        assert_eq!(file_count(&db.lock(), "plex1"), 3);

        shrunk.store(true, Ordering::SeqCst);
        let stats = sync(&db, &client, "plex1", &NOT_PAUSED, true).unwrap();

        assert_eq!(stats.files_removed, 0);
        assert!(titles(&db.lock()).contains(&("movie".into(), "Film 3".into(), 2000)));
    }

    #[test]
    fn a_section_left_a_day_without_a_walk_is_walked_whole() {
        let shelf = shelf();
        let server = shelf_library(shelf.clone());
        let db = Mutex::new(Db::open_in_memory().unwrap());
        let client = PlexClient::new(&server.base_url, "tok", "install");
        sync(&db, &client, "plex1", &NOT_PAUSED, false).unwrap();
        // walked on the first day of the epoch, which is more than a day ago
        db.lock().set_dir_mtime("plex1", "1:walked", 1).unwrap();
        let before = server.requests().len();

        sync(&db, &client, "plex1", &NOT_PAUSED, false).unwrap();

        assert_eq!(
            listings(&server, before),
            [
                listing("1", "1", ""),
                listing("2", "4", "lastViewedAt:desc")
            ]
        );
    }

    #[test]
    fn a_watch_on_another_client_is_picked_up_with_no_stamp_moving() {
        let shelf = shelf();
        let server = shelf_library(shelf.clone());
        let db = Mutex::new(Db::open_in_memory().unwrap());
        let client = PlexClient::new(&server.base_url, "tok", "install");
        sync(&db, &client, "plex1", &NOT_PAUSED, false).unwrap();
        let before = server.requests().len();

        // the episode is started elsewhere: its lastViewedAt is all that moves
        {
            let mut shelf = shelf.lock();
            shelf.episodes[1].viewed = Some(7000);
            shelf.episodes[1].offset_ms = Some(1_200_000);
        }
        let stats = sync(&db, &client, "plex1", &NOT_PAUSED, false).unwrap();

        assert_eq!(stats.files_upserted, 1);
        let file_id: i64 = db
            .lock()
            .conn()
            .query_row("SELECT id FROM files WHERE rating_key = '12'", [], |r| {
                r.get(0)
            })
            .unwrap();
        let row = db.lock().watch_state(file_id).unwrap().unwrap();
        assert_eq!(row.position_secs, 1200.0);
        assert_eq!(row.updated_at, 7000);
        assert_eq!(
            listings(&server, before),
            [
                listing("1", "1", "lastViewedAt:desc"),
                listing("2", "4", "lastViewedAt:desc")
            ]
        );

        // and once read it is not read again
        let again = sync(&db, &client, "plex1", &NOT_PAUSED, false).unwrap();
        assert_eq!(again.files_upserted, 0);
    }

    #[test]
    fn a_sweep_over_an_unchanged_library_writes_and_reports_nothing() {
        let shelf = shelf();
        let server = shelf_library(shelf);
        let db = Mutex::new(Db::open_in_memory().unwrap());
        let client = PlexClient::new(&server.base_url, "tok", "install");
        sync(&db, &client, "plex1", &NOT_PAUSED, false).unwrap();
        let before = server.requests().len();

        let gens = |db: &Mutex<Db>| -> Vec<i64> {
            db.lock()
                .conn()
                .prepare("SELECT seen_gen FROM files ORDER BY id")
                .unwrap()
                .query_map([], |r| r.get(0))
                .unwrap()
                .map(|r| r.unwrap())
                .collect()
        };
        let seen = gens(&db);
        let stats = sync(&db, &client, "plex1", &NOT_PAUSED, false).unwrap();

        assert_eq!(stats.files_upserted, 0);
        assert_eq!(stats.files_removed, 0);
        assert_eq!(stats.files_seen, 4);
        // no row is rewritten just to mark it seen
        assert_eq!(gens(&db), seen);
        // the sections list and one small watch page per section
        assert_eq!(server.requests().len(), before + 3);
    }

    #[test]
    fn a_new_show_and_a_new_episode_of_an_old_one_arrive_without_a_walk() {
        let shelf = shelf();
        let server = shelf_library(shelf.clone());
        let db = Mutex::new(Db::open_in_memory().unwrap());
        let client = PlexClient::new(&server.base_url, "tok", "install");
        sync(&db, &client, "plex1", &NOT_PAUSED, false).unwrap();
        let before = server.requests().len();

        {
            let mut shelf = shelf.lock();
            shelf.shows.push(ShelfItem::of("Ahsoka", 20, 6000));
            shelf.episodes.push(ShelfItem::of("Ahsoka", 21, 6000));
            shelf.episodes.push(ShelfItem::of("Andor", 13, 6000));
            shelf.show_stamp = 6000;
        }
        let stats = sync(&db, &client, "plex1", &NOT_PAUSED, false).unwrap();

        assert_eq!(stats.files_upserted, 2);
        assert!(listings(&server, before)
            .iter()
            .all(|(_, _, sort)| !sort.is_empty()));
        let guard = db.lock();
        let ahsoka: i64 = guard
            .conn()
            .query_row("SELECT id FROM titles WHERE name = 'Ahsoka'", [], |r| {
                r.get(0)
            })
            .unwrap();
        // the brand new show carries its own summary, read off the show item
        let row = guard.metadata(ahsoka).unwrap().unwrap();
        assert_eq!(row.overview_fr.as_deref(), Some("About Ahsoka."));
        let andor: i64 = guard
            .conn()
            .query_row(
                "SELECT COUNT(*) FROM files f JOIN titles t ON t.id = f.title_id WHERE t.name = 'Andor'",
                [],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(andor, 3);
    }

    /// One page of a synthetic section: real enough to parse and index, as
    /// small as the schema allows otherwise. What the benchmark below is
    /// measured against, at the owner's real scale rather than a handful of
    /// fixture items.
    fn synthetic_page(kind: &str, key_prefix: &str, total: u32, start: u32, size: u32) -> String {
        let end = (start + size).min(total);
        let mut items = String::new();
        for i in start..end {
            if i > start {
                items.push(',');
            }
            let rk = format!("{key_prefix}{i}");
            match kind {
                "movie" => items.push_str(&format!(
                    r#"{{"ratingKey":"{rk}","title":"Movie {i}","year":2000,
                       "Media":[{{"Part":[{{"key":"/library/parts/{rk}/1/f.mkv","size":1}}]}}]}}"#
                )),
                "show" => items.push_str(&format!(r#"{{"ratingKey":"{rk}","title":"Show {i}"}}"#)),
                _ => items.push_str(&format!(
                    r#"{{"ratingKey":"{rk}","title":"Episode","grandparentTitle":"Show {}",
                       "parentIndex":1,"index":{i},
                       "Media":[{{"Part":[{{"key":"/library/parts/{rk}/1/f.mkv","size":1}}]}}]}}"#,
                    i % 334
                )),
            }
        }
        format!(
            r#"{{"MediaContainer":{{"size":{},"totalSize":{total},"Metadata":[{items}]}}}}"#,
            end - start
        )
    }

    /// A two-section server at a chosen scale, paged like a real one:
    /// `movies` movie items, `shows` show summaries and `episodes` episodes
    /// spread evenly across them. `latency` is what one round trip to a real
    /// server costs; the loopback's own is too small to see, and a scan's
    /// wall clock is round trips before it is anything else.
    fn realistic_library(
        movies: u32,
        shows: u32,
        episodes: u32,
        updated: i64,
        latency: std::time::Duration,
    ) -> FakeServer {
        FakeServer::start_with_workers(16, move |req| {
            std::thread::sleep(latency);
            if req.url == "/library/sections" {
                return Reply::json(&format!(
                    r#"{{"MediaContainer":{{"size":2,"Directory":[
                      {{"key":"1","type":"movie","title":"Movies","updatedAt":{updated}}},
                      {{"key":"2","type":"show","title":"TV Shows","updatedAt":{updated}}}
                    ]}}}}"#
                ));
            }
            let start: u32 = query(&req.url, "X-Plex-Container-Start")
                .and_then(|v| v.parse().ok())
                .unwrap_or(0);
            let size: u32 = query(&req.url, "X-Plex-Container-Size")
                .and_then(|v| v.parse().ok())
                .unwrap_or(PAGE_SIZE);
            if req.url.starts_with("/library/sections/1/all") {
                return Reply::json(&synthetic_page("movie", "m", movies, start, size));
            }
            if req.url.starts_with("/library/sections/2/all") {
                let body = if query(&req.url, "type").as_deref() == Some("2") {
                    synthetic_page("show", "s", shows, start, size)
                } else {
                    synthetic_page("episode", "e", episodes, start, size)
                };
                return Reply::json(&body);
            }
            Reply::status(404)
        })
    }

    /// Several pages are in flight at once and land out of order; every item
    /// still has to be indexed, exactly once. The cap is what a real server
    /// does to a container size it thinks is too big, and it is what the
    /// walk's stride has to come from rather than from what was asked for.
    #[test]
    fn a_paged_sync_indexes_every_item_whatever_size_the_server_answers_at() {
        for cap in [PAGE_SIZE, 50] {
            const MOVIES: u32 = 1000;
            // more workers than the walk has fetchers: a fake with exactly as
            // many turns the client's parallelism back into a queue and stops
            // testing what the walk actually does
            let server = FakeServer::start_with_workers(PAGE_FETCHERS * 2, move |req| {
                if req.url == "/library/sections" {
                    return Reply::json(
                        r#"{"MediaContainer":{"Directory":[
                           {"key":"1","type":"movie","title":"Movies"}]}}"#,
                    );
                }
                let start: u32 = query(&req.url, "X-Plex-Container-Start")
                    .and_then(|v| v.parse().ok())
                    .unwrap_or(0);
                let size: u32 = query(&req.url, "X-Plex-Container-Size")
                    .and_then(|v| v.parse().ok())
                    .unwrap_or(PAGE_SIZE);
                Reply::json(&synthetic_page("movie", "m", MOVIES, start, size.min(cap)))
            });
            let db = parking_lot::Mutex::new(Db::open_in_memory().unwrap());
            let client = PlexClient::new(&server.base_url, "tok", "install");
            let stats = sync(&db, &client, "plex1", &NOT_PAUSED, false).unwrap();

            assert_eq!(stats.files_upserted, MOVIES, "cap {cap}");
            let names = db
                .lock()
                .conn()
                .prepare("SELECT count(*) FROM titles WHERE kind = 'movie'")
                .unwrap()
                .query_row([], |r| r.get::<_, i64>(0))
                .unwrap();
            assert_eq!(names, MOVIES as i64, "cap {cap}");
        }
    }

    const PAGED_MOVIES: u32 = 1000;

    /// The offset of the page the fake below refuses: page two of five, so
    /// there is a page before it already indexed and pages after it for the
    /// serial pass to have to redo.
    const REFUSED_START: u32 = 400;

    /// A one-section server that refuses the page at `REFUSED_START` its first
    /// `refusals` requests and answers everything else. `seen` counts what it
    /// was asked for that one page, which is how a test tells a retry apart
    /// from a walk that got lucky. Nothing here depends on timing: the same
    /// requests are refused whatever order the fetchers arrive in.
    fn library_refusing_one_page(refusals: u32, seen: Arc<AtomicU32>) -> FakeServer {
        FakeServer::start_with_workers(PAGE_FETCHERS * 2, move |req| {
            if req.url == "/library/sections" {
                return Reply::json(
                    r#"{"MediaContainer":{"Directory":[
                       {"key":"1","type":"movie","title":"Movies"}]}}"#,
                );
            }
            let start: u32 = query(&req.url, "X-Plex-Container-Start")
                .and_then(|v| v.parse().ok())
                .unwrap_or(0);
            // a 503 is what a server out of sockets says when it has one left
            // to say it with; a refused connection is the same walk, reported
            // by the transport instead
            if start == REFUSED_START && seen.fetch_add(1, Ordering::SeqCst) < refusals {
                return Reply::status(503);
            }
            let size: u32 = query(&req.url, "X-Plex-Container-Size")
                .and_then(|v| v.parse().ok())
                .unwrap_or(PAGE_SIZE);
            Reply::json(&synthetic_page("movie", "m", PAGED_MOVIES, start, size))
        })
    }

    /// One page refused and then served. Eight sockets against a NAS is one
    /// the server sometimes will not hold, and the walk asks again rather
    /// than losing a scan of the whole library over it.
    #[test]
    fn a_page_the_server_refuses_once_is_asked_for_again() {
        let seen = Arc::new(AtomicU32::new(0));
        let server = library_refusing_one_page(1, seen.clone());
        let db = parking_lot::Mutex::new(Db::open_in_memory().unwrap());
        let client = PlexClient::new(&server.base_url, "tok", "install");

        let stats = sync(&db, &client, "plex1", &NOT_PAUSED, false).unwrap();

        assert_eq!(stats.files_upserted, PAGED_MOVIES);
        assert_eq!(titles(&db.lock()).len(), PAGED_MOVIES as usize);
        // the refusal and the retry that answered it, and no third request
        assert_eq!(seen.load(Ordering::SeqCst), 2);
        // the sections list, five pages and the one retry. The retry is what
        // makes it seven: a walk that only fell back to the serial pass would
        // have refetched the pages after the hole as well.
        assert_eq!(server.requests().len(), 7);
    }

    /// A page still refused after every attempt costs the pages from it
    /// onward one more fetch each, serially on one connection, and costs the
    /// scan nothing: the walk knows the exact offset it failed to get, so it
    /// has somewhere to resume from.
    #[test]
    fn a_page_refused_past_every_attempt_costs_a_refetch_not_the_scan() {
        let seen = Arc::new(AtomicU32::new(0));
        let server = library_refusing_one_page(PAGE_ATTEMPTS, seen.clone());
        let db = parking_lot::Mutex::new(Db::open_in_memory().unwrap());
        let client = PlexClient::new(&server.base_url, "tok", "install");

        let stats = sync(&db, &client, "plex1", &NOT_PAUSED, false).unwrap();

        assert_eq!(stats.files_upserted, PAGED_MOVIES);
        assert_eq!(titles(&db.lock()).len(), PAGED_MOVIES as usize);
        // every attempt the parallel walk had, then the serial pass's own,
        // which is the request that finally got the page
        assert_eq!(seen.load(Ordering::SeqCst), PAGE_ATTEMPTS + 1);
    }

    /// A rejected token is not a busy server: the same request gets the same
    /// answer, and asking eight more times is its own bug.
    #[test]
    fn a_rejected_token_ends_the_walk_without_asking_again() {
        let server = FakeServer::start(|req| {
            if req.url == "/library/sections" {
                return Reply::json(
                    r#"{"MediaContainer":{"Directory":[
                       {"key":"1","type":"movie","title":"Movies"}]}}"#,
                );
            }
            Reply::status(401)
        });
        let db = parking_lot::Mutex::new(Db::open_in_memory().unwrap());
        let client = PlexClient::new(&server.base_url, "tok", "install");

        let err = sync(&db, &client, "plex1", &NOT_PAUSED, false).unwrap_err();

        assert!(matches!(err, SyncError::Plex(PlexError::Unauthorized)));
        // the sections list, and the one page that was refused
        assert_eq!(server.requests().len(), 2);
    }

    /// The real cost of a full scan and of a no-change rescan, at the
    /// owner's own scale: 3464 movies, 334 shows, 13084 files total. Run
    /// with `--ignored --nocapture` to read the request counts and wall
    /// clock; the assertions below cover correctness, the eprintln the
    /// numbers a report wants, neither pass/fail on the timing.
    ///
    /// Run twice: once against a server that answers instantly, which is
    /// the parsing and the writing alone, and once at a round trip a real
    /// server charges, which is what the viewer waits through.
    #[test]
    #[ignore]
    fn bench_full_scan_and_no_change_rescan_at_realistic_scale() {
        for latency_ms in [0, 30] {
            bench_one_scale(std::time::Duration::from_millis(latency_ms));
        }
    }

    fn bench_one_scale(latency: std::time::Duration) {
        const MOVIES: u32 = 3464;
        const SHOWS: u32 = 334;
        const EPISODES: u32 = 13084 - MOVIES;
        let server = realistic_library(MOVIES, SHOWS, EPISODES, 5000, latency);
        let db = parking_lot::Mutex::new(Db::open_in_memory().unwrap());
        let client = PlexClient::new(&server.base_url, "tok", "install");

        let t0 = std::time::Instant::now();
        let first = sync(&db, &client, "plex1", &NOT_PAUSED, false).unwrap();
        let first_elapsed = t0.elapsed();
        let first_requests = server.requests().len();
        assert_eq!(first.files_upserted, MOVIES + EPISODES);

        let t1 = std::time::Instant::now();
        let second = sync(&db, &client, "plex1", &NOT_PAUSED, false).unwrap();
        let second_elapsed = t1.elapsed();
        let second_requests = server.requests().len() - first_requests;
        assert_eq!(second.files_upserted, 0);
        assert_eq!(second.files_seen, MOVIES + EPISODES);

        eprintln!(
            "at {latency:?} a round trip:\n  \
             first scan: {first_requests} requests, {first_elapsed:?} wall clock\n  \
             no-change rescan: {second_requests} requests, {second_elapsed:?} wall clock"
        );
    }

    #[test]
    fn a_plex_edition_names_the_cut_of_its_copy() {
        let item: super::Metadata = serde_json::from_str(
            r#"{"ratingKey":"301","title":"Harry Potter","editionTitle":"Extended Edition",
                "Media":[{"videoResolution":"1080","Part":[{"id":1,"key":"/library/parts/1/1/hp.mkv","size":1}]}]}"#,
        )
        .unwrap();
        let media = &item.media[0];
        assert_eq!(
            super::file_media(&item, media, &media.part[0]).edition,
            "Extended Edition"
        );
    }
}
