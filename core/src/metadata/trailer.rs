//! A title's trailer: which of TMDB's videos to offer, and when to ask.

use super::client::{TmdbClient, TmdbError};
use super::models::Video;
use crate::index::db::{Db, IndexError};
use parking_lot::Mutex;
use std::cmp::Reverse;

/// The one site this app can send a viewer to. TMDB lists Vimeo alongside it,
/// and there is no Vimeo app on an Apple TV to hand a key to.
const YOUTUBE: &str = "YouTube";

/// How long "TMDB has no trailer for this" stands before it is worth another
/// request. Videos are contributed and are commonly added months after a
/// release, so the answer does change; a month is slow enough that a library
/// of thousands costs nothing to keep current.
pub const RECHECK_SECS: i64 = 30 * 24 * 60 * 60;

#[derive(Debug, thiserror::Error)]
pub enum TrailerError {
    #[error(transparent)]
    Index(#[from] IndexError),
    #[error(transparent)]
    Tmdb(#[from] TmdbError),
}

/// The YouTube key to offer, asking TMDB only when the answer is not already
/// stored.
///
/// A stored key is final: a trailer once chosen is kept, so the button does
/// not point somewhere else under a viewer who has already seen where it goes.
/// Only "there is none" expires, and only after `RECHECK_SECS`.
/// It takes the write connection, never across the request: the row is read
/// under the guard and the answer written under it again, so a playback report
/// is not queued behind somebody else's network.
pub fn trailer(
    db: &Mutex<Db>,
    client: &TmdbClient,
    title_id: i64,
    now: i64,
) -> Result<Option<String>, TrailerError> {
    let Some(state) = db.lock().trailer_state(title_id)? else {
        return Ok(None);
    };
    if let Some(key) = state.key {
        return Ok(Some(key));
    }
    if state.checked_at > 0 && now - state.checked_at < RECHECK_SECS {
        return Ok(None);
    }
    // No id to ask about: the matching pass has not reached this title yet, or
    // never will. Nothing is written, so the day an id lands this asks again.
    let Some(tmdb_id) = state.tmdb_id else {
        return Ok(None);
    };
    let chosen = best(&client.videos(tmdb_id, state.kind)?).map(|v| v.key.clone());
    db.lock().set_trailer(title_id, chosen.as_deref(), now)?;
    Ok(chosen)
}

/// The video to offer, None when TMDB lists nothing worth offering.
///
/// A trailer is a promise about what the film is, so the language it is in
/// comes first: a French viewer sent to an English trailer of a film their
/// library names in French has been sent to the wrong thing, even when it is
/// the better video. Under that, what the studio published beats what a
/// viewer uploaded - an unofficial upload is the one that disappears - and a
/// full trailer beats a teaser. Ties go to the most recent, which for a film
/// with several is the one cut closest to what it became.
///
/// Everything that is neither a trailer nor a teaser is skipped rather than
/// ranked last: a clip, a featurette or a behind-the-scenes is not a worse
/// trailer, it is a different thing, and a button that says "bande-annonce"
/// must not open one.
fn best(videos: &[Video]) -> Option<&Video> {
    videos
        .iter()
        .filter(|v| v.site == YOUTUBE && !v.key.is_empty())
        .filter_map(|v| rank(v).map(|r| (r, v)))
        .min_by(|(left, _), (right, _)| left.cmp(right))
        .map(|(_, v)| v)
}

/// Where one video stands, smallest first; None for one this app would not
/// send a viewer to at all.
fn rank(video: &Video) -> Option<(u8, bool, u8, Reverse<&str>)> {
    Some((
        language_rank(&video.iso_639_1)?,
        !video.official,
        kind_rank(&video.kind)?,
        Reverse(video.published_at.as_str()),
    ))
}

/// None for a language this app would not send a viewer to.
fn language_rank(iso: &str) -> Option<u8> {
    match iso {
        "fr" => Some(0),
        "en" => Some(1),
        // TMDB files a video that belongs to no one language under an empty
        // string. It is nobody's wrong language, so it is offered last rather
        // than skipped.
        "" => Some(2),
        _ => None,
    }
}

/// None for a video that is not a trailer at all.
fn kind_rank(kind: &str) -> Option<u8> {
    match kind {
        "Trailer" => Some(0),
        "Teaser" => Some(1),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::index::db::{MetadataRecord, MetadataSource};
    use crate::index::MediaKind;
    use crate::plex::fake::{FakeServer, Reply};
    use std::sync::atomic::{AtomicUsize, Ordering};
    use std::sync::Arc;

    fn video(key: &str, kind: &str, iso: &str, official: bool, published: &str) -> Video {
        Video {
            key: key.to_string(),
            site: YOUTUBE.to_string(),
            kind: kind.to_string(),
            official,
            iso_639_1: iso.to_string(),
            published_at: published.to_string(),
        }
    }

    #[test]
    fn french_wins_then_english_then_no_language() {
        let all = [
            video("none", "Trailer", "", true, "2024-01-01"),
            video("en", "Trailer", "en", true, "2024-01-01"),
            video("fr", "Trailer", "fr", true, "2024-01-01"),
        ];
        assert_eq!(best(&all).unwrap().key, "fr");
        assert_eq!(best(&all[..2]).unwrap().key, "en");
        assert_eq!(best(&all[..1]).unwrap().key, "none");
        // and a language this library would never draw is not a near miss
        assert!(best(&[video("ru", "Trailer", "ru", true, "2024-01-01")]).is_none());
    }

    #[test]
    fn language_outranks_everything_under_it() {
        // an English official trailer against a French unofficial teaser: the
        // viewer's own language decides, whatever quality says
        let all = [
            video("en", "Trailer", "en", true, "2024-06-01"),
            video("fr", "Teaser", "fr", false, "2023-01-01"),
        ];
        assert_eq!(best(&all).unwrap().key, "fr");
    }

    #[test]
    fn official_beats_an_upload_and_a_trailer_beats_a_teaser() {
        let all = [
            video("upload", "Trailer", "fr", false, "2024-06-01"),
            video("studio", "Teaser", "fr", true, "2023-01-01"),
        ];
        assert_eq!(best(&all).unwrap().key, "studio");

        let both_official = [
            video("teaser", "Teaser", "fr", true, "2024-06-01"),
            video("trailer", "Trailer", "fr", true, "2023-01-01"),
        ];
        assert_eq!(best(&both_official).unwrap().key, "trailer");
    }

    #[test]
    fn the_newest_of_equals_wins() {
        let all = [
            video("first", "Trailer", "fr", true, "2023-01-01"),
            video("final", "Trailer", "fr", true, "2024-06-01"),
        ];
        assert_eq!(best(&all).unwrap().key, "final");
    }

    #[test]
    fn nothing_that_is_not_a_trailer_is_offered() {
        let all = [
            video("clip", "Clip", "fr", true, "2024-06-01"),
            video("making-of", "Featurette", "fr", true, "2024-06-01"),
        ];
        assert!(best(&all).is_none());
    }

    #[test]
    fn a_site_with_nowhere_to_send_a_viewer_is_skipped() {
        let vimeo = Video {
            site: "Vimeo".to_string(),
            ..video("v", "Trailer", "fr", true, "2024-06-01")
        };
        assert!(best(&[vimeo]).is_none());
    }

    /// A title matched to TMDB, so the pass has an id to ask about.
    fn seeded(tmdb_id: Option<i64>) -> (Mutex<Db>, i64) {
        let db = Db::open_in_memory().unwrap();
        let id = db
            .upsert_title(MediaKind::Movie, "Dune", Some(2021))
            .unwrap();
        db.upsert_metadata(&MetadataRecord {
            title_id: id,
            tmdb_id,
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
            source: MetadataSource::Plex,
            fetched_at: 100,
            critics: None,
            audience: None,
            release_date: None,
        })
        .unwrap();
        (Mutex::new(db), id)
    }

    #[test]
    fn a_trailer_is_fetched_once_and_then_read_from_the_row() {
        let server = FakeServer::start(|_req| {
            Reply::json(
                r#"{"id":438631,"videos":{"results":[
                     {"key":"abc","site":"YouTube","type":"Trailer",
                      "official":true,"iso_639_1":"fr","published_at":"2021-01-01"}]}}"#,
            )
        });
        let client = TmdbClient::new(&server.base_url, "k3y");
        let (db, id) = seeded(Some(438631));

        assert_eq!(
            trailer(&db, &client, id, 1_000).unwrap(),
            Some("abc".to_string())
        );
        assert_eq!(server.requests().len(), 1);
        let asked = &server.requests()[0].url;
        assert!(asked.starts_with("/movie/438631"), "{asked}");
        assert!(asked.contains("append_to_response=videos"), "{asked}");
        assert!(
            asked.contains("include_video_language=fr%2Cen%2Cnull"),
            "{asked}"
        );

        // and never asked for again, even a year on: a key once chosen stands
        assert_eq!(
            trailer(&db, &client, id, 1_000 + RECHECK_SECS * 12).unwrap(),
            Some("abc".to_string())
        );
        assert_eq!(server.requests().len(), 1);
    }

    #[test]
    fn a_title_tmdb_lists_no_trailer_for_costs_one_request_a_month() {
        let asked = Arc::new(AtomicUsize::new(0));
        let counted = Arc::clone(&asked);
        let server = FakeServer::start(move |_req| {
            // a trailer added between the first ask and the second, which is
            // the whole reason the stored "none" expires at all
            if counted.fetch_add(1, Ordering::SeqCst) == 0 {
                return Reply::json(r#"{"id":9,"videos":{"results":[]}}"#);
            }
            Reply::json(
                r#"{"id":9,"videos":{"results":[
                     {"key":"late","site":"YouTube","type":"Trailer",
                      "official":true,"iso_639_1":"fr","published_at":"2021-06-01"}]}}"#,
            )
        });
        let client = TmdbClient::new(&server.base_url, "k3y");
        let (db, id) = seeded(Some(9));

        assert!(trailer(&db, &client, id, 1_000).unwrap().is_none());
        assert_eq!(server.requests().len(), 1);
        // every open of the screen in the meantime is answered from the row
        assert!(trailer(&db, &client, id, 1_000).unwrap().is_none());
        assert!(trailer(&db, &client, id, 1_000 + RECHECK_SECS - 1)
            .unwrap()
            .is_none());
        assert_eq!(server.requests().len(), 1);

        assert_eq!(
            trailer(&db, &client, id, 1_000 + RECHECK_SECS).unwrap(),
            Some("late".to_string())
        );
        assert_eq!(server.requests().len(), 2);
    }

    #[test]
    fn a_title_tmdb_never_placed_is_never_asked_about() {
        let server = FakeServer::start(|_req| Reply::json("{}"));
        let client = TmdbClient::new(&server.base_url, "k3y");
        // a row with no id is not a question TMDB can be asked, and nothing is
        // written, so the day an id lands this asks again
        let (db, id) = seeded(None);
        assert!(trailer(&db, &client, id, 1_000).unwrap().is_none());
        // nor is a title with no metadata row at all
        let bare = Db::open_in_memory().unwrap();
        bare.upsert_title(MediaKind::Movie, "Un film de famille", None)
            .unwrap();
        let bare = Mutex::new(bare);
        assert!(trailer(&bare, &client, 1, 1_000).unwrap().is_none());
        assert!(server.requests().is_empty());
    }
}
