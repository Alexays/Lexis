use super::client::{TmdbClient, TmdbError};
use crate::index::db::{Db, IndexError};
use crate::index::MediaKind;
use crate::slice::Slice;
use parking_lot::Mutex;
use std::collections::HashSet;

/// What one home row can show. TMDB answers twenty results a page, and the
/// tail of a similarity list is noise anyway.
pub const MAX_SIMILAR: usize = 20;

#[derive(Debug, Default, Clone, PartialEq, Eq)]
pub struct SimilarStats {
    pub attempted: u32,
    /// Titles TMDB named at least one neighbour for.
    pub linked: u32,
    pub failed: u32,
    /// Seconds TMDB asked to be left alone for, 0 when it did not. The batch
    /// stopped where it stood; the queue kept its place.
    pub retry_after_secs: u32,
}

#[derive(Debug, thiserror::Error)]
pub enum SimilarError {
    #[error("index error: {0}")]
    Index(#[from] IndexError),
    #[error("the TMDB key was rejected")]
    Unauthorized,
}

/// Fetches the similar list of at most `limit` matched titles that have none.
/// Every title it reaches is recorded, empty answer included, so calling it
/// again walks forward instead of retrying the same head of the queue. This is
/// the only network any home row needs: `home_rows` itself never leaves the
/// device.
///
/// It takes the write connection, never across a request: the batch is read
/// under the guard, each answer is written under it again, and a report or a
/// scan can run in between. A title purged mid-batch leaves rows keyed on a
/// tmdb_id no metadata row carries, which every reader joins away.
pub fn fetch_similar_pending(
    db: &Mutex<Db>,
    client: &TmdbClient,
    limit: u32,
    slice: &Slice,
) -> Result<SimilarStats, SimilarError> {
    let pending = db.lock().titles_needing_similar(limit)?;
    let mut stats = SimilarStats::default();
    for title in &pending {
        // each answer is written as it lands, so the titles already linked
        // stand and the rest of the queue is untouched
        if slice.expired() {
            return Ok(stats);
        }
        let fetched = match title.kind {
            MediaKind::Movie => client.recommended_movies(title.tmdb_id),
            MediaKind::Show => client.recommended_shows(title.tmdb_id),
        };
        let mut ids = match fetched {
            Ok(ids) => ids,
            // a rejected key fails every remaining title the same way: stop and
            // let the UI ask for a new one
            Err(TmdbError::Unauthorized) => return Err(SimilarError::Unauthorized),
            // so does a rate limit, and it says how long for: the rest of the
            // queue is intact, and the next call picks it up where this
            // stopped rather than spending itself collecting the same 429
            Err(TmdbError::RateLimited { retry_after_secs }) => {
                stats.retry_after_secs = retry_after_secs;
                return Ok(stats);
            }
            // one failed request must not cost the rest of the batch; the title
            // keeps no rows, so the next run picks it up again
            Err(_) => {
                stats.attempted += 1;
                stats.failed += 1;
                continue;
            }
        };
        stats.attempted += 1;
        // TMDB pages its similar lists and a title can sit on two of them; a
        // repeated id would fail the whole write on the primary key
        let mut seen = HashSet::with_capacity(ids.len());
        ids.retain(|id| seen.insert(*id));
        ids.truncate(MAX_SIMILAR);
        if !ids.is_empty() {
            stats.linked += 1;
        }
        db.lock().upsert_similar(title.tmdb_id, title.kind, &ids)?;
    }
    Ok(stats)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::index::db::MetadataRecord;
    use crate::index::db::MetadataSource;
    use crate::metadata::fake::tmdb;
    use crate::plex::fake::{FakeServer, Reply};

    /// Three matched titles: a movie TMDB has neighbours for, a show it also
    /// has one for, and a movie it knows nothing similar to.
    fn seeded() -> Mutex<Db> {
        let db = Db::open_in_memory().unwrap();
        for (kind, name, year, tmdb_id) in [
            (MediaKind::Movie, "Dune", Some(2021), 438631),
            (MediaKind::Show, "The Expanse", None, 63639),
            (MediaKind::Movie, "Solaris", Some(1972), 762),
        ] {
            let title_id = db.upsert_title(kind, name, year).unwrap();
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
        Mutex::new(db)
    }

    /// The ids stored for one title, in the order a home row shows them.
    fn linked(db: &Mutex<Db>, tmdb_id: i64) -> Vec<i64> {
        db.lock()
            .conn()
            .prepare(
                "SELECT similar_tmdb_id FROM tmdb_similar
                 WHERE tmdb_id = ?1 AND similar_tmdb_id <> 0 ORDER BY rank",
            )
            .unwrap()
            .query_map([tmdb_id], |r| r.get(0))
            .unwrap()
            .collect::<Result<_, _>>()
            .unwrap()
    }

    #[test]
    fn a_batch_links_what_it_can_and_stops_asking_about_the_rest() {
        let server = tmdb();
        let db = seeded();
        let client = TmdbClient::new(&server.base_url, "k");

        let stats = fetch_similar_pending(&db, &client, 10, &Slice::open()).unwrap();
        assert_eq!(stats.attempted, 3);
        assert_eq!(stats.linked, 2);
        assert_eq!(stats.failed, 0);
        assert_eq!(linked(&db, 438631), vec![78, 762, 11111]);

        // a show asks the tv endpoint, not the movie one
        assert!(server
            .requests()
            .iter()
            .any(|r| r.url.starts_with("/tv/63639/recommendations")));

        // nothing is left pending, so a second call costs no request
        let before = server.requests().len();
        assert_eq!(
            fetch_similar_pending(&db, &client, 10, &Slice::open())
                .unwrap()
                .attempted,
            0
        );
        assert_eq!(server.requests().len(), before);
    }

    #[test]
    fn a_batch_is_resumable_one_limit_at_a_time() {
        let server = tmdb();
        let db = seeded();
        let client = TmdbClient::new(&server.base_url, "k");
        assert_eq!(
            fetch_similar_pending(&db, &client, 2, &Slice::open())
                .unwrap()
                .attempted,
            2
        );
        assert_eq!(db.lock().titles_needing_similar(10).unwrap().len(), 1);
        assert_eq!(
            fetch_similar_pending(&db, &client, 2, &Slice::open())
                .unwrap()
                .attempted,
            1
        );
        assert_eq!(
            fetch_similar_pending(&db, &client, 2, &Slice::open())
                .unwrap()
                .attempted,
            0
        );
    }

    #[test]
    fn a_failed_request_costs_one_title_and_is_retried_next_run() {
        let db = seeded();
        let server = FakeServer::start(|req| {
            if req.url.starts_with("/movie/438631/recommendations") {
                return Reply::json(r#"{"results":[{"id":78}]}"#);
            }
            Reply::status(503)
        });
        let client = TmdbClient::new(&server.base_url, "k");

        let stats = fetch_similar_pending(&db, &client, 10, &Slice::open()).unwrap();
        assert_eq!(stats.attempted, 3);
        assert_eq!(stats.linked, 1);
        assert_eq!(stats.failed, 2);
        // the two that failed kept no rows, so the next run tries them again
        assert_eq!(db.lock().titles_needing_similar(10).unwrap().len(), 2);
    }

    #[test]
    fn a_rate_limited_batch_stops_and_keeps_the_rest_of_its_queue() {
        let db = seeded();
        // the first title is linked, and the next request is refused
        let server = FakeServer::start(|req| {
            if req.url.starts_with("/movie/438631/recommendations") {
                return Reply::json(r#"{"results":[{"id":78}]}"#);
            }
            Reply {
                status: 429,
                headers: vec![("Retry-After".to_string(), "9".to_string())],
                body: Vec::new(),
            }
        });
        let client = TmdbClient::new(&server.base_url, "k");

        let stats = fetch_similar_pending(&db, &client, 10, &Slice::open()).unwrap();
        assert_eq!(stats.attempted, 1);
        assert_eq!(stats.linked, 1);
        assert_eq!(stats.failed, 0);
        assert_eq!(stats.retry_after_secs, 9);
        // the batch stopped at the 429 rather than spending the last title on
        // it, and both are still owed a list
        assert_eq!(server.requests().len(), 2);
        assert_eq!(db.lock().titles_needing_similar(10).unwrap().len(), 2);
    }

    #[test]
    fn a_rejected_key_stops_the_batch_instead_of_burning_it() {
        let db = seeded();
        let server = FakeServer::start(|_req| Reply::status(401));
        let client = TmdbClient::new(&server.base_url, "stale");

        let err = fetch_similar_pending(&db, &client, 10, &Slice::open()).unwrap_err();
        assert!(matches!(err, SimilarError::Unauthorized));
        assert_eq!(server.requests().len(), 1); // it stopped at the first title
        assert_eq!(db.lock().titles_needing_similar(10).unwrap().len(), 3);
    }

    #[test]
    fn a_long_answer_is_cut_to_what_a_row_can_show() {
        let db = seeded();
        let long: Vec<String> = (1..=50).map(|i| format!(r#"{{"id":{i}}}"#)).collect();
        let body = format!(r#"{{"results":[{}]}}"#, long.join(","));
        let server = FakeServer::start(move |_req| Reply::json(&body));
        let client = TmdbClient::new(&server.base_url, "k");

        fetch_similar_pending(&db, &client, 1, &Slice::open()).unwrap();
        let stored: i64 = db
            .lock()
            .conn()
            .query_row(
                "SELECT COUNT(*) FROM tmdb_similar WHERE tmdb_id = 438631 AND similar_tmdb_id <> 0",
                [],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(stored as usize, MAX_SIMILAR);
    }

    #[test]
    fn an_id_two_pages_both_list_is_stored_once() {
        let db = seeded();
        let server = FakeServer::start(|_req| {
            Reply::json(
                r#"{"page":1,"results":[{"id":78},{"id":762},{"id":78},{"id":11111}],
                    "total_pages":2}"#,
            )
        });
        let client = TmdbClient::new(&server.base_url, "k");

        let stats = fetch_similar_pending(&db, &client, 1, &Slice::open()).unwrap();
        assert_eq!(stats.linked, 1);
        assert_eq!(stats.failed, 0);
        assert_eq!(linked(&db, 438631), vec![78, 762, 11111]);
    }
}
