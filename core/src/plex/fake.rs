//! Scripted HTTP server for tests: one handler closure, an OS-assigned port.

use parking_lot::Mutex;
use std::net::SocketAddr;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;

pub const SECTIONS_JSON: &str = r#"{"MediaContainer":{"size":3,"Directory":[
  {"key":"1","type":"movie","title":"Movies"},
  {"key":"2","type":"show","title":"TV Shows"},
  {"key":"3","type":"artist","title":"Music"}
]}}"#;

pub const MOVIES_JSON: &str = r#"{"MediaContainer":{"size":1,"totalSize":1,"Metadata":[
  {"ratingKey":"101","title":"Dune","year":2021,"addedAt":1690000000,
   "summary":"Dans un futur lointain.",
   "thumb":"/library/metadata/101/thumb/1","art":"/library/metadata/101/art/1",
   "Image":[{"type":"coverPoster","url":"/library/metadata/101/thumb/1"},
            {"type":"clearLogo","url":"/library/metadata/101/clearLogo/1"}],
   "viewOffset":1200000,"duration":9000000,"lastViewedAt":1699900000,
   "Genre":[{"tag":"Science-Fiction"},{"tag":"Aventure"}],
   "Role":[{"tag":"Timothee Chalamet"},{"tag":"Rebecca Ferguson"}],
   "Director":[{"tag":"Denis Villeneuve"}],
   "Writer":[{"tag":"Denis Villeneuve"},{"tag":"Jon Spaihts"},{"tag":"Eric Roth"}],
   "rating":8.0,"ratingImage":"imdb://image.rating",
   "audienceRating":9.1,"audienceRatingImage":"themoviedb://image.rating",
   "Media":[{"videoResolution":"4k","videoCodec":"hevc","audioCodec":"eac3",
             "audioChannels":6,"audioProfile":"atmos",
             "Part":[{"id":501,"key":"/library/parts/501/1/Dune.mkv","size":42,
                      "Stream":[{"streamType":1,"colorTrc":"smpte2084",
                                 "extendedDisplayTitle":"HEVC 4K HDR10"},
                                {"streamType":2,"languageTag":"en-US",
                                 "extendedDisplayTitle":"EAC3 5.1 (Atmos)"},
                                {"streamType":2,"languageTag":"fr"},
                                {"streamType":2,"languageTag":"en-GB"},
                                {"streamType":3,"languageTag":"fr"},
                                {"streamType":3}]}]}]}
]}}"#;

/// The show itself, at type=2: its own summary, poster and genre, distinct
/// from anything either episode below carries.
pub const SHOWS_JSON: &str = r#"{"MediaContainer":{"size":1,"totalSize":1,"Metadata":[
  {"ratingKey":"200","title":"The Expanse","year":2015,
   "summary":"L'humanite a colonise le systeme solaire.",
   "thumb":"/library/metadata/200/thumb/1","art":"/library/metadata/200/art/1",
   "Genre":[{"tag":"Science-Fiction"}],
   "Role":[{"tag":"Steven Strait"}]}
]}}"#;

pub const EPISODES_JSON: &str = r#"{"MediaContainer":{"size":2,"totalSize":2,"Metadata":[
  {"ratingKey":"201","title":"Dulcinea","grandparentTitle":"The Expanse","addedAt":1690000100,
   "parentIndex":1,"index":1,"year":2015,"summary":"Une inspectrice.",
   "thumb":"/library/metadata/201/thumb/1",
   "viewOffset":600000,"duration":3000000,"lastViewedAt":1700000000,
   "Media":[{"Part":[{"id":601,"key":"/library/parts/601/1/S01E01.mkv","size":10}]}]},
  {"ratingKey":"202","title":"Home","grandparentTitle":"The Expanse",
   "parentIndex":2,"index":3,"originallyAvailableAt":"2016-02-02",
   "viewCount":1,"duration":3000000,"lastViewedAt":1700086400,
   "Media":[{"Part":[{"id":602,"key":"/library/parts/602/1/S02E03.mkv","size":11}]}]}
]}}"#;

/// What the warm-up below asks for. Nothing else may use this path.
const WARM_PATH: &str = "/-/warm";

/// tiny_http hands every connection to a thread pool that starts at four and
/// only grows when one arrives to find none idle. A client opening eight
/// sockets at once outruns that: the accept loop queues eight handlers, four
/// threads take one each, and the rest sit in the pool's queue with no thread
/// left to pop them - so those clients are never read from and wait out their
/// own read timeout before reporting a transport error. That is a fault in
/// the fake, not in anything it is testing, and it made the suite fail one
/// run in four for a reason no production code could have.
///
/// Opening `workers` connections one at a time, each held open until the one
/// before it has been answered, never queues two handlers at once and so
/// grows the pool to `workers` threads. Any burst a test makes afterwards
/// finds them idle and waiting.
fn warm_connection_pool(addr: &SocketAddr, workers: usize) {
    use std::io::{Read, Write};
    let warm = format!("GET {WARM_PATH} HTTP/1.1\r\nHost: localhost\r\n\r\n");
    // held to the end: a connection returns its pool thread when it closes,
    // so releasing one early would let the next warm-up reuse it instead of
    // forcing the pool to grow
    let mut held = Vec::with_capacity(workers);
    for _ in 0..workers {
        let mut sock = std::net::TcpStream::connect(addr).unwrap();
        sock.set_read_timeout(Some(std::time::Duration::from_secs(10)))
            .unwrap();
        sock.write_all(warm.as_bytes()).unwrap();
        // the first byte of the answer: a pool thread is now bound to this
        // connection and blocked reading the next request on it
        let mut byte = [0u8; 1];
        sock.read_exact(&mut byte).unwrap();
        held.push(sock);
    }
}

/// One request as the server saw it.
#[derive(Clone, Debug)]
pub struct Req {
    /// Path plus query string, exactly as sent.
    pub url: String,
    pub headers: Vec<(String, String)>,
}

impl Req {
    pub fn header(&self, name: &str) -> Option<&str> {
        self.headers
            .iter()
            .find(|(k, _)| k.eq_ignore_ascii_case(name))
            .map(|(_, v)| v.as_str())
    }
}

pub struct Reply {
    pub status: u16,
    pub headers: Vec<(String, String)>,
    pub body: Vec<u8>,
}

impl Reply {
    pub fn json(body: &str) -> Reply {
        Reply {
            status: 200,
            headers: vec![("Content-Type".to_string(), "application/json".to_string())],
            body: body.as_bytes().to_vec(),
        }
    }

    pub fn status(code: u16) -> Reply {
        Reply {
            status: code,
            headers: Vec::new(),
            body: Vec::new(),
        }
    }
}

pub struct FakeServer {
    server: Arc<tiny_http::Server>,
    requests: Arc<Mutex<Vec<Req>>>,
    pub base_url: String,
}

impl FakeServer {
    pub fn start<F>(handler: F) -> FakeServer
    where
        F: Fn(&Req) -> Reply + Send + Sync + 'static,
    {
        FakeServer::start_with_workers(1, handler)
    }

    /// A server that holds and answers `workers` connections at once. One is
    /// the default because a serial client sees a deterministic request order
    /// through it; a client that fetches in parallel needs a server that does
    /// not turn its parallelism back into a queue, and needs `workers` at
    /// least as high as the sockets it opens at once.
    pub fn start_with_workers<F>(workers: usize, handler: F) -> FakeServer
    where
        F: Fn(&Req) -> Reply + Send + Sync + 'static,
    {
        let workers = workers.max(1);
        let server = Arc::new(tiny_http::Server::http("127.0.0.1:0").unwrap());
        let addr: SocketAddr = server.server_addr().to_ip().unwrap();
        let requests = Arc::new(Mutex::new(Vec::new()));
        let handler = Arc::new(handler);
        for _ in 0..workers {
            let server = server.clone();
            let requests = requests.clone();
            let handler = handler.clone();
            std::thread::spawn(move || {
                for rq in server.incoming_requests() {
                    // answered above the recorder and the handler both: a
                    // warm-up must not show up in a test's request log or
                    // move a handler's own counters
                    if rq.url() == WARM_PATH {
                        let _ = rq.respond(tiny_http::Response::empty(200));
                        continue;
                    }
                    let req = Req {
                        url: rq.url().to_string(),
                        headers: rq
                            .headers()
                            .iter()
                            .map(|h| {
                                (
                                    h.field.as_str().as_str().to_string(),
                                    h.value.as_str().to_string(),
                                )
                            })
                            .collect(),
                    };
                    requests.lock().push(req.clone());
                    let reply = handler(&req);
                    let mut resp =
                        tiny_http::Response::from_data(reply.body).with_status_code(reply.status);
                    for (k, v) in reply.headers {
                        resp = resp.with_header(
                            tiny_http::Header::from_bytes(k.as_bytes(), v.as_bytes()).unwrap(),
                        );
                    }
                    let _ = rq.respond(resp);
                }
            });
        }
        warm_connection_pool(&addr, workers);
        FakeServer {
            server,
            requests,
            base_url: format!("http://{addr}"),
        }
    }

    pub fn requests(&self) -> Vec<Req> {
        self.requests.lock().clone()
    }
}

/// A two-section Plex server: one movie, one show with two episodes, all three
/// carrying view state. It also serves the movie's artwork, to whoever sends
/// the token, and answers the `/:/` state endpoints.
/// `/video/:/transcode/universal/*`: the video session endpoints, refusing
/// the way the real server refuses. Measured against one (2026-08-27): a
/// request with no client profile is answered "no conversion profile found",
/// whatever the token, and the started output is a live stream that honours
/// no Range.
fn video_transcode_reply(req: &Req) -> Reply {
    if req.url.starts_with("/video/:/transcode/universal/ping")
        || req.url.starts_with("/video/:/transcode/universal/stop")
    {
        return Reply {
            status: 200,
            headers: Vec::new(),
            body: Vec::new(),
        };
    }
    let has_profile = req.url.contains("X-Plex-Client-Profile-Extra=");
    if req.url.starts_with("/video/:/transcode/universal/decision") {
        let body = if has_profile {
            r#"{"MediaContainer":{"transcodeDecisionCode":1001,
                "transcodeDecisionText":"Direct play not available; Conversion OK.",
                "Metadata":[{"Media":[{"bitrate":1720}]}]}}"#
        } else {
            r#"{"MediaContainer":{"transcodeDecisionCode":4005,
                "transcodeDecisionText":"Cannot convert this item. No conversion profile found."}}"#
        };
        return Reply::json(body);
    }
    if req.url.starts_with("/video/:/transcode/universal/start") {
        if !has_profile {
            return Reply::status(400);
        }
        // A few identifiable bytes: what a test reads back to prove the
        // session's own body reached it, not that a transcoder ran.
        return Reply {
            status: 200,
            headers: vec![
                ("Content-Type".to_string(), "video/x-matroska".to_string()),
                ("Accept-Ranges".to_string(), "none".to_string()),
            ],
            body: b"live-matroska-body".to_vec(),
        };
    }
    Reply::status(404)
}

pub fn library_reply(req: &Req, transcode_refused: bool) -> Reply {
    // the state endpoints: a real server answers 200 with an empty body
    if req.url.starts_with("/:/") {
        return Reply::status(200);
    }
    if req.url.starts_with("/video/:/transcode/universal/") {
        return video_transcode_reply(req);
    }
    if req.url.starts_with("/photo/:/transcode") {
        return if transcode_refused {
            Reply::status(400)
        } else {
            transcode_reply(req)
        };
    }
    if req.url.starts_with("/library/metadata/")
        && (req.url.contains("/thumb/") || req.url.contains("/art/"))
    {
        if req.header("X-Plex-Token") != Some("tok") {
            return Reply::status(401);
        }
        return Reply {
            status: 200,
            headers: vec![("Content-Type".to_string(), "image/jpeg".to_string())],
            body: vec![0xff, 0xd8, 0xff, 0xe0, 7, 7, 7, 7],
        };
    }
    if req.url.starts_with("/library/metadata/") && req.url.contains("/clearLogo/") {
        if req.header("X-Plex-Token") != Some("tok") {
            return Reply::status(401);
        }
        return Reply {
            status: 200,
            headers: vec![("Content-Type".to_string(), "image/png".to_string())],
            body: LOGO_PNG.to_vec(),
        };
    }
    if req.url == "/library/sections" {
        return Reply::json(SECTIONS_JSON);
    }
    if req.url.starts_with("/library/sections/1/all") {
        return Reply::json(MOVIES_JSON);
    }
    if req.url.starts_with("/library/sections/2/all") {
        // the show's own type=2 pass and the episode type=4 one share a
        // section key, and only the query param tells them apart
        return Reply::json(if query(&req.url, "type").as_deref() == Some("2") {
            SHOWS_JSON
        } else {
            EPISODES_JSON
        });
    }
    Reply::status(404)
}

/// `/photo/:/transcode`: a real server refuses it without the token, without
/// a numeric width and height, or for a `url` that names no known image, the
/// same as any other malformed request rather than serving the original
/// unsized.
fn transcode_reply(req: &Req) -> Reply {
    if req.header("X-Plex-Token") != Some("tok") {
        return Reply::status(401);
    }
    let width = query(&req.url, "width").and_then(|w| w.parse::<u32>().ok());
    let height = query(&req.url, "height").and_then(|h| h.parse::<u32>().ok());
    let (Some(width), Some(height)) = (width, height) else {
        return Reply::status(400);
    };
    if width == 0 || height == 0 {
        return Reply::status(400);
    }
    let Some(art) = query(&req.url, "url").map(|u| percent_decode(&u)) else {
        return Reply::status(400);
    };
    if !art.starts_with("/library/metadata/") || !(art.contains("/thumb/") || art.contains("/art/"))
    {
        return Reply::status(404);
    }
    Reply {
        status: 200,
        headers: vec![("Content-Type".to_string(), "image/jpeg".to_string())],
        body: vec![0xff, 0xd8, 0xff, 0xe0, 7, 7, 7, 7],
    }
}

/// Percent-decodes one query value: `%XX` back to its byte, everything else
/// untouched. The counterpart to the client's own encoder.
fn percent_decode(value: &str) -> String {
    let bytes = value.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%' && i + 2 < bytes.len() {
            if let Ok(byte) = u8::from_str_radix(&value[i + 1..i + 3], 16) {
                out.push(byte);
                i += 3;
                continue;
            }
        }
        out.push(bytes[i]);
        i += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

/// The head of an 800x200 PNG: all a logo is measured from.
pub const LOGO_PNG: [u8; 33] = [
    0x89, b'P', b'N', b'G', b'\r', b'\n', 0x1a, b'\n', 0, 0, 0, 13, b'I', b'H', b'D', b'R', 0, 0,
    3, 0x20, 0, 0, 0, 0xc8, 8, 6, 0, 0, 0, 0, 0, 0, 0,
];

pub fn library() -> FakeServer {
    FakeServer::start(|req| library_reply(req, false))
}

/// Like `library`, but every `/photo/:/transcode` request is refused with a
/// plain 400: what the fallback to the original thumb/art path is tested
/// against.
pub fn library_transcode_refused() -> FakeServer {
    FakeServer::start(|req| library_reply(req, true))
}

/// What `refusing_library` starts from: a movie left a third of the way in,
/// last viewed long before any test's clock.
pub const REFUSING_OFFSET_MS: i64 = 1_200_000;
pub const REFUSING_VIEWED_AT: i64 = 1_699_900_000;

/// A one-section library whose `/:/` writes can be switched off and back on,
/// for the offline queue: `refusing` is the switch a test flips, `status` what
/// a refusal answers with. The library routes answer all along, so a scan works
/// while the writes do not.
///
/// `reflect` is whether the server makes the accepted position its own, the way
/// a real Plex does. False is a server that took the write and still answers
/// with what it had, which is what proves nothing clobbers the local row.
pub fn refusing_library(refusing: Arc<AtomicBool>, status: u16, reflect: bool) -> FakeServer {
    let state = Arc::new(Mutex::new((REFUSING_OFFSET_MS, REFUSING_VIEWED_AT)));
    FakeServer::start(move |req| {
        if req.url.starts_with("/:/") {
            if refusing.load(Ordering::SeqCst) {
                return Reply::status(status);
            }
            if reflect {
                if let Some(time) = query(&req.url, "time") {
                    let mut state = state.lock();
                    state.0 = time.parse().unwrap_or(0);
                    state.1 = std::time::SystemTime::now()
                        .duration_since(std::time::UNIX_EPOCH)
                        .map(|d| d.as_secs() as i64)
                        .unwrap_or(0);
                }
            }
            return Reply::status(200);
        }
        if req.url == "/library/sections" {
            return Reply::json(
                r#"{"MediaContainer":{"size":1,"Directory":[
  {"key":"1","type":"movie","title":"Movies"}
]}}"#,
            );
        }
        if req.url.starts_with("/library/sections/1/all") {
            let (offset, viewed_at) = *state.lock();
            return Reply::json(&format!(
                r#"{{"MediaContainer":{{"size":1,"totalSize":1,"Metadata":[
  {{"ratingKey":"101","title":"Dune","year":2021,
   "viewOffset":{offset},"duration":9000000,"lastViewedAt":{viewed_at},
   "Media":[{{"Part":[{{"id":501,"key":"/library/parts/501/1/Dune.mkv","size":42}}]}}]}}
]}}}}"#
            ));
        }
        Reply::status(404)
    })
}

/// One item `shelf_library` serves: a film, a show, or an episode of `show`.
#[derive(Clone, Debug)]
pub struct ShelfItem {
    pub key: u32,
    /// The series, on a show and an episode.
    pub show: Option<&'static str>,
    pub added: i64,
    pub updated: i64,
    pub viewed: Option<i64>,
    pub offset_ms: Option<i64>,
    /// The id in the item's part key, which a replaced file changes.
    pub part: u32,
}

impl ShelfItem {
    pub fn film(key: u32, at: i64) -> ShelfItem {
        ShelfItem {
            key,
            show: None,
            added: at,
            updated: at,
            viewed: None,
            offset_ms: None,
            part: key,
        }
    }

    pub fn of(show: &'static str, key: u32, at: i64) -> ShelfItem {
        ShelfItem {
            show: Some(show),
            ..ShelfItem::film(key, at)
        }
    }
}

/// What `shelf_library` serves, held by the test that changes it between scans.
#[derive(Clone, Debug, Default)]
pub struct Shelf {
    pub movie_stamp: i64,
    pub show_stamp: i64,
    pub movies: Vec<ShelfItem>,
    pub shows: Vec<ShelfItem>,
    pub episodes: Vec<ShelfItem>,
}

/// A movie section ("1") and a show section ("2") that sort and page the way a
/// real server does: `sort=addedAt:desc`, `updatedAt:desc` and
/// `lastViewedAt:desc` with the container window, a never viewed item last,
/// and the section's own `totalSize` on every page.
pub fn shelf_library(shelf: Arc<Mutex<Shelf>>) -> FakeServer {
    FakeServer::start(move |req| {
        let shelf = shelf.lock();
        if req.url == "/library/sections" {
            return Reply::json(&format!(
                r#"{{"MediaContainer":{{"size":2,"Directory":[
                  {{"key":"1","type":"movie","title":"Movies","scannedAt":{}}},
                  {{"key":"2","type":"show","title":"TV Shows","scannedAt":{}}}
                ]}}}}"#,
                shelf.movie_stamp, shelf.show_stamp
            ));
        }
        let kind = query(&req.url, "type");
        let items = if req.url.starts_with("/library/sections/1/all") {
            &shelf.movies
        } else if !req.url.starts_with("/library/sections/2/all") {
            return Reply::status(404);
        } else if kind.as_deref() == Some("2") {
            &shelf.shows
        } else {
            &shelf.episodes
        };
        let mut items = items.clone();
        let sort = query(&req.url, "sort").unwrap_or_default();
        if sort.starts_with("addedAt") {
            items.sort_by_key(|i| std::cmp::Reverse(i.added));
        } else if sort.starts_with("updatedAt") {
            items.sort_by_key(|i| std::cmp::Reverse(i.updated));
        } else if sort.starts_with("lastViewedAt") {
            items.sort_by_key(|i| std::cmp::Reverse(i.viewed));
        }
        let start: usize = query(&req.url, "X-Plex-Container-Start")
            .and_then(|v| v.parse().ok())
            .unwrap_or(0);
        let size: usize = query(&req.url, "X-Plex-Container-Size")
            .and_then(|v| v.parse().ok())
            .unwrap_or(items.len());
        let total = items.len();
        let page: Vec<String> = items
            .iter()
            .skip(start)
            .take(size)
            .map(|i| {
                let watch = match (i.viewed, i.offset_ms) {
                    (Some(at), Some(ms)) => format!(r#""lastViewedAt":{at},"viewOffset":{ms},"#),
                    (Some(at), None) => format!(r#""lastViewedAt":{at},"viewCount":1,"#),
                    _ => String::new(),
                };
                let own = match (kind.as_deref(), i.show) {
                    (Some("2"), Some(show)) => format!(
                        r#""title":"{show}","summary":"About {show}.",
                           "thumb":"/library/metadata/{}/thumb/1""#,
                        i.key
                    ),
                    (_, Some(show)) => format!(
                        r#""title":"Episode {key}","grandparentTitle":"{show}",
                           "parentIndex":1,"index":{key},
                           "Media":[{{"Part":[{{"key":"/library/parts/{part}/1/e.mkv","size":1}}]}}]"#,
                        key = i.key,
                        part = i.part
                    ),
                    _ => format!(
                        r#""title":"Film {key}","year":2000,
                           "Media":[{{"Part":[{{"key":"/library/parts/{part}/1/f.mkv","size":1}}]}}]"#,
                        key = i.key,
                        part = i.part
                    ),
                };
                format!(
                    r#"{{"ratingKey":"{}","addedAt":{},"updatedAt":{},"duration":6000000,{watch}{own}}}"#,
                    i.key, i.added, i.updated
                )
            })
            .collect();
        Reply::json(&format!(
            r#"{{"MediaContainer":{{"size":{},"totalSize":{total},"Metadata":[{}]}}}}"#,
            page.len(),
            page.join(",")
        ))
    })
}

/// One query parameter of a URL the fake recorded, undecoded.
pub fn query(url: &str, key: &str) -> Option<String> {
    let prefix = format!("{key}=");
    url.split(['?', '&'])
        .skip(1)
        .find_map(|kv| kv.strip_prefix(prefix.as_str()).map(|v| v.to_string()))
}

/// Serves `data` over HTTP Range requests, like a Plex direct-play URL.
pub fn range_server(data: Vec<u8>) -> FakeServer {
    FakeServer::start(move |req| {
        let Some(range) = req.header("Range") else {
            return Reply::status(400);
        };
        let Some((from, to)) = range.trim().trim_start_matches("bytes=").split_once('-') else {
            return Reply::status(400);
        };
        let start: usize = from.parse().unwrap_or(0);
        let end = to
            .parse::<usize>()
            .unwrap_or(usize::MAX)
            .min(data.len().saturating_sub(1));
        if data.is_empty() || start > end {
            return Reply::status(416);
        }
        Reply {
            status: 206,
            headers: vec![(
                "Content-Range".to_string(),
                format!("bytes {start}-{end}/{}", data.len()),
            )],
            body: data[start..=end].to_vec(),
        }
    })
}

impl Drop for FakeServer {
    fn drop(&mut self) {
        // the worker thread ends on its own once unblocked; joining it here
        // would hang the test suite if it were mid-request
        self.server.unblock();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn status(url: &str, token: Option<&str>) -> u16 {
        let mut req = ureq::get(url);
        if let Some(token) = token {
            req = req.set("X-Plex-Token", token);
        }
        match req.call() {
            Ok(resp) => resp.status(),
            Err(ureq::Error::Status(code, _)) => code,
            Err(e) => panic!("transport error: {e}"),
        }
    }

    /// The fake refuses `/photo/:/transcode` the same way a real server
    /// would: no token, no numeric box, or a `url` naming nothing, all fail
    /// before it, and only a request with all three succeeds.
    #[test]
    fn the_transcode_endpoint_refuses_a_malformed_request_like_the_real_one() {
        let server = library();
        let ok = format!(
            "{}/photo/:/transcode?width=408&height=612&url=%2Flibrary%2Fmetadata%2F101%2Fthumb%2F1",
            server.base_url
        );
        assert_eq!(status(&ok, None), 401, "no token at all");
        assert_eq!(status(&ok, Some("nope")), 401, "the wrong token");

        let no_width = format!(
            "{}/photo/:/transcode?height=612&url=%2Flibrary%2Fmetadata%2F101%2Fthumb%2F1",
            server.base_url
        );
        assert_eq!(status(&no_width, Some("tok")), 400, "no width at all");

        let bad_width = format!(
            "{}/photo/:/transcode?width=big&height=612&url=%2Flibrary%2Fmetadata%2F101%2Fthumb%2F1",
            server.base_url
        );
        assert_eq!(
            status(&bad_width, Some("tok")),
            400,
            "a width that is not a number"
        );

        let no_url = format!("{}/photo/:/transcode?width=408&height=612", server.base_url);
        assert_eq!(status(&no_url, Some("tok")), 400, "no url at all");

        let unknown = format!(
            "{}/photo/:/transcode?width=408&height=612&url=%2Fnowhere",
            server.base_url
        );
        assert_eq!(
            status(&unknown, Some("tok")),
            404,
            "a url naming no known image"
        );

        assert_eq!(status(&ok, Some("tok")), 200, "a well formed request");
    }

    /// `library_transcode_refused` is the fallback fixture: it 400s a request
    /// a real, well formed one would succeed at, and leaves the raw thumb/art
    /// path untouched for the fallback to reach.
    #[test]
    fn library_transcode_refused_leaves_the_plain_path_working() {
        let server = library_transcode_refused();
        let sized = format!(
            "{}/photo/:/transcode?width=408&height=612&url=%2Flibrary%2Fmetadata%2F101%2Fthumb%2F1",
            server.base_url
        );
        assert_eq!(status(&sized, Some("tok")), 400);

        let plain = format!("{}/library/metadata/101/thumb/1", server.base_url);
        assert_eq!(status(&plain, Some("tok")), 200);
        assert_eq!(status(&plain, None), 401);
    }
}
