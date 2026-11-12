//! TheIntroDB: where an episode's or a film's intro, recap and credits run,
//! as its community timed them, keyed by TMDB id. The one place the player
//! learns them, whatever source the file comes from.

use crate::index::MediaKind;
use serde::Deserialize;

pub const API_BASE: &str = "https://api.theintrodb.org/v3";

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SegmentKind {
    Intro,
    Recap,
    Credits,
}

/// One stretch, in seconds. An end of None runs to the end of the file, which
/// is how credits usually come.
#[derive(Debug, Clone, PartialEq)]
pub struct Segment {
    pub kind: SegmentKind,
    pub start_secs: f64,
    pub end_secs: Option<f64>,
}

#[derive(Deserialize)]
struct Media {
    #[serde(default)]
    intro: Vec<Stamp>,
    #[serde(default)]
    recap: Vec<Stamp>,
    #[serde(default)]
    credits: Vec<Stamp>,
}

#[derive(Deserialize)]
struct Stamp {
    start_ms: Option<i64>,
    end_ms: Option<i64>,
}

/// The segments TheIntroDB holds for a film, or for one episode of a show,
/// for the release closest to `duration_secs`: the same episode cut for
/// broadcast and for disc runs a different length, and its marks with it.
/// Empty where nobody has timed it. An error is the service not answering,
/// which is worth asking again; a 404 is an answer.
pub fn segments(
    agent: &ureq::Agent,
    base: &str,
    tmdb_id: i64,
    kind: MediaKind,
    season_episode: Option<(u16, u16)>,
    duration_secs: f64,
) -> Result<Vec<Segment>, String> {
    let mut request = agent
        .get(&format!("{base}/media"))
        .set("Accept", "application/json")
        .set("User-Agent", "Lexis")
        .query("tmdb_id", &tmdb_id.to_string());
    if kind == MediaKind::Show {
        let Some((season, episode)) = season_episode else {
            return Ok(Vec::new());
        };
        request = request
            .query("season", &season.to_string())
            .query("episode", &episode.to_string());
    }
    if duration_secs > 0.0 {
        request = request.query(
            "duration_ms",
            &((duration_secs * 1000.0) as i64).to_string(),
        );
    }
    let media: Media = match request.call() {
        Ok(response) => response.into_json().map_err(|e| e.to_string())?,
        Err(ureq::Error::Status(404, _)) => return Ok(Vec::new()),
        Err(ureq::Error::Status(code, _)) => return Err(format!("status {code}")),
        Err(ureq::Error::Transport(t)) => return Err(t.kind().to_string()),
    };
    let stretch = |stamps: Vec<Stamp>, kind: SegmentKind| {
        stamps.into_iter().filter_map(move |stamp| {
            let end_secs = stamp.end_ms.map(|ms| ms as f64 / 1000.0);
            // an intro or a recap with no start opens the file; credits with
            // no start are no stretch at all
            let start_secs = match (stamp.start_ms, kind) {
                (Some(ms), _) => ms as f64 / 1000.0,
                (None, SegmentKind::Credits) => return None,
                (None, _) => 0.0,
            };
            if end_secs.is_some_and(|end| end <= start_secs) {
                return None;
            }
            Some(Segment {
                kind,
                start_secs,
                end_secs,
            })
        })
    };
    Ok(stretch(media.recap, SegmentKind::Recap)
        .chain(stretch(media.intro, SegmentKind::Intro))
        .chain(stretch(media.credits, SegmentKind::Credits))
        .collect())
}

#[cfg(test)]
mod tests {
    use super::*;
    use parking_lot::Mutex;
    use std::sync::Arc;

    /// A server that answers every request with `body` and `status`, and
    /// keeps the URL it was asked for.
    fn serve(status: u16, body: &'static str) -> (String, Arc<Mutex<Vec<String>>>) {
        let server = tiny_http::Server::http("127.0.0.1:0").unwrap();
        let base = format!("http://{}", server.server_addr().to_ip().unwrap());
        let asked = Arc::new(Mutex::new(Vec::new()));
        let seen = asked.clone();
        std::thread::spawn(move || {
            for request in server.incoming_requests() {
                seen.lock().push(request.url().to_string());
                let _ = request
                    .respond(tiny_http::Response::from_string(body).with_status_code(status));
            }
        });
        (base, asked)
    }

    #[test]
    fn an_episode_is_asked_by_show_season_episode_and_length() {
        let (base, asked) = serve(
            200,
            r#"{"tmdb_id":1399,"type":"tv","season":1,"episode":2,
                "intro":[{"start_ms":62000,"end_ms":151000}],
                "recap":[{"start_ms":null,"end_ms":58000}],
                "credits":[{"start_ms":3302000,"end_ms":null}],
                "preview":[]}"#,
        );
        let found = segments(
            &ureq::agent(),
            &base,
            1399,
            MediaKind::Show,
            Some((1, 2)),
            3350.5,
        )
        .unwrap();
        assert_eq!(
            found,
            [
                Segment {
                    kind: SegmentKind::Recap,
                    start_secs: 0.0,
                    end_secs: Some(58.0)
                },
                Segment {
                    kind: SegmentKind::Intro,
                    start_secs: 62.0,
                    end_secs: Some(151.0)
                },
                Segment {
                    kind: SegmentKind::Credits,
                    start_secs: 3302.0,
                    end_secs: None
                },
            ]
        );
        let url = asked.lock()[0].clone();
        assert!(url.starts_with("/media?"), "{url}");
        for part in [
            "tmdb_id=1399",
            "season=1",
            "episode=2",
            "duration_ms=3350500",
        ] {
            assert!(url.contains(part), "{url} lacks {part}");
        }
    }

    #[test]
    fn nobody_having_timed_it_is_an_answer_and_a_failure_is_not() {
        let (base, _) = serve(404, "{}");
        assert_eq!(
            segments(&ureq::agent(), &base, 7, MediaKind::Movie, None, 0.0).unwrap(),
            []
        );
        let (base, _) = serve(503, "{}");
        assert!(segments(&ureq::agent(), &base, 7, MediaKind::Movie, None, 0.0).is_err());
    }

    #[test]
    fn an_episode_with_no_numbers_is_not_asked_about() {
        let (base, asked) = serve(200, "{}");
        assert_eq!(
            segments(&ureq::agent(), &base, 7, MediaKind::Show, None, 60.0).unwrap(),
            []
        );
        assert!(asked.lock().is_empty());
    }
}
