use super::models::{ItemsResponse, Metadata, Section, SectionsResponse};
use serde::de::DeserializeOwned;
use std::io::Read;
use std::time::Duration;

/// Item types for /library/sections/{key}/all?type=N.
pub const TYPE_MOVIE: u8 = 1;
pub const TYPE_SHOW: u8 = 2;
pub const TYPE_EPISODE: u8 = 4;

/// The agent every state write has to name; a write without it is ignored.
const LIBRARY_IDENTIFIER: &str = "com.plexapp.plugins.library";

/// Connections the pool keeps for this server. Artwork is fetched by several
/// threads at once (`ARTWORK_FETCHERS`) and ureq pools one per host by
/// default, so every fetch past the first would open and close a socket.
const IDLE_CONNECTIONS: usize = 8;

/// The read timeout of a playback stream. A socket silent this long is dead,
/// and the range reader reopens it rather than holding the player as long as
/// an API call may legitimately take.
pub const STREAM_READ_TIMEOUT: Duration = Duration::from_secs(8);

/// Percent-encodes one query value per RFC 3986. The transcode endpoint reads
/// the art path back out of `url=`, so anything the query string would read
/// as a delimiter has to leave as `%XX`.
fn percent_encode_query(value: &str) -> String {
    let mut out = String::with_capacity(value.len());
    for byte in value.bytes() {
        match byte {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'.' | b'_' | b'~' => {
                out.push(byte as char);
            }
            _ => out.push_str(&format!("%{byte:02X}")),
        }
    }
    out
}

/// What the player is doing, as /:/timeline spells it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PlayState {
    Playing,
    Paused,
    Stopped,
}

impl PlayState {
    pub fn as_str(self) -> &'static str {
        match self {
            PlayState::Playing => "playing",
            PlayState::Paused => "paused",
            PlayState::Stopped => "stopped",
        }
    }
}

#[derive(Debug, thiserror::Error)]
pub enum PlexError {
    #[error("the Plex token was rejected")]
    Unauthorized,
    #[error("plex http status {0}")]
    Status(u16),
    #[error("plex transport error: {0}")]
    Transport(String),
    #[error("invalid plex response: {0}")]
    Decode(String),
}

pub struct ItemsPage {
    /// Items in the whole section, as the server reports it.
    pub total: u32,
    pub items: Vec<Metadata>,
}

/// A lookup worth a line. Resolving a Plex server's name costs a millisecond
/// or two once the OS has it cached; the 3.3 s a cold one cost on the owner's
/// Apple TV is the kind of thing the next person reading a console needs to
/// see, and ureq puts no deadline on the lookup at all.
const SLOW_LOOKUP: Duration = Duration::from_millis(200);

/// The address a `plex.direct` name already carries, or None for any other
/// host. Plex publishes `192-168-1-35.<hash>.plex.direct` through public DNS
/// so a certificate can be issued for a machine on a private network: the
/// first label is the address, with dashes for dots. Reading it costs nothing,
/// where asking the internet for it cost 3.3 s on the owner's Apple TV.
///
/// Only the dotted-quad form: Plex spells IPv6 differently and a name that
/// does not parse is left to the resolver rather than guessed at. The
/// hostname is still what TLS validates against - this decides where to
/// connect, not who we are talking to.
pub(crate) fn address_in_name(host: &str) -> Option<std::net::Ipv4Addr> {
    let (label, zone) = host.split_once('.')?;
    if !zone.ends_with("plex.direct") {
        return None;
    }
    let mut octets = [0u8; 4];
    let mut parts = label.split('-');
    for octet in &mut octets {
        *octet = parts.next()?.parse().ok()?;
    }
    if parts.next().is_some() {
        return None;
    }
    Some(std::net::Ipv4Addr::from(octets))
}

/// `ToSocketAddrs`, with a line for a lookup that took long enough to matter.
/// Names no address: how many came back and in which families is the shape of
/// the answer, and the address itself is the owner's own server.
pub fn timed_resolve(netloc: &str) -> std::io::Result<Vec<std::net::SocketAddr>> {
    use std::net::ToSocketAddrs;
    if let Some((host, port)) = netloc.rsplit_once(':') {
        if let (Some(ip), Ok(port)) = (address_in_name(host), port.parse::<u16>()) {
            return Ok(vec![std::net::SocketAddr::from((ip, port))]);
        }
    }
    let t0 = std::time::Instant::now();
    let addrs: Vec<std::net::SocketAddr> = netloc.to_socket_addrs()?.collect();
    let took = t0.elapsed();
    if took >= SLOW_LOOKUP {
        let v6 = addrs.iter().filter(|a| a.is_ipv6()).count();
        eprintln!(
            "[lexis.open] name lookup {} ms, {} addrs ({} v6, {} v4)",
            took.as_millis(),
            addrs.len(),
            v6,
            addrs.len() - v6,
        );
    }
    Ok(addrs)
}

#[derive(Clone)]
pub struct PlexClient {
    agent: ureq::Agent,
    /// Part fetches only: the same settings with `STREAM_READ_TIMEOUT`.
    stream_agent: ureq::Agent,
    base_url: String,
    token: String,
    /// This install's identity, on every request. Plex takes a request without
    /// it and drops the ones that write state on the floor: a timeline comes
    /// back 200 and the resume point never moves.
    client_id: String,
}

impl PlexClient {
    pub fn new(base_url: &str, token: &str, client_id: &str) -> PlexClient {
        let builder = || {
            ureq::AgentBuilder::new()
                .timeout_connect(Duration::from_secs(10))
                // the token rides in a header, which ureq would forward to
                // whatever host a redirect names
                .redirects(0)
                // artwork is fetched by several threads at once and the default
                // pool holds one connection per host: without this every image
                // past the first opens a socket of its own and closes it again
                .max_idle_connections_per_host(IDLE_CONNECTIONS)
                .resolver(timed_resolve)
        };
        PlexClient {
            agent: builder().timeout_read(Duration::from_secs(30)).build(),
            stream_agent: builder().timeout_read(STREAM_READ_TIMEOUT).build(),
            base_url: base_url.trim_end_matches('/').to_string(),
            token: token.to_string(),
            client_id: client_id.to_string(),
        }
    }

    /// Cloning shares the connection pool.
    pub fn agent(&self) -> ureq::Agent {
        self.agent.clone()
    }

    /// The agent part fetches share, and the pool `warm` keeps a connection in.
    pub fn stream_agent(&self) -> ureq::Agent {
        self.stream_agent.clone()
    }

    /// Leaves one live connection to this server in the agent's pool, which
    /// is the pool a part fetch takes its own from. `/identity` is the
    /// cheapest thing a Plex server answers and it needs no token, so a warm
    /// connection is never a credential sent somewhere it was not needed.
    ///
    /// The body is read to the end on purpose: a response dropped unread
    /// leaves ureq no way to know the connection is still good, and it closes
    /// it instead of pooling it, which would warm nothing.
    pub fn warm(&self) {
        if let Ok(resp) = self
            .stream_agent
            .get(&format!("{}/identity", self.base_url))
            .call()
        {
            let _ = resp.into_string();
        }
    }

    pub fn token(&self) -> &str {
        &self.token
    }

    /// Absolute URL for a Part key ("/library/parts/123/1/file.mkv").
    pub fn part_url(&self, part_key: &str) -> String {
        format!("{}{}", self.base_url, part_key)
    }

    /// A server-side resize of a thumb or art path, fit into `width`x`height`
    /// rather than served at whatever resolution the library holds it at.
    /// `minSize`/`upscale` ask the server not to enlarge a source already
    /// smaller than the box; `width`/`height` alone still bound the result if
    /// a server ignores them.
    pub fn transcoded_art_url(&self, art_path: &str, width: u32, height: u32) -> String {
        format!(
            "{}/photo/:/transcode?width={width}&height={height}&minSize=1&upscale=1&url={}",
            self.base_url,
            percent_encode_query(art_path)
        )
    }

    pub fn sections(&self) -> Result<Vec<Section>, PlexError> {
        let resp: SectionsResponse = self.get_json("/library/sections", &[])?;
        Ok(resp.container.directory)
    }

    /// One window of a section, in the server's own order or by `sort`
    /// ("addedAt:desc"). The caller pages; nothing here is unbounded.
    pub fn items_page(
        &self,
        section_key: &str,
        item_type: u8,
        sort: Option<&str>,
        start: u32,
        size: u32,
    ) -> Result<ItemsPage, PlexError> {
        let path = format!("/library/sections/{section_key}/all");
        let mut query = vec![
            ("type", item_type.to_string()),
            // The Media attributes carry the resolution and the codecs but
            // not the transfer function, so HDR is only ever readable off
            // the video track. This is what puts the tracks in the listing
            // the sync already makes; a server that does not know the
            // parameter ignores it and answers exactly as it did before,
            // which is the same answer as a section with no HDR in it.
            ("includeStreams", "1".to_string()),
            ("X-Plex-Container-Start", start.to_string()),
            ("X-Plex-Container-Size", size.to_string()),
        ];
        if let Some(sort) = sort {
            query.push(("sort", sort.to_string()));
        }
        let resp: ItemsResponse = self.get_json(&path, &query)?;
        let container = resp.container;
        // totalSize is only sent on paged responses; without it the window we
        // just read is all there is, and the caller must not loop forever
        let total = if container.total_size > 0 {
            container.total_size
        } else {
            start.saturating_add(container.metadata.len() as u32)
        };
        Ok(ItemsPage {
            total,
            items: container.metadata,
        })
    }

    /// Reports where playback got to. Times are milliseconds, as the API takes
    /// them. `Stopped` is the state that records a resume point without opening
    /// a play session on the server, which is what a report every few seconds
    /// wants: Lexis is writing history, not driving the server's dashboard.
    pub fn timeline(
        &self,
        rating_key: &str,
        state: PlayState,
        time_ms: i64,
        duration_ms: i64,
    ) -> Result<(), PlexError> {
        self.get_ok(
            "/:/timeline",
            &[
                ("ratingKey", rating_key.to_string()),
                ("key", format!("/library/metadata/{rating_key}")),
                ("identifier", LIBRARY_IDENTIFIER.to_string()),
                ("time", time_ms.to_string()),
                ("state", state.as_str().to_string()),
                ("duration", duration_ms.to_string()),
            ],
        )
    }

    /// Marks the item played, whatever position it was left at.
    pub fn scrobble(&self, rating_key: &str) -> Result<(), PlexError> {
        self.get_ok(
            "/:/scrobble",
            &[
                ("identifier", LIBRARY_IDENTIFIER.to_string()),
                ("key", rating_key.to_string()),
            ],
        )
    }

    pub fn unscrobble(&self, rating_key: &str) -> Result<(), PlexError> {
        self.get_ok(
            "/:/unscrobble",
            &[
                ("identifier", LIBRARY_IDENTIFIER.to_string()),
                ("key", rating_key.to_string()),
            ],
        )
    }

    /// A call whose answer is its status alone. The state endpoints send an
    /// empty body, which `get_json` would report as a decode failure.
    pub(crate) fn get_ok(&self, path: &str, query: &[(&str, String)]) -> Result<(), PlexError> {
        let mut req = self
            .agent
            .get(&format!("{}{}", self.base_url, path))
            .set("X-Plex-Token", &self.token)
            .set("X-Plex-Client-Identifier", &self.client_id)
            .set("X-Plex-Product", "Lexis");
        for (k, v) in query {
            req = req.query(k, v);
        }
        let resp = req.call().map_err(|e| match e {
            ureq::Error::Status(401, _) => PlexError::Unauthorized,
            ureq::Error::Status(code, _) => PlexError::Status(code),
            ureq::Error::Transport(t) => PlexError::Transport(t.kind().to_string()),
        })?;
        let status = resp.status();
        // read and drop it: an unread body keeps the connection out of the
        // pool, and the next report would open a new one
        let _ = resp.into_string();
        // `call` only fails from 400 up, and redirects are disabled, so a 3xx
        // arrives here as a response: the server recorded nothing
        if status != 200 {
            return Err(PlexError::Status(status));
        }
        Ok(())
    }

    /// The untyped reading of `get_json`, for the endpoints whose answer is
    /// a couple of fields in a large, shifting document: the transcode
    /// decision is the one, and a struct per server version is not worth it.
    pub(crate) fn get_json_value(
        &self,
        path: &str,
        query: &[(&str, String)],
    ) -> Result<serde_json::Value, PlexError> {
        self.get_json(path, query)
    }

    pub(crate) fn base_url(&self) -> &str {
        &self.base_url
    }

    fn get_json<T: DeserializeOwned>(
        &self,
        path: &str,
        query: &[(&str, String)],
    ) -> Result<T, PlexError> {
        let mut req = self
            .agent
            .get(&format!("{}{}", self.base_url, path))
            .set("Accept", "application/json")
            // a header, not a query param: a token in the URL lands in the
            // server and proxy logs of every page we read
            .set("X-Plex-Token", &self.token)
            .set("X-Plex-Client-Identifier", &self.client_id)
            .set("X-Plex-Product", "Lexis");
        for (k, v) in query {
            req = req.query(k, v);
        }
        let resp = req.call().map_err(|e| match e {
            ureq::Error::Status(401, _) => PlexError::Unauthorized,
            ureq::Error::Status(code, _) => PlexError::Status(code),
            // the kind alone: the Display of `t` prefixes the URL, and its
            // message quotes whatever ureq choked on, which is the whole header
            // line (name and token) for a token that arrived with a stray
            // newline in it, or the host for a name that did not resolve
            ureq::Error::Transport(t) => PlexError::Transport(t.kind().to_string()),
        })?;
        // whole before parsing: serde_json reads a slice several times faster
        // than a reader, and a page with its tracks runs to megabytes
        let mut body = Vec::new();
        resp.into_reader()
            .read_to_end(&mut body)
            .map_err(|e| PlexError::Transport(e.kind().to_string()))?;
        serde_json::from_slice(&body).map_err(|e| PlexError::Decode(e.to_string()))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_plex_direct_name_is_resolved_from_the_name_itself() {
        // The zone synthesises an answer for any well-formed name, so a real
        // one would resolve either way and prove nothing. This hash is the
        // wrong length, so public DNS has nothing for it: an answer can only
        // have been read out of the name. Correct, this test touches no
        // network at all.
        let addrs = timed_resolve("172-31-9-9.zzzz.plex.direct:32400").unwrap();
        assert_eq!(addrs.len(), 1, "{addrs:?}");
        assert_eq!(addrs[0].to_string(), "172.31.9.9:32400");
    }

    #[test]
    fn anything_that_is_not_that_shape_is_left_to_the_resolver() {
        // a label that is not four octets, a zone that is not plex.direct, and
        // an IPv6 spelling Plex writes differently: each is a guess this must
        // not make
        assert_eq!(address_in_name("192-168-1.hash.plex.direct"), None);
        assert_eq!(address_in_name("192-168-1-35-9.hash.plex.direct"), None);
        assert_eq!(address_in_name("192-168-1-999.hash.plex.direct"), None);
        assert_eq!(address_in_name("192-168-1-35.example.com"), None);
        assert_eq!(address_in_name("plex.direct"), None);
        assert_eq!(
            address_in_name("192-168-1-35.hash.plex.direct")
                .map(|ip| ip.to_string())
                .as_deref(),
            Some("192.168.1.35")
        );
    }

    use crate::plex::fake::{FakeServer, Reply, EPISODES_JSON, MOVIES_JSON, SECTIONS_JSON};

    fn param(url: &str, key: &str) -> Option<String> {
        let prefix = format!("{key}=");
        url.split(['?', '&'])
            .skip(1)
            .find_map(|kv| kv.strip_prefix(prefix.as_str()).map(|v| v.to_string()))
    }

    #[test]
    fn sections_carry_the_token_and_ask_for_json() {
        let server = FakeServer::start(|_req| Reply::json(SECTIONS_JSON));
        let client = PlexClient::new(&server.base_url, "tok123", "install");

        let sections = client.sections().unwrap();
        assert_eq!(sections.len(), 3);
        assert_eq!(sections[0].key, "1");
        assert_eq!(sections[0].kind, "movie");
        assert_eq!(sections[0].title, "Movies");
        assert_eq!(sections[1].kind, "show");

        let req = &server.requests()[0];
        assert_eq!(req.url, "/library/sections");
        // the token travels in a header, never in a logged URL
        assert_eq!(req.header("X-Plex-Token"), Some("tok123"));
        assert!(!req.url.contains("tok123"), "{}", req.url);
        assert_eq!(req.header("Accept"), Some("application/json"));
    }

    #[test]
    fn a_trailing_slash_on_the_base_url_does_not_double_up() {
        let server = FakeServer::start(|_req| Reply::json(SECTIONS_JSON));
        let client = PlexClient::new(&format!("{}/", server.base_url), "tok", "install");
        client.sections().unwrap();
        assert_eq!(server.requests()[0].url, "/library/sections");
        assert_eq!(
            client.part_url("/library/parts/1/1/f.mkv"),
            format!("{}/library/parts/1/1/f.mkv", server.base_url)
        );
    }

    #[test]
    fn a_transcode_url_sizes_the_request_and_keeps_the_token_out_of_it() {
        let client = PlexClient::new("http://plex.local:32400", "sekrit", "install");
        let url = client.transcoded_art_url("/library/metadata/101/thumb/1", 408, 612);
        assert_eq!(
            url,
            "http://plex.local:32400/photo/:/transcode?width=408&height=612&\
             minSize=1&upscale=1&url=%2Flibrary%2Fmetadata%2F101%2Fthumb%2F1"
        );
        assert!(!url.contains("sekrit"), "{url}");
    }

    #[test]
    fn a_rejected_token_is_its_own_error() {
        let server = FakeServer::start(|_req| Reply::status(401));
        let client = PlexClient::new(&server.base_url, "stale", "install");
        assert!(matches!(client.sections(), Err(PlexError::Unauthorized)));
    }

    #[test]
    fn other_failures_keep_their_shape() {
        let server = FakeServer::start(|_req| Reply::status(503));
        let client = PlexClient::new(&server.base_url, "tok", "install");
        assert!(matches!(client.sections(), Err(PlexError::Status(503))));

        let garbage = FakeServer::start(|_req| Reply::json("{not json"));
        let client = PlexClient::new(&garbage.base_url, "tok", "install");
        assert!(matches!(client.sections(), Err(PlexError::Decode(_))));

        // nothing listens on port 1: a server that is down is not a bad token
        let down = PlexClient::new("http://127.0.0.1:1", "tok", "install");
        assert!(matches!(down.sections(), Err(PlexError::Transport(_))));
    }

    #[test]
    fn a_transport_error_never_carries_the_token() {
        let down = PlexClient::new("http://127.0.0.1:1", "sekrit-token", "install");
        let err = down.sections().unwrap_err();
        let shown = err.to_string();
        assert!(!shown.contains("sekrit-token"), "{shown}");
        assert!(!shown.contains("X-Plex-Token"), "{shown}");

        // a pasted token keeps whatever the clipboard held: a trailing newline
        // makes the header unparseable, and the rejection quotes the whole line
        let pasted = PlexClient::new("http://127.0.0.1:1", "sekrit-token\nX-Evil: 1", "install");
        let shown = pasted.sections().unwrap_err().to_string();
        assert!(!shown.contains("sekrit-token"), "{shown}");
        assert!(!shown.contains("X-Plex-Token"), "{shown}");
    }

    #[test]
    fn a_movie_page_carries_type_and_window_and_parses_parts() {
        let server = FakeServer::start(|_req| Reply::json(MOVIES_JSON));
        let client = PlexClient::new(&server.base_url, "tok", "install");

        let page = client.items_page("1", TYPE_MOVIE, None, 0, 200).unwrap();
        assert_eq!(page.total, 1);
        assert_eq!(page.items.len(), 1);
        let movie = &page.items[0];
        assert_eq!(movie.rating_key, "101");
        assert_eq!(movie.title, "Dune");
        assert_eq!(movie.year, Some(2021));
        assert_eq!(movie.media[0].part[0].id, 501);
        assert_eq!(movie.media[0].part[0].key, "/library/parts/501/1/Dune.mkv");
        assert_eq!(movie.media[0].part[0].size, 42);

        let url = &server.requests()[0].url;
        assert!(url.starts_with("/library/sections/1/all?"), "{url}");
        assert_eq!(param(url, "type").as_deref(), Some("1"));
        assert_eq!(param(url, "X-Plex-Container-Start").as_deref(), Some("0"));
        assert_eq!(param(url, "X-Plex-Container-Size").as_deref(), Some("200"));
        // the tracks come back in this listing or not at all: the Media
        // attributes carry no transfer function, so HDR is only readable off
        // the video track, and a request per item is a round trip per title
        assert_eq!(param(url, "includeStreams").as_deref(), Some("1"));
        let stream = &movie.media[0].part[0].stream[0];
        assert_eq!(stream.stream_type, Some(1));
        assert_eq!(stream.color_trc.as_deref(), Some("smpte2084"));
    }

    #[test]
    fn an_episode_page_parses_show_season_and_episode() {
        let server = FakeServer::start(|_req| Reply::json(EPISODES_JSON));
        let client = PlexClient::new(&server.base_url, "tok", "install");

        let page = client.items_page("2", TYPE_EPISODE, None, 0, 200).unwrap();
        assert_eq!(page.total, 2);
        let last = &page.items[1];
        assert_eq!(last.grandparent_title.as_deref(), Some("The Expanse"));
        assert_eq!(last.parent_index, Some(2));
        assert_eq!(last.index, Some(3));
        assert_eq!(last.media[0].part[0].key, "/library/parts/602/1/S02E03.mkv");
        assert_eq!(
            param(&server.requests()[0].url, "type").as_deref(),
            Some("4")
        );
    }

    #[test]
    fn a_response_without_total_size_still_reports_a_total() {
        let server = FakeServer::start(|_req| {
            Reply::json(
                r#"{"MediaContainer":{"size":1,"Metadata":[
                {"ratingKey":"1","title":"Solo","Media":[{"Part":[{"key":"/p/1","size":1}]}]}
            ]}}"#,
            )
        });
        let client = PlexClient::new(&server.base_url, "tok", "install");
        let page = client.items_page("1", TYPE_MOVIE, None, 10, 200).unwrap();
        assert_eq!(page.total, 11); // start + what came back: the loop stops
        assert_eq!(page.items[0].year, None);
        assert!(page.items[0].grandparent_title.is_none());
    }

    #[test]
    fn an_empty_section_yields_no_items() {
        let server =
            FakeServer::start(|_req| Reply::json(r#"{"MediaContainer":{"size":0,"totalSize":0}}"#));
        let client = PlexClient::new(&server.base_url, "tok", "install");
        let page = client.items_page("1", TYPE_MOVIE, None, 0, 200).unwrap();
        assert_eq!(page.total, 0);
        assert!(page.items.is_empty());
    }

    #[test]
    fn item_pages_report_a_rejected_token_too() {
        let server = FakeServer::start(|_req| Reply::status(401));
        let client = PlexClient::new(&server.base_url, "stale", "install");
        assert!(matches!(
            client.items_page("1", TYPE_MOVIE, None, 0, 200),
            Err(PlexError::Unauthorized)
        ));
    }

    #[test]
    fn a_timeline_report_carries_the_item_the_position_and_the_runtime() {
        let server = FakeServer::start(|_req| Reply::status(200));
        let client = PlexClient::new(&server.base_url, "tok", "install");

        client
            .timeline("202", PlayState::Stopped, 930_000, 3_000_000)
            .unwrap();

        let req = &server.requests()[0];
        assert!(req.url.starts_with("/:/timeline?"), "{}", req.url);
        assert_eq!(param(&req.url, "ratingKey").as_deref(), Some("202"));
        assert_eq!(param(&req.url, "time").as_deref(), Some("930000"));
        assert_eq!(param(&req.url, "duration").as_deref(), Some("3000000"));
        assert_eq!(param(&req.url, "state").as_deref(), Some("stopped"));
        // Without this the server takes the report and does nothing with it:
        // 200, and the resume point never moves. It is the whole of why
        // history was not reaching Plex.
        assert_eq!(req.header("X-Plex-Client-Identifier"), Some("install"));
        assert_eq!(req.header("X-Plex-Product"), Some("Lexis"));
        assert_eq!(
            param(&req.url, "identifier").as_deref(),
            Some("com.plexapp.plugins.library")
        );
        // the item's own metadata path, as every Plex client sends it
        assert!(
            req.url.contains("key=%2Flibrary%2Fmetadata%2F202")
                || req.url.contains("key=/library/metadata/202"),
            "{}",
            req.url
        );
        // the token is a header, never a query parameter
        assert_eq!(req.header("X-Plex-Token"), Some("tok"));
        assert!(!req.url.contains("tok"), "{}", req.url);
    }

    #[test]
    fn scrobbling_marks_an_item_played_and_unscrobbling_undoes_it() {
        let server = FakeServer::start(|_req| Reply::status(200));
        let client = PlexClient::new(&server.base_url, "tok", "install");

        client.scrobble("101").unwrap();
        client.unscrobble("101").unwrap();

        let requests = server.requests();
        assert!(
            requests[0].url.starts_with("/:/scrobble?"),
            "{:?}",
            requests[0]
        );
        assert_eq!(param(&requests[0].url, "key").as_deref(), Some("101"));
        assert_eq!(
            param(&requests[0].url, "identifier").as_deref(),
            Some("com.plexapp.plugins.library")
        );
        assert!(
            requests[1].url.starts_with("/:/unscrobble?"),
            "{:?}",
            requests[1]
        );
        assert_eq!(param(&requests[1].url, "key").as_deref(), Some("101"));
        assert_eq!(requests[1].header("X-Plex-Token"), Some("tok"));
    }

    #[test]
    fn an_empty_body_is_success_and_a_refusal_keeps_its_shape() {
        // what a real server sends back: 200 and nothing at all
        let server = FakeServer::start(|_req| Reply::status(200));
        let client = PlexClient::new(&server.base_url, "tok", "install");
        assert!(client.timeline("1", PlayState::Playing, 0, 0).is_ok());

        let stale = FakeServer::start(|_req| Reply::status(401));
        let client = PlexClient::new(&stale.base_url, "s3cr3t", "install");
        let err = client
            .timeline("1", PlayState::Stopped, 1000, 2000)
            .unwrap_err();
        assert!(matches!(err, PlexError::Unauthorized));
        assert!(!err.to_string().contains("s3cr3t"), "{err}");
        assert!(matches!(client.scrobble("1"), Err(PlexError::Unauthorized)));

        let broken = FakeServer::start(|_req| Reply::status(503));
        let client = PlexClient::new(&broken.base_url, "tok", "install");
        assert!(matches!(
            client.unscrobble("1"),
            Err(PlexError::Status(503))
        ));

        // nothing listens on port 1: a server that is down is not a bad token
        let down = PlexClient::new("http://127.0.0.1:1", "s3cr3t", "install");
        let err = down.timeline("1", PlayState::Stopped, 0, 0).unwrap_err();
        assert!(matches!(err, PlexError::Transport(_)));
        assert!(!err.to_string().contains("s3cr3t"), "{err}");
    }

    #[test]
    fn a_redirect_is_a_write_the_server_never_recorded() {
        // a Plex behind a proxy that sends http to https: the token must not
        // follow the redirect, so the write is lost and has to be reported
        let server = FakeServer::start(|_req| Reply {
            status: 302,
            headers: vec![("Location".to_string(), "https://elsewhere/".to_string())],
            body: Vec::new(),
        });
        let client = PlexClient::new(&server.base_url, "tok", "install");
        assert!(matches!(
            client.timeline("1", PlayState::Stopped, 0, 0),
            Err(PlexError::Status(302))
        ));
        assert!(matches!(client.scrobble("1"), Err(PlexError::Status(302))));
        assert!(matches!(
            client.unscrobble("1"),
            Err(PlexError::Status(302))
        ));
        // the token stayed here, on the host it was given for
        for req in server.requests() {
            assert_eq!(req.header("X-Plex-Token"), Some("tok"));
        }
    }

    #[test]
    fn the_switchable_library_refuses_writes_and_then_takes_them() {
        use crate::plex::fake::refusing_library;
        use std::sync::atomic::{AtomicBool, Ordering};
        use std::sync::Arc;

        let refusing = Arc::new(AtomicBool::new(true));
        let server = refusing_library(refusing.clone(), 503, true);
        let client = PlexClient::new(&server.base_url, "tok", "install");
        assert!(matches!(
            client.timeline("101", PlayState::Stopped, 1000, 2000),
            Err(PlexError::Status(503))
        ));
        // the library answers all along: a scan works while the writes do not
        assert!(client.sections().is_ok());

        refusing.store(false, Ordering::SeqCst);
        assert!(client
            .timeline("101", PlayState::Stopped, 1000, 2000)
            .is_ok());
        assert_eq!(server.requests().len(), 3);
    }
}
