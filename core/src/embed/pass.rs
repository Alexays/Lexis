//! The background queue: vectors for the titles that are owed one, then the
//! neighbours of every title that has one. Both are resumable and neither
//! holds the write lock across the work it does.

use super::model::EmbedModel;
use super::space::Space;
use super::EmbedError;
use crate::index::db::{Db, EmbeddingRecord, IndexError, PendingEmbed, TitleVector};
use crate::index::taste::{MOODS, SEASONS};
use crate::slice::Slice;
use parking_lot::Mutex;

/// The most neighbours one title keeps. How many it actually keeps is decided
/// by `nearest`'s similarity floor, which is why this is a ceiling on what a
/// row can show and never a count to fill: a title with nothing in common
/// with the rest of the library keeps none of these slots.
pub const SEMANTIC_NEIGHBOURS: usize = 20;

/// What a stored score is in: the cosine in ten-thousandths. The column is an
/// integer and the cosine is what the floor is decided on, so this is the
/// number a reader gets back rather than a dot product of quantised bytes.
const SCORE_SCALE: f32 = 10_000.0;

/// The cap on one read of the vector table: 20 000 vectors is 7.7 MB, well
/// past the owner's library, and the sweep reads the whole set on every batch
/// since any title already in memory might be another one's neighbour.
pub const MAX_VECTORS: u32 = 20_000;

#[derive(Debug, Default, Clone, PartialEq, Eq)]
pub struct EmbedStats {
    pub attempted: u32,
    pub embedded: u32,
    /// Looked at, and the description had not moved.
    pub skipped: u32,
}

/// Whether anything is owed a vector under `version`: a missing anchor, or a
/// title whose description is newer than its vector. Read before the model is
/// loaded, which costs a second and its whole mapping to find nothing.
pub fn embedding_owed(db: &Mutex<Db>, version: i64) -> Result<bool, EmbedError> {
    let keys: Vec<&str> = SEASONS.iter().chain(&MOODS).map(|(key, _)| *key).collect();
    let guard = db.lock();
    Ok(!guard
        .anchors_missing(&keys, version)
        .map_err(index)?
        .is_empty()
        || !guard
            .titles_needing_embedding(version, 1)
            .map_err(index)?
            .is_empty())
}

/// Embeds the titles owed a vector, at most `limit` of them and only for as
/// long as `slice` lasts. Every title it reaches ends with a row or with a
/// fresh timestamp, so calling it again walks forward instead of retrying the
/// same head of the queue - and a batch the slice cut short banks what it
/// already computed rather than throwing it away.
///
/// `limit` caps the read, not the batch: one forward pass is the unit of work
/// here and it costs milliseconds on a Mac and more on a television, so what
/// ends the batch is the slice.
///
/// The batch is read under the guard, computed with no lock held, and written
/// back under the guard: a scan or a playback report can land in between.
pub fn embed_pending(
    db: &Mutex<Db>,
    model: &EmbedModel,
    limit: u32,
    now: i64,
    slice: &Slice,
) -> Result<EmbedStats, EmbedError> {
    // The seasonal and mood anchors, before the titles: a handful of short
    // texts, once per model, and every pass after the first finds nothing
    // missing. They are what those rows are ranked against, and a pass that
    // embedded the library without them would leave the rows empty until
    // the next scan.
    let version = model.version();
    let missing = {
        let keys: Vec<&str> = SEASONS.iter().chain(&MOODS).map(|(key, _)| *key).collect();
        db.lock().anchors_missing(&keys, version).map_err(index)?
    };
    for key in missing {
        // a press on play stops the anchors as it stops the titles: the
        // missing ones are asked for again by the next batch
        if slice.expired() {
            return Ok(EmbedStats::default());
        }
        let Some((_, text)) = SEASONS.iter().chain(&MOODS).find(|(k, _)| *k == key) else {
            continue;
        };
        let Some(vector) = model.embed(text)? else {
            continue;
        };
        db.lock()
            .put_anchor_vector(&key, version, &vector)
            .map_err(index)?;
    }

    let pending = db
        .lock()
        .titles_needing_embedding(version, limit)
        .map_err(index)?;

    let mut stats = EmbedStats::default();
    let mut computed: Vec<(i64, Vec<i8>, i64)> = Vec::with_capacity(pending.len());
    let mut unmoved: Vec<i64> = Vec::new();
    for title in &pending {
        // before the forward pass, never after it: a title half embedded is
        // work spent for nothing, and the rest of the queue is still queued
        if slice.expired() {
            break;
        }
        stats.attempted += 1;
        let text = embed_text(title);
        let hash = source_hash(&text);
        if title.source_hash == Some(hash) {
            stats.skipped += 1;
            unmoved.push(title.title_id);
            continue;
        }
        let vector = model.embed(&text)?;
        if vector.is_some() {
            stats.embedded += 1;
        }
        computed.push((title.title_id, vector.unwrap_or_default(), hash));
    }

    let guard = db.lock();
    // One transaction for the batch, the way `upsert_semantic` writes its
    // own: a commit per vector is a commit per title of the library, and each
    // one is a WAL frame and an fsync of its own.
    let tx = guard
        .conn()
        .unchecked_transaction()
        .map_err(|e| index(IndexError::from(e)))?;
    for (title_id, vector, hash) in computed {
        // a title whose text says nothing is written with an empty vector: it
        // is nothing to compare against, and the row is what keeps it from
        // being asked about on every pass forever
        guard
            .upsert_embedding(&EmbeddingRecord {
                title_id,
                model_version: version,
                source_hash: hash,
                vector,
                computed_at: now,
            })
            .map_err(index)?;
    }
    for title_id in unmoved {
        // the vector still stands: only the timestamp has to move past the
        // sync that rewrote the same description
        guard
            .touch_embedding(title_id, version, now)
            .map_err(index)?;
    }
    tx.commit().map_err(|e| index(IndexError::from(e)))?;
    Ok(stats)
}

#[derive(Debug, Default, Clone, PartialEq, Eq)]
pub struct SemanticStats {
    pub attempted: u32,
    /// Titles that got at least one neighbour.
    pub linked: u32,
    /// Looked at, and nothing in the library passed the similarity floor.
    pub empty: u32,
    /// Whether this batch had to read the library rather than reuse the one
    /// the last batch left. A full sweep reads it once.
    pub read_library: bool,
}

/// The library every seed is measured against, kept between the batches of one
/// sweep. Reading it and centring it costs more than the fifty seeds a batch
/// does, and it is the same answer for all of them.
pub struct Library {
    /// What the vector table looked like when this was built.
    stamp: (i64, i64, i64),
    vectors: Vec<TitleVector>,
    space: Space,
}

/// Computes the neighbours of up to `limit` titles whose vector is new since
/// their row in `similar_semantic` was last written, or that have never been
/// looked at, for as long as `slice` lasts. Each title's own row is written as
/// it is reached, in one transaction per batch: a sweep stopped after any
/// batch has already banked that many titles, and the next call resumes where
/// `titles_needing_semantic` left off rather than starting over. A full sweep
/// is this called until `attempted` comes back zero.
///
/// `version` is the encoder the index is set to: only its vectors are read.
///
/// One seed is a scan of every vector in the library, so `limit` caps the read
/// and the slice ends the batch. The vectors are read once either way, which
/// is why the slice has to be long enough to be worth that read.
pub fn semantic_pending(
    db: &Mutex<Db>,
    held: &Mutex<Option<Library>>,
    version: i64,
    limit: u32,
    now: i64,
    slice: &Slice,
) -> Result<SemanticStats, IndexError> {
    let (stale, stamp) = {
        let guard = db.lock();
        (
            guard.titles_needing_semantic(version, limit)?,
            guard.embedding_stamp(version)?,
        )
    };
    // the common answer at launch: nothing to link, so no library to read
    if stale.is_empty() {
        return Ok(SemanticStats::default());
    }
    // The library is the same answer for every seed in the sweep, and reading
    // and centring it costs more than the seeds do. It is kept until the
    // vector table moves under it: a title embedded mid-sweep belongs to a
    // different library than the one before it, and measuring it against the
    // older centre would place it against a direction its own vector helped
    // define.
    let read_library = held
        .lock()
        .as_ref()
        .is_none_or(|library| library.stamp != stamp);
    if read_library {
        let vectors = db.lock().vectors(version, MAX_VECTORS)?;
        let space = Space::of(&vectors);
        *held.lock() = Some(Library {
            stamp,
            vectors,
            space,
        });
    }
    let guard = held.lock();
    let Some(library) = guard.as_ref() else {
        return Ok(SemanticStats::default());
    };
    let (vectors, space) = (&library.vectors, &library.space);
    // Built once for the batch: found by a scan of the library per seed, this
    // is the library squared over a full sweep.
    let index_of: std::collections::HashMap<i64, usize> = vectors
        .iter()
        .enumerate()
        .map(|(i, v)| (v.title_id, i))
        .collect();
    let mut links = Vec::with_capacity(stale.len());
    let mut empty = 0u32;
    let mut attempted = 0u32;
    for title_id in &stale {
        // the seeds already done are written below whatever stops the batch
        // here, so the sweep resumes at this one rather than at the first
        if slice.expired() {
            break;
        }
        attempted += 1;
        // titles_needing_semantic only names titles vectors() also reads, so
        // this is always found; skipping rather than panicking costs nothing
        // if a scan prunes one between the two locks above
        let Some(&seed) = index_of.get(title_id) else {
            continue;
        };
        let near = nearest(vectors, space, seed);
        if near.is_empty() {
            empty += 1;
        }
        links.push((*title_id, near));
    }
    drop(guard);
    db.lock().upsert_semantic(&links, version, now)?;
    Ok(SemanticStats {
        attempted,
        linked: attempted - empty,
        empty,
        read_library,
    })
}

/// The nearest vectors of the same kind, best first, and only the ones a
/// chance resemblance cannot account for.
///
/// The cut is a count of neighbours nowhere: filling a fixed number of slots
/// is what pads a row with titles that merely share a language, and this
/// library is dense enough that the twentieth is always *some* title. What a
/// title keeps is decided against its own similarities to the rest of the
/// library, which are a distribution the library itself supplies: the mean of
/// them says what an arbitrary title scores against this one, their spread
/// says how far that wanders, and the best of `n` such draws lands about
/// `sqrt(2 ln n)` deviations above the mean. A candidate below that is no
/// closer than the closest unrelated title would have been anyway, whatever
/// its rank, so the row ends there.
///
/// Nothing in that is tuned. Both ends are measured per seed and the reach of
/// the extreme comes from the library's own size, so a smaller shelf, a
/// generic title that sits near everything and a distinctive one that sits
/// near nothing each get their own answer instead of one number picked
/// against somebody else's library. The floor never falls below zero: a
/// cosine of zero or less is orthogonal or opposite, not similar by any
/// reading of the word.
///
/// All of which is only true of cosines measured from the library's own
/// centre. Raw encoder output shares a direction between every title (see
/// `Space`), and a mean and a spread taken across that shared part describe
/// the encoder's habits rather than this library's: on the owner's shelf the
/// whole informative range was 0.018 wide and the rule kept near-duplicates
/// and nothing else. Centred, the same rule with the same constants reads a
/// spread of 0.080 and links half the library.
fn nearest(vectors: &[TitleVector], space: &Space, seed: usize) -> Vec<(i64, i32)> {
    let (kind, vector) = (vectors[seed].kind, &vectors[seed].vector);
    // a vector that is the shared direction and nothing else points nowhere
    // of its own, and every cosine against it is not a number
    if !space.placed(seed) {
        return Vec::new();
    }
    let mut best: Vec<(i64, f32)> = Vec::with_capacity(SEMANTIC_NEIGHBOURS + 1);
    let mut sum = 0.0f64;
    let mut squares = 0.0f64;
    let mut counted = 0u32;
    for (i, other) in vectors.iter().enumerate() {
        if i == seed || other.kind != kind || other.vector.len() != vector.len() || !space.placed(i)
        {
            continue;
        }
        let dot: i32 = other
            .vector
            .iter()
            .zip(vector)
            .map(|(a, b)| i32::from(*a) * i32::from(*b))
            .sum();
        let cos = space.cos(i, seed, dot as f32);
        sum += f64::from(cos);
        squares += f64::from(cos) * f64::from(cos);
        counted += 1;
        if best.len() == SEMANTIC_NEIGHBOURS && cos <= best[SEMANTIC_NEIGHBOURS - 1].1 {
            continue;
        }
        // ids are walked in order, so an insertion that keeps equal scores in
        // the order they arrived makes the row the same on every pass
        let at = best.partition_point(|(_, score)| *score >= cos);
        best.insert(at, (other.title_id, cos));
        best.truncate(SEMANTIC_NEIGHBOURS);
    }
    if counted == 0 {
        return Vec::new();
    }
    let floor = chance_floor(sum, squares, counted);
    best.into_iter()
        .take_while(|(_, cos)| *cos > floor)
        .map(|(id, cos)| (id, (cos * SCORE_SCALE) as i32))
        .collect()
}

/// The cosine past which a candidate is closer than chance puts the best of
/// `counted` unrelated titles, given the sum and the sum of squares of their
/// cosines: `nearest` says why. Never below zero.
pub(crate) fn chance_floor(sum: f64, squares: f64, counted: u32) -> f32 {
    let n = f64::from(counted);
    let mean = sum / n;
    let spread = (squares / n - mean * mean).max(0.0).sqrt();
    (mean + (2.0 * n.ln()).sqrt() * spread).max(0.0) as f32
}

/// How much of the billing the text carries: the leads, which say who a film is
/// for. The rest of `cast_names` is for the faces a detail screen draws.
const EMBEDDED_CAST: usize = 8;

/// What a title reads as, to the model: its name, its year, who directed it,
/// its genres, TMDB's keywords, the sagas it belongs to, its billing, who
/// wrote and scored it, and its synopsis, in that order.
///
/// The keywords sit beside the genres because they are the same kind of claim
/// made more precisely: "heist", "time loop", "feel good" say the tone a
/// synopsis only implies.
///
/// A collection sits with the genres because it says the same kind of thing -
/// what this title is one of - and because the synopsis is what the token cap
/// cuts: the saga two films share is a handful of words and must not be the
/// half that falls off the end.
///
/// The order is the ranking, not a list: an encoder that reads word order
/// weighs the front of the text hardest, and the tail is what a token cap
/// takes. So the director sits directly behind the name, ahead of the genres,
/// because who made a film says more about who else will like it than what
/// shelf it sits on; the writer and the composer sit behind the billing,
/// because they are the same kind of claim made more weakly. Everything kept is
/// in front of the synopsis, which is the only part long enough to be cut.
fn embed_text(p: &PendingEmbed) -> String {
    let cast = match p.cast_names.match_indices(',').nth(EMBEDDED_CAST - 1) {
        Some((end, _)) => &p.cast_names[..end],
        None => p.cast_names.as_str(),
    };
    let mut text = String::with_capacity(64 + p.overview.len());
    text.push_str(&p.name);
    if let Some(year) = p.year {
        text.push(' ');
        text.push_str(&year.to_string());
    }
    for part in [
        p.director_names.as_str(),
        &p.genres,
        &p.keywords,
        &p.collections,
        cast,
        &p.writer_names,
        &p.composer_names,
        &p.overview,
    ] {
        if !part.is_empty() {
            text.push_str(". ");
            text.push_str(part);
        }
    }
    text
}

fn index(e: IndexError) -> EmbedError {
    EmbedError::Index(e.to_string())
}

/// FNV-1a over the text that was embedded. Not a checksum of anything anyone
/// sends us: it only has to change when the description does.
fn source_hash(text: &str) -> i64 {
    let mut hash = 0xcbf2_9ce4_8422_2325u64;
    for b in text.as_bytes() {
        hash ^= u64::from(*b);
        hash = hash.wrapping_mul(0x1000_0000_01b3);
    }
    hash as i64
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::embed::fixture;
    use crate::embed::model::EmbedModel;
    use crate::index::db::{
        Db, EmbeddingRecord, FileMedia, FileRecord, MetadataRecord, MetadataSource,
    };
    use crate::index::MediaKind;
    use std::sync::atomic::{AtomicBool, Ordering};
    use std::time::Duration;

    const NOW: i64 = 1_700_000_000;
    /// What the fixture's vectors are stamped with: it is planted at the small
    /// encoder's paths.
    const SMALL: i64 = 2;

    /// The hand-written encoder, in a directory that outlives it: the model
    /// maps its weights, so the file has to stay while the tests run.
    fn model() -> (tempfile::TempDir, EmbedModel) {
        let dir = tempfile::tempdir().unwrap();
        let model = EmbedModel::load(&fixture::write_model(dir.path()))
            .unwrap()
            .unwrap();
        (dir, model)
    }

    fn described(db: &Db, name: &str, genres: &str, cast: &str, overview: &str) -> i64 {
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
        db.upsert_metadata(&MetadataRecord {
            title_id: id,
            tmdb_id: Some(id),
            overview_fr: Some(overview.to_string()),
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
            fetched_at: 100,
            critics: None,
            audience: None,
            release_date: None,
        })
        .unwrap();
        id
    }

    /// Four described titles. Every one of them gets a vector: the encoder
    /// tokenizes into subwords, so unlike the table it replaced there is no
    /// such thing as a text it has no word for.
    fn library() -> (Mutex<Db>, [i64; 4]) {
        let db = Db::open_in_memory().unwrap();
        let dune = described(&db, "dune", "science,fiction", "epice", "dune desert epice");
        let desert = described(&db, "desert", "science,fiction", "", "desert dune");
        let alien = described(&db, "alien", "horreur", "", "alien horreur");
        let mute = described(&db, "xylophone", "", "", "");
        (Mutex::new(db), [dune, desert, alien, mute])
    }

    #[test]
    fn a_batch_embeds_what_it_reaches_and_the_next_one_walks_forward() {
        let (db, ids) = library();
        let (_dir, model) = model();

        let stats = embed_pending(&db, &model, 2, NOW, &Slice::open()).unwrap();
        assert_eq!(stats.attempted, 2);
        assert_eq!(stats.embedded, 2);
        assert_eq!(stats.skipped, 0);
        assert_eq!(db.lock().vectors(SMALL, 100).unwrap().len(), 2);

        let stats = embed_pending(&db, &model, 2, NOW, &Slice::open()).unwrap();
        assert_eq!(stats.attempted, 2);
        assert_eq!(stats.embedded, 2);
        let vectors = db.lock().vectors(SMALL, 100).unwrap();
        assert_eq!(vectors.len(), 4);
        assert!(vectors.iter().any(|v| v.title_id == ids[3]));

        // the queue is empty, and stays empty
        let stats = embed_pending(&db, &model, 10, NOW, &Slice::open()).unwrap();
        assert_eq!(stats.attempted, 0);
        assert_eq!(stats.embedded, 0);
    }

    #[test]
    fn a_batch_stops_at_the_title_its_deadline_ran_out_on() {
        // a forward pass is the most expensive item on any of the queues, and
        // what it costs is the device's, not ours: sizing a batch in titles
        // decides how long it runs only if you already know the device. So the
        // batch below is given far less time than its queue needs, and what is
        // asserted is that it stopped somewhere in the middle of it - not at
        // the first title, which a deadline read once on the way in would do,
        // and not at the last, which is the bug.
        let db = Db::open_in_memory().unwrap();
        // the anchors are banked already: the budget is the titles' alone
        for (key, _) in SEASONS.iter().chain(&MOODS) {
            db.put_anchor_vector(key, SMALL, &[1]).unwrap();
        }
        for i in 0..40 {
            described(
                &db,
                &format!("film {i:03}"),
                "science,fiction",
                "epice",
                "dune desert epice alien horreur space",
            );
        }
        let db = Mutex::new(db);
        let (_dir, model) = model();

        // a budget of a few forward passes on this machine, the fastest of a
        // handful: a fixed one is a coin toss in a debug build under load
        let budget = (0..5)
            .map(|_| {
                let started = std::time::Instant::now();
                model
                    .embed("film. dune desert epice alien horreur space")
                    .unwrap();
                started.elapsed()
            })
            .min()
            .unwrap()
            * 4;
        // A batch preempted past its deadline before its first title wrote
        // nothing and is run again; one that reads it on the way in never
        // gets past zero.
        let running = AtomicBool::new(false);
        let cut = (0..5)
            .map(|_| embed_pending(&db, &model, 40, NOW, &Slice::of(budget, &running)).unwrap())
            .find(|cut| cut.attempted >= 1)
            .expect("the deadline was read before the batch did anything at all");
        assert!(
            cut.attempted < 40,
            "the deadline passed and the batch held the thread to the end of \
             its queue: {} titles",
            cut.attempted
        );
        assert_eq!(cut.embedded, cut.attempted, "what it reached, it banked");

        // and the queue kept its place: the titles it did not reach are still
        // owed a vector, and the ones it did are not asked for again
        assert_eq!(
            db.lock().vectors(SMALL, 100).unwrap().len(),
            cut.attempted as usize
        );
        let rest = embed_pending(&db, &model, 40, NOW, &Slice::open()).unwrap();
        assert_eq!(
            rest.attempted,
            40 - cut.attempted,
            "the batch that resumed started the queue over"
        );
    }

    #[test]
    fn a_pause_stops_the_anchors_too() {
        let (db, _) = library();
        let (_dir, model) = model();
        let paused = AtomicBool::new(true);
        let cut = embed_pending(
            &db,
            &model,
            10,
            NOW,
            &Slice::of(Duration::from_secs(3600), &paused),
        )
        .unwrap();
        assert_eq!(cut.attempted, 0);
        let keys: Vec<&str> = SEASONS.iter().chain(&MOODS).map(|(key, _)| *key).collect();
        let missing = db.lock().anchors_missing(&keys, SMALL).unwrap();
        assert_eq!(
            missing.len(),
            keys.len(),
            "an anchor was embedded behind the film"
        );
    }

    #[test]
    fn a_pause_stops_the_batch_where_it_stands_however_long_it_had_left() {
        // the deadline is an hour away here, so the only thing that can end
        // this batch is the flag a viewer pressing play sets. Two hundred
        // titles are queued and the flag goes up while the encoder is working
        // through them.
        let db = Db::open_in_memory().unwrap();
        // the anchors are banked already: the budget is the titles' alone
        for (key, _) in SEASONS.iter().chain(&MOODS) {
            db.put_anchor_vector(key, SMALL, &[1]).unwrap();
        }
        for i in 0..200 {
            described(
                &db,
                &format!("film {i:03}"),
                "science,fiction",
                "epice",
                "dune desert epice alien horreur space",
            );
        }
        let db = Mutex::new(db);
        let (_dir, model) = model();

        // a few forward passes on this machine, as in the deadline test above
        let press = (0..5)
            .map(|_| {
                let started = std::time::Instant::now();
                model
                    .embed("film. dune desert epice alien horreur space")
                    .unwrap();
                started.elapsed()
            })
            .min()
            .unwrap()
            * 4;
        // as above, a batch the press beat to its first title is run again
        let paused = AtomicBool::new(false);
        let cut = (0..5)
            .map(|_| {
                paused.store(false, Ordering::Relaxed);
                std::thread::scope(|threads| {
                    threads.spawn(|| {
                        std::thread::sleep(press);
                        paused.store(true, Ordering::Relaxed);
                    });
                    embed_pending(
                        &db,
                        &model,
                        200,
                        NOW,
                        &Slice::of(Duration::from_secs(3600), &paused),
                    )
                    .unwrap()
                })
            })
            .find(|cut| cut.attempted >= 1)
            .expect("the batch did nothing at all");
        assert!(
            cut.attempted < 200,
            "the film waited on {} more titles: the flag is read between \
             batches and not between titles",
            200 - cut.attempted
        );
    }

    #[test]
    fn a_description_that_did_not_move_is_not_embedded_twice() {
        let (db, ids) = library();
        let (_dir, model) = model();
        embed_pending(&db, &model, 10, NOW, &Slice::open()).unwrap();
        let before = db.lock().vectors(SMALL, 100).unwrap();

        // a Plex sync rewrites the same row with a newer timestamp, which is
        // what every scan does
        {
            let guard = db.lock();
            let row = guard.metadata(ids[0]).unwrap().unwrap();
            guard
                .upsert_metadata(&MetadataRecord {
                    fetched_at: NOW + 5,
                    collections: String::new(),
                    director_names: String::new(),
                    writer_names: String::new(),
                    composer_names: String::new(),
                    source: MetadataSource::Plex,
                    critics: None,
                    audience: None,
                    release_date: None,
                    ..row
                })
                .unwrap();
        }
        let stats = embed_pending(&db, &model, 10, NOW + 10, &Slice::open()).unwrap();
        assert_eq!(stats.attempted, 1);
        assert_eq!(stats.embedded, 0);
        assert_eq!(stats.skipped, 1);
        // and the vector it was already holding is still there
        assert_eq!(db.lock().vectors(SMALL, 100).unwrap(), before);
        // and it is not owed a look again either
        assert_eq!(
            embed_pending(&db, &model, 10, NOW + 20, &Slice::open())
                .unwrap()
                .attempted,
            0
        );

        // a description that really moved is embedded again
        {
            let guard = db.lock();
            let row = guard.metadata(ids[0]).unwrap().unwrap();
            guard
                .upsert_metadata(&MetadataRecord {
                    overview_fr: Some("alien horreur".into()),
                    fetched_at: NOW + 25,
                    critics: None,
                    audience: None,
                    release_date: None,
                    ..row
                })
                .unwrap();
        }
        let stats = embed_pending(&db, &model, 10, NOW + 30, &Slice::open()).unwrap();
        assert_eq!(stats.embedded, 1);
    }

    #[test]
    fn the_saga_a_title_belongs_to_is_part_of_what_it_reads_as() {
        let db = Db::open_in_memory().unwrap();
        let alien = described(&db, "alien", "horreur", "", "alien horreur");
        let db = Mutex::new(db);
        let (_dir, model) = model();
        embed_pending(&db, &model, 10, NOW, &Slice::open()).unwrap();
        let before = db.lock().vectors(SMALL, 100).unwrap();

        // the saga lands on the row, and it is the only thing about the title
        // that moves
        {
            let guard = db.lock();
            let row = guard.metadata(alien).unwrap().unwrap();
            guard
                .upsert_metadata(&MetadataRecord {
                    collections: "dune".into(),
                    fetched_at: NOW + 5,
                    critics: None,
                    audience: None,
                    release_date: None,
                    ..row
                })
                .unwrap();
        }

        let stats = embed_pending(&db, &model, 10, NOW + 10, &Slice::open()).unwrap();
        assert_eq!(stats.embedded, 1);
        assert_eq!(stats.skipped, 0);
        let after = db.lock().vectors(SMALL, 100).unwrap();
        assert_ne!(after[0].vector, before[0].vector);
    }

    #[test]
    fn the_director_is_read_before_the_genres_and_the_synopsis() {
        let text = embed_text(&PendingEmbed {
            keywords: String::new(),
            title_id: 1,
            kind: crate::index::MediaKind::Movie,
            name: "Un prophete".into(),
            year: Some(2009),
            genres: "Policier,Drame".into(),
            collections: String::new(),
            cast_names: "Tahar Rahim,Niels Arestrup".into(),
            director_names: "Jacques Audiard".into(),
            writer_names: "Thomas Bidegain".into(),
            composer_names: "Alexandre Desplat".into(),
            overview: "Condamne a six ans de prison.".into(),
            source_hash: None,
        });
        assert_eq!(
            text,
            "Un prophete 2009. Jacques Audiard. Policier,Drame. \
             Tahar Rahim,Niels Arestrup. Thomas Bidegain. Alexandre Desplat. \
             Condamne a six ans de prison."
        );
        // the order is the ranking: an encoder that reads word order weighs
        // the front hardest, and the synopsis is the only part long enough for
        // a token cap to take
        let at = |needle: &str| text.find(needle).unwrap();
        assert!(at("Jacques Audiard") < at("Policier"));
        assert!(at("Tahar Rahim") < at("Thomas Bidegain"));
        assert!(at("Alexandre Desplat") < at("Condamne"));
    }

    #[test]
    fn a_crew_nobody_named_leaves_no_gap_in_what_a_title_reads_as() {
        // an unmatched home movie has no crew at all, and its text must not
        // carry the empty segments where one would have been
        let text = embed_text(&PendingEmbed {
            keywords: String::new(),
            title_id: 1,
            kind: crate::index::MediaKind::Movie,
            name: "Vacances".into(),
            year: None,
            genres: String::new(),
            collections: String::new(),
            cast_names: String::new(),
            director_names: String::new(),
            writer_names: String::new(),
            composer_names: String::new(),
            overview: "Le camescope de 1998.".into(),
            source_hash: None,
        });
        assert_eq!(text, "Vacances. Le camescope de 1998.");
    }

    #[test]
    fn a_row_another_model_wrote_is_re_embedded_and_not_skipped_forever() {
        let (db, _) = library();
        let (_dir, model) = model();
        embed_pending(&db, &model, 10, NOW, &Slice::open()).unwrap();

        // the artifact changed under the stored rows: they are owed a
        // recompute whatever their description still says
        db.lock()
            .conn()
            .execute("UPDATE embeddings SET model_version = 99", [])
            .unwrap();

        let stats = embed_pending(&db, &model, 10, NOW + 10, &Slice::open()).unwrap();
        assert_eq!(stats.attempted, 4);
        assert_eq!(stats.embedded, 4);
        assert_eq!(stats.skipped, 0);
        assert_eq!(db.lock().vectors(SMALL, 100).unwrap().len(), 4);
        // and the queue drains: the version moved with the vector, so the next
        // pass is not handed the same head again
        assert_eq!(
            embed_pending(&db, &model, 10, NOW + 20, &Slice::open())
                .unwrap()
                .attempted,
            0
        );
    }

    #[test]
    fn another_encoder_owes_every_title_and_anchor_a_vector_of_its_own() {
        let (db, _) = library();
        let (dir, model) = model();
        embed_pending(&db, &model, 10, NOW, &Slice::open()).unwrap();

        // the same files read as the other encoder: nothing the first one
        // wrote counts for it, however unchanged the descriptions are
        let mut artifact = crate::embed::download::ModelSource::default().artifact(dir.path());
        artifact.encoder = crate::embed::Encoder::Base;
        let base = EmbedModel::load(&artifact).unwrap().unwrap();
        let stats = embed_pending(&db, &base, 10, NOW + 10, &Slice::open()).unwrap();
        assert_eq!((stats.attempted, stats.embedded, stats.skipped), (4, 4, 0));

        let guard = db.lock();
        let v = crate::embed::Encoder::Base.version();
        assert_eq!(guard.vectors(v, 100).unwrap().len(), 4);
        // each encoder keeps its own: the small vectors stand beside the base
        // ones, and neither read ever returns the other's
        assert_eq!(guard.vectors(SMALL, 100).unwrap().len(), 4);
        assert!(guard
            .anchors_missing(&["light", "oct"], v)
            .unwrap()
            .is_empty());
    }

    #[test]
    fn coming_back_to_the_small_encoder_owes_it_nothing() {
        let (db, _) = library();
        let (dir, small) = model();
        embed_pending(&db, &small, 10, NOW, &Slice::open()).unwrap();
        let before = db.lock().vectors(SMALL, 100).unwrap();

        let mut artifact = crate::embed::download::ModelSource::default().artifact(dir.path());
        artifact.encoder = crate::embed::Encoder::Base;
        let base = EmbedModel::load(&artifact).unwrap().unwrap();
        embed_pending(&db, &base, 10, NOW + 10, &Slice::open()).unwrap();

        let back = embed_pending(&db, &small, 10, NOW + 20, &Slice::open()).unwrap();
        assert_eq!(back.attempted, 0, "the small vectors were owed again");
        assert_eq!(db.lock().vectors(SMALL, 100).unwrap(), before);
    }

    /// The width of the hand-written vectors below: one dimension the whole
    /// shelf shares a little of, sixteen a single film each, and three the
    /// trilogy tells itself apart with.
    const WIDTH: usize = 20;

    /// A title with a vector and nothing else, which is all a sweep reads.
    fn vectorised(db: &Db, kind: MediaKind, name: &str, vector: &[i8]) -> i64 {
        let id = db.upsert_title(kind, name, None).unwrap();
        db.upsert_embedding(&EmbeddingRecord {
            title_id: id,
            model_version: SMALL,
            source_hash: 0,
            vector: vector.to_vec(),
            computed_at: 1,
        })
        .unwrap();
        id
    }

    /// A shelf shaped like a real one: a trilogy whose three films are nearly
    /// the same film (cosine 0.998 between any two), and sixteen singles
    /// fanned out around it, each a little nearer it than the last and none
    /// closer than 0.15. Vectors are written in rather than embedded, so what
    /// every similarity is worth is on the page.
    fn shelf() -> (Mutex<Db>, [i64; 3], Vec<i64>) {
        let db = Db::open_in_memory().unwrap();
        let mut trilogy = [0i64; 3];
        for (i, name) in ["dune", "dune two", "dune three"].iter().enumerate() {
            let mut v = vec![0i8; WIDTH];
            v[0] = 100;
            v[WIDTH - 3 + i] = 5;
            trilogy[i] = vectorised(&db, MediaKind::Movie, name, &v);
        }
        let singles: Vec<i64> = (0..16)
            .map(|k| {
                let mut v = vec![0i8; WIDTH];
                v[0] = k as i8;
                v[1 + k] = 100;
                vectorised(&db, MediaKind::Movie, &format!("single {k}"), &v)
            })
            .collect();
        (Mutex::new(db), trilogy, singles)
    }

    /// The neighbours stored for one title, best first, the sentinel skipped.
    fn stored(db: &Mutex<Db>, title_id: i64) -> Vec<i64> {
        let guard = db.lock();
        let mut stmt = guard
            .conn()
            .prepare(
                "SELECT similar_title_id FROM similar_semantic
                 WHERE title_id = ?1 AND similar_title_id <> 0 ORDER BY rank",
            )
            .unwrap();
        let rows = stmt.query_map([title_id], |r| r.get(0)).unwrap();
        rows.collect::<Result<_, _>>().unwrap()
    }

    #[test]
    fn a_full_sweep_links_every_vectorised_title_to_the_nearest_of_its_kind() {
        let (db, trilogy, _singles) = shelf();
        // a show that is the same film as the trilogy's first, and must still
        // not turn up in a movie's neighbours
        {
            let mut v = vec![0i8; WIDTH];
            v[0] = 100;
            vectorised(&db.lock(), MediaKind::Show, "dune the series", &v);
        }

        // one sweep, wide enough to reach every vectorised title in a batch
        let stats =
            semantic_pending(&db, &Mutex::new(None), SMALL, 100, NOW, &Slice::open()).unwrap();
        assert_eq!(stats.attempted, 20);

        // the two films it is one of, in order, and neither the show nor the
        // nearest of the singles behind them
        assert_eq!(stored(&db, trilogy[0]), vec![trilogy[1], trilogy[2]]);
        // the show was the only one of its kind, so it has nothing to be near
        assert_eq!(stats.linked, 3);
        assert_eq!(stats.empty, 17);

        // a title whose neighbours are already fresh is not recomputed
        assert_eq!(
            semantic_pending(&db, &Mutex::new(None), SMALL, 100, NOW + 1, &Slice::open())
                .unwrap()
                .attempted,
            0
        );
    }

    /// The shelf a sentence encoder actually writes: one large component every
    /// title carries - the language, the register, that this is a film at all -
    /// and a much smaller remainder that is the only part telling two of them
    /// apart. Two of these titles are the same film twice, at a raw cosine of
    /// 0.9997.
    ///
    /// Read raw, they are still lost. What varies most across the shelf is not
    /// what the titles are about but how much of each one is the shared
    /// component, so the spread of an ordinary cosine here is 0.065 while the
    /// pair beats an ordinary neighbour by 0.02. The floor lands above 1.0 and
    /// the shelf keeps nothing at all. Measured from the library's own centre,
    /// the shared part is gone from both ends and the pair is the only thing
    /// left standing.
    #[test]
    fn a_pair_under_a_component_the_whole_shelf_shares_is_still_a_pair() {
        let db = Db::open_in_memory().unwrap();
        // seventeen titles pointing seventeen ways, each carrying the shared
        // component in a different proportion - a one-line synopsis is nearly
        // all shared component, a long one much less so
        let singles: Vec<i64> = (0..17)
            .map(|k| {
                let mut v = vec![0i8; WIDTH];
                v[0] = 100;
                v[1 + k] = 20 + 4 * k as i8;
                vectorised(&db, MediaKind::Movie, &format!("single {k}"), &v)
            })
            .collect();
        // and two that are the same film twice, both of them short
        let mut pair = [0i64; 2];
        for (i, name) in ["dune", "dune two"].iter().enumerate() {
            let mut v = vec![0i8; WIDTH];
            v[0] = 100;
            v[WIDTH - 2] = 6;
            v[WIDTH - 1] = 3 * i as i8;
            pair[i] = vectorised(&db, MediaKind::Movie, name, &v);
        }
        let db = Mutex::new(db);
        semantic_pending(&db, &Mutex::new(None), SMALL, 100, NOW, &Slice::open()).unwrap();

        assert_eq!(stored(&db, pair[0]), vec![pair[1]]);
        assert_eq!(stored(&db, pair[1]), vec![pair[0]]);
        // and the seventeen that share only what every title on the shelf has
        // keep nobody: a component held in common is not a resemblance
        for (k, id) in singles.iter().enumerate() {
            assert!(stored(&db, *id).is_empty(), "single {k}");
        }
    }

    #[test]
    fn a_title_only_a_little_nearer_than_the_shelf_around_it_keeps_nothing() {
        let (db, trilogy, singles) = shelf();
        semantic_pending(&db, &Mutex::new(None), SMALL, 100, NOW, &Slice::open()).unwrap();

        // the last single is the one the trilogy is nearest to, and by the
        // widest margin any single has over the fan behind it: 0.15 against a
        // best of 0.02 among its own kind. That is still the top of an
        // ordinary spread rather than a resemblance, and it keeps nothing
        assert!(stored(&db, singles[15]).is_empty());
        // while the trilogy, whose siblings stand right out of the same
        // spread, keeps them and stops
        assert_eq!(stored(&db, trilogy[2]), vec![trilogy[0], trilogy[1]]);
    }

    #[test]
    fn a_title_with_nothing_in_common_yields_no_neighbours_rather_than_weak_ones() {
        let db = Db::open_in_memory().unwrap();
        // bare titles: no genres, no cast, no overview, so their vectors carry
        // only their own name and share not even a punctuation token
        let dune = described(&db, "dune", "", "", "");
        let alien = described(&db, "alien", "", "", "");
        let (_dir, model) = model();
        let db = Mutex::new(db);
        embed_pending(&db, &model, 10, NOW, &Slice::open()).unwrap();

        let stats =
            semantic_pending(&db, &Mutex::new(None), SMALL, 10, NOW, &Slice::open()).unwrap();
        assert_eq!(stats.attempted, 2);
        assert_eq!(stats.linked, 0);
        assert_eq!(stats.empty, 2);

        let guard = db.lock();
        for title_id in [dune, alien] {
            let near: i64 = guard
                .conn()
                .query_row(
                    "SELECT COUNT(*) FROM similar_semantic
                     WHERE title_id = ?1 AND similar_title_id <> 0",
                    [title_id],
                    |r| r.get(0),
                )
                .unwrap();
            assert_eq!(near, 0);
        }
    }

    /// Every title with at least one row in `similar_semantic`, for a test to
    /// say how much of a sweep has landed so far.
    fn linked_titles(db: &Mutex<Db>) -> Vec<i64> {
        let guard = db.lock();
        let mut stmt = guard
            .conn()
            .prepare("SELECT DISTINCT title_id FROM similar_semantic ORDER BY title_id")
            .unwrap();
        let rows = stmt.query_map([], |r| r.get(0)).unwrap();
        rows.collect::<Result<_, _>>().unwrap()
    }

    #[test]
    fn a_sweep_reads_the_library_once_and_the_next_batch_measures_against_it() {
        // reading and centring the library costs more than the seeds a batch
        // does, and every seed in the sweep wants the same answer
        let (db, _trilogy, _singles) = shelf();
        let held = Mutex::new(None);

        let first = semantic_pending(&db, &held, SMALL, 5, NOW, &Slice::open()).unwrap();
        assert!(first.read_library, "the first batch has nothing to reuse");
        assert_eq!(first.attempted, 5);

        let second = semantic_pending(&db, &held, SMALL, 5, NOW, &Slice::open()).unwrap();
        assert!(
            !second.read_library,
            "the vector table stood still, so the library did too"
        );
        assert_eq!(second.attempted, 5);
    }

    #[test]
    fn a_library_of_real_hashes_can_be_stamped_at_all() {
        // source_hash is FNV over the embedded text and uses the whole of an
        // i64: SQLite answers a sum of integers that overflows with an error,
        // not a number, and a sweep that cannot stamp its library cannot run
        let db = Db::open_in_memory().unwrap();
        for (i, hash) in [i64::MAX, i64::MAX - 1, i64::MIN].iter().enumerate() {
            let id = db
                .upsert_title(MediaKind::Movie, &format!("film {i}"), None)
                .unwrap();
            db.upsert_embedding(&EmbeddingRecord {
                title_id: id,
                model_version: SMALL,
                source_hash: *hash,
                vector: vec![1i8; WIDTH],
                computed_at: 1,
            })
            .unwrap();
        }
        let stamp = db.embedding_stamp(SMALL).unwrap();
        assert_eq!(stamp.0, 3, "{stamp:?}");
    }

    #[test]
    fn a_title_re_embedded_between_batches_is_not_measured_against_the_older_library() {
        // the centre is the mean of the library, so a vector that moved helped
        // define the direction every cosine is measured from: reusing the
        // library it predates would place every later seed against a centre
        // that no longer exists
        let (db, trilogy, _singles) = shelf();
        let held = Mutex::new(None);
        semantic_pending(&db, &held, SMALL, 5, NOW, &Slice::open()).unwrap();

        // the same title, a different film: the count is unchanged, so only the
        // source hash says the library moved
        let mut moved = vec![0i8; WIDTH];
        moved[WIDTH - 1] = 100;
        db.lock()
            .upsert_embedding(&EmbeddingRecord {
                title_id: trilogy[0],
                model_version: SMALL,
                source_hash: 99,
                vector: moved,
                computed_at: 2,
            })
            .unwrap();

        let after = semantic_pending(&db, &held, SMALL, 5, NOW, &Slice::open()).unwrap();
        assert!(
            after.read_library,
            "a vector moved under the library, so it has to be read again"
        );
    }

    #[test]
    fn a_sweep_stopped_after_one_batch_resumes_instead_of_restarting() {
        let (db, ids) = library();
        let (_dir, model) = model();
        embed_pending(&db, &model, 100, NOW, &Slice::open()).unwrap();

        // the sweep is interrupted after its first title
        let first =
            semantic_pending(&db, &Mutex::new(None), SMALL, 1, NOW, &Slice::open()).unwrap();
        assert_eq!(first.attempted, 1);
        assert_eq!(linked_titles(&db), vec![ids[0]]);

        // resuming reaches the rest without redoing dune, whose row stands
        let second =
            semantic_pending(&db, &Mutex::new(None), SMALL, 1, NOW + 1, &Slice::open()).unwrap();
        assert_eq!(second.attempted, 1);
        assert_eq!(linked_titles(&db), vec![ids[0], ids[1]]);

        // and a third batch drains the queue
        assert_eq!(
            semantic_pending(&db, &Mutex::new(None), SMALL, 10, NOW + 2, &Slice::open())
                .unwrap()
                .attempted,
            2
        );
        assert_eq!(
            semantic_pending(&db, &Mutex::new(None), SMALL, 10, NOW + 3, &Slice::open())
                .unwrap()
                .attempted,
            0
        );
    }

    #[test]
    fn a_sweep_stops_at_the_seed_its_deadline_ran_out_on() {
        // one seed here is a scan of every vector in the library, so what a
        // seed costs is the library's own size and no count of them means the
        // same thing on two devices. The vectors are written straight to the
        // index: what is under test is the sweep's own arithmetic, not the
        // encoder's.
        let db = Db::open_in_memory().unwrap();
        for i in 0..500i32 {
            let id = db
                .upsert_title(MediaKind::Movie, &format!("film {i:03}"), Some(2000))
                .unwrap();
            db.upsert_embedding(&EmbeddingRecord {
                title_id: id,
                model_version: SMALL,
                source_hash: i64::from(i),
                vector: (0..384).map(|d| (((d + i) % 61) - 30) as i8).collect(),
                computed_at: NOW,
            })
            .unwrap();
        }
        let db = Mutex::new(db);

        // The library is read and held by a batch stopped before its first
        // seed: on a loaded machine that read alone outlasts the 20 ms.
        let held = Mutex::new(None);
        let stopped = AtomicBool::new(true);
        let warm = semantic_pending(
            &db,
            &held,
            SMALL,
            500,
            NOW + 1,
            &Slice::of(Duration::from_secs(60), &stopped),
        )
        .unwrap();
        assert_eq!(warm.attempted, 0);

        let running = AtomicBool::new(false);
        let cut = semantic_pending(
            &db,
            &held,
            SMALL,
            500,
            NOW + 1,
            &Slice::of(Duration::from_millis(20), &running),
        )
        .unwrap();

        assert!(cut.attempted >= 1, "the sweep did nothing at all");
        assert!(
            cut.attempted < 500,
            "the deadline passed and the sweep read the library out: {} seeds",
            cut.attempted
        );

        // the seeds it reached are banked, so the next batch starts at the one
        // it stopped on rather than at the first
        let banked: i64 = db
            .lock()
            .conn()
            .query_row(
                "SELECT COUNT(*) FROM semantic_computed WHERE title_id <> 0",
                [],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(banked, i64::from(cut.attempted));
    }

    /// The real cost of a full sweep, against a real library: point
    /// `LEXIS_BENCH_DB` at a writable copy of an `index.sqlite` (never the
    /// owner's live one) and run with `--ignored --nocapture`. Batches at 500,
    /// the size a background tick can afford, and prints the wall clock and
    /// title count rather than asserting on either: the number belongs in a
    /// report, not in a pass/fail.
    #[test]
    #[ignore]
    fn bench_full_sweep_measures_real_wall_clock() {
        let path = std::env::var("LEXIS_BENCH_DB")
            .expect("set LEXIS_BENCH_DB to a writable copy of index.sqlite");
        let db = Mutex::new(Db::open(std::path::Path::new(&path)).unwrap());
        let now = 2_000_000_000;
        let start = std::time::Instant::now();
        let (mut attempted_total, mut linked_total, mut empty_total, mut batches) =
            (0u32, 0u32, 0u32, 0u32);
        loop {
            let stats =
                semantic_pending(&db, &Mutex::new(None), SMALL, 500, now, &Slice::open()).unwrap();
            if stats.attempted == 0 {
                break;
            }
            attempted_total += stats.attempted;
            linked_total += stats.linked;
            empty_total += stats.empty;
            batches += 1;
        }
        eprintln!(
            "full sweep: {attempted_total} titles, {batches} batches, \
             {linked_total} linked, {empty_total} empty, {:?} wall clock",
            start.elapsed()
        );
    }

    /// What a full embed pass costs and what it produces, against a real
    /// library: point `LEXIS_BENCH_DB` at a writable copy of an `index.sqlite`
    /// (never the owner's live one) and `LEXIS_BENCH_WEIGHTS`,
    /// `LEXIS_BENCH_TOKENIZER` and `LEXIS_BENCH_CONFIG` at the pinned files, then run with `--ignored
    /// --nocapture`. `LEXIS_BENCH_PROBES` is a comma-separated list of title
    /// ids whose neighbours are printed at the end.
    ///
    /// Prints rather than asserts: the numbers belong in a report, and what
    /// the neighbours are worth is a judgement no assertion can make.
    #[test]
    #[ignore]
    fn bench_embed_pass_over_a_real_library() {
        use crate::embed::download::Artifact;
        use std::path::PathBuf;

        let path = std::env::var("LEXIS_BENCH_DB")
            .expect("set LEXIS_BENCH_DB to a writable copy of index.sqlite");
        let artifact = Artifact {
            encoder: crate::embed::Encoder::Small,
            weights: PathBuf::from(std::env::var("LEXIS_BENCH_WEIGHTS").unwrap()),
            tokenizer: PathBuf::from(std::env::var("LEXIS_BENCH_TOKENIZER").unwrap()),
            config: PathBuf::from(std::env::var("LEXIS_BENCH_CONFIG").unwrap()),
        };
        let loading = std::time::Instant::now();
        let model = EmbedModel::load(&artifact).unwrap().unwrap();
        eprintln!(
            "model: {} dims, {} layers, loaded in {:?}",
            model.dims(),
            model.layers(),
            loading.elapsed()
        );

        // how many titles to embed before stopping, for comparing one build
        // against another without waiting out the whole library
        let cap: u32 = std::env::var("LEXIS_BENCH_LIMIT")
            .ok()
            .and_then(|v| v.parse().ok())
            .unwrap_or(u32::MAX);

        let db = Mutex::new(Db::open(std::path::Path::new(&path)).unwrap());
        let now = 2_000_000_000;
        let start = std::time::Instant::now();
        let (mut attempted, mut embedded) = (0u32, 0u32);
        while embedded < cap {
            let stats =
                embed_pending(&db, &model, 200.min(cap - embedded), now, &Slice::open()).unwrap();
            if stats.attempted == 0 {
                break;
            }
            attempted += stats.attempted;
            embedded += stats.embedded;
            eprint!("\r  embedded {embedded} in {:?}   ", start.elapsed());
        }
        let embed_time = start.elapsed();
        eprintln!(
            "\nembed pass: {attempted} titles, {embedded} vectors, {embed_time:?} wall clock, \
             {:.1} ms per title",
            embed_time.as_secs_f64() * 1000.0 / f64::from(embedded.max(1))
        );

        let start = std::time::Instant::now();
        let (mut swept, mut linked) = (0u32, 0u32);
        loop {
            let stats =
                semantic_pending(&db, &Mutex::new(None), SMALL, 500, now, &Slice::open()).unwrap();
            if stats.attempted == 0 {
                break;
            }
            swept += stats.attempted;
            linked += stats.linked;
        }
        eprintln!(
            "sweep: {swept} titles, {linked} linked, {:?} wall clock",
            start.elapsed()
        );

        let guard = db.lock();
        for probe in std::env::var("LEXIS_BENCH_PROBES")
            .unwrap_or_default()
            .split(',')
            .filter_map(|s| s.trim().parse::<i64>().ok())
        {
            let mut name = guard
                .conn()
                .prepare("SELECT name, year FROM titles WHERE id = ?")
                .unwrap();
            let (title, year): (String, i64) = name
                .query_row([probe], |r| Ok((r.get(0)?, r.get(1)?)))
                .unwrap();
            eprintln!("\n### {title} ({year})  [id {probe}]");
            let mut stmt = guard
                .conn()
                .prepare(
                    "SELECT t.name, t.year, s.score FROM similar_semantic s \
                     JOIN titles t ON t.id = s.similar_title_id \
                     WHERE s.title_id = ? ORDER BY s.rank LIMIT 10",
                )
                .unwrap();
            let rows = stmt
                .query_map([probe], |r| {
                    Ok((
                        r.get::<_, String>(0)?,
                        r.get::<_, i64>(1)?,
                        r.get::<_, i64>(2)?,
                    ))
                })
                .unwrap();
            for (i, row) in rows.enumerate() {
                let (n, y, score) = row.unwrap();
                eprintln!("   {i:2}. {:.4}  {n} ({y})", score as f64 / 10_000.0);
            }
        }
    }
}
