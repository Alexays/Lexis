//! A title's own lettering: which of TMDB's logos to draw, and when to ask.

use super::client::{TmdbClient, TmdbError};
use super::enrich::normalize;
use super::models::LogoImage;
use crate::index::db::{Db, IndexError};
use parking_lot::Mutex;
use std::cmp::Ordering;

/// Logos are drawn at most `treatment.logoHeight` points tall on a 1080p
/// screen, so w500 covers the 2x canvas with room over. The size is part of
/// the path, as it is for the poster and the backdrop.
pub const TMDB_LOGO_BASE: &str = "https://image.tmdb.org/t/p/w500";

/// How a logo path a source stored reads apart from TMDB's, which is a bare
/// file name at the root: a Plex server's is under its library tree.
pub const SOURCE_LOGO_PREFIX: &str = "/library/";

/// The width over height of a PNG, read off its header; None for anything
/// that is not one.
pub fn png_aspect(head: &[u8]) -> Option<f32> {
    if head.len() < 24 || &head[..8] != b"\x89PNG\r\n\x1a\n" {
        return None;
    }
    let width = u32::from_be_bytes(head[16..20].try_into().ok()?);
    let height = u32::from_be_bytes(head[20..24].try_into().ok()?);
    (width > 0 && height > 0).then(|| width as f32 / height as f32)
}

/// How long "TMDB has no logo for this" stands before it is worth another
/// request. Logos are contributed, so the answer does change; a month is slow
/// enough that a library of thousands costs nothing to keep current.
pub const RECHECK_SECS: i64 = 30 * 24 * 60 * 60;

#[derive(Debug, thiserror::Error)]
pub enum LogoError {
    #[error(transparent)]
    Index(#[from] IndexError),
    #[error(transparent)]
    Tmdb(#[from] TmdbError),
}

/// A chosen logo: the TMDB path, and the shape it will draw in.
#[derive(Debug, Clone, PartialEq)]
pub struct Logo {
    pub path: String,
    /// Width over height. The app sizes a logo by height and needs this to
    /// know the width before the file is decoded.
    pub aspect: f32,
}

/// The logo to draw, asking TMDB only when the answer is not already stored.
///
/// A stored path is final: a logo once chosen is kept, so the treatment does
/// not change under a viewer who has seen it. Only "there is none" expires,
/// and only after `RECHECK_SECS`.
///
/// It takes the write connection, never across the request: the row is read
/// under the guard and the answer written under it again, so a playback report
/// is not queued behind somebody else's network.
pub fn logo(
    db: &Mutex<Db>,
    client: &TmdbClient,
    title_id: i64,
    now: i64,
) -> Result<Option<Logo>, LogoError> {
    let Some(state) = db.lock().logo_state(title_id)? else {
        return Ok(None);
    };
    if let Some(path) = state.path {
        return Ok(Some(Logo {
            path,
            aspect: state.aspect,
        }));
    }
    if state.checked_at > 0 && now - state.checked_at < RECHECK_SECS {
        return Ok(None);
    }
    // No id to ask about: the matching pass has not reached this title yet, or
    // never will. Nothing is written, so the day an id lands this asks again.
    let Some(tmdb_id) = state.tmdb_id else {
        return Ok(None);
    };
    let (english_name, logos) = client.logos(tmdb_id, state.kind)?;
    let chosen = best(&logos, &state.name, &english_name).map(|l| Logo {
        path: l.file_path.clone(),
        aspect: l.aspect_ratio,
    });
    db.lock().set_logo(
        title_id,
        chosen.as_ref().map(|l| l.path.as_str()),
        chosen.as_ref().map_or(0.0, |l| l.aspect),
        now,
    )?;
    Ok(chosen)
}

/// The logo to draw for a title the app calls `display_name`, given TMDB's
/// English name for it; None when type serves the viewer better.
///
/// A logo is worth drawing when it shows the title the app would otherwise
/// write. Nothing can read the lettering in the image, so which title that is
/// has to come from the language TMDB filed it under:
///
/// - French lettering on a French library is the title on screen by
///   construction, and is drawn.
/// - English lettering spells the English name. That is only the title on
///   screen when the library uses it too - which is most of a French library,
///   since a title whose French and original names are the same word keeps
///   it. When the two differ the logo says something else, and a viewer
///   reading a name their library does not use is worse served than by plain
///   type.
/// - Lettering TMDB files under no language is, by its own account, lettering
///   with nothing language-specific to disagree with, and is drawn.
/// - Any other language is skipped rather than ranked last: a Russian title
///   treatment on a French film is not a near miss, it is the wrong image.
///
/// Within a rank, whichever TMDB's own voters put highest.
///
/// SVG logos are skipped whatever their language: TMDB serves them from the
/// same array and at the same sized paths, and the app draws no vector
/// image.
fn best<'a>(
    logos: &'a [LogoImage],
    display_name: &str,
    english_name: &str,
) -> Option<&'a LogoImage> {
    // one comparison for the whole array, not one per logo. TMDB spells a name
    // with punctuation and spacing Plex does not, so the two are compared in
    // the same folded form the title matcher uses.
    let english_reads_right =
        !english_name.is_empty() && normalize(english_name) == normalize(display_name);
    logos
        .iter()
        // a zero aspect would be drawn zero points wide
        .filter(|l| l.file_path.ends_with(".png") && l.aspect_ratio > 0.0)
        .filter_map(|l| rank(l.iso_639_1.as_deref(), english_reads_right).map(|r| (r, l)))
        .min_by(|(left_rank, left), (right_rank, right)| {
            left_rank.cmp(right_rank).then_with(|| {
                right
                    .vote_average
                    .partial_cmp(&left.vote_average)
                    .unwrap_or(Ordering::Equal)
            })
        })
        .map(|(_, l)| l)
}

/// None for lettering this app would not draw on this title.
fn rank(iso: Option<&str>, english_reads_right: bool) -> Option<u8> {
    match iso {
        Some("fr") => Some(0),
        Some("en") => english_reads_right.then_some(1),
        // TMDB writes lettering with no language as a JSON null and, on some
        // rows, as an empty string
        None | Some("") => Some(2),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::index::db::{MetadataRecord, MetadataSource};
    use crate::index::MediaKind;
    use crate::metadata::fake::tmdb;
    use crate::plex::fake::{FakeServer, Reply};

    #[test]
    fn a_png_is_measured_off_its_header_and_anything_else_is_not() {
        assert_eq!(png_aspect(&crate::plex::fake::LOGO_PNG), Some(4.0));
        assert_eq!(png_aspect(&[0xff, 0xd8, 0xff, 0xe0, 7, 7, 7, 7]), None);
        assert_eq!(png_aspect(&crate::plex::fake::LOGO_PNG[..20]), None);
    }

    fn image(path: &str, iso: Option<&str>, aspect: f32, vote: f32) -> LogoImage {
        LogoImage {
            file_path: path.to_string(),
            iso_639_1: iso.map(str::to_string),
            aspect_ratio: aspect,
            vote_average: vote,
        }
    }

    #[test]
    fn french_wins_then_english_then_no_language() {
        let all = [
            image("/none.png", None, 4.0, 9.0),
            image("/en.png", Some("en"), 4.0, 9.0),
            image("/fr.png", Some("fr"), 4.0, 1.0),
        ];
        assert_eq!(best(&all, "Dune", "Dune").unwrap().file_path, "/fr.png");
        // a library with no French logo takes the English one rather than none
        assert_eq!(
            best(&all[..2], "Dune", "Dune").unwrap().file_path,
            "/en.png"
        );
        assert_eq!(
            best(&all[..1], "Dune", "Dune").unwrap().file_path,
            "/none.png"
        );
    }

    #[test]
    fn english_lettering_is_drawn_only_on_a_title_the_library_names_in_english() {
        let all = [
            image("/en-wide.png", Some("en"), 5.5, 0.0),
            image("/en.png", Some("en"), 1.5, 0.0),
        ];
        // TMDB knows this series' French name and holds English lettering
        // only: the logo would spell a title the library does not use
        assert!(best(&all, "La carte des desirs", "The Map of Longing").is_none());
        // the same series on a library that kept the English name
        assert_eq!(
            best(&all, "The Map of Longing", "The Map of Longing")
                .unwrap()
                .file_path,
            "/en-wide.png"
        );
        // and a title whose French and English names are the same word, which
        // is a large share of any French library, keeps its logo
        assert_eq!(
            best(&all, "Dune", "Dune").unwrap().file_path,
            "/en-wide.png"
        );

        // spacing, case and accents are not a different title: TMDB writes a
        // narrow no-break space before a colon where Plex writes a plain one
        assert_eq!(
            best(&all, "Le Prince Caspian", "Le Prince\u{a0}caspian")
                .unwrap()
                .file_path,
            "/en-wide.png"
        );
        // an English name TMDB does not hold cannot agree with anything
        assert!(best(&all, "Dune", "").is_none());
    }

    #[test]
    fn a_refused_english_logo_falls_to_lettering_of_no_language_not_to_nothing() {
        let all = [
            image("/en.png", Some("en"), 4.0, 9.0),
            image("/none.png", None, 4.0, 1.0),
        ];
        assert_eq!(
            best(&all, "La carte des desirs", "The Map of Longing")
                .unwrap()
                .file_path,
            "/none.png"
        );
    }

    #[test]
    fn a_language_the_app_would_not_draw_is_skipped_not_ranked_last() {
        let all = [image("/ru.png", Some("ru"), 4.0, 9.0)];
        assert!(best(&all, "Dune", "Dune").is_none());
        // and it never wins over a language that is drawn
        let with_english = [
            image("/ru.png", Some("ru"), 4.0, 9.0),
            image("/en.png", Some("en"), 4.0, 0.0),
        ];
        assert_eq!(
            best(&with_english, "Dune", "Dune").unwrap().file_path,
            "/en.png"
        );
    }

    #[test]
    fn within_one_language_the_best_voted_wins() {
        let all = [
            image("/en-low.png", Some("en"), 4.0, 1.0),
            image("/en-high.png", Some("en"), 4.0, 8.0),
            image("/en-mid.png", Some("en"), 4.0, 5.0),
        ];
        assert_eq!(
            best(&all, "Dune", "Dune").unwrap().file_path,
            "/en-high.png"
        );
    }

    #[test]
    fn a_vector_logo_is_not_drawable_and_is_skipped() {
        // the best-voted French logo of the three, and unusable
        let all = [
            image("/fr.svg", Some("fr"), 4.0, 9.0),
            image("/en.png", Some("en"), 4.0, 2.0),
        ];
        assert_eq!(best(&all, "Dune", "Dune").unwrap().file_path, "/en.png");
        assert!(best(&all[..1], "Dune", "Dune").is_none());
        // nor is a PNG that measures nothing
        let flat = [image("/fr.png", Some("fr"), 0.0, 9.0)];
        assert!(best(&flat, "Dune", "Dune").is_none());
    }

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
    fn a_logo_is_fetched_once_and_then_read_from_the_row() {
        let server = tmdb();
        let client = TmdbClient::new(&server.base_url, "k3y");
        let (db, id) = seeded(Some(438631));

        let found = logo(&db, &client, id, 1_000).unwrap().unwrap();
        assert_eq!(found.path, "/dune-fr-logo.png");
        assert_eq!(found.aspect, 3.5);
        assert_eq!(server.requests().len(), 1);
        // one request for both halves: the lettering, and the English name it
        // is weighed against
        let asked = &server.requests()[0].url;
        assert!(asked.starts_with("/movie/438631"), "{asked}");
        assert!(asked.contains("append_to_response=images"), "{asked}");
        assert!(asked.contains("language=en-US"), "{asked}");
        assert!(
            asked.contains("include_image_language=fr%2Cen%2Cnull"),
            "{asked}"
        );

        // and never asked for again, even a year on: a logo once chosen stands
        assert_eq!(
            logo(&db, &client, id, 1_000 + RECHECK_SECS * 12)
                .unwrap()
                .unwrap(),
            found
        );
        assert_eq!(server.requests().len(), 1);
    }

    #[test]
    fn a_title_tmdb_has_no_logo_for_costs_one_request_a_month() {
        let server = FakeServer::start(|_req| {
            Reply::json(r#"{"id":9,"title":"Dune","images":{"logos":[]}}"#)
        });
        let client = TmdbClient::new(&server.base_url, "k3y");
        let (db, id) = seeded(Some(9));

        assert!(logo(&db, &client, id, 1_000).unwrap().is_none());
        assert_eq!(server.requests().len(), 1);
        // every draw of the hero in the meantime is answered from the row
        assert!(logo(&db, &client, id, 1_000).unwrap().is_none());
        assert!(logo(&db, &client, id, 1_000 + RECHECK_SECS - 1)
            .unwrap()
            .is_none());
        assert_eq!(server.requests().len(), 1);
        // a logo contributed since is found once the answer goes stale
        assert!(logo(&db, &client, id, 1_000 + RECHECK_SECS)
            .unwrap()
            .is_none());
        assert_eq!(server.requests().len(), 2);
    }

    #[test]
    fn a_title_with_no_tmdb_id_asks_nothing_and_is_not_written_off() {
        let server = tmdb();
        let client = TmdbClient::new(&server.base_url, "k3y");
        let (db, id) = seeded(None);

        assert!(logo(&db, &client, id, 1_000).unwrap().is_none());
        assert!(server.requests().is_empty());
        // the matching pass reaches it, and the next draw asks for real
        let mut row = db.lock().metadata(id).unwrap().unwrap();
        row.tmdb_id = Some(438631);
        row.source = MetadataSource::Plex;
        db.lock().upsert_metadata(&row).unwrap();
        assert!(logo(&db, &client, id, 1_000).unwrap().is_some());
        assert_eq!(server.requests().len(), 1);
    }

    #[test]
    fn a_title_nothing_has_described_has_no_logo_and_no_request() {
        let server = tmdb();
        let client = TmdbClient::new(&server.base_url, "k3y");
        let db = Db::open_in_memory().unwrap();
        let id = db.upsert_title(MediaKind::Movie, "Solaris", None).unwrap();
        let db = Mutex::new(db);

        assert!(logo(&db, &client, id, 1_000).unwrap().is_none());
        assert!(server.requests().is_empty());
    }

    #[test]
    fn a_show_is_asked_for_on_the_tv_endpoint() {
        let server = tmdb();
        let client = TmdbClient::new(&server.base_url, "k3y");
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
            fetched_at: 100,
            critics: None,
            audience: None,
            release_date: None,
        })
        .unwrap();
        let db = Mutex::new(db);

        assert_eq!(
            logo(&db, &client, id, 1_000).unwrap().unwrap().path,
            "/expanse-en-logo.png"
        );
        assert!(server.requests()[0].url.starts_with("/tv/63639"));
    }

    #[test]
    fn a_series_the_library_names_in_french_is_not_given_english_lettering() {
        let server = tmdb();
        let client = TmdbClient::new(&server.base_url, "k3y");
        let db = Db::open_in_memory().unwrap();
        let id = db
            .upsert_title(MediaKind::Show, "La carte des désirs", Some(2026))
            .unwrap();
        db.upsert_metadata(&MetadataRecord {
            title_id: id,
            tmdb_id: Some(288671),
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
            fetched_at: 100,
            critics: None,
            audience: None,
            release_date: None,
        })
        .unwrap();
        let db = Mutex::new(db);

        // TMDB spells this one "The Map of Longing" and holds only English
        // lettering for it: the hero writes the French name in type instead
        assert!(logo(&db, &client, id, 1_000).unwrap().is_none());
        // and the answer is stored, so the hero does not ask again every draw
        let stored = db.lock().logo_state(id).unwrap().unwrap();
        assert_eq!(stored.checked_at, 1_000);
        assert!(logo(&db, &client, id, 1_000).unwrap().is_none());
        assert_eq!(server.requests().len(), 1);
    }

    #[test]
    fn a_refused_key_is_reported_and_nothing_is_written_off() {
        let server = FakeServer::start(|_req| Reply::status(401));
        let client = TmdbClient::new(&server.base_url, "k3y");
        let (db, id) = seeded(Some(9));

        assert!(matches!(
            logo(&db, &client, id, 1_000),
            Err(LogoError::Tmdb(TmdbError::Unauthorized))
        ));
        // the failure is the key's, not the title's: a working key finds it
        let stored = db.lock().logo_state(id).unwrap().unwrap();
        assert_eq!(stored.checked_at, 0);
    }
}
