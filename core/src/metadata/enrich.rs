use super::client::{TmdbClient, TmdbError, LANG_EN, LANG_FR};
use super::models::{Credits, Details, SearchResult};
use crate::index::db::{
    crew_column, Db, IndexError, MetadataRecord, MetadataSource, PendingFaces, PendingTitle, Score,
    MAX_CAST, MAX_COMPOSERS, MAX_DIRECTORS, MAX_WRITERS,
};
use crate::index::MediaKind;
use crate::slice::Slice;
use parking_lot::Mutex;
use unicode_normalization::char::is_combining_mark;
use unicode_normalization::UnicodeNormalization;

/// A title TMDB did not know is not asked about again for a month; a matched
/// one is refreshed on the same clock, since artwork paths and overviews move.
pub const MAX_AGE_SECS: i64 = 30 * 24 * 60 * 60;

/// How far a year may disagree before a candidate is somebody else. A festival
/// premiere, a re-release and the year a Plex agent settled on are routinely
/// one apart; two apart is another film with the same name.
const YEAR_SLACK: i64 = 1;

#[derive(Debug, Default, Clone, PartialEq, Eq)]
pub struct EnrichStats {
    pub attempted: u32,
    pub matched: u32,
    pub failed: u32,
    /// Seconds TMDB asked to be left alone for, 0 when it did not. The batch
    /// stopped where it stood; the queue kept its place.
    pub retry_after_secs: u32,
}

#[derive(Debug, thiserror::Error)]
pub enum EnrichError {
    #[error("index error: {0}")]
    Index(#[from] IndexError),
    #[error("the TMDB key was rejected")]
    Unauthorized,
}

/// Describes at most `limit` titles: first the ones nothing has described at
/// all, then the ones Plex described and TMDB has never been asked about.
/// Every title it reaches ends with a row, or with the attempt recorded on the
/// row it already had, so calling it again walks forward instead of retrying
/// the same head of the queue. Rows are written one by one: a batch
/// interrupted halfway keeps what it already fetched.
///
/// It takes the write connection, never across a request: a batch is several
/// seconds of somebody else's network, and a playback report or a scan must
/// not queue behind all of it.
pub fn enrich_pending(
    db: &Mutex<Db>,
    client: &TmdbClient,
    limit: u32,
    now: i64,
    slice: &Slice,
) -> Result<EnrichStats, EnrichError> {
    let mut stats = EnrichStats::default();
    describe_missing(db, client, limit, now, slice, &mut stats)?;
    // a rate limit stops the pass where it stands, and so does a slice that
    // ran out: asking the next queue would spend the batch collecting the
    // same 429, or hold the thread past the deadline the first queue reached
    if stats.retry_after_secs == 0 && stats.attempted < limit && !slice.expired() {
        match_described(db, client, limit - stats.attempted, now, slice, &mut stats)?;
    }
    // last, because the two above fill faces for free on every title they
    // reach: what is left here is what they will never reach again
    if stats.retry_after_secs == 0 && stats.attempted < limit && !slice.expired() {
        backfill_faces(db, client, limit - stats.attempted, now, slice, &mut stats)?;
    }
    Ok(stats)
}

/// The titles with no metadata row at all: files nothing else describes, and
/// the TMDB rows that have gone stale. A title TMDB does not know still gets a
/// row, with a null tmdb_id: unmatched files stay visible (spec: Metadata) and
/// stop costing a search on every run.
/// How many TMDB voters a score needs before it is worth storing. Below this
/// a title reads 10 out of 10 off four people, which says less than no number
/// at all: the screen draws a quantity a viewer takes for a measurement.
const MIN_VOTES: u32 = 50;

/// The token the app maps to the word "TMDB", the way Plex's own scores carry
/// "imdb" or "rottentomatoes". A token the screen cannot name draws nothing.
const TMDB_PROVIDER: &str = "themoviedb";

fn describe_missing(
    db: &Mutex<Db>,
    client: &TmdbClient,
    limit: u32,
    now: i64,
    slice: &Slice,
    stats: &mut EnrichStats,
) -> Result<(), EnrichError> {
    let pending = db
        .lock()
        .titles_needing_metadata(now, MAX_AGE_SECS, limit)?;
    for title in &pending {
        // rows are written one by one, so stopping here keeps every title
        // already described and leaves the rest of the queue where it was
        if slice.expired() {
            return Ok(());
        }
        // a stale row is refreshed by the id it already holds: searching again
        // by name can lose a match TMDB has since made ambiguous
        let known = db.lock().metadata(title.id)?.and_then(|m| m.tmdb_id);
        let mut record = MetadataRecord {
            title_id: title.id,
            tmdb_id: known,
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
            fetched_at: now,
            critics: None,
            audience: None,
            release_date: None,
        };
        let mut faces = Vec::new();
        match step(describe(client, title, &mut record, &mut faces), stats)? {
            Step::Answered => {}
            Step::Skipped => continue,
            Step::Stopped => return Ok(()),
        }
        let db = db.lock();
        db.upsert_metadata(&record)?;
        // an id here is the payload the faces came off, so the two travel
        // together: a title TMDB could not place has no billing to record
        if record.tmdb_id.is_some() {
            stats.matched += 1;
            write_faces(&db, record.title_id, &faces, now)?;
        }
    }
    Ok(())
}

/// The faces of one title's credits, written after its metadata so the tag
/// rows `upsert_metadata` wrote already exist for them to be found by.
///
/// Called only where TMDB actually answered with a billing: the stamp says
/// this title's credits have been read, and a title nobody could place has
/// nothing to say about the names on it.
fn write_faces(db: &Db, title_id: i64, faces: &[CastFace], now: i64) -> Result<(), IndexError> {
    for face in faces {
        db.set_person(&face.name, face.tmdb_person_id, &face.profile_path, now)?;
    }
    // the billing's parts, which land only where the row holds this same
    // billing: a row that kept a longer list of its own keeps its own parts
    let billed = faces
        .iter()
        .filter_map(|f| Some((f.name.as_str(), f.character.as_deref()?)));
    let names = billed
        .clone()
        .map(|(name, _)| name)
        .collect::<Vec<_>>()
        .join(",");
    let characters = billed.map(|(_, part)| part).collect::<Vec<_>>().join(",");
    db.set_cast_characters(title_id, &names, &characters)?;
    db.mark_faces_checked(title_id, now)?;
    Ok(())
}

/// The titles Plex described, which carry no tmdb_id and so join nothing: no
/// similar list, no saga, no seed for the home row. What TMDB has to say is
/// added to them, never over them - the overview came off the owner's own
/// server in their own language, and the genres and the billing are Plex's
/// (spec: Metadata). Only a field Plex left empty is filled.
///
/// The attempt is recorded either way, so a title TMDB cannot place is not
/// searched for again until it goes stale.
fn match_described(
    db: &Mutex<Db>,
    client: &TmdbClient,
    limit: u32,
    now: i64,
    slice: &Slice,
    stats: &mut EnrichStats,
) -> Result<(), EnrichError> {
    let pending = db.lock().titles_needing_match(now, MAX_AGE_SECS, limit)?;
    for title in &pending {
        if slice.expired() {
            return Ok(());
        }
        // a scan can prune a title between the queue and here
        let Some(row) = db.lock().metadata(title.id)? else {
            continue;
        };
        let mut merged = row.clone();
        let mut faces = Vec::new();
        match step(describe(client, title, &mut merged, &mut faces), stats)? {
            Step::Answered => {}
            // the row Plex wrote stands untouched, matched_at included: the
            // next run asks TMDB about it again
            Step::Skipped => continue,
            Step::Stopped => return Ok(()),
        }
        // the queue only holds rows with none, so an id here is a new one, and
        // it is the payload the faces came off
        let placed = merged.tmdb_id.is_some();
        if placed {
            stats.matched += 1;
        }
        // the embedding queue keys on fetched_at (see `titles_needing_embedding`):
        // a row whose description moved is owed a new vector, and an id is not
        // part of any description
        if merged.overview_fr != row.overview_fr
            || merged.overview_en != row.overview_en
            || merged.genres != row.genres
            || merged.cast_names != row.cast_names
            || merged.collections != row.collections
        {
            merged.fetched_at = now;
        }
        let db = db.lock();
        db.attach_tmdb_match(&merged, now)?;
        if placed {
            write_faces(&db, merged.title_id, &faces, now)?;
        }
    }
    Ok(())
}

/// The titles TMDB placed before their billing was worth reading.
///
/// Every field added to the describe path meets the same wall: the call that
/// would carry it has already been made, the row it would land on is fresh,
/// and no queue names a placed title twice - so a library that is already
/// described never learns the new field at all. `profile_path` is the one that
/// hit it; this is the one queue that walks back over it, and it asks for the
/// credits alone, so a row Plex wrote keeps every word of its own.
///
/// One request per title and no search: the id is already on the row. Every
/// name the title is tagged with is stamped afterwards, answered or not, so
/// the queue drains and does not refill.
fn backfill_faces(
    db: &Mutex<Db>,
    client: &TmdbClient,
    limit: u32,
    now: i64,
    slice: &Slice,
    stats: &mut EnrichStats,
) -> Result<(), EnrichError> {
    let pending = db.lock().titles_needing_faces(limit)?;
    for title in &pending {
        if slice.expired() {
            return Ok(());
        }
        let mut billing = Credits::default();
        match step(credits(client, title, &mut billing), stats)? {
            Step::Answered => {}
            Step::Skipped => continue,
            Step::Stopped => return Ok(()),
        }
        let mut faces = Vec::new();
        read_faces(&billing, &mut faces);
        let db = db.lock();
        // a row described before the billing ran this long, or written off a
        // Plex listing: fetched_at moves because the embedding reads the cast
        if let Some(mut row) = db.metadata(title.title_id)? {
            if lengthen_cast(&mut row, &billing) {
                row.fetched_at = now;
                db.upsert_metadata(&row)?;
            }
        }
        write_faces(&db, title.title_id, &faces, now)?;
    }
    Ok(())
}

/// How many keywords a title carries into its embedding. TMDB lists a few
/// dozen on a popular film, most of them trivia; the first dozen are the
/// subject and the tone, and the token budget is the synopsis's.
const MAX_KEYWORDS: usize = 12;

/// The keywords of every placed title, asked once each. They are what the
/// synopsis describes without naming ("time travel", "dystopia", "feel good"),
/// which is the half of a film's character the encoder reads worst off
/// prose. A 404 is an id TMDB no longer holds, and is stamped as no keywords.
///
/// Apart from `enrich_pending` rather than its last queue: it is one request
/// per title across the whole library, and the describing queues are what a
/// new title needs first.
pub fn backfill_keywords(
    db: &Mutex<Db>,
    client: &TmdbClient,
    limit: u32,
    now: i64,
    slice: &Slice,
    stats: &mut EnrichStats,
) -> Result<(), EnrichError> {
    let pending = db.lock().titles_needing_keywords(limit)?;
    for title in &pending {
        if slice.expired() {
            return Ok(());
        }
        let mut keywords = Vec::new();
        let asked = match client.keywords(title.kind, title.tmdb_id) {
            Ok(found) => {
                keywords = found;
                Ok(())
            }
            Err(TmdbError::Status(404)) => Ok(()),
            Err(e) => Err(e),
        };
        match step(asked, stats)? {
            Step::Answered => {}
            Step::Skipped => continue,
            Step::Stopped => return Ok(()),
        }
        // a comma is the separator the embedding text is joined on
        let joined = keywords
            .iter()
            .take(MAX_KEYWORDS)
            .map(|k| k.replace(',', " "))
            .collect::<Vec<_>>()
            .join(", ");
        db.lock().set_keywords(title.title_id, &joined, now)?;
    }
    Ok(())
}

/// One placed title's billing. A 404 is an id TMDB no longer holds, which is
/// permanent: it answers with no faces rather than an error, so the names on
/// the title are stamped and the dead id is never asked again.
fn credits(
    client: &TmdbClient,
    title: &PendingFaces,
    billing: &mut Credits,
) -> Result<(), TmdbError> {
    let answer = match title.kind {
        MediaKind::Movie => client.movie_credits(title.tmdb_id),
        MediaKind::Show => client.show_credits(title.tmdb_id),
    };
    *billing = match answer {
        Ok(billing) => billing,
        Err(TmdbError::Status(404)) => Credits::default(),
        Err(e) => return Err(e),
    };
    Ok(())
}

/// What one title's requests did to the batch.
enum Step {
    /// TMDB answered, and what it said is worth writing.
    Answered,
    /// A request failed: this title alone pays for it, keeps no row, and the
    /// next run picks it up again.
    Skipped,
    /// TMDB is rate limiting. The batch stops here with its queue intact,
    /// rather than spending itself collecting the same 429.
    Stopped,
}

/// Reads one title's outcome into the batch's tally. A rejected key fails
/// every remaining title the same way, so it ends the batch as an error and
/// lets the UI ask for a new one.
fn step(outcome: Result<(), TmdbError>, stats: &mut EnrichStats) -> Result<Step, EnrichError> {
    match outcome {
        Ok(()) => {
            stats.attempted += 1;
            Ok(Step::Answered)
        }
        Err(TmdbError::Unauthorized) => Err(EnrichError::Unauthorized),
        Err(TmdbError::RateLimited { retry_after_secs }) => {
            stats.retry_after_secs = retry_after_secs;
            Ok(Step::Stopped)
        }
        Err(_) => {
            stats.attempted += 1;
            stats.failed += 1;
            Ok(Step::Skipped)
        }
    }
}

/// Writes what TMDB says about `title` into `record`, over nothing it already
/// carries. A blank record is a full description; a row Plex wrote keeps every
/// word of it and gains the id, the saga, and whatever Plex had nothing to say
/// about.
///
/// The three credits worth storing, by the exact `job` TMDB spells them with.
///
/// A crew list runs to dozens of names and almost every one of them is somebody
/// no viewer has ever chosen a film by: a gaffer, a grip, a VFX supervisor. The
/// three kept here are the ones a viewer picks by name - who directed it, who
/// wrote it, who scored it - and everything else is dropped, because each name
/// stored costs a search row, an index row and a share of the vector the title
/// is found by.
///
/// The one real omission is the cinematographer, who does shape how a film
/// looks: dropped because almost nobody browses by one, so the dilution would
/// buy an aesthetic signal already carried by the director it belongs to.
///
/// "Novel", "Characters" and "Adaptation" are deliberately not writers here:
/// they credit the source material rather than the film's own voice.
const DIRECTOR_JOBS: &[&str] = &["Director"];
const WRITER_JOBS: &[&str] = &["Screenplay", "Writer", "Story"];
const COMPOSER_JOBS: &[&str] = &["Original Music Composer"];

/// The names on this payload holding one of `jobs`, in TMDB's own order.
fn jobs<'a>(d: &'a Details, jobs: &'a [&str]) -> impl Iterator<Item = &'a str> {
    d.credits
        .crew
        .iter()
        .filter(move |c| jobs.contains(&c.job.as_str()))
        .map(|c| c.name.as_str())
}

/// A credited name TMDB named, with the photograph of them it holds. The
/// credits are already in the details payload the enrichment asks for, so
/// collecting these costs no request: `profile_path` is empty for a performer
/// TMDB has no photograph of, which is a final answer.
pub struct CastFace {
    pub name: String,
    pub tmdb_person_id: i64,
    pub profile_path: String,
    /// The part played, None for a director.
    pub character: Option<String>,
}

/// The names one billing is worth a row for, in TMDB's own order and cut to
/// the same lengths the columns are: the two kinds a face is ever drawn for.
///
/// Keyed to the names TMDB itself lists, scrubbed the way the columns scrub
/// them, rather than to whatever the row ends up storing: when Plex named the
/// cast in its own spelling the two can differ, and a face filed under a name
/// nothing carries is a row nobody reads - which is the right failure, where
/// drawing it anyway would be the wrong face.
fn read_faces(billing: &Credits, faces: &mut Vec<CastFace>) {
    faces.extend(billing.cast.iter().take(MAX_CAST).map(|c| CastFace {
        name: c.name.replace(',', " "),
        tmdb_person_id: c.id,
        profile_path: c.profile_path.clone(),
        character: Some(c.character.replace(',', " ")),
    }));
    faces.extend(
        billing
            .crew
            .iter()
            .filter(|c| DIRECTOR_JOBS.contains(&c.job.as_str()))
            .take(MAX_DIRECTORS)
            .map(|c| CastFace {
                name: c.name.replace(',', " ").trim().to_string(),
                tmdb_person_id: c.id,
                profile_path: c.profile_path.clone(),
                character: None,
            }),
    );
}

/// Takes TMDB's billing onto `record` when it names more people, and says
/// whether it did.
///
/// The one column TMDB may overrule rather than merely fill. Every other field
/// defers to what the server already knew, and rightly: a Plex agent that named
/// the genres named them well. Billing is different - a Plex listing carries
/// three or four names where TMDB carries the whole top billing, in billing
/// order, and a "Cast" lane of four faces reads as a film nobody was in. So the
/// longer list wins, and a server that knew more than TMDB keeps its own.
fn lengthen_cast(record: &mut MetadataRecord, billing: &Credits) -> bool {
    let stored = record
        .cast_names
        .split(',')
        .filter(|n| !n.is_empty())
        .count();
    if billing.cast.len().min(MAX_CAST) <= stored {
        return false;
    }
    record.cast_names = billing
        .cast
        .iter()
        .take(MAX_CAST)
        .map(|c| c.name.replace(',', " "))
        .collect::<Vec<_>>()
        .join(",");
    true
}

/// `record.tmdb_id` is left alone when nothing certain came back: an unmatched
/// title is not an error, and the caller records the attempt either way.
///
/// `faces` is filled from the credits whatever the record ends up storing:
/// the caller writes them beside the metadata, in the same lock.
fn describe(
    client: &TmdbClient,
    title: &PendingTitle,
    record: &mut MetadataRecord,
    faces: &mut Vec<CastFace>,
) -> Result<(), TmdbError> {
    // a known id that TMDB no longer holds (404) falls back to a search
    let known = match record.tmdb_id.take() {
        Some(id) => details(client, title.kind, id, LANG_FR)?.map(|fr| (id, fr)),
        None => None,
    };
    let (id, fr) = match known {
        Some(found) => found,
        None => {
            let Some(id) = search_match(client, title)? else {
                return Ok(());
            };
            let Some(fr) = details(client, title.kind, id, LANG_FR)? else {
                return Ok(());
            };
            (id, fr)
        }
    };
    // fr-FR with en-US fallback (spec: Metadata): TMDB answers an untranslated
    // title with an empty overview, not with a 404. An en-US 404 here costs the
    // overview, not the match: the fr payload is already worth a row.
    let en = if record.overview_fr.is_none()
        && record.overview_en.is_none()
        && fr.overview.trim().is_empty()
    {
        details(client, title.kind, id, LANG_EN)?.unwrap_or_default()
    } else {
        Details::default()
    };

    record.tmdb_id = Some(id);
    if record.collections.is_empty() {
        // the saga, which is the one thing on this payload no Plex row for
        // this library carries; a comma is the separator, so a name carrying
        // one would read as two
        record.collections = fr
            .belongs_to_collection
            .as_ref()
            .map_or(String::new(), |c| c.name.replace(',', " "));
    }
    if record.genres.is_empty() {
        record.genres = if fr.genres.is_empty() { &en } else { &fr }
            .genres
            .iter()
            .map(|g| g.name.as_str())
            .collect::<Vec<_>>()
            .join(",");
    }
    if record.release_date.is_none() {
        let date = match title.kind {
            MediaKind::Movie => &fr.release_date,
            MediaKind::Show => &fr.first_air_date,
        };
        record.release_date = Some(date.clone()).filter(|d| !d.is_empty());
    }
    lengthen_cast(record, &fr.credits);
    read_faces(&fr.credits, faces);
    // each crew column is filled on its own, so a Plex row that named the
    // director and the writers still gains the composer no Plex agent carries
    if record.director_names.is_empty() {
        record.director_names = crew_column(jobs(&fr, DIRECTOR_JOBS), MAX_DIRECTORS, "");
    }
    if record.writer_names.is_empty() {
        record.writer_names =
            crew_column(jobs(&fr, WRITER_JOBS), MAX_WRITERS, &record.director_names);
    }
    if record.composer_names.is_empty() {
        record.composer_names = crew_column(
            jobs(&fr, COMPOSER_JOBS),
            MAX_COMPOSERS,
            &record.director_names,
        );
    }
    if record.overview_fr.is_none() {
        record.overview_fr = Some(fr.overview.trim().to_string()).filter(|o| !o.is_empty());
    }
    if record.overview_en.is_none() {
        record.overview_en = Some(en.overview.trim().to_string()).filter(|o| !o.is_empty());
    }
    // an artwork path is fetched against the row's own source (see
    // `api::library`), so a TMDB path on a Plex row would be asked of the Plex
    // server: Plex art stays Plex's, and a Plex row with none keeps none
    if record.source == MetadataSource::Tmdb {
        record.poster_path = fr.poster_path.or(en.poster_path);
        record.backdrop_path = fr.backdrop_path.or(en.backdrop_path);
    }
    // The audience column and never the critics' one: these are TMDB's own
    // users, the population Plex files under `audienceRating`, and the two
    // columns exist precisely so that one number never stands for the other.
    // A server that stated a score keeps it, like every other column here: the
    // fallback is for the libraries whose agent carries none at all.
    if record.audience.is_none()
        && fr.vote_count >= MIN_VOTES
        && fr.vote_average > 0.0
        && fr.vote_average <= 10.0
    {
        record.audience = Some(Score {
            value: fr.vote_average,
            source: TMDB_PROVIDER.to_string(),
            votes: Some(fr.vote_count),
        });
    }
    Ok(())
}

/// The queries a title is looked for under, in order, stopping at the first
/// TMDB answers with a match `pick` is sure of. A Plex name is often
/// "Main : Sub", which TMDB's search answers with nothing at all while
/// answering the head with everything; the full title still has to come back
/// on the result, so a looser query is not a looser match.
fn search_match(client: &TmdbClient, title: &PendingTitle) -> Result<Option<i64>, TmdbError> {
    let mut queries = vec![(title.name.as_str(), title.year)];
    // Only a movie search sends the year, so only a movie search is worth
    // repeating without it: TMDB files some films under the year of a release
    // this library never saw, and `pick` still holds the answer to one year of
    // the year Plex has. The same retry on a show would be the same request
    // twice.
    if title.year.is_some() && title.kind == MediaKind::Movie {
        queries.push((title.name.as_str(), None));
    }
    if let Some((head, _)) = title.name.split_once(':') {
        let head = head.trim();
        if !head.is_empty() {
            queries.push((head, title.year));
        }
    }
    for (query, year) in queries {
        let results = match title.kind {
            MediaKind::Movie => client.search_movies(query, year)?,
            MediaKind::Show => client.search_shows(query)?,
        };
        if let Some(hit) = pick(&title.name, title.year, title.kind, &results) {
            return Ok(Some(hit.id));
        }
    }
    Ok(None)
}

/// Which result, if any, is this title. A name and a year are all there is to
/// go on, so the rule is exact: the same title once accents, case and
/// punctuation are gone - French or original, since a library holds both - and
/// a year within `YEAR_SLACK`. Anything less certain is left unmatched. A
/// wrong id attaches a stranger's saga and a stranger's similar list, and both
/// go straight onto the screen (spec: Recommendations), which is worse for the
/// viewer than a title TMDB never placed.
fn pick<'a>(
    name: &str,
    year: Option<u16>,
    kind: MediaKind,
    results: &'a [SearchResult],
) -> Option<&'a SearchResult> {
    let wanted = normalize(name);
    let mut exact = results.iter().filter(|r| {
        titles(r, kind).iter().any(|t| normalize(t) == wanted)
            && match (year, released(r, kind)) {
                (Some(y), Some(found)) => (i64::from(y) - i64::from(found)).abs() <= YEAR_SLACK,
                // the year is the only thing that could tell two films of the
                // same name apart, and TMDB holds none for this one
                (Some(_), None) => false,
                (None, _) => true,
            }
    });
    let first = exact.next()?;
    // with no year in hand nothing separates two titles spelled alike, which
    // is most of what a library of shows is: TMDB's own order is a popularity
    // ranking, not evidence about which one sits on this disk
    if year.is_none() && exact.any(|r| r.id != first.id) {
        return None;
    }
    Some(first)
}

/// The two spellings a search result carries: TMDB names a movie's `title` and
/// `original_title`, a show's `name` and `original_name`.
fn titles(result: &SearchResult, kind: MediaKind) -> [&str; 2] {
    match kind {
        MediaKind::Movie => [&result.title, &result.original_title],
        MediaKind::Show => [&result.name, &result.original_name],
    }
}

/// The year off a "YYYY-MM-DD", or None when TMDB holds no date at all.
fn released(result: &SearchResult, kind: MediaKind) -> Option<u16> {
    let date = match kind {
        MediaKind::Movie => &result.release_date,
        MediaKind::Show => &result.first_air_date,
    };
    date.get(..4)?.parse().ok()
}

/// The form two spellings of one title are compared in: accents folded, case
/// gone, and every run of anything else read as a single space. TMDB writes
/// "Le Monde de Narnia\u{a0}: Le Prince caspian" where Plex writes a plain
/// space and a colon; neither survives this, and what is left is the same
/// line.
pub(crate) fn normalize(title: &str) -> String {
    let mut out = String::with_capacity(title.len());
    let mut gap = false;
    for c in title.nfd().filter(|c| !is_combining_mark(*c)) {
        if c.is_alphanumeric() {
            if gap && !out.is_empty() {
                out.push(' ');
            }
            gap = false;
            out.extend(c.to_lowercase());
        } else {
            gap = true;
        }
    }
    out
}

/// `None` when TMDB has no such id: a 404 here is permanent, so the caller
/// records a no-match instead of retrying the same dead id on every run.
fn details(
    client: &TmdbClient,
    kind: MediaKind,
    id: i64,
    language: &str,
) -> Result<Option<Details>, TmdbError> {
    let details = match kind {
        MediaKind::Movie => client.movie_details(id, language),
        MediaKind::Show => client.show_details(id, language),
    };
    match details {
        Ok(details) => Ok(Some(details)),
        Err(TmdbError::Status(404)) => Ok(None),
        Err(e) => Err(e),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::metadata::fake::tmdb;
    use crate::plex::fake::{FakeServer, Reply};
    use rusqlite::params;
    use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
    use std::sync::Arc;
    use std::time::Duration;

    const NOW: i64 = 1_800_000_000;

    fn seeded() -> Mutex<Db> {
        let db = Db::open_in_memory().unwrap();
        db.upsert_title(MediaKind::Movie, "Dune", Some(2021))
            .unwrap();
        db.upsert_title(MediaKind::Movie, "Solaris", Some(1972))
            .unwrap();
        db.upsert_title(MediaKind::Show, "The Expanse", None)
            .unwrap();
        db.upsert_title(MediaKind::Movie, "Anniversaire Mamie", Some(2019))
            .unwrap();
        Mutex::new(db)
    }

    /// A row of the shape a Plex sync leaves: the server's own words, its own
    /// artwork, and no tmdb_id at all.
    fn plex_row(db: &Mutex<Db>, name: &str, overview: &str, genres: &str, cast: &str) -> i64 {
        let title_id: i64 = db
            .lock()
            .conn()
            .query_row("SELECT id FROM titles WHERE name = ?1", [name], |r| {
                r.get(0)
            })
            .unwrap();
        db.lock()
            .upsert_metadata(&MetadataRecord {
                title_id,
                tmdb_id: None,
                overview_fr: Some(overview.to_string()).filter(|o| !o.is_empty()),
                overview_en: None,
                poster_path: Some(format!("/library/metadata/{title_id}/thumb/1")),
                backdrop_path: Some(format!("/library/metadata/{title_id}/art/1")),
                genres: genres.to_string(),
                cast_names: cast.to_string(),
                collections: String::new(),
                director_names: String::new(),
                writer_names: String::new(),
                composer_names: String::new(),
                source: MetadataSource::Plex,
                fetched_at: NOW - 1,
                critics: None,
                audience: None,
                release_date: None,
            })
            .unwrap();
        title_id
    }

    fn tags(db: &Mutex<Db>, title_id: i64, kind: &str) -> Vec<String> {
        db.lock()
            .conn()
            .prepare(
                "SELECT value FROM title_tags WHERE title_id = ?1 AND kind = ?2 ORDER BY value",
            )
            .unwrap()
            .query_map(params![title_id, kind], |r| r.get(0))
            .unwrap()
            .collect::<Result<_, _>>()
            .unwrap()
    }

    fn row(db: &Mutex<Db>, name: &str) -> MetadataRecord {
        let id: i64 = db
            .lock()
            .conn()
            .query_row("SELECT id FROM titles WHERE name = ?1", [name], |r| {
                r.get(0)
            })
            .unwrap();
        db.lock().metadata(id).unwrap().unwrap()
    }

    /// The day a title came out, off the details it was described with: a
    /// film's release date and a series' first air date. A title TMDB names
    /// no date for keeps none rather than an empty string.
    #[test]
    fn a_title_tmdb_describes_keeps_the_day_it_came_out() {
        let server = tmdb();
        let db = seeded();
        let client = TmdbClient::new(&server.base_url, "k");

        enrich_pending(&db, &client, 10, NOW, &Slice::open()).unwrap();

        assert_eq!(row(&db, "Dune").release_date.as_deref(), Some("2021-09-15"));
        assert_eq!(
            row(&db, "The Expanse").release_date.as_deref(),
            Some("2015-12-14")
        );
        assert_eq!(row(&db, "Solaris").release_date, None);
    }

    /// TMDB's own voters, on a title the server described without one. The
    /// column is the audience's and never the critics': the number is a site
    /// average, and the two columns exist so that neither ever stands in for
    /// the other.
    #[test]
    fn a_title_tmdb_describes_gains_the_audience_score_its_voters_gave_it() {
        let server = tmdb();
        let db = seeded();
        let client = TmdbClient::new(&server.base_url, "k");

        enrich_pending(&db, &client, 10, NOW, &Slice::open()).unwrap();

        let dune = row(&db, "Dune");
        let audience = dune.audience.clone().unwrap();
        assert_eq!(audience.value, 7.8);
        assert_eq!(audience.source, "themoviedb");
        // and how many voted, which is what the evening weighs the score by
        assert_eq!(audience.votes, Some(1_240));
        // and nothing lands in the critics' column, which no TMDB payload
        // measures
        assert_eq!(dune.critics, None);

        // a score off twelve voters says less than no score at all: a title
        // reading 9,5 out of ten is a measurement, and this is not one
        assert_eq!(row(&db, "Solaris").audience, None);
    }

    /// The fallback is for a library whose agent carries no score, and stops
    /// there: a server that stated one has a better answer than TMDB's own.
    #[test]
    fn a_score_the_server_stated_is_not_replaced_by_tmdb_s() {
        let server = tmdb();
        let db = seeded();
        let client = TmdbClient::new(&server.base_url, "k");
        let title_id: i64 = db
            .lock()
            .conn()
            .query_row("SELECT id FROM titles WHERE name = 'Dune'", [], |r| {
                r.get(0)
            })
            .unwrap();
        db.lock()
            .upsert_metadata(&MetadataRecord {
                title_id,
                tmdb_id: None,
                overview_fr: Some("Le resume du serveur.".to_string()),
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
                fetched_at: NOW - 1,
                critics: None,
                audience: Some(Score {
                    value: 7.9,
                    source: "imdb".to_string(),
                    votes: None,
                }),
                release_date: None,
            })
            .unwrap();

        enrich_pending(&db, &client, 10, NOW, &Slice::open()).unwrap();

        let audience = db
            .lock()
            .metadata(title_id)
            .unwrap()
            .unwrap()
            .audience
            .unwrap();
        assert_eq!((audience.value, audience.source.as_str()), (7.9, "imdb"));
        // Plex never says how many voted, and TMDB's count is not the server's
        assert_eq!(audience.votes, None);
    }

    /// The shape the owner's library is in: Plex wrote the row, a matching
    /// pass placed it, and every credited name is known with no face on it.
    /// No queue names a title in this state, which is what the faces queue is
    /// for.
    fn placed_plex_row(db: &Mutex<Db>, name: &str, cast: &str, tmdb_id: i64) -> i64 {
        let title_id = plex_row(db, name, "Le resume du serveur.", "Aventure", cast);
        db.lock()
            .conn()
            .execute(
                "UPDATE metadata SET tmdb_id = ?2, matched_at = ?3 WHERE title_id = ?1",
                params![title_id, tmdb_id, NOW - 1],
            )
            .unwrap();
        title_id
    }

    /// A credited name's photograph and when TMDB was last asked for it.
    fn face(db: &Mutex<Db>, name: &str) -> (String, i64) {
        db.lock()
            .conn()
            .query_row(
                "SELECT profile_path, profile_checked_at FROM people WHERE name = ?1",
                [name],
                |r| Ok((r.get(0)?, r.get(1)?)),
            )
            .unwrap()
    }

    fn pending(db: &Mutex<Db>, now: i64) -> usize {
        db.lock()
            .titles_needing_metadata(now, MAX_AGE_SECS, 100)
            .unwrap()
            .len()
    }

    #[test]
    fn a_batch_matches_what_it_can_and_marks_the_rest() {
        let server = tmdb();
        let db = seeded();
        let client = TmdbClient::new(&server.base_url, "k");

        let stats = enrich_pending(&db, &client, 10, NOW, &Slice::open()).unwrap();
        assert_eq!(stats.attempted, 4);
        assert_eq!(stats.matched, 3);
        assert_eq!(stats.failed, 0);

        let dune = row(&db, "Dune");
        assert_eq!(dune.tmdb_id, Some(438631));
        assert_eq!(dune.overview_fr.as_deref(), Some("Dans un futur lointain."));
        assert_eq!(dune.overview_en, None); // fr answered, so en was never asked
        assert_eq!(dune.poster_path.as_deref(), Some("/dune.jpg"));
        assert_eq!(dune.backdrop_path.as_deref(), Some("/dune-bd.jpg"));
        assert_eq!(dune.genres, "Science-Fiction,Aventure");
        assert_eq!(dune.source, MetadataSource::Tmdb);
        assert_eq!(dune.fetched_at, NOW);

        // TMDB files this one under another year, so the year-less retry finds
        // it, and it has no French translation
        let solaris = row(&db, "Solaris");
        assert_eq!(solaris.tmdb_id, Some(762));
        assert_eq!(solaris.overview_fr, None);
        assert_eq!(
            solaris.overview_en.as_deref(),
            Some("A psychologist is sent.")
        );
        assert_eq!(solaris.genres, "Science Fiction");
        assert_eq!(solaris.poster_path.as_deref(), Some("/solaris.jpg"));

        let show = row(&db, "The Expanse");
        assert_eq!(show.tmdb_id, Some(63639));
        assert_eq!(show.overview_fr.as_deref(), Some("Au 23e siecle."));
        // a series is billed across every season, each name with the part it
        // played in the most episodes
        assert_eq!(show.cast_names, "Steven Strait,Dominique Tipper");
        assert_eq!(
            db.lock().cast_characters(show.title_id).unwrap(),
            "James Holden,Naomi Nagata"
        );

        // an unmatched home movie stays visible and stops being asked about
        let home = row(&db, "Anniversaire Mamie");
        assert_eq!(home.tmdb_id, None);
        assert!(home.overview_fr.is_none());
        assert_eq!(home.genres, "");

        // nothing is left pending, so a second call costs no request
        let before = server.requests().len();
        assert_eq!(
            enrich_pending(&db, &client, 10, NOW, &Slice::open()).unwrap(),
            EnrichStats::default()
        );
        assert_eq!(server.requests().len(), before);
    }

    /// The library the owner actually has: everything placed, so no queue
    /// asks about any of it, and no face on any credited name.
    #[test]
    fn a_placed_title_gets_its_faces_and_its_full_billing_from_one_request() {
        let server = tmdb();
        let db = seeded();
        let client = TmdbClient::new(&server.base_url, "k");
        let id = placed_plex_row(&db, "Dune", "Timothee Chalamet,Oscar Isaac", 438631);
        let before = row(&db, "Dune");

        let stats = enrich_pending(&db, &client, 10, NOW, &Slice::open()).unwrap();
        assert_eq!(stats.failed, 0);

        // one request, and it is the billing alone: no search, since the id is
        // already on the row, and no details, since nothing here may rewrite
        // what Plex said
        let asked: Vec<String> = server
            .requests()
            .iter()
            .map(|r| r.url.split('?').next().unwrap().to_string())
            .filter(|u| u.starts_with("/movie/438631"))
            .collect();
        assert_eq!(asked, ["/movie/438631/credits"]);

        assert_eq!(face(&db, "Timothee Chalamet").0, "/tc.jpg");
        // the director rides on the same billing
        assert_eq!(face(&db, "Denis Villeneuve").0, "/dv.jpg");

        // TMDB bills ten names where the listing carried two, so the longer
        // billing wins; everything else Plex wrote is untouched, and the row
        // is still Plex's
        let after = row(&db, "Dune");
        assert_eq!(after.cast_names.split(',').count(), 10);
        assert_eq!(after.fetched_at, NOW);
        assert_eq!(
            MetadataRecord {
                cast_names: before.cast_names.clone(),
                fetched_at: before.fetched_at,
                ..after
            },
            before
        );
        assert_eq!(before.source, MetadataSource::Plex);
        assert_eq!(tags(&db, id, "cast").len(), 10);

        // and it drains: a second launch costs the queue's own query and no
        // request at all
        let asked = server.requests().len();
        assert_eq!(
            enrich_pending(&db, &client, 10, NOW, &Slice::open()).unwrap(),
            EnrichStats::default()
        );
        assert_eq!(server.requests().len(), asked);
    }

    /// Two names one answer says nothing about: a performer TMDB holds no
    /// photograph of, and a name off a Plex server that TMDB's billing never
    /// spells that way. Both are final answers, and an unrecorded one would
    /// put their title back in the queue on every launch for good.
    #[test]
    fn a_name_with_no_photograph_behind_it_is_asked_about_once() {
        let server = tmdb();
        let db = seeded();
        let client = TmdbClient::new(&server.base_url, "k");
        // as long as TMDB's own billing, so the listing's spelling stays on it
        placed_plex_row(
            &db,
            "Dune",
            "Oscar Isaac,T. Chalamet,A,B,C,D,E,F,G,H",
            438631,
        );

        enrich_pending(&db, &client, 10, NOW, &Slice::open()).unwrap();

        // TMDB bills Oscar Isaac with a null photograph, and never bills
        // anybody as "T. Chalamet" - a face is filed under TMDB's own
        // spelling, so no billing will ever carry that name
        for name in ["Oscar Isaac", "T. Chalamet"] {
            assert_eq!(face(&db, name), (String::new(), NOW), "{name}");
        }

        assert!(db.lock().titles_needing_faces(10).unwrap().is_empty());
        let asked = server.requests().len();
        enrich_pending(&db, &client, 10, NOW, &Slice::open()).unwrap();
        assert_eq!(server.requests().len(), asked);
    }

    /// A placed title is asked its keywords once: they land on the row, move
    /// its description forward so the embedding is recomputed, and an empty
    /// answer is stamped all the same, so the queue drains.
    #[test]
    fn a_placed_title_is_asked_its_keywords_once() {
        let server = tmdb();
        let db = seeded();
        let client = TmdbClient::new(&server.base_url, "k");
        let dune = placed_plex_row(&db, "Dune", "Timothee Chalamet", 438631);
        let solaris = placed_plex_row(&db, "Solaris", "", 762);
        let mut stats = EnrichStats::default();
        backfill_keywords(&db, &client, 10, NOW, &Slice::open(), &mut stats).unwrap();
        assert_eq!(stats.attempted, 2);
        let read = |id: i64| -> (String, i64, i64) {
            db.lock()
                .conn()
                .query_row(
                    "SELECT keywords, keywords_at, fetched_at FROM metadata WHERE title_id = ?1",
                    [id],
                    |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
                )
                .unwrap()
        };
        assert_eq!(read(dune), ("desert, messiah".to_string(), NOW, NOW));
        // nothing to say leaves the description where it was
        assert_eq!(read(solaris), (String::new(), NOW, NOW - 1));
        let asked = server.requests().len();
        let mut again = EnrichStats::default();
        backfill_keywords(&db, &client, 10, NOW, &Slice::open(), &mut again).unwrap();
        assert_eq!((again.attempted, server.requests().len()), (0, asked));
    }

    /// A billing answers for everybody it lists, not only for the title it was
    /// asked about: the same performer is credited across a library, and the
    /// answer belongs to them. Recording it on the person is what keeps the
    /// queue from spending a request per film they appear in.
    #[test]
    fn one_billing_answers_for_every_film_the_names_on_it_appear_in() {
        let server = tmdb();
        let db = Db::open_in_memory().unwrap();
        db.upsert_title(MediaKind::Movie, "Dune", Some(2021))
            .unwrap();
        db.upsert_title(MediaKind::Movie, "Solaris", Some(1972))
            .unwrap();
        let db = Mutex::new(db);
        let client = TmdbClient::new(&server.base_url, "k");
        placed_plex_row(&db, "Dune", "Timothee Chalamet", 438631);
        // Zendaya is billed on Dune, and it is the only place TMDB says so;
        // Solaris's own billing was read long ago
        let solaris = placed_plex_row(&db, "Solaris", "Zendaya", 762);
        db.lock()
            .conn()
            .execute(
                "UPDATE metadata SET billed_at = ?2 WHERE title_id = ?1",
                params![solaris, NOW - 1],
            )
            .unwrap();

        // one title per call, so the second call reads the queue afresh
        assert_eq!(
            enrich_pending(&db, &client, 1, NOW, &Slice::open())
                .unwrap()
                .attempted,
            1
        );
        assert_eq!(face(&db, "Zendaya"), (String::new(), NOW));

        // Solaris is answered for without ever being asked about
        let asked = server.requests().len();
        assert_eq!(
            enrich_pending(&db, &client, 1, NOW, &Slice::open()).unwrap(),
            EnrichStats::default()
        );
        assert_eq!(server.requests().len(), asked);
    }

    /// A title TMDB could not place has no billing to record, so the names on
    /// it keep their turn: one of them may be billed on a film that does
    /// match, and stamping them here would lose that face.
    #[test]
    fn a_title_tmdb_cannot_place_records_nothing_about_the_names_on_it() {
        let server = tmdb();
        let db = Db::open_in_memory().unwrap();
        db.upsert_title(MediaKind::Movie, "Anniversaire Mamie", Some(2019))
            .unwrap();
        let db = Mutex::new(db);
        let client = TmdbClient::new(&server.base_url, "k");
        plex_row(
            &db,
            "Anniversaire Mamie",
            "Chez mamie.",
            "",
            "Tonton Bernard",
        );

        enrich_pending(&db, &client, 10, NOW, &Slice::open()).unwrap();

        assert_eq!(row(&db, "Anniversaire Mamie").tmdb_id, None);
        assert_eq!(face(&db, "Tonton Bernard"), (String::new(), 0));
    }

    #[test]
    fn a_batch_is_resumable_one_limit_at_a_time() {
        let server = tmdb();
        let db = seeded();
        let client = TmdbClient::new(&server.base_url, "k");

        assert_eq!(
            enrich_pending(&db, &client, 2, NOW, &Slice::open())
                .unwrap()
                .attempted,
            2
        );
        assert_eq!(pending(&db, NOW), 2);
        assert_eq!(
            enrich_pending(&db, &client, 2, NOW, &Slice::open())
                .unwrap()
                .attempted,
            2
        );
        assert_eq!(
            enrich_pending(&db, &client, 2, NOW, &Slice::open())
                .unwrap()
                .attempted,
            0
        );
    }

    #[test]
    fn a_batch_stops_at_the_title_its_deadline_ran_out_on() {
        // a title on this queue is a search and up to three more requests, so
        // the deadline is what ends the batch and the read-ahead never does.
        // One title here is twice sixty milliseconds, against a batch given
        // forty: it does the title it started and leaves the rest queued.
        let server = FakeServer::start(|_| {
            std::thread::sleep(Duration::from_millis(60));
            Reply::json(r#"{"page":1,"results":[],"total_results":0}"#)
        });
        let db = seeded();
        let client = TmdbClient::new(&server.base_url, "k");

        let running = AtomicBool::new(false);
        let cut = enrich_pending(
            &db,
            &client,
            10,
            NOW,
            &Slice::of(Duration::from_millis(40), &running),
        )
        .unwrap();

        assert_eq!(cut.attempted, 1, "the batch ran past its deadline");
        assert_eq!(
            server.requests().len(),
            2,
            "the batch went on to titles it had no time for"
        );
        // the three it did not reach are still owed a row, and the one it did
        // is not asked about again
        assert_eq!(pending(&db, NOW), 3);
        assert_eq!(
            enrich_pending(&db, &client, 10, NOW, &Slice::open())
                .unwrap()
                .attempted,
            3
        );
    }

    #[test]
    fn a_stale_row_is_refetched_and_a_plex_row_is_left_alone() {
        let server = tmdb();
        let db = seeded();
        let client = TmdbClient::new(&server.base_url, "k");
        enrich_pending(&db, &client, 10, NOW, &Slice::open()).unwrap();

        let month_later = NOW + MAX_AGE_SECS + 1;
        assert_eq!(pending(&db, month_later), 4);

        // a Plex title is the server's to describe: its row never expires here
        let alien = db
            .lock()
            .upsert_title(MediaKind::Movie, "Alien", Some(1979))
            .unwrap();
        db.lock()
            .upsert_metadata(&MetadataRecord {
                title_id: alien,
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
                fetched_at: NOW,
                critics: None,
                audience: None,
                release_date: None,
            })
            .unwrap();
        assert!(!db
            .lock()
            .titles_needing_metadata(month_later, MAX_AGE_SECS, 100)
            .unwrap()
            .iter()
            .any(|t| t.id == alien));
        enrich_pending(&db, &client, 100, month_later, &Slice::open()).unwrap();
        assert_eq!(
            row(&db, "Alien").overview_fr.as_deref(),
            Some("Dans l'espace.")
        );
    }

    #[test]
    fn a_stale_match_is_refreshed_by_its_id_without_searching_again() {
        let server = tmdb();
        let db = seeded();
        let client = TmdbClient::new(&server.base_url, "k");
        enrich_pending(&db, &client, 10, NOW, &Slice::open()).unwrap();
        let matched = row(&db, "Dune").tmdb_id;
        assert!(matched.is_some());
        let spent = server.requests().len();

        let month_later = NOW + MAX_AGE_SECS + 1;
        enrich_pending(&db, &client, 10, month_later, &Slice::open()).unwrap();
        let refresh = &server.requests()[spent..];
        assert!(refresh.iter().any(|r| r.url.starts_with("/movie/438631")));
        assert!(
            !refresh
                .iter()
                .any(|r| r.url.starts_with("/search") && r.url.contains("Dune")),
            "{refresh:?}"
        );
        let refreshed = row(&db, "Dune");
        assert_eq!(refreshed.tmdb_id, matched);
        assert_eq!(refreshed.fetched_at, month_later);
    }

    #[test]
    fn a_failed_request_costs_one_title_and_is_retried_next_run() {
        let db = seeded();
        // answers Dune and breaks on everything else
        let server = FakeServer::start(|req| {
            if req.url.contains("query=Dune") {
                return Reply::json(
                    r#"{"results":[{"id":438631,"title":"Dune","release_date":"2021-09-15"}]}"#,
                );
            }
            if req.url.starts_with("/movie/438631") {
                return Reply::json(r#"{"id":438631,"overview":"Dans un futur lointain."}"#);
            }
            Reply::status(503)
        });
        let client = TmdbClient::new(&server.base_url, "k");

        let stats = enrich_pending(&db, &client, 10, NOW, &Slice::open()).unwrap();
        assert_eq!(stats.attempted, 4);
        assert_eq!(stats.matched, 1);
        assert_eq!(stats.failed, 3);
        // the three that failed kept no row, so the next run tries them again
        assert_eq!(pending(&db, NOW), 3);
    }

    #[test]
    fn a_rejected_key_stops_the_batch_instead_of_burning_it() {
        let db = seeded();
        let server = FakeServer::start(|_req| Reply::status(401));
        let client = TmdbClient::new(&server.base_url, "stale");

        let err = enrich_pending(&db, &client, 10, NOW, &Slice::open()).unwrap_err();
        assert!(matches!(err, EnrichError::Unauthorized));
        assert_eq!(server.requests().len(), 1); // it stopped at the first title
        assert_eq!(pending(&db, NOW), 4);
    }

    #[test]
    fn a_search_hit_with_no_details_is_a_no_match_not_a_retry() {
        let db = Mutex::new(Db::open_in_memory().unwrap());
        db.lock()
            .upsert_title(MediaKind::Movie, "Dune", Some(2021))
            .unwrap();
        // the search knows the id, the details endpoint does not
        let server = FakeServer::start(|req| {
            if req.url.starts_with("/search/movie") {
                return Reply::json(
                    r#"{"results":[{"id":438631,"title":"Dune","release_date":"2021-09-15"}]}"#,
                );
            }
            Reply::status(404)
        });
        let client = TmdbClient::new(&server.base_url, "k");

        let stats = enrich_pending(&db, &client, 10, NOW, &Slice::open()).unwrap();
        assert_eq!(stats.attempted, 1);
        assert_eq!(stats.matched, 0);
        assert_eq!(stats.failed, 0);
        assert_eq!(row(&db, "Dune").tmdb_id, None);

        // the no-match row suppresses it for a month, like any other
        let before = server.requests().len();
        assert_eq!(
            enrich_pending(&db, &client, 10, NOW, &Slice::open()).unwrap(),
            EnrichStats::default()
        );
        assert_eq!(server.requests().len(), before);
    }

    #[test]
    fn a_blank_overview_falls_back_and_is_never_persisted() {
        let db = Mutex::new(Db::open_in_memory().unwrap());
        db.lock()
            .upsert_title(MediaKind::Movie, "Dune", Some(2021))
            .unwrap();
        let server = FakeServer::start(|req| {
            if req.url.starts_with("/search/movie") {
                return Reply::json(
                    r#"{"results":[{"id":438631,"title":"Dune","release_date":"2021-09-15"}]}"#,
                );
            }
            if req.url.contains("language=en-US") {
                return Reply::json(r#"{"id":438631,"overview":"  A far future. "}"#);
            }
            Reply::json(r#"{"id":438631,"overview":" \n ","genres":null}"#)
        });
        let client = TmdbClient::new(&server.base_url, "k");

        assert_eq!(
            enrich_pending(&db, &client, 10, NOW, &Slice::open())
                .unwrap()
                .matched,
            1
        );
        let dune = row(&db, "Dune");
        assert_eq!(dune.tmdb_id, Some(438631));
        assert_eq!(dune.overview_fr, None);
        assert_eq!(dune.overview_en.as_deref(), Some("A far future."));
        assert_eq!(dune.genres, "");
    }

    #[test]
    fn a_missing_english_translation_keeps_the_french_row() {
        let db = Mutex::new(Db::open_in_memory().unwrap());
        db.lock()
            .upsert_title(MediaKind::Movie, "Dune", Some(2021))
            .unwrap();
        // fr-FR answers with everything but an overview, en-US does not exist
        let server = FakeServer::start(|req| {
            if req.url.starts_with("/search/movie") {
                return Reply::json(
                    r#"{"results":[{"id":438631,"title":"Dune","release_date":"2021-09-15"}]}"#,
                );
            }
            if req.url.contains("language=en-US") {
                return Reply::status(404);
            }
            Reply::json(
                r#"{"id":438631,"overview":"","poster_path":"/dune.jpg",
                    "backdrop_path":"/dune-bd.jpg",
                    "genres":[{"id":878,"name":"Science-Fiction"}]}"#,
            )
        });
        let client = TmdbClient::new(&server.base_url, "k");

        assert_eq!(
            enrich_pending(&db, &client, 10, NOW, &Slice::open())
                .unwrap()
                .matched,
            1
        );
        let dune = row(&db, "Dune");
        assert_eq!(dune.tmdb_id, Some(438631));
        assert_eq!(dune.poster_path.as_deref(), Some("/dune.jpg"));
        assert_eq!(dune.backdrop_path.as_deref(), Some("/dune-bd.jpg"));
        assert_eq!(dune.genres, "Science-Fiction");
        assert_eq!(dune.overview_fr, None);
        assert_eq!(dune.overview_en, None);
    }

    #[test]
    fn a_described_title_carries_the_billing_the_credits_name() {
        let server = tmdb();
        let db = Mutex::new(Db::open_in_memory().unwrap());
        let dune = db
            .lock()
            .upsert_title(MediaKind::Movie, "Dune", Some(2021))
            .unwrap();
        let client = TmdbClient::new(&server.base_url, "key");
        enrich_pending(&db, &client, 10, NOW, &Slice::open()).unwrap();

        let row = db.lock().metadata(dune).unwrap().unwrap();
        // the part rides beside the name it belongs to
        assert!(db
            .lock()
            .cast_characters(dune)
            .unwrap()
            .starts_with("Paul Atreides,"));
        // top billing first, in TMDB's own order
        assert_eq!(
            row.cast_names,
            "Timothee Chalamet,Rebecca Ferguson,Oscar Isaac,Josh Brolin,\
             Stellan Skarsgard,Zendaya,Chang Chen,Dave Bautista,\
             Sharon Duncan-Brewster,Jason Momoa"
        );
        // one request per language, credits included: the cast is not a third
        let details: Vec<String> = server
            .requests()
            .into_iter()
            .map(|r| r.url)
            .filter(|u| u.starts_with("/movie/438631?") || u.starts_with("/movie/438631&"))
            .collect();
        assert!(
            details
                .iter()
                .all(|u| u.contains("append_to_response=credits")),
            "{details:#?}"
        );
    }

    /// The photographs ride on the details call the enrichment already makes,
    /// so a face costs no request of its own. The count below is the whole of
    /// the argument for putting them here rather than on a pass of their own.
    #[test]
    fn the_credits_hand_back_a_face_without_a_request_of_their_own() {
        let server = tmdb();
        let db = Mutex::new(Db::open_in_memory().unwrap());
        db.lock()
            .upsert_title(MediaKind::Movie, "Dune", Some(2021))
            .unwrap();
        let client = TmdbClient::new(&server.base_url, "key");
        enrich_pending(&db, &client, 10, NOW, &Slice::open()).unwrap();

        let db = db.lock();
        let (_, chalamet) = db.person("Timothee Chalamet").unwrap().unwrap();
        assert_eq!(chalamet, "/tc.jpg");
        // the director is credited from the crew, and gets a face the same way
        let (_, villeneuve) = db.person("Denis Villeneuve").unwrap().unwrap();
        assert_eq!(villeneuve, "/dv.jpg");
        // a performer TMDB names but holds no photograph of is a person all
        // the same: their page opens, their tile draws without a face
        let (isaac, none) = db.person("Oscar Isaac").unwrap().unwrap();
        assert!(isaac > 0);
        assert_eq!(none, "");

        // nothing asked TMDB about a person: no /person path was ever fetched
        assert!(
            !server
                .requests()
                .iter()
                .any(|r| r.url.starts_with("/person")),
            "the enrichment asked TMDB about a person"
        );
    }

    #[test]
    fn the_crew_is_cut_to_the_three_credits_a_viewer_picks_a_film_by() {
        let server = tmdb();
        let db = Mutex::new(Db::open_in_memory().unwrap());
        let dune = db
            .lock()
            .upsert_title(MediaKind::Movie, "Dune", Some(2021))
            .unwrap();
        let client = TmdbClient::new(&server.base_url, "key");
        enrich_pending(&db, &client, 10, NOW, &Slice::open()).unwrap();

        let row = db.lock().metadata(dune).unwrap().unwrap();
        assert_eq!(row.director_names, "Denis Villeneuve");
        // he wrote it as well as directed it, and is kept once; Frank Herbert
        // is credited "Novel", which is the source and not the film's voice
        assert_eq!(row.writer_names, "Jon Spaihts,Eric Roth");
        // the composer shares TMDB's "Sound" department with the boom
        // operator, which is why the job and never the department decides
        assert_eq!(row.composer_names, "Hans Zimmer");

        // the payload also names an editor and a director of photography, and
        // neither is anybody this library is browsed by
        let stored = format!(
            "{} {} {}",
            row.director_names, row.writer_names, row.composer_names
        );
        assert!(!stored.contains("Joe Walker"), "{stored}");
        assert!(!stored.contains("Greig Fraser"), "{stored}");
        assert!(!stored.contains("Theresa"), "{stored}");
        assert!(!stored.contains("Frank Herbert"), "{stored}");
    }

    #[test]
    fn a_plex_row_keeps_its_own_crew_and_still_gains_the_composer() {
        // the split that matters on this library: Plex answers for the
        // director and the writers, TMDB alone answers for the score, and each
        // column is filled on its own so the one Plex has cannot block the one
        // it does not.
        let server = tmdb();
        let db = seeded();
        let dune = plex_row(
            &db,
            "Dune",
            "Sur Arrakis, une planete de sable.",
            "Science-Fiction",
            "Timothee Chalamet",
        );
        db.lock()
            .conn()
            .execute(
                "UPDATE metadata SET director_names = 'Le realisateur selon Plex',
                     writer_names = 'Le scenariste selon Plex' WHERE title_id = ?1",
                [dune],
            )
            .unwrap();
        let client = TmdbClient::new(&server.base_url, "k");
        enrich_pending(&db, &client, 10, NOW, &Slice::open()).unwrap();

        let row = db.lock().metadata(dune).unwrap().unwrap();
        assert_eq!(row.director_names, "Le realisateur selon Plex");
        assert_eq!(row.writer_names, "Le scenariste selon Plex");
        assert_eq!(row.composer_names, "Hans Zimmer");
    }

    #[test]
    fn a_title_with_no_credits_carries_no_cast_and_is_still_described() {
        let server = tmdb();
        let db = Mutex::new(Db::open_in_memory().unwrap());
        let solaris = db
            .lock()
            .upsert_title(MediaKind::Movie, "Solaris", Some(1972))
            .unwrap();
        let client = TmdbClient::new(&server.base_url, "key");
        enrich_pending(&db, &client, 10, NOW, &Slice::open()).unwrap();

        let row = db.lock().metadata(solaris).unwrap().unwrap();
        assert_eq!(row.cast_names, "");
        assert_eq!(row.director_names, "");
        assert_eq!(row.composer_names, "");
        assert_eq!(row.tmdb_id, Some(762));
        assert_eq!(row.overview_en.as_deref(), Some("A psychologist is sent."));
    }

    #[test]
    fn a_plex_row_gains_the_id_and_the_saga_and_keeps_its_own_words() {
        let server = tmdb();
        let db = seeded();
        let dune = plex_row(
            &db,
            "Dune",
            "Sur Arrakis, une planete de sable.",
            "Science-Fiction",
            "Timothee Chalamet",
        );
        // a show the server described without a genre or a billing
        let expanse = plex_row(&db, "The Expanse", "Au 23e siecle, selon Plex.", "", "");
        let client = TmdbClient::new(&server.base_url, "k");

        let stats = enrich_pending(&db, &client, 10, NOW, &Slice::open()).unwrap();
        // the two Plex rows matched, and so did one of the two titles that
        // had no row at all
        assert_eq!(stats.matched, 3);

        let row = db.lock().metadata(dune).unwrap().unwrap();
        assert_eq!(row.tmdb_id, Some(438631));
        // the saga is what only TMDB had, and it reaches the rail that joins
        // on it
        assert_eq!(row.collections, "Dune - Saga");
        assert_eq!(tags(&db, dune, "collection"), ["Dune - Saga"]);
        // the owner's own WORDS stand: their language, their tags, their
        // artwork, and the row is still theirs
        assert_eq!(
            row.overview_fr.as_deref(),
            Some("Sur Arrakis, une planete de sable.")
        );
        assert_eq!(row.overview_en, None);
        assert_eq!(row.genres, "Science-Fiction");
        // Billing is the exception, and deliberately: it is a list of facts
        // rather than a piece of writing, and an agent that filed one name
        // where TMDB carries the top billing leaves a cast rail with one
        // face on it. The longer list wins; a server that knew more than
        // TMDB would still keep its own.
        assert_eq!(
            row.cast_names,
            "Timothee Chalamet,Rebecca Ferguson,Oscar Isaac,Josh Brolin,\
Stellan Skarsgard,Zendaya,Chang Chen,Dave Bautista,Sharon Duncan-Brewster,Jason Momoa"
        );
        assert_eq!(
            row.poster_path.as_deref(),
            Some("/library/metadata/1/thumb/1")
        );
        assert_eq!(
            row.backdrop_path.as_deref(),
            Some("/library/metadata/1/art/1")
        );
        assert_eq!(row.source, MetadataSource::Plex);
        // the description moved, so the vector built from it is owed again
        assert_eq!(row.fetched_at, NOW);

        // what Plex had nothing to say about is filled rather than left empty
        let row = db.lock().metadata(expanse).unwrap().unwrap();
        assert_eq!(row.tmdb_id, Some(63639));
        assert_eq!(row.genres, "Science-Fiction et fantastique");
        assert_eq!(
            row.overview_fr.as_deref(),
            Some("Au 23e siecle, selon Plex.")
        );
        assert_eq!(row.collections, ""); // TMDB files no show under a saga

        // both are matched, so neither is asked about again
        assert!(db
            .lock()
            .titles_needing_match(NOW, MAX_AGE_SECS, 10)
            .unwrap()
            .is_empty());
        let spent = server.requests().len();
        assert_eq!(
            enrich_pending(&db, &client, 10, NOW, &Slice::open())
                .unwrap()
                .attempted,
            0
        );
        assert_eq!(server.requests().len(), spent);
    }

    #[test]
    fn a_title_tmdb_cannot_place_stops_being_searched_for_until_it_goes_stale() {
        let server = tmdb();
        let db = Mutex::new(Db::open_in_memory().unwrap());
        db.lock()
            .upsert_title(MediaKind::Movie, "Anniversaire Mamie", Some(2019))
            .unwrap();
        let home = plex_row(&db, "Anniversaire Mamie", "Le gateau.", "", "");
        let client = TmdbClient::new(&server.base_url, "k");

        let stats = enrich_pending(&db, &client, 10, NOW, &Slice::open()).unwrap();
        assert_eq!(stats.attempted, 1);
        assert_eq!(stats.matched, 0);
        assert_eq!(stats.failed, 0);
        let row = db.lock().metadata(home).unwrap().unwrap();
        assert_eq!(row.tmdb_id, None);
        assert_eq!(row.overview_fr.as_deref(), Some("Le gateau."));
        // the row it had is untouched: nothing was fetched to touch it with
        assert_eq!(row.fetched_at, NOW - 1);

        let spent = server.requests().len();
        assert_eq!(
            enrich_pending(&db, &client, 10, NOW, &Slice::open())
                .unwrap()
                .attempted,
            0
        );
        assert_eq!(server.requests().len(), spent);

        // a month on, TMDB may have learned it
        let later = NOW + MAX_AGE_SECS + 1;
        assert_eq!(
            enrich_pending(&db, &client, 10, later, &Slice::open())
                .unwrap()
                .attempted,
            1
        );
        assert!(server.requests().len() > spent);
    }

    #[test]
    fn a_first_result_that_is_another_film_is_left_unmatched() {
        // TMDB's own best guess for "Gold" is a film called "One Piece: Gold",
        // and the year rules out the one film actually named Gold
        let server = FakeServer::start(|req| {
            if req.url.starts_with("/search/movie") {
                return Reply::json(
                    r#"{"results":[
                        {"id":374205,"title":"One Piece: Gold","release_date":"2016-07-23"},
                        {"id":760926,"title":"Gold","release_date":"2010-01-01"}]}"#,
                );
            }
            Reply::status(500)
        });
        let db = Mutex::new(Db::open_in_memory().unwrap());
        db.lock()
            .upsert_title(MediaKind::Movie, "Gold", Some(2022))
            .unwrap();
        plex_row(&db, "Gold", "Deux hommes dans le desert.", "", "");
        let client = TmdbClient::new(&server.base_url, "k");

        let stats = enrich_pending(&db, &client, 10, NOW, &Slice::open()).unwrap();
        assert_eq!(stats.attempted, 1);
        assert_eq!(stats.matched, 0);
        // no details request was ever sent: nothing was certain enough to ask
        // about, and a stranger's saga is worse than no saga
        assert!(
            server
                .requests()
                .iter()
                .all(|r| r.url.starts_with("/search/movie")),
            "{:#?}",
            server.requests()
        );
        assert_eq!(db.lock().metadata(1).unwrap().unwrap().tmdb_id, None);
    }

    #[test]
    fn a_show_two_shows_are_named_after_is_left_unmatched() {
        // no year to tell them apart, and TMDB's order is a popularity
        // ranking, not evidence about which one is on this disk
        let server = FakeServer::start(|req| {
            if req.url.starts_with("/search/tv") {
                return Reply::json(
                    r#"{"results":[
                        {"id":106379,"name":"Fallout","first_air_date":"2024-04-10"},
                        {"id":32366,"name":"Fallout","first_air_date":"2006-01-01"}]}"#,
                );
            }
            // TMDB would happily describe either of them
            Reply::json(r#"{"id":106379,"overview":"Un abri.","genres":[]}"#)
        });
        let db = Mutex::new(Db::open_in_memory().unwrap());
        db.lock()
            .upsert_title(MediaKind::Show, "Fallout", None)
            .unwrap();
        plex_row(&db, "Fallout", "Un abri.", "", "");
        let client = TmdbClient::new(&server.base_url, "k");

        assert_eq!(
            enrich_pending(&db, &client, 10, NOW, &Slice::open())
                .unwrap()
                .matched,
            0
        );
        assert_eq!(db.lock().metadata(1).unwrap().unwrap().tmdb_id, None);
        // neither of them was asked about: picking the popular one is a guess
        assert!(
            server
                .requests()
                .iter()
                .all(|r| r.url.starts_with("/search/tv")),
            "{:#?}",
            server.requests()
        );
    }

    #[test]
    fn a_show_tmdb_cannot_place_is_searched_for_once_whatever_year_it_carries() {
        // a show search sends no year, so the year-less retry a film gets
        // would be the same request twice
        let server = FakeServer::start(|_req| Reply::json(r#"{"results":[]}"#));
        let db = Mutex::new(Db::open_in_memory().unwrap());
        db.lock()
            .upsert_title(MediaKind::Show, "La carte des désirs", Some(2026))
            .unwrap();
        let client = TmdbClient::new(&server.base_url, "k");

        assert_eq!(
            enrich_pending(&db, &client, 10, NOW, &Slice::open())
                .unwrap()
                .matched,
            0
        );
        assert_eq!(server.requests().len(), 1, "{:#?}", server.requests());
    }

    #[test]
    fn a_subtitled_name_is_looked_for_by_its_head_and_still_matched_in_full() {
        // TMDB's search answers the whole line with nothing and the head with
        // the film, whose French title is the whole line again
        let server = FakeServer::start(|req| {
            if req.url.starts_with("/search/movie") {
                if req.url.contains("query=Love+Again&") || req.url.contains("query=Love%20Again&")
                {
                    return Reply::json(
                        r#"{"results":[{"id":758336,
                            "title":"Love Again : Un peu, beaucoup, passionnement",
                            "release_date":"2023-05-04"}]}"#,
                    );
                }
                return Reply::json(r#"{"results":[]}"#);
            }
            Reply::json(r#"{"id":758336,"overview":"Un texto.","genres":[]}"#)
        });
        let db = Mutex::new(Db::open_in_memory().unwrap());
        db.lock()
            .upsert_title(
                MediaKind::Movie,
                "Love Again : Un peu, beaucoup, passionnement",
                Some(2023),
            )
            .unwrap();
        let client = TmdbClient::new(&server.base_url, "k");

        assert_eq!(
            enrich_pending(&db, &client, 10, NOW, &Slice::open())
                .unwrap()
                .matched,
            1
        );
        assert_eq!(
            db.lock().metadata(1).unwrap().unwrap().tmdb_id,
            Some(758336)
        );
    }

    #[test]
    fn a_rate_limited_batch_stops_where_it_stands_and_resumes_there() {
        let calls = Arc::new(AtomicUsize::new(0));
        let counted = Arc::clone(&calls);
        // Dune is described, and the next search is refused with a delay
        let server = FakeServer::start(move |req| {
            if req.url.contains("query=Dune") {
                counted.fetch_add(1, Ordering::SeqCst);
                return Reply::json(
                    r#"{"results":[{"id":438631,"title":"Dune","release_date":"2021-09-15"}]}"#,
                );
            }
            if req.url.starts_with("/movie/438631") {
                return Reply::json(r#"{"id":438631,"overview":"Dans un futur lointain."}"#);
            }
            Reply {
                status: 429,
                headers: vec![("Retry-After".to_string(), "7".to_string())],
                body: Vec::new(),
            }
        });
        let db = seeded();
        let client = TmdbClient::new(&server.base_url, "k");

        let stats = enrich_pending(&db, &client, 10, NOW, &Slice::open()).unwrap();
        // one title described, one 429, and the batch stopped there rather
        // than spending the other two collecting the same answer
        assert_eq!(stats.attempted, 1);
        assert_eq!(stats.matched, 1);
        assert_eq!(stats.failed, 0);
        assert_eq!(stats.retry_after_secs, 7);
        assert_eq!(pending(&db, NOW), 3);
        let spent = server.requests().len();

        // the next call starts at the title the limit stopped on, and Dune is
        // not searched for a second time
        let stats = enrich_pending(&db, &client, 10, NOW, &Slice::open()).unwrap();
        assert_eq!(stats.retry_after_secs, 7);
        assert_eq!(stats.attempted, 0);
        assert_eq!(calls.load(Ordering::SeqCst), 1);
        assert!(server.requests().len() > spent);
    }

    #[test]
    fn a_title_with_no_files_is_still_enriched() {
        let server = tmdb();
        let db = Mutex::new(Db::open_in_memory().unwrap());
        db.lock()
            .upsert_title(MediaKind::Movie, "Dune", Some(2021))
            .unwrap();
        let client = TmdbClient::new(&server.base_url, "k");
        assert_eq!(
            enrich_pending(&db, &client, 10, NOW, &Slice::open())
                .unwrap()
                .matched,
            1
        );
    }
}
