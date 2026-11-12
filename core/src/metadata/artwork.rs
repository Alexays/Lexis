use std::io::Read;
use std::path::{Path, PathBuf};

/// The TMDB image CDN needs no key, and w500 is what a 10-foot poster grid
/// asks for; the size is part of the path, so it is not negotiated per fetch.
pub const TMDB_POSTER_BASE: &str = "https://image.tmdb.org/t/p/w500";

/// The wide image a detail hero is built on, full bleed over a 3840x2160
/// framebuffer. TMDB's backdrop ladder is w300, w780, w1280, original and
/// nothing between, so original is the only rung that is not an upscale.
pub const TMDB_BACKDROP_BASE: &str = "https://image.tmdb.org/t/p/original";

/// The same wide image for a rail's landscape card. w780 is the rung above the
/// 800x450 such a card is drawn at, and a twentieth of what `original` weighs.
pub const TMDB_THUMB_BASE: &str = "https://image.tmdb.org/t/p/w780";

/// A performer's photograph, for a face on a cast rail. TMDB's profile ladder
/// is w45, w185, h632, original: w185 is the rung above the 160 points such a
/// tile is drawn at, and the one below it is a thumbnail. A rail can ask for a
/// dozen of these at once, which is the other reason not to reach for `h632`.
pub const TMDB_PROFILE_BASE: &str = "https://image.tmdb.org/t/p/w185";

/// A poster is a few hundred KB; anything past this is not one.
const MAX_BYTES: u64 = 8 * 1024 * 1024;

#[derive(Debug, thiserror::Error)]
pub enum ArtworkError {
    #[error("artwork http status {0}")]
    Status(u16),
    #[error("artwork transport error: {0}")]
    Transport(String),
    #[error("artwork cache error: {0}")]
    Io(String),
}

/// What a cached image is called: `{name}-{size}.{ext}`. The three travel
/// together because `evict`'s sweep parses all three back out of the name, and
/// a file it cannot parse is one it deletes.
///
/// `name` is the caller's cache key, which is what lets one title hold a
/// poster, a backdrop and a logo at once. `size` names the dimensions asked
/// for: a cached image is never inspected, so the size has to be in the name
/// for one cached at dimensions nobody asks for any more to miss the cache
/// rather than be served forever.
///
/// `ext` names the slot, not the format. It is fixed per kind - `jpg` for a
/// poster or backdrop, `png` for a logo, whose transparency is what it is
/// asked for - and the bytes under it are whatever the server chose to send,
/// which for TMDB is usually WebP. Nothing may read a format back out of it:
/// ImageIO sniffs content and ignores the extension, `evict` parses the name
/// only to tell this build's files from another's, and no other reader looks.
pub struct CacheName<'a> {
    pub name: &'a str,
    pub size: &'a str,
    pub ext: &'a str,
}

/// Downloads one image into `cache_dir/artwork/` under `file` and returns its
/// path. A file already there is returned untouched: a purge is what makes it
/// fetch again (spec: Storage model), and `evict`'s sweep is what reclaims
/// one nobody asks for any more, so nothing here walks the directory.
/// `fallback`, when given, is tried if `url` fails: a sized request a server
/// refuses is not a reason to go without art entirely, when the plain path
/// still has it. `token` is the Plex token when the artwork lives on a Plex
/// server; TMDB images need no credential. Pass an agent built with
/// redirects(0): a custom token header must not follow a redirect.
pub fn artwork_file(
    agent: &ureq::Agent,
    cache_dir: &Path,
    file: CacheName<'_>,
    url: &str,
    fallback: Option<&str>,
    token: Option<&str>,
) -> Result<PathBuf, ArtworkError> {
    let CacheName { name, size, ext } = file;
    let dir = cache_dir.join("artwork");
    let stem = format!("{name}-");
    let path = dir.join(format!("{stem}{size}.{ext}"));
    if path.exists() {
        return Ok(path);
    }
    std::fs::create_dir_all(&dir).map_err(|e| ArtworkError::Io(e.to_string()))?;

    // only a refusal is worth the fallback: after a timeout or a reset, the
    // full-size original is the last thing a struggling server should be asked
    let bytes = match (download(agent, url, token), fallback) {
        (Ok(bytes), _) => bytes,
        (Err(ArtworkError::Status(_)), Some(fallback)) => download(agent, fallback, token)?,
        (Err(e), _) => return Err(e),
    };

    // written aside and renamed: a download cut in half would otherwise be
    // served as the poster for as long as the cache lives
    let part = dir.join(format!("{stem}{size}.{ext}.part"));
    std::fs::write(&part, &bytes).map_err(|e| {
        let _ = std::fs::remove_file(&part);
        ArtworkError::Io(e.to_string())
    })?;
    std::fs::rename(&part, &path).map_err(|e| {
        let _ = std::fs::remove_file(&part);
        ArtworkError::Io(e.to_string())
    })?;

    Ok(path)
}

/// One fetch attempt, whole image in memory, never written to disk: the
/// caller decides whether a failure here is worth a fallback or the end of
/// the request.
///
/// The `Accept` is a preference, never a requirement, and the second half of
/// it is what makes that true: `image.tmdb.org` serves the same URL as WebP
/// for a third off a poster and nearly half off a backdrop, and a Plex server
/// goes on sending JPEG. Nothing here or downstream reads the bytes, so what
/// comes back is stored as it arrives - see `CacheName`, where the extension
/// names the slot and not the format.
fn download(agent: &ureq::Agent, url: &str, token: Option<&str>) -> Result<Vec<u8>, ArtworkError> {
    let mut req = agent.get(url).set("Accept", "image/webp,image/*");
    if let Some(token) = token {
        req = req.set("X-Plex-Token", token);
    }
    let resp = req.call().map_err(|e| match e {
        ureq::Error::Status(code, _) => ArtworkError::Status(code),
        // the kind alone: the Display of `t` quotes the URL, and a Plex
        // artwork URL is one the token is sent with
        ureq::Error::Transport(t) => ArtworkError::Transport(t.kind().to_string()),
    })?;
    // an agent built with redirects(0) hands back the 3xx itself, body and all;
    // only a 200 carries an image
    if resp.status() != 200 {
        return Err(ArtworkError::Status(resp.status()));
    }
    let mut bytes = Vec::new();
    resp.into_reader()
        .take(MAX_BYTES)
        .read_to_end(&mut bytes)
        .map_err(|e| ArtworkError::Io(e.to_string()))?;
    if bytes.is_empty() {
        return Err(ArtworkError::Io("the server sent no image".to_string()));
    }
    // the reader stopped at the cap, so the image goes on past it: what is in
    // hand is a truncated file, and caching it would break the poster for good
    if bytes.len() as u64 == MAX_BYTES {
        return Err(ArtworkError::Io(
            "the image is too large to be a poster".to_string(),
        ));
    }
    Ok(bytes)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::plex::fake::{FakeServer, Reply};

    fn jpeg() -> Vec<u8> {
        let mut body = vec![0xff, 0xd8, 0xff, 0xe0];
        body.extend(vec![7u8; 2048]);
        body
    }

    fn agent() -> ureq::Agent {
        ureq::AgentBuilder::new().build()
    }

    #[test]
    fn a_poster_is_downloaded_once_and_then_read_from_the_cache() {
        let body = jpeg();
        let served = body.clone();
        let server = FakeServer::start(move |_req| Reply {
            status: 200,
            headers: vec![("Content-Type".into(), "image/jpeg".into())],
            body: served.clone(),
        });
        let cache = tempfile::tempdir().unwrap();

        let path = artwork_file(
            &agent(),
            cache.path(),
            CacheName {
                name: "42",
                size: "w500",
                ext: "jpg",
            },
            &format!("{}/t/p/w500/dune.jpg", server.base_url),
            None,
            None,
        )
        .unwrap();
        assert_eq!(path, cache.path().join("artwork/42-w500.jpg"));
        assert_eq!(std::fs::read(&path).unwrap(), body);
        assert_eq!(server.requests().len(), 1);
        // no credential is sent to the image CDN
        assert_eq!(server.requests()[0].header("X-Plex-Token"), None);

        let again = artwork_file(
            &agent(),
            cache.path(),
            CacheName {
                name: "42",
                size: "w500",
                ext: "jpg",
            },
            &format!("{}/t/p/w500/dune.jpg", server.base_url),
            None,
            None,
        )
        .unwrap();
        assert_eq!(again, path);
        assert_eq!(server.requests().len(), 1);
        // nothing half-written is left behind
        let left: Vec<String> = std::fs::read_dir(cache.path().join("artwork"))
            .unwrap()
            .map(|e| e.unwrap().file_name().to_string_lossy().into_owned())
            .collect();
        assert_eq!(left, ["42-w500.jpg"]);
    }

    /// TMDB serves the same URL as WebP for the asking, a third off a poster
    /// and nearly half off a backdrop. There is no `Vary` in front of it, so
    /// what comes back is the server's choice and not ours: the header is a
    /// preference, and the bytes are stored under the name the kind gives
    /// them whichever format arrives.
    #[test]
    fn a_webp_answer_is_stored_under_the_name_the_kind_gives_it() {
        let webp = b"RIFF\x24\x00\x00\x00WEBPVP8 ".to_vec();
        let served = webp.clone();
        let server = FakeServer::start(move |_req| Reply {
            status: 200,
            headers: vec![("Content-Type".into(), "image/webp".into())],
            body: served.clone(),
        });
        let cache = tempfile::tempdir().unwrap();

        let path = artwork_file(
            &agent(),
            cache.path(),
            CacheName {
                name: "42",
                size: "w500",
                ext: "jpg",
            },
            &format!("{}/t/p/w500/dune.jpg", server.base_url),
            None,
            None,
        )
        .unwrap();

        // asked for, and asked for in a way that still takes a JPEG: a Plex
        // server shares this fetcher and knows nothing about WebP
        let accept = server.requests()[0].header("Accept").unwrap().to_string();
        assert!(accept.contains("image/webp"), "{accept}");
        assert!(accept.contains("image/*"), "{accept}");
        // the slot is the kind's, the bytes are the server's, and nothing in
        // between rewrote or rejected them
        assert_eq!(path, cache.path().join("artwork/42-w500.jpg"));
        assert_eq!(std::fs::read(&path).unwrap(), webp);
    }

    #[test]
    fn a_logo_is_stored_as_the_png_it_is_beside_the_title_s_other_art() {
        let server = FakeServer::start(|_req| Reply {
            status: 200,
            headers: vec![("Content-Type".into(), "image/png".into())],
            body: vec![0x89, 0x50, 0x4e, 0x47, 7, 7, 7],
        });
        let cache = tempfile::tempdir().unwrap();
        let logo = artwork_file(
            &agent(),
            cache.path(),
            CacheName {
                name: "42-logo",
                size: "w500",
                ext: "png",
            },
            &format!("{}/t/p/w500/dune-logo.png", server.base_url),
            None,
            None,
        )
        .unwrap();
        // not .jpg: transparency survives the round trip only if what is
        // written is what came back, and the sweep parses this name
        assert_eq!(logo, cache.path().join("artwork/42-logo-w500.png"));
        assert_eq!(
            artwork_file(
                &agent(),
                cache.path(),
                CacheName {
                    name: "42-logo",
                    size: "w500",
                    ext: "png"
                },
                &format!("{}/t/p/w500/dune-logo.png", server.base_url),
                None,
                None
            )
            .unwrap(),
            logo
        );
        assert_eq!(server.requests().len(), 1);
    }

    #[test]
    fn the_two_images_of_one_title_are_two_files() {
        let server = FakeServer::start(move |_req| Reply {
            status: 200,
            headers: vec![("Content-Type".into(), "image/jpeg".into())],
            body: jpeg(),
        });
        let cache = tempfile::tempdir().unwrap();

        let poster = artwork_file(
            &agent(),
            cache.path(),
            CacheName {
                name: "42-poster",
                size: "408",
                ext: "jpg",
            },
            &format!("{}/thumb", server.base_url),
            None,
            None,
        )
        .unwrap();
        let backdrop = artwork_file(
            &agent(),
            cache.path(),
            CacheName {
                name: "42-backdrop",
                size: "2560",
                ext: "jpg",
            },
            &format!("{}/art", server.base_url),
            None,
            None,
        )
        .unwrap();

        assert_eq!(poster, cache.path().join("artwork/42-poster-408.jpg"));
        assert_eq!(backdrop, cache.path().join("artwork/42-backdrop-2560.jpg"));
        // one download each: the wide image does not evict the poster
        assert_eq!(server.requests().len(), 2);
        assert_eq!(
            artwork_file(
                &agent(),
                cache.path(),
                CacheName {
                    name: "42-poster",
                    size: "408",
                    ext: "jpg"
                },
                &format!("{}/thumb", server.base_url),
                None,
                None
            )
            .unwrap(),
            poster
        );
        assert_eq!(server.requests().len(), 2);
        assert!(backdrop.exists());
    }

    #[test]
    fn an_image_cached_at_a_size_nobody_asks_for_any_more_is_fetched_again() {
        let server = FakeServer::start(move |_req| Reply {
            status: 200,
            headers: vec![("Content-Type".into(), "image/jpeg".into())],
            body: jpeg(),
        });
        let cache = tempfile::tempdir().unwrap();
        let url = format!("{}/art", server.base_url);

        let small = artwork_file(
            &agent(),
            cache.path(),
            CacheName {
                name: "42-backdrop",
                size: "1280",
                ext: "jpg",
            },
            &url,
            None,
            None,
        )
        .unwrap();
        // the poster is the neighbour a sweep keyed on the wrong prefix eats
        let poster = artwork_file(
            &agent(),
            cache.path(),
            CacheName {
                name: "42-poster",
                size: "408",
                ext: "jpg",
            },
            &url,
            None,
            None,
        )
        .unwrap();

        let large = artwork_file(
            &agent(),
            cache.path(),
            CacheName {
                name: "42-backdrop",
                size: "2560",
                ext: "jpg",
            },
            &url,
            None,
            None,
        )
        .unwrap();
        assert_ne!(large, small);
        assert_eq!(server.requests().len(), 3, "the old size was served again");
        // the old size stays until a sweep reclaims it: deleting it here would
        // be a walk of the whole directory on every image downloaded, and
        // `evict` already deletes every size this build does not ask for
        assert!(small.exists());
        assert!(poster.exists());
    }

    #[test]
    fn plex_artwork_is_fetched_with_the_token() {
        let server = FakeServer::start(|req| {
            if req.header("X-Plex-Token") != Some("tok") {
                return Reply::status(401);
            }
            Reply {
                status: 200,
                headers: Vec::new(),
                body: jpeg(),
            }
        });
        let cache = tempfile::tempdir().unwrap();
        let url = format!("{}/library/metadata/101/thumb/1", server.base_url);
        assert!(artwork_file(
            &agent(),
            cache.path(),
            CacheName {
                name: "7",
                size: "408",
                ext: "jpg"
            },
            &url,
            None,
            Some("tok")
        )
        .is_ok());
        assert!(matches!(
            artwork_file(
                &agent(),
                cache.path(),
                CacheName {
                    name: "8",
                    size: "408",
                    ext: "jpg"
                },
                &url,
                None,
                None
            ),
            Err(ArtworkError::Status(401))
        ));
    }

    #[test]
    fn a_failed_download_caches_nothing() {
        let server = FakeServer::start(|_req| Reply::status(404));
        let cache = tempfile::tempdir().unwrap();
        let err = artwork_file(
            &agent(),
            cache.path(),
            CacheName {
                name: "9",
                size: "w500",
                ext: "jpg",
            },
            &format!("{}/gone.jpg", server.base_url),
            None,
            None,
        )
        .unwrap_err();
        assert!(matches!(err, ArtworkError::Status(404)));
        assert!(!cache.path().join("artwork/9-w500.jpg").exists());

        // an empty body is not a poster either
        let empty = FakeServer::start(|_req| Reply {
            status: 200,
            headers: Vec::new(),
            body: Vec::new(),
        });
        assert!(matches!(
            artwork_file(
                &agent(),
                cache.path(),
                CacheName {
                    name: "9",
                    size: "w500",
                    ext: "jpg"
                },
                &format!("{}/empty.jpg", empty.base_url),
                None,
                None
            ),
            Err(ArtworkError::Io(_))
        ));
        assert!(!cache.path().join("artwork/9-w500.jpg").exists());
    }

    #[test]
    fn a_body_too_large_to_be_a_poster_is_refused_whole() {
        let server = FakeServer::start(|_req| Reply {
            status: 200,
            headers: vec![("Content-Type".into(), "image/jpeg".into())],
            body: vec![7u8; MAX_BYTES as usize + 1],
        });
        let cache = tempfile::tempdir().unwrap();
        assert!(matches!(
            artwork_file(
                &agent(),
                cache.path(),
                CacheName {
                    name: "12",
                    size: "w500",
                    ext: "jpg"
                },
                &format!("{}/huge.jpg", server.base_url),
                None,
                None
            ),
            Err(ArtworkError::Io(_))
        ));
        // neither the truncated bytes nor the temp file survive
        assert!(!cache.path().join("artwork/12-w500.jpg").exists());
        assert!(!cache.path().join("artwork/12-w500.jpg.part").exists());
    }

    #[test]
    fn a_redirect_the_agent_refuses_to_follow_is_not_a_poster() {
        let server = FakeServer::start(|_req| Reply {
            status: 302,
            headers: vec![("Location".into(), "http://elsewhere.invalid/p.jpg".into())],
            body: Vec::new(),
        });
        let cache = tempfile::tempdir().unwrap();
        // the TMDB agent is built with redirects(0), so a 3xx comes back as a
        // reply with an empty body rather than as an error
        let agent = ureq::AgentBuilder::new().redirects(0).build();
        assert!(matches!(
            artwork_file(
                &agent,
                cache.path(),
                CacheName {
                    name: "11",
                    size: "w500",
                    ext: "jpg"
                },
                &format!("{}/moved.jpg", server.base_url),
                None,
                None
            ),
            Err(ArtworkError::Status(302))
        ));
        assert!(!cache.path().join("artwork/11-w500.jpg").exists());
    }

    #[test]
    fn a_sized_request_the_server_refuses_falls_back_to_the_plain_path() {
        let server = FakeServer::start(|req| {
            if req.url.starts_with("/photo/") {
                return Reply::status(400);
            }
            Reply {
                status: 200,
                headers: vec![("Content-Type".into(), "image/jpeg".into())],
                body: jpeg(),
            }
        });
        let cache = tempfile::tempdir().unwrap();
        let path = artwork_file(
            &agent(),
            cache.path(),
            CacheName {
                name: "13",
                size: "408",
                ext: "jpg",
            },
            &format!("{}/photo/:/transcode?width=408&height=612", server.base_url),
            Some(&format!("{}/library/metadata/101/thumb/1", server.base_url)),
            None,
        )
        .unwrap();
        assert_eq!(std::fs::read(&path).unwrap(), jpeg());
        assert_eq!(server.requests().len(), 2);
        assert!(server.requests()[0].url.starts_with("/photo/"));
        assert!(server.requests()[1].url.starts_with("/library/metadata/"));
    }

    #[test]
    fn a_fallback_that_also_fails_caches_nothing() {
        let server = FakeServer::start(|req| {
            if req.url.starts_with("/photo/") {
                Reply::status(500)
            } else {
                Reply::status(404)
            }
        });
        let cache = tempfile::tempdir().unwrap();
        let err = artwork_file(
            &agent(),
            cache.path(),
            CacheName {
                name: "14",
                size: "408",
                ext: "jpg",
            },
            &format!("{}/photo/:/transcode?width=408&height=612", server.base_url),
            Some(&format!("{}/library/metadata/101/thumb/1", server.base_url)),
            None,
        )
        .unwrap_err();
        // the fallback's own failure is the one reported: it ran last and is
        // what a retry would actually hit
        assert!(matches!(err, ArtworkError::Status(404)));
        assert!(!cache.path().join("artwork/14-408.jpg").exists());
        assert!(!cache.path().join("artwork/14-408.jpg.part").exists());
    }
}
