use super::models::{
    Credits, DetailedImages, DetailedVideos, Details, Keywords, LogoImage, SearchResponse,
    SearchResult, Video,
};
use crate::index::MediaKind;
use serde::de::DeserializeOwned;
use std::time::Duration;

pub const API_BASE: &str = "https://api.themoviedb.org/3";
pub const LANG_FR: &str = "fr-FR";
pub const LANG_EN: &str = "en-US";

/// How long a 429 with no `Retry-After` of its own is worth waiting. TMDB
/// answers a burst rather than a quota, so what it wants is a pause, not an
/// hour.
const DEFAULT_RETRY_AFTER: u32 = 5;

/// The longest one 429 can hold a pass back. A header asking for more is not
/// refused, it is simply asked again after this: a pass that stops answering
/// for ten minutes reads as a broken app.
const MAX_RETRY_AFTER: u32 = 60;

#[derive(Debug, thiserror::Error)]
pub enum TmdbError {
    #[error("the TMDB key was rejected")]
    Unauthorized,
    #[error("tmdb http status {0}")]
    Status(u16),
    #[error("tmdb is rate limiting: retry in {retry_after_secs}s")]
    RateLimited { retry_after_secs: u32 },
    #[error("tmdb transport error: {0}")]
    Transport(String),
    #[error("invalid tmdb response: {0}")]
    Decode(String),
}

pub struct TmdbClient {
    agent: ureq::Agent,
    base_url: String,
    key: String,
}

impl TmdbClient {
    /// The agent every API call goes through. An agent owns the connection
    /// pool, so one per client is one TCP connection and one TLS handshake
    /// per client: a caller that makes a client per batch of titles pays both
    /// for every batch, which is why the core keeps one of these and hands it
    /// to `with_agent`.
    pub fn api_agent() -> ureq::Agent {
        ureq::AgentBuilder::new()
            .timeout_connect(Duration::from_secs(10))
            .timeout_read(Duration::from_secs(30))
            // the key rides in a header, which ureq would forward to whatever
            // host a redirect names
            .redirects(0)
            .build()
    }

    /// `base_url` is API_BASE outside tests; the tests point it at a fake.
    /// A connection pool of its own, which is what makes this the shape for a
    /// test and the wrong one for a caller that runs batch after batch.
    pub fn new(base_url: &str, key: &str) -> TmdbClient {
        TmdbClient::with_agent(TmdbClient::api_agent(), base_url, key)
    }

    /// The same, over a pool somebody else keeps.
    pub fn with_agent(agent: ureq::Agent, base_url: &str, key: &str) -> TmdbClient {
        TmdbClient {
            agent,
            base_url: base_url.trim_end_matches('/').to_string(),
            key: key.to_string(),
        }
    }

    /// Cloning shares the connection pool.
    pub fn agent(&self) -> ureq::Agent {
        self.agent.clone()
    }

    /// What TMDB answers a query with, in its own order, which is the order of
    /// its confidence. Which of them is the title being looked for is the
    /// caller's to decide (see `enrich::pick`): the first result is a guess,
    /// and a guess attaches a stranger's saga.
    pub fn search_movies(
        &self,
        query: &str,
        year: Option<u16>,
    ) -> Result<Vec<SearchResult>, TmdbError> {
        let mut params = vec![
            ("query", query.to_string()),
            ("language", LANG_FR.to_string()),
        ];
        if let Some(y) = year {
            params.push(("year", y.to_string()));
        }
        let resp: SearchResponse = self.get_json("/search/movie", &params)?;
        Ok(resp.results)
    }

    pub fn search_shows(&self, query: &str) -> Result<Vec<SearchResult>, TmdbError> {
        let resp: SearchResponse = self.get_json(
            "/search/tv",
            &[
                ("query", query.to_string()),
                ("language", LANG_FR.to_string()),
            ],
        )?;
        Ok(resp.results)
    }

    /// The details, and the billing, in one request: TMDB appends a sub-request
    /// to the same call for free, and the cast is half of what a title's
    /// embedding is built from.
    pub fn movie_details(&self, id: i64, language: &str) -> Result<Details, TmdbError> {
        self.get_json(
            &format!("/movie/{id}"),
            &[
                ("language", language.to_string()),
                ("append_to_response", "credits".to_string()),
            ],
        )
    }

    /// The cast is the whole run's, the crew the latest season's: `credits` on
    /// a series bills only whoever is in its last season.
    pub fn show_details(&self, id: i64, language: &str) -> Result<Details, TmdbError> {
        let mut details: Details = self.get_json(
            &format!("/tv/{id}"),
            &[
                ("language", language.to_string()),
                (
                    "append_to_response",
                    "credits,aggregate_credits".to_string(),
                ),
            ],
        )?;
        if !details.aggregate_credits.cast.is_empty() {
            details.credits.cast = std::mem::take(&mut details.aggregate_credits.cast);
            // the part they played most, for someone billed under several
            for member in &mut details.credits.cast {
                if let Some(role) = member.roles.iter().max_by_key(|r| r.episode_count) {
                    member.character = role.character.clone();
                }
            }
        }
        Ok(details)
    }

    /// The billing alone, for a title whose id is already in hand. It is the
    /// same sub-request `append_to_response=credits` hangs off the details,
    /// and it answers with the same cast in the same order - but without the
    /// overview, the artwork and the genres, which a row Plex wrote is the
    /// owner's own copy of and which nothing here may rewrite.
    pub fn movie_credits(&self, id: i64) -> Result<Credits, TmdbError> {
        self.get_json(
            &format!("/movie/{id}/credits"),
            &[("language", LANG_FR.to_string())],
        )
    }

    /// A title's keywords, in whichever language TMDB keeps them (English):
    /// the encoder is multilingual, and a tag is a tag.
    pub fn keywords(&self, kind: MediaKind, id: i64) -> Result<Vec<String>, TmdbError> {
        let path = match kind {
            MediaKind::Movie => format!("/movie/{id}/keywords"),
            MediaKind::Show => format!("/tv/{id}/keywords"),
        };
        let answer: Keywords = self.get_json(&path, &[])?;
        Ok(answer
            .keywords
            .into_iter()
            .chain(answer.results)
            .map(|k| k.name)
            .filter(|n| !n.is_empty())
            .collect())
    }

    /// The details call rather than `/credits`, for the whole run's cast
    /// `show_details` assembles in the same one request.
    pub fn show_credits(&self, id: i64) -> Result<Credits, TmdbError> {
        self.show_details(id, LANG_FR).map(|d| d.credits)
    }

    /// The ids TMDB recommends after a movie, best first, page 1 only. Not
    /// `/similar`: it matches on genres and keywords alone, and reads as noise.
    pub fn recommended_movies(&self, id: i64) -> Result<Vec<i64>, TmdbError> {
        let resp: SearchResponse = self.get_json(
            &format!("/movie/{id}/recommendations"),
            &[("language", LANG_FR.to_string())],
        )?;
        Ok(resp.results.iter().map(|r| r.id).collect())
    }

    pub fn recommended_shows(&self, id: i64) -> Result<Vec<i64>, TmdbError> {
        let resp: SearchResponse = self.get_json(
            &format!("/tv/{id}/recommendations"),
            &[("language", LANG_FR.to_string())],
        )?;
        Ok(resp.results.iter().map(|r| r.id).collect())
    }

    /// One page of what TMDB counts as trending this week, most first: twenty
    /// ids, pages from 1.
    pub fn trending(&self, kind: MediaKind, page: u32) -> Result<Vec<i64>, TmdbError> {
        let path = if kind == MediaKind::Show {
            "/trending/tv/week"
        } else {
            "/trending/movie/week"
        };
        let resp: SearchResponse = self.get_json(path, &[("page", page.to_string())])?;
        Ok(resp.results.iter().map(|r| r.id).collect())
    }

    /// Every logo TMDB holds for a title in the three languages worth drawing,
    /// and the English name it spells English lettering with.
    ///
    /// `include_image_language` is what widens the answer past the one
    /// language a plain call would return; `null` in it is TMDB's own spelling
    /// for lettering with no language, and is not a JSON null. The images ride
    /// on a details call rather than `/images` because choosing between them
    /// needs the English name too, and `append_to_response` costs no second
    /// request.
    pub fn logos(&self, id: i64, kind: MediaKind) -> Result<(String, Vec<LogoImage>), TmdbError> {
        let path = match kind {
            MediaKind::Movie => format!("/movie/{id}"),
            MediaKind::Show => format!("/tv/{id}"),
        };
        let resp: DetailedImages = self.get_json(
            &path,
            &[
                ("language", LANG_EN.to_string()),
                ("append_to_response", "images".to_string()),
                ("include_image_language", "fr,en,null".to_string()),
            ],
        )?;
        let english_name = match kind {
            MediaKind::Movie => resp.title,
            MediaKind::Show => resp.name,
        };
        Ok((english_name, resp.images.logos))
    }

    /// Every video TMDB lists for a title, in the languages worth offering.
    ///
    /// `include_video_language` is what widens the answer past the one
    /// language a plain call returns, the way `include_image_language` does
    /// for the logos above; `null` in it is TMDB's own spelling for a video
    /// filed under no language, and is not a JSON null. They ride a details
    /// call rather than `/videos` because `append_to_response` costs no second
    /// request.
    pub fn videos(&self, id: i64, kind: MediaKind) -> Result<Vec<Video>, TmdbError> {
        let path = match kind {
            MediaKind::Movie => format!("/movie/{id}"),
            MediaKind::Show => format!("/tv/{id}"),
        };
        let resp: DetailedVideos = self.get_json(
            &path,
            &[
                ("language", LANG_FR.to_string()),
                ("append_to_response", "videos".to_string()),
                ("include_video_language", "fr,en,null".to_string()),
            ],
        )?;
        Ok(resp.videos.results)
    }

    fn get_json<T: DeserializeOwned>(
        &self,
        path: &str,
        query: &[(&str, String)],
    ) -> Result<T, TmdbError> {
        let mut req = self
            .agent
            .get(&format!("{}{}", self.base_url, path))
            .set("Accept", "application/json")
            // v4 auth on a v3 endpoint: TMDB also takes an api_key query
            // parameter, but a key in a URL lands in every log on the way
            .set("Authorization", &format!("Bearer {}", self.key));
        for (k, v) in query {
            req = req.query(k, v);
        }
        let resp = req.call().map_err(|e| match e {
            ureq::Error::Status(401, _) => TmdbError::Unauthorized,
            // the one status worth reading a header off: it says when this is
            // worth trying again, and every other title in the batch is about
            // to be answered the same way
            ureq::Error::Status(429, resp) => TmdbError::RateLimited {
                retry_after_secs: resp
                    .header("Retry-After")
                    .and_then(|v| v.trim().parse::<u32>().ok())
                    .unwrap_or(DEFAULT_RETRY_AFTER)
                    .clamp(1, MAX_RETRY_AFTER),
            },
            ureq::Error::Status(code, _) => TmdbError::Status(code),
            // the kind alone: the Display of `t` quotes whatever ureq choked
            // on, which is the whole header line for a key with a stray
            // newline in it
            ureq::Error::Transport(t) => TmdbError::Transport(t.kind().to_string()),
        })?;
        resp.into_json()
            .map_err(|e| TmdbError::Decode(e.to_string()))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::metadata::fake::tmdb;
    use crate::plex::fake::{FakeServer, Reply};

    #[test]
    fn a_movie_search_carries_the_bearer_key_and_the_year() {
        let server = tmdb();
        let client = TmdbClient::new(&server.base_url, "k3y");
        let results = client.search_movies("Dune", Some(2021)).unwrap();
        // every candidate, in TMDB's order, titles and dates included: which
        // one is the film asked for is not this layer's call
        assert_eq!(
            results.iter().map(|r| r.id).collect::<Vec<_>>(),
            [9, 438631]
        );
        assert_eq!(results[1].title, "Dune");
        assert_eq!(results[1].release_date, "2021-09-15");

        let req = &server.requests()[0];
        assert!(req.url.starts_with("/search/movie?"), "{}", req.url);
        assert!(req.url.contains("query=Dune"), "{}", req.url);
        assert!(req.url.contains("year=2021"), "{}", req.url);
        assert!(req.url.contains("language=fr-FR"), "{}", req.url);
        assert_eq!(req.header("Authorization"), Some("Bearer k3y"));
        assert!(!req.url.contains("k3y"), "{}", req.url);
    }

    #[test]
    fn a_query_with_spaces_and_accents_is_encoded() {
        let server = tmdb();
        let client = TmdbClient::new(&server.base_url, "k");
        client.search_movies("Le Cinquieme Element", None).unwrap();
        let url = &server.requests()[0].url;
        assert!(!url.contains(' '), "{url}");
        assert!(!url.contains("year="), "{url}");
        client.search_shows("L'ete ou").unwrap();
        let url = &server.requests()[1].url;
        assert!(url.starts_with("/search/tv?"), "{url}");
    }

    #[test]
    fn details_parse_overview_artwork_and_genres() {
        let server = tmdb();
        let client = TmdbClient::new(&server.base_url, "k");
        let fr = client.movie_details(438631, LANG_FR).unwrap();
        assert!(fr.overview.starts_with("Dans un futur"), "{}", fr.overview);
        assert_eq!(fr.poster_path.as_deref(), Some("/dune.jpg"));
        assert_eq!(fr.backdrop_path.as_deref(), Some("/dune-bd.jpg"));
        let names: Vec<&str> = fr.genres.iter().map(|g| g.name.as_str()).collect();
        assert_eq!(names, ["Science-Fiction", "Aventure"]);
        assert!(server.requests()[0].url.contains("language=fr-FR"));

        let show = client.show_details(63639, LANG_EN).unwrap();
        assert_eq!(show.overview, "In the 23rd century.");
        assert!(server.requests()[1].url.starts_with("/tv/63639?"));
    }

    #[test]
    fn an_empty_result_set_is_no_match_not_an_error() {
        let server = tmdb();
        let client = TmdbClient::new(&server.base_url, "k");
        assert!(client
            .search_movies("Nothing At All", None)
            .unwrap()
            .is_empty());
        assert!(client.search_shows("Nothing At All").unwrap().is_empty());
    }

    #[test]
    fn a_missing_overview_reads_as_empty() {
        let server = tmdb();
        let client = TmdbClient::new(&server.base_url, "k");
        let bare = client.movie_details(999, LANG_FR).unwrap();
        assert!(bare.overview.is_empty());
        assert!(bare.poster_path.is_none());
        assert!(bare.genres.is_empty());
    }

    #[test]
    fn failures_keep_their_shape_and_never_carry_the_key() {
        let server = FakeServer::start(|_req| Reply::status(401));
        let client = TmdbClient::new(&server.base_url, "s3cr3t");
        let err = client.search_movies("Dune", None).unwrap_err();
        assert!(matches!(err, TmdbError::Unauthorized));
        assert!(!err.to_string().contains("s3cr3t"));

        let garbage = FakeServer::start(|_req| Reply::json("{not json"));
        let client = TmdbClient::new(&garbage.base_url, "k");
        assert!(matches!(
            client.search_movies("Dune", None),
            Err(TmdbError::Decode(_))
        ));

        let down = TmdbClient::new("http://127.0.0.1:1", "s3cr3t");
        let err = down.search_movies("Dune", None).unwrap_err();
        assert!(matches!(err, TmdbError::Transport(_)));
        assert!(!err.to_string().contains("s3cr3t"), "{err}");

        // a pasted key keeps whatever the clipboard held: a stray newline makes
        // the header unparseable, and the rejection quotes the whole line
        let pasted = TmdbClient::new("http://127.0.0.1:1", "s3cr3t\nX-Evil: 1");
        let shown = pasted.search_movies("Dune", None).unwrap_err().to_string();
        assert!(!shown.contains("s3cr3t"), "{shown}");
        assert!(!shown.contains("Authorization"), "{shown}");
    }

    #[test]
    fn a_rate_limit_says_how_long_to_wait_and_is_never_a_plain_status() {
        let asked = FakeServer::start(|_req| Reply {
            status: 429,
            headers: vec![("Retry-After".to_string(), " 3 ".to_string())],
            body: Vec::new(),
        });
        let client = TmdbClient::new(&asked.base_url, "k");
        assert!(matches!(
            client.search_movies("Dune", None),
            Err(TmdbError::RateLimited {
                retry_after_secs: 3
            })
        ));

        // no header, a header in the date form TMDB never sends, and one
        // asking for the rest of the hour: a pass still has to come back
        for header in [None, Some("Wed, 21 Oct 2015 07:28:00 GMT"), Some("3600")] {
            let server = FakeServer::start(move |_req| Reply {
                status: 429,
                headers: header
                    .map(|h| vec![("Retry-After".to_string(), h.to_string())])
                    .unwrap_or_default(),
                body: Vec::new(),
            });
            let client = TmdbClient::new(&server.base_url, "k");
            let Err(TmdbError::RateLimited { retry_after_secs }) =
                client.search_movies("Dune", None)
            else {
                panic!("{header:?} was not read as a rate limit");
            };
            assert!(
                (1..=MAX_RETRY_AFTER).contains(&retry_after_secs),
                "{header:?} -> {retry_after_secs}"
            );
        }
    }

    #[test]
    fn a_redirect_is_never_followed_so_the_key_stays_on_the_host() {
        let elsewhere = tmdb();
        let target = format!("{}/search/movie?query=Dune", elsewhere.base_url);
        let redirector = FakeServer::start(move |_req| Reply {
            status: 302,
            headers: vec![("Location".to_string(), target.clone())],
            body: Vec::new(),
        });

        let client = TmdbClient::new(&redirector.base_url, "s3cr3t");
        // the 302 arrives unfollowed, and its empty body is not a search result
        assert!(client.search_movies("Dune", None).is_err());
        assert!(elsewhere.requests().is_empty());
    }
}
