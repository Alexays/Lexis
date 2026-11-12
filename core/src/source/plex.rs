use super::module::{Choice, ChoicesState, LinkStart, LinkState, Setup, SourceModule, Values};
use super::{
    ArtKind, ArtUrl, Catalogue, Entry, Pause, PlaybackState, ReadSeek, Source, SourceError,
    WatchSync,
};
use crate::api::CoreError;
use crate::index::db::Db;
use crate::index::scan::{ScanError, ScanStats};
use crate::plex::client::{PlayState, PlexClient, PlexError};
use crate::plex::sync::{sync, SyncError};
use parking_lot::Mutex;
use std::collections::HashMap;
use std::io::{self, Read, Seek, SeekFrom};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, OnceLock};

/// tvOS poster tile at 2x (`tv/Sources/App/Theme.swift`: 204x306 points).
const POSTER_WIDTH: u32 = 408;
const POSTER_HEIGHT: u32 = 612;

/// A backdrop is full bleed behind a hero: 1920x1080 points at 2x, so this is
/// native and nothing is upscaled. A projector shows the difference an
/// intermediate rung leaves, which is why the owner asked for it; the price
/// is a projected 3.45 GB over a full library in a cache that has no
/// eviction yet. Plex transcodes to whatever is asked; `TMDB_BACKDROP_BASE`
/// reaches the same place through `original`, its only rung above w1280. One
/// file per title serves the hero and the 400x225pt resume thumbnail alike.
const BACKDROP_WIDTH: u32 = 3840;
const BACKDROP_HEIGHT: u32 = 2160;

/// The same wide image for a rail's landscape card, which is 400x225pt: 2x
/// that and no more. The hero's file drawn here would be twenty times the
/// bytes and a 4K resize on the server, for an image scaled down to this.
const THUMB_WIDTH: u32 = 800;
const THUMB_HEIGHT: u32 = 450;

/// An episode's own frame, drawn beside its own words at 320x180pt
/// (`tv/Sources/App/Theme.swift`) and asked for at 2x. Half the thumbnail's pixels, and
/// a season of Friends is twenty-four of these against one backdrop: a list
/// asks for as many at once as a rail does and each one is seen once.
const STILL_WIDTH: u32 = 640;
const STILL_HEIGHT: u32 = 360;

/// The playback half of the Plex connector. The library half is plex::sync.
pub struct PlexSource {
    id: String,
    client: PlexClient,
}

impl PlexSource {
    pub fn new(id: &str, base_url: &str, token: &str, client_id: &str) -> PlexSource {
        PlexSource {
            id: id.to_string(),
            client: PlexClient::new(base_url, token, client_id),
        }
    }
}

impl Source for PlexSource {
    fn id(&self) -> &str {
        &self.id
    }

    /// Always empty: Plex is indexed through `catalogue()`, which bypasses
    /// directory listing entirely.
    fn list(&self, _dir_path: &str) -> Result<Vec<Entry>, SourceError> {
        Ok(Vec::new())
    }

    /// `file_path` is a Plex Part key ("/library/parts/123/1/file.mkv"), the
    /// path `catalogue()` stored in the files table.
    fn open(&self, file_path: &str) -> Result<Box<dyn ReadSeek>, SourceError> {
        // `--log-source` on the process prints the part's full address, token
        // included: a measurement switch, for playing the same file outside
        // the app.
        if std::env::args().any(|a| a == "--log-source") {
            eprintln!(
                "[lexis-core] source: {}?X-Plex-Token={}",
                self.client.part_url(file_path),
                self.client.token()
            );
        }
        let reader = RangeReader::open(
            self.client.stream_agent(),
            self.client.part_url(file_path),
            "X-Plex-Token",
            self.client.token(),
        )?;
        Ok(Box::new(reader))
    }

    fn catalogue(&self) -> Option<&dyn Catalogue> {
        Some(self)
    }

    fn watch_sync(&self) -> Option<&dyn WatchSync> {
        Some(self)
    }

    fn warm(&self) {
        self.client.warm();
    }
}

/// A rejected token, a transport failure and a 5xx are queueable the same way
/// a `SourceError::Io`/`Unauthorized` is; anything else the server understood
/// and meant, so it fails the same way forever.
fn convert(e: PlexError) -> SourceError {
    match e {
        PlexError::Unauthorized => SourceError::Unauthorized,
        PlexError::Transport(t) => SourceError::Io(std::io::Error::other(t)),
        PlexError::Status(code) if code >= 500 => {
            SourceError::Io(std::io::Error::other(format!("http status {code}")))
        }
        PlexError::Status(code) => SourceError::Refused(format!("http status {code}")),
        PlexError::Decode(msg) => SourceError::Refused(msg),
    }
}

impl Catalogue for PlexSource {
    fn pull(&self, db: &Mutex<Db>, paused: &Pause, full: bool) -> Result<ScanStats, ScanError> {
        sync(db, &self.client, &self.id, paused, full).map_err(|e| {
            let msg = e.to_string();
            match e {
                SyncError::Index(e) => ScanError::Index(e),
                SyncError::Plex(e) => ScanError::Source(convert(e)),
                SyncError::EmptyLibrary => ScanError::Source(SourceError::Refused(msg)),
            }
        })
    }
    fn art_url(&self, art_path: &str, kind: ArtKind) -> ArtUrl {
        let (width, height) = match kind {
            ArtKind::Poster => (POSTER_WIDTH, POSTER_HEIGHT),
            ArtKind::Thumb => (THUMB_WIDTH, THUMB_HEIGHT),
            ArtKind::Backdrop => (BACKDROP_WIDTH, BACKDROP_HEIGHT),
            ArtKind::Still => (STILL_WIDTH, STILL_HEIGHT),
            // the lettering as the server holds it: the transcoder answers
            // a jpeg, which would lose the transparency it is drawn with
            ArtKind::Logo => {
                let url = self.client.part_url(art_path);
                return ArtUrl {
                    url: url.clone(),
                    fallback: url,
                    width: 0,
                };
            }
            // a face is keyed by a person, not by a title, so no row of this
            // catalogue's ever names one
            ArtKind::Face => {
                debug_assert!(false, "a catalogue was asked for a face");
                (POSTER_WIDTH, POSTER_HEIGHT)
            }
        };
        ArtUrl {
            url: self.client.transcoded_art_url(art_path, width, height),
            fallback: self.client.part_url(art_path),
            width,
        }
    }
    fn art_width(&self, kind: ArtKind) -> u32 {
        match kind {
            ArtKind::Poster => POSTER_WIDTH,
            ArtKind::Thumb => THUMB_WIDTH,
            ArtKind::Backdrop => BACKDROP_WIDTH,
            ArtKind::Still => STILL_WIDTH,
            // never in `asked_sizes`, which lists the logo's own TMDB size
            ArtKind::Logo => {
                debug_assert!(false, "a catalogue was asked for a logo width");
                0
            }
            ArtKind::Face => {
                debug_assert!(false, "a catalogue was asked for a face width");
                0
            }
        }
    }
    fn agent(&self) -> ureq::Agent {
        self.client.agent()
    }
    fn token(&self) -> &str {
        self.client.token()
    }
    /// The full item carries a photograph on each credit, where the listing
    /// the sync reads carries names alone. An episode's credits are its guest
    /// stars, so a show's are read off the show it belongs to.
    fn cast_faces(&self, rating_key: &str) -> Result<Vec<(String, String)>, SourceError> {
        let item = |key: &str| -> Result<serde_json::Value, SourceError> {
            let answer = self
                .client
                .get_json_value(&format!("/library/metadata/{key}"), &[])
                .map_err(convert)?;
            Ok(answer["MediaContainer"]["Metadata"][0].clone())
        };
        let mut found = item(rating_key)?;
        if found["type"] == "episode" {
            let Some(show) = found["grandparentRatingKey"].as_str().map(str::to_string) else {
                return Ok(Vec::new());
            };
            found = item(&show)?;
        }
        let mut faces = Vec::new();
        for kind in ["Role", "Director", "Writer"] {
            for credit in found[kind].as_array().into_iter().flatten() {
                if let (Some(name), Some(thumb)) =
                    (credit["tag"].as_str(), credit["thumb"].as_str())
                {
                    if thumb.starts_with("https://") {
                        faces.push((name.replace(',', " "), thumb.to_string()));
                    }
                }
            }
        }
        Ok(faces)
    }
    /// Plex's own intro and credits detection, where the server was set to
    /// run it: offsets in milliseconds, on the item itself.
    fn markers(&self, rating_key: &str) -> Result<Vec<super::Marker>, SourceError> {
        let answer = self
            .client
            .get_json_value(
                &format!("/library/metadata/{rating_key}"),
                &[("includeMarkers", "1".to_string())],
            )
            .map_err(convert)?;
        let found = &answer["MediaContainer"]["Metadata"][0]["Marker"];
        Ok(found
            .as_array()
            .into_iter()
            .flatten()
            .filter_map(|marker| {
                let credits = match marker["type"].as_str()? {
                    "intro" => false,
                    "credits" => true,
                    _ => return None,
                };
                let start = marker["startTimeOffset"].as_f64()? / 1000.0;
                let end = marker["endTimeOffset"].as_f64()? / 1000.0;
                Some(super::Marker {
                    credits,
                    start_secs: start,
                    end_secs: end.max(start),
                })
            })
            .collect())
    }
}

impl WatchSync for PlexSource {
    fn timeline(
        &self,
        rating_key: &str,
        state: PlaybackState,
        position_secs: f64,
        duration_secs: f64,
    ) -> Result<(), SourceError> {
        self.client
            .timeline(
                rating_key,
                match state {
                    PlaybackState::Playing => PlayState::Playing,
                    PlaybackState::Paused => PlayState::Paused,
                    PlaybackState::Stopped => PlayState::Stopped,
                },
                (position_secs * 1000.0) as i64,
                (duration_secs * 1000.0) as i64,
            )
            .map_err(convert)
    }
    fn scrobble(&self, rating_key: &str) -> Result<(), SourceError> {
        self.client.scrobble(rating_key).map_err(convert)
    }
    fn unscrobble(&self, rating_key: &str) -> Result<(), SourceError> {
        self.client.unscrobble(rating_key).map_err(convert)
    }
}

/// plex.tv's own account API, distinct from `PlexClient` (which talks to one
/// server once its address and token are known). Not exported: only
/// `PlexModule` uses it.
struct AccountClient {
    agent: ureq::Agent,
    base: String,
}

impl AccountClient {
    fn new(base: &str) -> AccountClient {
        AccountClient {
            agent: ureq::AgentBuilder::new()
                .timeout_connect(std::time::Duration::from_secs(10))
                .timeout_read(std::time::Duration::from_secs(10))
                .redirects(0)
                .build(),
            base: base.trim_end_matches('/').to_string(),
        }
    }

    fn start_pin(&self, client_id: &str) -> Result<(String, String), CoreError> {
        #[derive(serde::Deserialize)]
        struct Pin {
            id: i64,
            code: String,
        }
        let pin: Pin = self
            .agent
            .post(&format!("{}/api/v2/pins", self.base))
            .set("Accept", "application/json")
            .set("X-Plex-Product", "Lexis")
            .set("X-Plex-Client-Identifier", client_id)
            // "strong" picks between two unrelated code shapes: true hands
            // back a long opaque string meant for a browser redirect, false
            // the short one a viewer reads off a screen and types by hand
            .send_form(&[("strong", "false")])
            .map_err(account_error)?
            .into_json()
            .map_err(|e| CoreError::SourceUnavailable {
                source_id: "plex".to_string(),
                msg: format!("plex.tv sent something unreadable: {e}"),
            })?;
        Ok((pin.id.to_string(), pin.code))
    }

    fn poll_pin(&self, pin_id: &str, client_id: &str) -> Result<Option<String>, CoreError> {
        #[derive(serde::Deserialize)]
        struct Pin {
            #[serde(rename = "authToken")]
            auth_token: Option<String>,
        }
        let pin: Pin = self
            .agent
            .get(&format!("{}/api/v2/pins/{pin_id}", self.base))
            .set("Accept", "application/json")
            .set("X-Plex-Client-Identifier", client_id)
            .call()
            .map_err(account_error)?
            .into_json()
            .map_err(|e| CoreError::SourceUnavailable {
                source_id: "plex".to_string(),
                msg: format!("plex.tv sent something unreadable: {e}"),
            })?;
        Ok(pin.auth_token)
    }
}

/// The kind alone, never the URL or a header: this call carries no token of
/// its own yet (the pin is unauthenticated), but the pattern stays the same
/// as every other Plex error path in this crate. Also the error path for
/// `probe_choices`' resources call, which does carry a token: a 401 there
/// means the same thing it means everywhere else in this crate, so it is
/// mapped the same way `convert` maps it for a linked server.
fn account_error(e: ureq::Error) -> CoreError {
    match e {
        // plex.tv answers a pin nobody claimed the same way it answers one it
        // has never heard of or one polled with a different client
        // identifier: none of the three gives a viewer anything to act on
        // beyond starting over
        ureq::Error::Status(404, _) => CoreError::SourceUnavailable {
            source_id: "plex".to_string(),
            msg: "the link has expired".to_string(),
        },
        ureq::Error::Status(401, _) => CoreError::Unauthorized {
            source_id: "plex".to_string(),
        },
        ureq::Error::Status(code, _) => CoreError::SourceUnavailable {
            source_id: "plex".to_string(),
            msg: format!("plex.tv http status {code}"),
        },
        ureq::Error::Transport(t) => CoreError::SourceUnavailable {
            source_id: "plex".to_string(),
            msg: format!("plex.tv transport error: {}", t.kind()),
        },
    }
}

const PLEX_TV: &str = "https://plex.tv";

pub struct PlexModule;

impl SourceModule for PlexModule {
    fn id(&self) -> &'static str {
        "plex"
    }
    fn glyph(&self) -> &'static str {
        "chevron"
    }
    fn setup(&self) -> Setup {
        Setup::Link
    }
    /// The machine, not the certificate's name. Plex reaches a server on a
    /// private network through `192-168-1-35.<hash>.plex.direct`, and a viewer
    /// reading that across a room learns nothing from the hash except that it
    /// is long. The address the name carries is the thing they can act on: it
    /// is what they would type into a browser, and what tells one server on
    /// the shelf from another.
    fn detail(&self, values: &Values) -> String {
        let url = values.get("base_url").cloned().unwrap_or_default();
        let netloc = url
            .split_once("://")
            .map_or(url.as_str(), |(_, rest)| rest)
            .trim_end_matches('/');
        let (host, port) = netloc.rsplit_once(':').unwrap_or((netloc, ""));
        match crate::plex::client::address_in_name(host) {
            Some(ip) if port.is_empty() => ip.to_string(),
            Some(ip) => format!("{ip}:{port}"),
            None => url,
        }
    }
    fn secret_keys(&self) -> &'static [&'static str] {
        &["token"]
    }
    fn build(&self, id: &str, values: &Values) -> Result<Arc<dyn Source>, CoreError> {
        let base_url = values
            .get("base_url")
            .ok_or_else(|| CoreError::InvalidConfig {
                msg: "a Plex source needs a base_url".to_string(),
            })?;
        // a bare host reaches the HTTP client as a relative URL and fails much
        // later with a message nobody can act on
        if !base_url.starts_with("http://") && !base_url.starts_with("https://") {
            return Err(CoreError::InvalidConfig {
                msg: "a Plex base URL must start with http:// or https://".to_string(),
            });
        }
        let token = values
            .get("token")
            .ok_or_else(|| CoreError::InvalidConfig {
                msg: "a Plex source needs a token".to_string(),
            })?;
        // Plex accepts a request with no client identity and quietly does
        // nothing with the ones that write state - a timeline lands 200 and
        // never moves the resume point. plex.tv is blunter about it and 400s,
        // which is why the account client has always sent this and the server
        // client never did.
        let client_id = values
            .get(crate::api::sources::CLIENT_ID_KEY)
            .map(String::as_str)
            .unwrap_or_default();
        Ok(Arc::new(PlexSource::new(id, base_url, token, client_id)))
    }

    fn link_start(&self, install_id: &str) -> Result<LinkStart, CoreError> {
        self.link_start_at(PLEX_TV, install_id)
    }

    fn link_poll(
        &self,
        install_id: &str,
        state: &Values,
    ) -> Result<(LinkState, Values), CoreError> {
        self.link_poll_at(PLEX_TV, install_id, state)
    }

    fn link_choices(&self, state: &Values) -> Result<(ChoicesState, Values), CoreError> {
        self.link_choices_at(PLEX_TV, state)
    }

    fn choice_values(&self, state: &Values, choice_id: &str) -> Result<Values, CoreError> {
        self.choice_values_at(state, choice_id)
    }
}

#[derive(serde::Deserialize)]
struct Resource {
    name: String,
    #[serde(rename = "clientIdentifier")]
    client_identifier: String,
    provides: String,
    connections: Vec<Connection>,
}

#[derive(serde::Deserialize, Clone)]
struct Connection {
    uri: String,
    local: bool,
}

impl PlexModule {
    /// Split out so tests point it at a fake server; production always calls
    /// through `link_start`/`link_poll` above, which fix the address at
    /// `plex.tv`.
    fn link_start_at(&self, base: &str, install_id: &str) -> Result<LinkStart, CoreError> {
        let (pin_id, code) = AccountClient::new(base).start_pin(install_id)?;
        let mut state = Values::new();
        state.insert("pin_id".to_string(), pin_id);
        state.insert("account_base".to_string(), base.to_string());
        state.insert("client_id".to_string(), install_id.to_string());
        Ok(LinkStart { code, state })
    }

    fn link_poll_at(
        &self,
        base: &str,
        install_id: &str,
        state: &Values,
    ) -> Result<(LinkState, Values), CoreError> {
        let pin_id = state
            .get("pin_id")
            .ok_or_else(|| CoreError::InvalidConfig {
                msg: "this link was never started".to_string(),
            })?;
        match AccountClient::new(base).poll_pin(pin_id, install_id) {
            Ok(Some(token)) => {
                let mut next = state.clone();
                next.insert("token".to_string(), token);
                Ok((LinkState::Linked, next))
            }
            Ok(None) => Ok((LinkState::Waiting, state.clone())),
            Err(CoreError::SourceUnavailable { msg, .. }) if msg == "the link has expired" => {
                Ok((LinkState::Expired, state.clone()))
            }
            Err(e) => Err(e),
        }
    }

    /// Split out so tests point it at a fake plex.tv; production always calls
    /// through `link_choices`, which fixes the address at `plex.tv`. Starts
    /// the probe on its own thread on the first call (the state carries no
    /// `probe_id` yet) and answers `Probing` at once; a repeat call polls the
    /// same probe by the id that call was handed back. Once a probe answers
    /// `Ready`, every choice's own address is cached in the state under its
    /// id, so `choice_values_at` never has to probe again for a choice this
    /// call already resolved.
    fn link_choices_at(
        &self,
        base: &str,
        state: &Values,
    ) -> Result<(ChoicesState, Values), CoreError> {
        if let Some(probe_id) = state.get("probe_id") {
            let choices_state = poll_probe(probe_id)?;
            let mut next = state.clone();
            if let ChoicesState::Ready { choices } = &choices_state {
                for c in choices {
                    next.insert(format!("base_url:{}", c.id), c.detail.clone());
                }
            }
            return Ok((choices_state, next));
        }
        let token = state.get("token").ok_or_else(|| CoreError::InvalidConfig {
            msg: "this link has not been claimed yet".to_string(),
        })?;
        let client_id = state
            .get("client_id")
            .ok_or_else(|| CoreError::InvalidConfig {
                msg: "this link is missing its client identifier".to_string(),
            })?;
        let probe_id = start_probe(base.to_string(), token.clone(), client_id.clone());
        let mut next = state.clone();
        next.insert("probe_id".to_string(), probe_id);
        Ok((ChoicesState::Probing, next))
    }

    /// Split out so tests point it at a fake plex.tv; production always calls
    /// through `choice_values`, which fixes the address at `plex.tv`. The
    /// choice step already showed this account's servers once, and
    /// `link_choices_at` cached the address it found for every one of them
    /// in the state it handed back: the common case is a map lookup, not a
    /// second network round trip a viewer would wait on right after the one
    /// this fix already stopped blocking on. Only a state that never went
    /// through that path (or named a choice it never offered) still probes.
    fn choice_values_at(&self, state: &Values, choice_id: &str) -> Result<Values, CoreError> {
        let token = state.get("token").ok_or_else(|| CoreError::InvalidConfig {
            msg: "this link has not been claimed yet".to_string(),
        })?;
        let base_url = match state.get(&format!("base_url:{choice_id}")) {
            Some(cached) => cached.clone(),
            None => {
                let base = state
                    .get("account_base")
                    .map(String::as_str)
                    .unwrap_or(PLEX_TV);
                let client_id = state
                    .get("client_id")
                    .ok_or_else(|| CoreError::InvalidConfig {
                        msg: "this link is missing its client identifier".to_string(),
                    })?;
                let choices = probe_choices(base, token, client_id)?;
                // the choice step already showed this list; a caller passing
                // an id it never offered is not one the app produces
                choices
                    .into_iter()
                    .find(|c| c.id == choice_id)
                    .map(|c| c.detail)
                    .ok_or_else(|| CoreError::InvalidConfig {
                        msg: "no such server on this account".to_string(),
                    })?
            }
        };
        let mut values = Values::new();
        values.insert("base_url".to_string(), base_url);
        values.insert("token".to_string(), token.clone());
        Ok(values)
    }
}

/// A probe's answer once its thread has one: the same list `link_choices_at`
/// would have returned synchronously before, or the error it would have
/// failed with.
type ProbeAnswer = Option<Result<Vec<Choice>, CoreError>>;

/// One account's server probe, running on a thread of its own past the call
/// that started it, keyed by an id carried in the link session's own state.
/// The registry holds only what a `Choice` already shows on screen, never a
/// token: `start_probe` clones one into the thread it spawns, and that clone
/// is dropped with the thread's own stack once the probe answers.
fn probes() -> &'static Mutex<HashMap<String, Arc<Mutex<ProbeAnswer>>>> {
    static PROBES: OnceLock<Mutex<HashMap<String, Arc<Mutex<ProbeAnswer>>>>> = OnceLock::new();
    PROBES.get_or_init(|| Mutex::new(HashMap::new()))
}

/// Starts a probe on its own thread and returns the id it is filed under.
fn start_probe(base: String, token: String, client_id: String) -> String {
    static SEQ: AtomicU64 = AtomicU64::new(0);
    let id = format!("probe-{}", SEQ.fetch_add(1, Ordering::Relaxed));
    let slot = Arc::new(Mutex::new(None));
    probes().lock().insert(id.clone(), slot.clone());
    std::thread::spawn(move || {
        let result = probe_choices(&base, &token, &client_id);
        *slot.lock() = Some(result);
    });
    id
}

/// `Probing` while the thread `start_probe` spawned has not answered yet;
/// once it has, the answer is taken out and the registry entry dropped, so a
/// probe's own memory never outlives the one call that reads its result.
fn poll_probe(probe_id: &str) -> Result<ChoicesState, CoreError> {
    let slot = probes().lock().get(probe_id).cloned();
    let Some(slot) = slot else {
        return Err(CoreError::InvalidConfig {
            msg: "this probe is no longer running".to_string(),
        });
    };
    let done = slot.lock().take();
    match done {
        None => Ok(ChoicesState::Probing),
        Some(result) => {
            probes().lock().remove(probe_id);
            result.map(|choices| ChoicesState::Ready { choices })
        }
    }
}

/// Fetches the account's servers from plex.tv and probes each one's
/// connections, bounded the way `PROBE_TIMEOUT` and the thread-per-server
/// comment below describe. Blocking and network-bound: every caller either
/// runs it on a thread of its own (`start_probe`) or accepts the wait
/// (`choice_values_at`, already a single short call by the time it runs
/// this).
fn probe_choices(base: &str, token: &str, client_id: &str) -> Result<Vec<Choice>, CoreError> {
    let agent = ureq::AgentBuilder::new()
        .timeout_connect(std::time::Duration::from_secs(10))
        .timeout_read(std::time::Duration::from_secs(10))
        .redirects(0)
        .build();
    // plex.tv checks this header before it looks at the token: omitting it
    // answers 400 no matter how good the token is. X-Plex-Product stays off
    // this call the same way it is off poll_pin: both are GETs against an
    // already-identified client, and only the POST that registers a pin
    // names a product for the device list to show.
    let resources: Vec<Resource> = agent
        .get(&format!("{base}/api/v2/resources?includeHttps=1"))
        .set("Accept", "application/json")
        .set("X-Plex-Token", token)
        .set("X-Plex-Client-Identifier", client_id)
        .call()
        .map_err(account_error)?
        .into_json()
        .map_err(|e| CoreError::SourceUnavailable {
            source_id: "plex".to_string(),
            msg: format!("plex.tv sent something unreadable: {e}"),
        })?;
    let mut servers: Vec<Resource> = resources
        .into_iter()
        .filter(|r| r.provides.split(',').any(|p| p == "server"))
        .collect();
    // An account that holds no server is an answer, not a failure: the link
    // worked and the account is reachable, it simply offers nothing to add.
    // Returning it as an empty list is also what keeps the caller from having
    // to read English prose to tell this apart from a server that broke.
    if servers.is_empty() {
        return Ok(Vec::new());
    }
    // nearby before remote, decided once so a server's thread below and
    // its timeout fallback agree on the same order
    for r in &mut servers {
        r.connections.sort_by_key(|c| !c.local);
    }
    // one thread per server: an account's own server count must never
    // multiply the wait, only the slowest single server's connection
    // count does. The account holds few servers, so a thread each never
    // approaches a count that would call for a pool.
    let max_connections = servers
        .iter()
        .map(|r| r.connections.len())
        .max()
        .unwrap_or(1)
        .max(1);
    let bound = PROBE_TIMEOUT * max_connections as u32 + std::time::Duration::from_secs(1);
    let (tx, rx) = std::sync::mpsc::channel();
    for (i, r) in servers.iter().enumerate() {
        let tx = tx.clone();
        // Agent is an Arc handle to shared connection state; cloning it
        // never touches the token, which no thread here is given at all
        let agent = agent.clone();
        let connections = r.connections.clone();
        std::thread::spawn(move || {
            let answered = connections.iter().find(|c| probe(&agent, &c.uri));
            let result = match answered {
                Some(c) => (c.uri.clone(), c.local, true),
                None => {
                    let (detail, nearby) = best_effort(&connections);
                    (detail, nearby, false)
                }
            };
            // the receiver may already be gone past the deadline; this
            // thread's answer is then simply too late to matter
            let _ = tx.send((i, result));
        });
    }
    drop(tx);
    let mut results: Vec<Option<(String, bool, bool)>> = vec![None; servers.len()];
    let mut remaining = results.len();
    let deadline = std::time::Instant::now() + bound;
    while remaining > 0 {
        let now = std::time::Instant::now();
        if now >= deadline {
            break;
        }
        match rx.recv_timeout(deadline - now) {
            Ok((i, result)) => {
                results[i] = Some(result);
                remaining -= 1;
            }
            Err(_) => break,
        }
    }
    Ok(servers
        .into_iter()
        .enumerate()
        .map(|(i, r)| {
            // never the completion order: a server always lands at the
            // position plex.tv gave it, whichever thread answers last
            let (detail, nearby, reachable) = results[i].take().unwrap_or_else(|| {
                let (detail, nearby) = best_effort(&r.connections);
                (detail, nearby, false)
            });
            Choice {
                id: r.client_identifier,
                name: r.name,
                detail,
                reachable,
                nearby,
            }
        })
        .collect())
}

/// Short on purpose: an identity probe carries no body and no server-side
/// work, so a live connection (LAN or remote) answers in a fraction of this;
/// a dead one must not cost the same wait as a real API call, especially
/// once a server with several connections is probed one at a time.
const PROBE_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(3);

/// Whether a GET to this connection's own identify endpoint answers at all.
/// Never follows a redirect and sends no token: reachability, not a request
/// that could leak a credential to a host this device only guesses is right.
fn probe(agent: &ureq::Agent, uri: &str) -> bool {
    agent
        .get(&format!("{uri}/identity"))
        .timeout(PROBE_TIMEOUT)
        .call()
        .is_ok()
}

/// The address shown for a server whose probe was abandoned, whether
/// because nothing answered or the overall bound ran out first: the
/// nearby-first candidate, so the choice still names what would be tried.
fn best_effort(connections: &[Connection]) -> (String, bool) {
    (
        connections
            .first()
            .map(|c| c.uri.clone())
            .unwrap_or_default(),
        connections.first().is_some_and(|c| c.local),
    )
}

/// Read span per range request at steady state. 2 MiB: the measured span at
/// which a single connection independently cleared 130+ Mbps.
const CHUNK: u64 = 2 * 1024 * 1024;

/// A sequential reader doubles its span up to here after this many chunks in
/// a row. Stop-and-wait per chunk costs a full round trip per 2 MiB; growing
/// the span amortises the same latency over twice the bytes with no second
/// buffer and no thread, which is what the byte cache upstream of the demuxer
/// cannot do for us. Kept low because a seek drops whatever of the chunk is
/// still in flight. A seek or any backward move resets it to `FIRST_CHUNK`.
const SEQUENTIAL_BEFORE_GROW: u32 = 3;
const MAX_CHUNK: u64 = 4 * 1024 * 1024;

/// The span of the very first request, which is the one that pays for a
/// connection nothing has warmed yet: 10.7 Mbps measured, where a full
/// 2 MiB span holds that slow connection for 1.6 s. Every later request
/// rides the warm connection at 130 Mbps and takes the full span, where the
/// larger span is what amortises the latency. A seek starts over from this
/// span too, since a seek is often followed by another. It is also how far
/// ahead of the bytes in hand a read still reads on through the open body
/// rather than asking again.
const FIRST_CHUNK: u64 = 256 * 1024;

/// The pause before each new attempt at a range that failed in transit: a
/// dropped connection or a 5xx is retried, a 4xx is the server's answer.
const RETRY_BACKOFF_MS: [u64; 3] = [0, 200, 800];

/// The longest a request waits reading out the rest of the body before it to
/// keep that connection: about what a cold connection's first span costs.
const DRAIN_SECONDS: f64 = 0.1;

static AGENT_POOL: OnceLock<Mutex<HashMap<String, Arc<ureq::Agent>>>> = OnceLock::new();

fn agent_pool() -> &'static Mutex<HashMap<String, Arc<ureq::Agent>>> {
    AGENT_POOL.get_or_init(|| Mutex::new(HashMap::new()))
}

fn build_agent() -> ureq::Agent {
    ureq::AgentBuilder::new()
        .timeout_connect(std::time::Duration::from_secs(10))
        .timeout_read(crate::plex::client::STREAM_READ_TIMEOUT)
        // the auth header would otherwise be forwarded to whatever host a
        // redirect names
        .redirects(0)
        .resolver(crate::plex::client::timed_resolve)
        .build()
}

/// scheme+host+port, never the full URL: a file id or a token riding in the
/// path must never become the key a stale pool entry hangs around under.
fn origin_key(url: &str) -> String {
    let (scheme, rest) = url.split_once("://").unwrap_or(("", url));
    let authority_end = rest.find(['/', '?', '#']).unwrap_or(rest.len());
    format!("{scheme}://{}", &rest[..authority_end])
}

/// One agent per server host, shared by every stream to that host for
/// the process's life: the TCP pool and the TLS session cache live in
/// the agent, so the cold handshake is a one-time event per server,
/// not per open. Keyed by scheme+host+port, never by full URL.
pub fn shared_stream_agent(url: &str) -> ureq::Agent {
    let key = origin_key(url);
    let mut pool = agent_pool().lock();
    let arc = pool.entry(key).or_insert_with(|| Arc::new(build_agent()));
    (**arc).clone()
}

/// The pointer identity of the pooled agent `shared_stream_agent` just
/// stored for `url`'s origin: two URLs on one host must read back the
/// same identity, never a real accessor - only sharing needs this to
/// leave the pool.
#[cfg(test)]
fn shared_stream_agent_pool_id(url: &str) -> usize {
    let key = origin_key(url);
    let pool = agent_pool().lock();
    Arc::as_ptr(
        pool.get(&key)
            .expect("call shared_stream_agent for this url first"),
    ) as usize
}

/// A seekable stream over HTTP Range requests. The response to the last
/// request stays open and is read a socket read at a time, and what has
/// arrived of it is kept, so a read never waits for more of a range than its
/// first bytes and a backward seek inside it costs nothing.
pub struct RangeReader {
    agent: ureq::Agent,
    url: String,
    /// Sent on every request. An empty name means the stream needs no auth.
    header_name: String,
    header_value: String,
    len: u64,
    pos: u64,
    /// Where the current response starts in the file.
    chunk_start: u64,
    /// The current response's bytes: `filled` have arrived, of the `expected`
    /// it declared and the span asked for allow. Grown to the widest span and
    /// never shrunk, so a socket read lands in it without zeroing it first.
    chunk: Vec<u8>,
    filled: usize,
    expected: usize,
    /// The current response's body, open until `expected` bytes have arrived.
    body: Option<Box<dyn Read + Send + Sync>>,
    /// When the current response's headers arrived: its rate so far is
    /// `filled` over the time since.
    body_started: std::time::Instant,
    /// What the next request asks for. `FIRST_CHUNK` on open and after any
    /// discontinuity, `CHUNK` once one has been answered, doubling per run of
    /// sequential chunks up to `MAX_CHUNK`.
    span: u64,
    /// Consecutive chunk-boundary crossings in one direction: the growth
    /// signal. Any discontinuity zeroes it and the span with it.
    sequential: u32,
    /// Failures in transit since the last byte that arrived, which is what
    /// indexes `RETRY_BACKOFF_MS`.
    attempt: usize,
}

/// Hand-written so the cached chunk is not dumped and the credential cannot leak.
impl std::fmt::Debug for RangeReader {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("RangeReader")
            .field("url", &self.url)
            .field("len", &self.len)
            .field("pos", &self.pos)
            .field("chunk_start", &self.chunk_start)
            .field("chunk_len", &self.filled)
            .finish()
    }
}

impl RangeReader {
    pub fn open(
        agent: ureq::Agent,
        url: String,
        header_name: &str,
        header_value: &str,
    ) -> Result<RangeReader, SourceError> {
        let mut reader = RangeReader {
            agent,
            url,
            header_name: header_name.to_string(),
            header_value: header_value.to_string(),
            len: 0,
            pos: 0,
            chunk_start: 0,
            chunk: Vec::new(),
            filled: 0,
            expected: 0,
            body: None,
            body_started: std::time::Instant::now(),
            span: FIRST_CHUNK,
            sequential: 0,
            attempt: 0,
        };
        // the first range response carries the total size in Content-Range,
        // so the size costs no extra round trip, and a demuxer always starts
        // by reading the header anyway
        reader.fetch(0)?;
        Ok(reader)
    }

    /// Asks for the next span from `start`, and grows the one after it.
    fn fetch(&mut self, start: u64) -> Result<(), SourceError> {
        let span = self.span;
        // whatever this one costs, the connection is warm behind it, and the
        // next request is never smaller than the steady-state floor
        self.span = CHUNK.max(self.span);
        self.attempt = 0;
        // a start near u64::MAX comes from a seek there
        self.request(start, start.saturating_add(span - 1))
    }

    /// Sends one range request and keeps its body open, retrying what fails
    /// in transit. Whatever the last response had delivered is dropped.
    fn request(&mut self, start: u64, end: u64) -> Result<(), SourceError> {
        // A body dropped mid-way closes its connection, and this request
        // would then pay for a cold one. A rest the body's own rate brings in
        // within `DRAIN_SECONDS` costs less to read out, and ureq hands the
        // connection back to the pool once the last declared byte is in. The
        // rate is only trusted over a first span's worth: the bytes riding
        // in with the headers say nothing of the link. A slow link drops it,
        // as a seek must not wait.
        if let Some(body) = self.body.take() {
            let rest = (self.expected - self.filled) as f64;
            let elapsed = self.body_started.elapsed().as_secs_f64();
            if self.filled as u64 >= FIRST_CHUNK
                && rest * elapsed <= self.filled as f64 * DRAIN_SECONDS
            {
                let _ = io::copy(&mut body.take(rest as u64), &mut io::sink());
            }
        }
        // no answer yet: this is the open's request
        let first = self.len == 0;
        let t0 = std::time::Instant::now();
        loop {
            let mut req = self
                .agent
                .get(&self.url)
                .set("Range", &format!("bytes={start}-{end}"));
            // the credential rides in a header; keeping it out of the URL keeps it
            // out of proxy and server logs
            if !self.header_name.is_empty() {
                req = req.set(&self.header_name, &self.header_value);
            }
            let failure = match req.call() {
                Ok(resp) => {
                    if resp.status() != 206 {
                        return Err(SourceError::Io(io::Error::other(format!(
                            "range not honoured: status {}",
                            resp.status()
                        ))));
                    }
                    // "bytes <start>-<end>/<total>": the start is the server's
                    // answer, not ours. Filing a later subrange at the offset we
                    // asked for would hand the caller the wrong bytes with no
                    // error at all.
                    let (chunk_start, chunk_end, total) = resp
                        .header("Content-Range")
                        .and_then(|v| {
                            let (range, total) = v.trim().strip_prefix("bytes")?.split_once('/')?;
                            let (from, to) = range.trim().split_once('-')?;
                            let from = from.parse::<u64>().ok()?;
                            let to = to.parse::<u64>().ok().filter(|&to| to >= from)?;
                            Some((from, to, total.trim().parse::<u64>().ok()?))
                        })
                        .ok_or_else(|| SourceError::Io(io::Error::other("bad Content-Range")))?;
                    if first {
                        eprintln!(
                            "[lexis.open] range first fetch: to headers {} ms",
                            t0.elapsed().as_millis()
                        );
                    }
                    // never more than was asked for, whatever the server declares
                    let expected = (chunk_end - chunk_start).min(end - start) + 1;
                    self.expected = expected as usize;
                    if self.chunk.len() < self.expected {
                        self.chunk.resize(self.expected, 0);
                    }
                    self.len = total;
                    self.chunk_start = chunk_start;
                    self.filled = 0;
                    self.body_started = std::time::Instant::now();
                    self.body = Some(resp.into_reader());
                    return Ok(());
                }
                Err(e) => {
                    // a 4xx is the server's answer, and so is a request ureq
                    // could not even form
                    let transient = match &e {
                        ureq::Error::Status(code, _) => *code >= 500,
                        ureq::Error::Transport(t) => matches!(
                            t.kind(),
                            ureq::ErrorKind::Io | ureq::ErrorKind::ConnectionFailed
                        ),
                    };
                    let failure = match e {
                        ureq::Error::Status(401, _) => SourceError::Unauthorized,
                        ureq::Error::Status(404, _) => SourceError::NotFound(self.url.clone()),
                        ureq::Error::Status(code, _) => {
                            SourceError::Io(io::Error::other(format!("http status {code}")))
                        }
                        // the kind alone: the Display of `t` prefixes the URL, and its
                        // message quotes whatever ureq choked on, which is the whole header
                        // line (name and credential) for a token that arrived with a stray
                        // newline in it, or the host for a name that did not resolve
                        ureq::Error::Transport(t) => {
                            SourceError::Io(io::Error::other(t.kind().to_string()))
                        }
                    };
                    if !transient {
                        return Err(failure);
                    }
                    failure
                }
            };
            self.back_off().ok_or(failure)?;
        }
    }

    /// Waits out the pause before the next attempt, or None once every
    /// attempt is spent.
    fn back_off(&mut self) -> Option<()> {
        let pause = *RETRY_BACKOFF_MS.get(self.attempt)?;
        std::thread::sleep(std::time::Duration::from_millis(pause));
        self.attempt += 1;
        Some(())
    }
}

impl Read for RangeReader {
    fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
        if buf.is_empty() || self.pos >= self.len {
            return Ok(0);
        }
        // whether a request was sent for this very position
        let mut asked = false;
        loop {
            let arrived = self.chunk_start + self.filled as u64;
            if let Some(offset) = self
                .pos
                .checked_sub(self.chunk_start)
                .filter(|&o| o < self.filled as u64)
            {
                let offset = offset as usize;
                let n = buf.len().min(self.filled - offset);
                buf[..n].copy_from_slice(&self.chunk[offset..offset + n]);
                self.pos += n as u64;
                return Ok(n);
            }
            // a position the open body reaches soon is read on to rather than
            // asked for again: a short skip costs less than a round trip
            let reachable = self.pos >= arrived
                && self.pos < self.chunk_start + self.expected as u64
                && (asked || self.pos - arrived <= FIRST_CHUNK);
            if let (true, Some(body)) = (reachable, self.body.as_mut()) {
                // one socket read: whatever has arrived, never the whole range
                match body.read(&mut self.chunk[self.filled..self.expected]) {
                    Ok(0) => {
                        // the body ended where its framing says, short of what
                        // Content-Range promised: that is all this answer holds
                        self.expected = self.filled;
                        self.body = None;
                    }
                    Ok(n) => {
                        self.filled += n;
                        self.attempt = 0;
                        if self.filled == self.expected {
                            self.body = None;
                        }
                    }
                    // a reset, a socket silent past the read timeout or a body
                    // cut short: the rest of the range again, from where it stopped
                    Err(e) => {
                        self.body = None;
                        self.back_off().ok_or(e)?;
                        let end = self.chunk_start + self.expected as u64 - 1;
                        self.request(arrived, end).map_err(io::Error::from)?;
                        asked = true;
                    }
                }
                continue;
            }
            // returning Ok(0) here would read as a clean EOF and truncate playback
            if asked {
                return Err(io::Error::new(
                    io::ErrorKind::UnexpectedEof,
                    "the server served no bytes before the end of the file",
                ));
            }
            // contiguity is what says "keep growing" from "start over": a
            // reader walking the file earns bigger spans, a seeker pays the
            // small ones again
            if self.filled > 0 && self.pos == arrived {
                self.sequential += 1;
                if self.sequential >= SEQUENTIAL_BEFORE_GROW {
                    self.span = (self.span * 2).min(MAX_CHUNK);
                }
            } else {
                self.sequential = 0;
                self.span = FIRST_CHUNK;
            }
            // from pos itself: whatever lies before it is either in the chunk
            // just read or was left behind by a seek
            self.fetch(self.pos).map_err(io::Error::from)?;
            asked = true;
        }
    }
}

impl Seek for RangeReader {
    fn seek(&mut self, pos: SeekFrom) -> io::Result<u64> {
        // seeking past the end is legal; the next read returns 0. an offset
        // that lands before the start, or off the end of u64, is not: this
        // runs under a C callback, where a panic would be undefined behaviour
        let target = match pos {
            SeekFrom::Start(n) => Some(n),
            SeekFrom::Current(d) => self.pos.checked_add_signed(d),
            SeekFrom::End(d) => self.len.checked_add_signed(d),
        };
        self.pos = target.ok_or_else(|| {
            io::Error::new(
                io::ErrorKind::InvalidInput,
                "seek outside the range of the stream",
            )
        })?;
        Ok(self.pos)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_plex_source_shows_the_machine_rather_than_the_certificate_name() {
        // the hash identifies the server publicly and reads as noise across a
        // room; the address in front of it is what a viewer could act on
        let mut values = Values::new();
        values.insert(
            "base_url".to_string(),
            "https://192-168-1-35.0123456789abcdef0123456789abcdef.plex.direct:32400".to_string(),
        );
        assert_eq!(PlexModule.detail(&values), "192.168.1.35:32400");

        // anything else is shown as it was given: a name we cannot read is not
        // a name we should rewrite
        values.insert("base_url".to_string(), "http://nas.lan:32400".to_string());
        assert_eq!(PlexModule.detail(&values), "http://nas.lan:32400");
    }
    use crate::index::db::Db;
    use crate::plex::fake::{library, range_server, FakeServer, Reply, Req};

    /// A fake `plex.tv`, wrapping `handler` in the one check every real
    /// `api/v2/*` endpoint makes before anything else: plex.tv answers a
    /// request with no `X-Plex-Client-Identifier` 400, in the same shape
    /// for every endpoint, whatever the token or the pin say. A fake that
    /// skipped this would accept what the real service refuses, which is
    /// exactly how the missing header on `probe_choices` shipped unnoticed.
    fn plex_tv<F>(handler: F) -> FakeServer
    where
        F: Fn(&Req) -> Reply + Send + Sync + 'static,
    {
        FakeServer::start(move |req| {
            if req.header("X-Plex-Client-Identifier").is_none() {
                return Reply {
                    status: 400,
                    headers: vec![("Content-Type".to_string(), "application/json".to_string())],
                    body: br#"{"code":1000,"message":"X-Plex-Client-Identifier is missing"}"#
                        .to_vec(),
                };
            }
            handler(req)
        })
    }

    #[test]
    fn the_plex_tv_fake_rejects_a_request_with_no_client_identifier_like_the_real_service() {
        let server = plex_tv(|_req| Reply::json(r#"{"ok": true}"#));
        let err = ureq::get(&format!("{}/api/v2/resources", server.base_url))
            .set("Accept", "application/json")
            .call()
            .unwrap_err();
        let ureq::Error::Status(400, resp) = err else {
            panic!("expected 400, got {err:?}");
        };
        let body = resp.into_string().unwrap();
        assert!(body.contains("X-Plex-Client-Identifier"), "{body}");

        // the same request, carrying the header, reaches the handler
        let ok = ureq::get(&format!("{}/api/v2/resources", server.base_url))
            .set("Accept", "application/json")
            .set("X-Plex-Client-Identifier", "test-install")
            .call()
            .unwrap();
        assert_eq!(ok.status(), 200);
    }

    fn body(n: usize) -> Vec<u8> {
        (0..n).map(|i| (i % 251) as u8).collect()
    }

    fn reader(server: &FakeServer) -> RangeReader {
        RangeReader::open(
            ureq::AgentBuilder::new().build(),
            format!("{}/library/parts/1/1/f.mkv", server.base_url),
            "X-Plex-Token",
            "tok",
        )
        .unwrap()
    }

    /// The width one request asked for, parsed back out of its Range header.
    fn requested_span(req: &crate::plex::fake::Req) -> Option<u64> {
        let range = req.header("Range")?.strip_prefix("bytes=")?;
        let (start, end) = range.split_once('-')?;
        Some(end.parse::<u64>().ok()? - start.parse::<u64>().ok()? + 1)
    }

    #[test]
    fn a_sequential_reader_grows_its_span_and_a_seek_resets_it() {
        let data = body((MAX_CHUNK * 3) as usize);
        let server = range_server(data.clone());
        let mut r = reader(&server);

        // walk forward well past the growth threshold: spans double every
        // SEQUENTIAL_BEFORE_GROW chunks, so a run this long must have asked
        // for more than one steady chunk at a time
        let mut buf = vec![0u8; 1024 * 1024];
        while r.stream_position().unwrap() < MAX_CHUNK * 2 {
            let n = r.read(&mut buf).unwrap();
            assert!(n > 0);
        }
        let widest = server
            .requests()
            .iter()
            .filter_map(requested_span)
            .max()
            .unwrap();
        assert!(widest > CHUNK, "sequential walk never grew past {widest}");

        // any jump backwards starts over from the short first span, then the
        // steady one
        r.seek(SeekFrom::Start(0)).unwrap();
        let mut head = vec![0u8; FIRST_CHUNK as usize + 8];
        r.read_exact(&mut head).unwrap();
        let requests = server.requests();
        let spans: Vec<u64> = requests[requests.len() - 2..]
            .iter()
            .filter_map(requested_span)
            .collect();
        assert_eq!(spans, [FIRST_CHUNK, CHUNK]);
    }

    #[test]
    fn the_request_after_a_chunk_starts_where_that_chunk_ended() {
        let data = body(3 * 1024 * 1024);
        let server = range_server(data.clone());
        let mut r = reader(&server);
        let mut out = Vec::new();
        r.read_to_end(&mut out).unwrap();
        assert_eq!(out, data);
        // never back over the first chunk's bytes, which are already in hand
        let second = format!("bytes={FIRST_CHUNK}-{}", FIRST_CHUNK + CHUNK - 1);
        assert_eq!(server.requests()[1].header("Range"), Some(second.as_str()));
    }

    #[test]
    fn a_range_that_fails_in_transit_is_asked_for_again() {
        let data = body(300 * 1024);
        let served = data.clone();
        let seen = std::sync::atomic::AtomicUsize::new(0);
        let server = FakeServer::start(move |req| {
            let range = req.header("Range").unwrap().trim_start_matches("bytes=");
            let (from, to) = range.split_once('-').unwrap();
            let start: usize = from.parse().unwrap();
            // the open is answered short, the next request is a 503
            let end = match seen.fetch_add(1, std::sync::atomic::Ordering::SeqCst) {
                0 => 999,
                1 => return Reply::status(503),
                _ => to.parse::<usize>().unwrap().min(served.len() - 1),
            };
            Reply {
                status: 206,
                headers: vec![(
                    "Content-Range".to_string(),
                    format!("bytes {start}-{end}/{}", served.len()),
                )],
                body: served[start..=end].to_vec(),
            }
        });
        let mut r = reader(&server);
        let mut out = Vec::new();
        r.read_to_end(&mut out).unwrap();
        assert_eq!(out, data);
        let requests = server.requests();
        assert_eq!(requests.len(), 3);
        assert_eq!(requests[1].header("Range"), requests[2].header("Range"));
    }

    /// A range server on a bare socket, one request per connection, whose body
    /// goes out `piece` bytes at a time with `pause` between pieces. The first
    /// body is cut off after `cut` bytes when one is given. Hands back its
    /// address and the Range header of every request.
    fn paced_server(
        data: Vec<u8>,
        piece: usize,
        pause: std::time::Duration,
        cut: Option<usize>,
    ) -> (String, Arc<Mutex<Vec<String>>>) {
        use std::io::{BufRead, BufReader, Write};
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let base = format!("http://{}", listener.local_addr().unwrap());
        let ranges = Arc::new(Mutex::new(Vec::new()));
        let seen = ranges.clone();
        let data = Arc::new(data);
        std::thread::spawn(move || {
            for stream in listener.incoming() {
                let (Ok(mut stream), data, seen) = (stream, data.clone(), seen.clone()) else {
                    continue;
                };
                std::thread::spawn(move || {
                    let mut range = String::new();
                    let mut head = BufReader::new(stream.try_clone().unwrap());
                    loop {
                        let mut line = String::new();
                        if head.read_line(&mut line).unwrap_or(0) == 0 || line == "\r\n" {
                            break;
                        }
                        if let Some(v) = line.strip_prefix("Range: bytes=") {
                            range = v.trim().to_string();
                        }
                    }
                    let first = {
                        let mut seen = seen.lock();
                        seen.push(range.clone());
                        seen.len() == 1
                    };
                    let (from, to) = range.split_once('-').unwrap();
                    let start: usize = from.parse().unwrap();
                    let end = to.parse::<usize>().unwrap().min(data.len() - 1);
                    let _ = write!(
                        stream,
                        "HTTP/1.1 206 Partial Content\r\nContent-Range: bytes {start}-{end}/{}\r\n\
                         Content-Length: {}\r\nConnection: close\r\n\r\n",
                        data.len(),
                        end - start + 1
                    );
                    let mut body = &data[start..=end];
                    if let (true, Some(cut)) = (first, cut) {
                        body = &body[..cut];
                    }
                    for part in body.chunks(piece) {
                        // a write fails once the client has hung up
                        if stream.write_all(part).is_err() {
                            return;
                        }
                        std::thread::sleep(pause);
                    }
                });
            }
        });
        (base, ranges)
    }

    #[test]
    fn a_seek_while_a_long_body_arrives_waits_for_none_of_it() {
        let data = body(4 * 1024 * 1024);
        // 16 KiB every 20 ms: the steady 2 MiB span takes over two seconds
        let (base, ranges) = paced_server(
            data.clone(),
            16 * 1024,
            std::time::Duration::from_millis(20),
            None,
        );
        let mut r = RangeReader::open(
            ureq::AgentBuilder::new().build(),
            format!("{base}/library/parts/1/1/f.mkv"),
            "X-Plex-Token",
            "tok",
        )
        .unwrap();
        let mut head = vec![0u8; FIRST_CHUNK as usize];
        r.read_exact(&mut head).unwrap();
        assert_eq!(head, data[..FIRST_CHUNK as usize]);

        let started = std::time::Instant::now();
        // the read that opens the steady span answers with its first bytes
        let mut buf = vec![0u8; 64 * 1024];
        let n = r.read(&mut buf).unwrap();
        assert!(n > 0);
        assert_eq!(
            buf[..n],
            data[FIRST_CHUNK as usize..FIRST_CHUNK as usize + n]
        );
        let target = 3 * 1024 * 1024;
        r.seek(SeekFrom::Start(target as u64)).unwrap();
        let mut landed = [0u8; 8];
        r.read_exact(&mut landed).unwrap();
        assert_eq!(landed, data[target..target + 8]);
        let waited = started.elapsed();
        assert!(
            waited < std::time::Duration::from_secs(1),
            "the seek waited {waited:?}"
        );

        let ranges = ranges.lock().clone();
        assert_eq!(ranges.len(), 3);
        assert!(ranges[2].starts_with(&format!("{target}-")), "{ranges:?}");
    }

    #[test]
    fn a_body_cut_off_midway_is_asked_for_again_from_where_it_stopped() {
        let data = body(300 * 1024);
        let cut = 100_000;
        let (base, ranges) = paced_server(
            data.clone(),
            64 * 1024,
            std::time::Duration::ZERO,
            Some(cut),
        );
        let mut r = RangeReader::open(
            ureq::AgentBuilder::new().build(),
            format!("{base}/library/parts/1/1/f.mkv"),
            "X-Plex-Token",
            "tok",
        )
        .unwrap();
        let mut out = Vec::new();
        r.read_to_end(&mut out).unwrap();
        assert_eq!(out, data);
        let ranges = ranges.lock().clone();
        // the rest of the first range, not the whole of it again
        assert_eq!(ranges[0], format!("0-{}", FIRST_CHUNK - 1));
        assert_eq!(ranges[1], format!("{cut}-{}", FIRST_CHUNK - 1));
    }

    #[test]
    fn the_first_range_response_gives_the_total_size() {
        let data = body(3 * 1024 * 1024);
        let server = range_server(data.clone());
        let mut r = reader(&server);
        assert_eq!(r.seek(SeekFrom::End(0)).unwrap(), data.len() as u64);
        // no HEAD, no second fetch
        assert_eq!(server.requests().len(), 1);
        // the short first span: a cold connection makes a full one 1.6 s
        // of nothing before the demuxer is handed a byte
        assert_eq!(server.requests()[0].header("Range"), Some("bytes=0-262143"));
        assert_eq!(server.requests()[0].header("X-Plex-Token"), Some("tok"));
    }

    #[test]
    fn reads_across_a_chunk_boundary_and_backwards() {
        let data = body(3 * 1024 * 1024);
        let server = range_server(data.clone());
        let mut r = reader(&server);

        let mut head = [0u8; 8];
        r.read_exact(&mut head).unwrap();
        assert_eq!(head, data[..8]);

        let boundary = (CHUNK - 4) as usize;
        r.seek(SeekFrom::Start(boundary as u64)).unwrap();
        let mut across = [0u8; 8];
        r.read_exact(&mut across).unwrap();
        assert_eq!(across, data[boundary..boundary + 8]);

        r.seek(SeekFrom::Start(16)).unwrap();
        let mut back = [0u8; 4];
        r.read_exact(&mut back).unwrap();
        assert_eq!(back, data[16..20]);

        // the tail of the file, one chunk past the boundary
        let tail = data.len() - 5;
        r.seek(SeekFrom::End(-5)).unwrap();
        let mut end = Vec::new();
        r.read_to_end(&mut end).unwrap();
        assert_eq!(end, data[tail..]);
    }

    #[test]
    fn one_chunk_serves_many_reads() {
        let server = range_server(body(300 * 1024));
        let mut r = reader(&server);
        let mut buf = [0u8; 16];
        r.read_exact(&mut buf).unwrap();
        r.seek(SeekFrom::Start(1024)).unwrap();
        r.read_exact(&mut buf).unwrap();
        r.seek(SeekFrom::Start(0)).unwrap();
        r.read_exact(&mut buf).unwrap();
        assert_eq!(server.requests().len(), 1);
    }

    #[test]
    fn a_whole_small_file_reads_in_one_request() {
        let data = body(1000);
        let server = range_server(data.clone());
        let mut r = reader(&server);
        let mut out = Vec::new();
        r.read_to_end(&mut out).unwrap();
        assert_eq!(out, data);
        assert_eq!(server.requests().len(), 1);
    }

    #[test]
    fn reading_past_the_end_returns_zero_and_seeking_before_it_fails() {
        let server = range_server(body(10));
        let mut r = reader(&server);
        assert_eq!(r.seek(SeekFrom::End(0)).unwrap(), 10);
        assert_eq!(r.read(&mut [0u8; 4]).unwrap(), 0);
        assert!(r.seek(SeekFrom::Current(-100)).is_err());
    }

    /// Answers every range from its start but stops after `cap` bytes, which
    /// RFC 7233 allows and which a real server does under load.
    fn short_server(data: Vec<u8>, cap: usize) -> FakeServer {
        FakeServer::start(move |req| {
            let range = req.header("Range").unwrap();
            let start: usize = range
                .trim_start_matches("bytes=")
                .split('-')
                .next()
                .unwrap()
                .parse()
                .unwrap();
            if start >= data.len() {
                return Reply::status(416);
            }
            let end = (start + cap - 1).min(data.len() - 1);
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

    #[test]
    fn a_server_that_answers_short_still_reads_the_whole_file() {
        let data = body(700 * 1024);
        let server = short_server(data.clone(), 60_000);
        let mut r = reader(&server);
        let mut out = Vec::new();
        r.read_to_end(&mut out).unwrap();
        assert_eq!(out.len(), data.len()); // never a silent truncation
        assert_eq!(out, data);
    }

    /// Answers a subrange starting later than asked for, as a server clamping
    /// a range to a boundary of its own does.
    fn shifting_server(data: Vec<u8>, shift: usize) -> FakeServer {
        FakeServer::start(move |req| {
            let range = req.header("Range").unwrap();
            let asked: usize = range
                .trim_start_matches("bytes=")
                .split('-')
                .next()
                .unwrap()
                .parse()
                .unwrap();
            let start = asked + shift;
            if start >= data.len() {
                return Reply::status(416);
            }
            let end = (start + CHUNK as usize - 1).min(data.len() - 1);
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

    #[test]
    fn bytes_from_a_later_subrange_are_never_filed_at_the_requested_offset() {
        let data = body(700 * 1024);
        let server = shifting_server(data.clone(), 100);
        let mut r = reader(&server);
        assert_eq!(r.seek(SeekFrom::End(0)).unwrap(), data.len() as u64);

        // the server never sends byte 0, so a read there has nothing to serve:
        // an error, never data[100..] handed back as data[0..]
        r.seek(SeekFrom::Start(0)).unwrap();
        let err = r.read(&mut [0u8; 8]).unwrap_err();
        assert_eq!(err.kind(), io::ErrorKind::UnexpectedEof);

        // a position the answer does cover still reads the right bytes
        r.seek(SeekFrom::Start(500)).unwrap();
        let mut buf = [0u8; 8];
        r.read_exact(&mut buf).unwrap();
        assert_eq!(buf, data[500..508]);
    }

    #[test]
    fn a_server_that_answers_nothing_is_an_error_not_an_end_of_file() {
        let server = FakeServer::start(|_req| Reply {
            status: 206,
            headers: vec![("Content-Range".to_string(), "bytes 0-9/10".to_string())],
            body: Vec::new(),
        });
        let mut r = reader(&server);
        let err = r.read(&mut [0u8; 4]).unwrap_err();
        assert_eq!(err.kind(), io::ErrorKind::UnexpectedEof);
    }

    #[test]
    fn a_read_at_the_end_of_the_address_space_errors_without_overflowing() {
        // one byte per answer and a total of u64::MAX: the read then asks for
        // a range starting past u64::MAX - CHUNK
        let server = FakeServer::start(|req| {
            let start: u64 = req
                .header("Range")
                .unwrap()
                .trim_start_matches("bytes=")
                .split('-')
                .next()
                .unwrap()
                .parse()
                .unwrap();
            Reply {
                status: 206,
                headers: vec![(
                    "Content-Range".to_string(),
                    format!("bytes {start}-{start}/{}", u64::MAX),
                )],
                body: vec![7],
            }
        });
        let mut r = reader(&server);
        r.seek(SeekFrom::Start(u64::MAX - 10)).unwrap();
        let mut buf = [0u8; 4];
        assert_eq!(r.read(&mut buf).unwrap(), 1);
        assert_eq!(buf[0], 7);
    }

    #[test]
    fn extreme_seeks_are_refused_without_panicking_and_keep_the_cache() {
        let data = body(1000);
        let server = range_server(data.clone());
        let mut r = reader(&server);

        // any absolute position is legal, however far past the end
        assert_eq!(r.seek(SeekFrom::Start(u64::MAX)).unwrap(), u64::MAX);
        assert_eq!(r.read(&mut [0u8; 4]).unwrap(), 0);

        assert_eq!(
            r.seek(SeekFrom::Current(i64::MAX)).unwrap_err().kind(),
            io::ErrorKind::InvalidInput
        );
        assert_eq!(
            r.seek(SeekFrom::End(i64::MIN)).unwrap_err().kind(),
            io::ErrorKind::InvalidInput
        );

        r.seek(SeekFrom::Start(8)).unwrap();
        let mut buf = [0u8; 4];
        r.read_exact(&mut buf).unwrap();
        assert_eq!(buf, data[8..12]);
        assert_eq!(server.requests().len(), 1); // the chunk from open, still
    }

    #[test]
    fn a_missing_part_is_not_found_and_a_broken_one_is_an_io_error() {
        let missing = FakeServer::start(|_req| Reply::status(404));
        let err = RangeReader::open(
            ureq::AgentBuilder::new().build(),
            format!("{}/library/parts/9/1/x.mkv", missing.base_url),
            "X-Plex-Token",
            "tok",
        )
        .unwrap_err();
        assert!(matches!(err, SourceError::NotFound(_)));

        // a server that ignores Range would hand us the wrong bytes
        let whole = FakeServer::start(|_req| Reply {
            status: 200,
            headers: Vec::new(),
            body: b"hello".to_vec(),
        });
        let err = RangeReader::open(
            ureq::AgentBuilder::new().build(),
            format!("{}/library/parts/1/1/f.mkv", whole.base_url),
            "X-Plex-Token",
            "tok",
        )
        .unwrap_err();
        assert!(matches!(err, SourceError::Io(_)));
    }

    #[test]
    fn open_streams_a_part_by_its_plex_key() {
        let data = body(1000);
        let server = range_server(data.clone());
        let src = PlexSource::new("plex1", &server.base_url, "tok", "install");
        assert_eq!(src.id(), "plex1");

        let mut stream = src.open("/library/parts/501/1/Dune.mkv").unwrap();
        let mut out = Vec::new();
        stream.read_to_end(&mut out).unwrap();
        assert_eq!(out, data);

        let req = &server.requests()[0];
        assert_eq!(req.url, "/library/parts/501/1/Dune.mkv");
        assert_eq!(req.header("X-Plex-Token"), Some("tok"));
    }

    #[test]
    fn a_rejected_token_is_unauthorized_and_reads_as_permission_denied() {
        let unauthorized = FakeServer::start(|_req| Reply::status(401));
        let err = RangeReader::open(
            ureq::AgentBuilder::new().build(),
            format!("{}/library/parts/1/1/f.mkv", unauthorized.base_url),
            "X-Plex-Token",
            "stale",
        )
        .unwrap_err();
        assert!(matches!(err, SourceError::Unauthorized));

        // a token revoked mid-stream must not read as a plain io failure
        let data = body(3 * 1024 * 1024);
        let seen = std::sync::atomic::AtomicUsize::new(0);
        let expiring = FakeServer::start(move |_req| {
            if seen.fetch_add(1, std::sync::atomic::Ordering::SeqCst) > 0 {
                return Reply::status(401);
            }
            Reply {
                status: 206,
                headers: vec![(
                    "Content-Range".to_string(),
                    format!("bytes 0-{}/{}", CHUNK - 1, data.len()),
                )],
                body: data[..CHUNK as usize].to_vec(),
            }
        });
        let mut r = reader(&expiring);
        // past the first chunk, so the read has to fetch again
        r.seek(SeekFrom::Start(2_500_000)).unwrap();
        assert_eq!(
            r.read(&mut [0u8; 4]).unwrap_err().kind(),
            io::ErrorKind::PermissionDenied
        );
    }

    #[test]
    fn a_transport_error_carries_neither_the_url_nor_the_token() {
        // nothing listens on port 1
        let err = RangeReader::open(
            ureq::AgentBuilder::new().build(),
            "http://127.0.0.1:1/library/parts/1/1/f.mkv".to_string(),
            "X-Plex-Token",
            "sekrit-token",
        )
        .unwrap_err();
        let shown = err.to_string();
        assert!(!shown.contains("127.0.0.1"), "{shown}");
        assert!(!shown.contains("sekrit-token"), "{shown}");

        // a pasted token keeps whatever the clipboard held: a trailing newline
        // makes the header unparseable, and the rejection quotes the whole line
        let err = RangeReader::open(
            ureq::AgentBuilder::new().build(),
            "http://127.0.0.1:1/library/parts/1/1/f.mkv".to_string(),
            "X-Plex-Token",
            "sekrit-token\nX-Evil: 1",
        )
        .unwrap_err();
        let shown = err.to_string();
        assert!(!shown.contains("sekrit-token"), "{shown}");
        assert!(!shown.contains("X-Plex-Token"), "{shown}");
    }

    #[test]
    fn a_redirect_is_never_followed_so_the_token_stays_on_the_host() {
        let elsewhere = FakeServer::start(|_req| Reply::status(200));
        let target = format!("{}/stolen.mkv", elsewhere.base_url);
        let redirector = FakeServer::start(move |_req| Reply {
            status: 302,
            headers: vec![("Location".to_string(), target.clone())],
            body: Vec::new(),
        });

        let src = PlexSource::new("plex1", &redirector.base_url, "tok", "install");
        assert!(src.open("/library/parts/1/1/f.mkv").is_err());
        assert!(elsewhere.requests().is_empty());
    }

    #[test]
    fn listing_a_plex_source_is_always_empty() {
        let server = range_server(body(4));
        let src = PlexSource::new("plex1", &server.base_url, "tok", "install");
        assert!(src.list("").unwrap().is_empty());
        assert!(src.list("anything").unwrap().is_empty());
        assert!(server.requests().is_empty()); // listing talks to nobody
    }

    #[test]
    fn opening_a_part_the_server_lost_is_not_found() {
        let server = FakeServer::start(|_req| Reply::status(404));
        let src = PlexSource::new("plex1", &server.base_url, "tok", "install");
        assert!(matches!(
            src.open("/library/parts/9/1/x.mkv"),
            Err(SourceError::NotFound(_))
        ));
    }

    #[test]
    fn a_plex_source_is_usable_as_a_trait_object() {
        let server = range_server(body(8));
        let src: Box<dyn Source> =
            Box::new(PlexSource::new("plex1", &server.base_url, "tok", "install"));
        assert_eq!(src.id(), "plex1");
        assert!(src.list("").unwrap().is_empty());
    }

    #[test]
    fn a_plex_source_answers_both_catalogue_and_watch_sync() {
        let server = range_server(body(4));
        let src = PlexSource::new("plex1", &server.base_url, "tok", "install");
        assert!(src.catalogue().is_some());
        assert!(src.watch_sync().is_some());
    }

    #[test]
    fn the_catalogue_pulls_the_library_through_sync() {
        let server = library();
        let db = Mutex::new(Db::open_in_memory().unwrap());
        let paused = Pause::new();
        let src = PlexSource::new("plex1", &server.base_url, "tok", "install");
        let stats = src.catalogue().unwrap().pull(&db, &paused, false).unwrap();
        assert_eq!(stats.files_seen, 3);
    }

    #[test]
    fn a_paused_pull_never_reaches_the_server_until_it_is_stood_down() {
        let server = library();
        let db = Mutex::new(Db::open_in_memory().unwrap());
        let paused = Pause::new();
        paused.set(true);
        let src = PlexSource::new("plex1", &server.base_url, "tok", "install");
        let before = server.requests().len();
        std::thread::scope(|scope| {
            let handle = scope.spawn(|| src.catalogue().unwrap().pull(&db, &paused, false));
            // the walk parks before its first request: give it a moment to
            // prove it. The flag is stood down BEFORE any assertion - a panic
            // here would otherwise wait forever on a thread parked in pause.
            std::thread::sleep(std::time::Duration::from_millis(150));
            let grew_while_paused = server.requests().len() > before;
            paused.set(false);
            handle.join().unwrap().unwrap();
            assert!(
                !grew_while_paused,
                "a paused pull must not reach the server"
            );
        });
        assert!(server.requests().len() > before);
    }

    #[test]
    fn a_rejected_token_reports_unauthorized_through_watch_sync() {
        let unauthorized = FakeServer::start(|_req| Reply::status(401));
        let src = PlexSource::new("plex1", &unauthorized.base_url, "stale", "install");
        let err = src
            .watch_sync()
            .unwrap()
            .timeline("1", PlaybackState::Playing, 0.0, 0.0)
            .unwrap_err();
        assert!(matches!(err, SourceError::Unauthorized));
    }

    #[test]
    fn the_plex_module_builds_from_base_url_and_token() {
        let m = PlexModule;
        assert_eq!(m.id(), "plex");
        assert_eq!(m.glyph(), "chevron");
        assert_eq!(m.secret_keys(), &["token"]);
        let mut values = Values::new();
        values.insert(
            "base_url".to_string(),
            "http://plex.local:32400".to_string(),
        );
        values.insert("token".to_string(), "tok".to_string());
        assert_eq!(m.detail(&values), "http://plex.local:32400");
        let built = m.build("plex1", &values).unwrap();
        assert_eq!(built.id(), "plex1");
    }

    #[test]
    fn the_plex_module_refuses_a_base_url_with_no_scheme() {
        let m = PlexModule;
        let mut values = Values::new();
        values.insert("base_url".to_string(), "plex.local:32400".to_string());
        values.insert("token".to_string(), "tok".to_string());
        assert!(matches!(
            m.build("plex1", &values),
            Err(CoreError::InvalidConfig { .. })
        ));
    }

    #[test]
    fn a_link_reads_the_code_and_waits_until_the_pin_carries_a_token() {
        let claimed = std::sync::atomic::AtomicBool::new(false);
        let server = plex_tv(move |req| {
            if req.url.starts_with("/api/v2/pins") && req.url.len() == "/api/v2/pins".len() {
                return Reply::json(r#"{"id": 42, "code": "ABCD"}"#);
            }
            if claimed.swap(true, std::sync::atomic::Ordering::SeqCst) {
                return Reply::json(r#"{"authToken": "linked-token"}"#);
            }
            Reply::json(r#"{"authToken": null}"#)
        });

        let m = PlexModule;
        let started = m.link_start_at(&server.base_url, "test-install").unwrap();
        assert_eq!(started.code, "ABCD");

        let (waiting, state) = m
            .link_poll_at(&server.base_url, "test-install", &started.state)
            .unwrap();
        assert_eq!(waiting, LinkState::Waiting);

        let (linked, state) = m
            .link_poll_at(&server.base_url, "test-install", &state)
            .unwrap();
        assert_eq!(linked, LinkState::Linked);
        assert_eq!(state.get("token"), Some(&"linked-token".to_string()));
    }

    #[test]
    fn a_pin_the_server_no_longer_has_reports_expired() {
        let server = plex_tv(|req| {
            if req.url.starts_with("/api/v2/pins") && req.url.len() == "/api/v2/pins".len() {
                return Reply::json(r#"{"id": 1, "code": "ABCD"}"#);
            }
            Reply::status(404)
        });
        let m = PlexModule;
        let started = m.link_start_at(&server.base_url, "test-install").unwrap();
        let (state, _) = m
            .link_poll_at(&server.base_url, "test-install", &started.state)
            .unwrap();
        assert_eq!(state, LinkState::Expired);
    }

    #[test]
    fn a_link_carries_no_token_before_it_is_claimed_and_the_pin_id_never_leaks_it() {
        let server = plex_tv(|req| {
            if req.url.starts_with("/api/v2/pins") && req.url.len() == "/api/v2/pins".len() {
                return Reply::json(r#"{"id": 1, "code": "ABCD"}"#);
            }
            Reply::json(r#"{"authToken": null}"#)
        });
        let m = PlexModule;
        let started = m.link_start_at(&server.base_url, "test-install").unwrap();
        assert!(!started.state.contains_key("token"));
    }

    #[test]
    fn plex_now_links_by_code_and_no_longer_takes_typed_fields() {
        assert!(matches!(PlexModule.setup(), Setup::Link));
    }

    #[test]
    fn a_server_that_refuses_the_pin_reports_an_actionable_sentence_with_no_secret() {
        let server = plex_tv(|_req| Reply::status(500));
        let m = PlexModule;
        let err = m
            .link_start_at(&server.base_url, "test-install")
            .err()
            .unwrap();
        let CoreError::SourceUnavailable { msg, .. } = err else {
            panic!("expected SourceUnavailable, got {err:?}");
        };
        assert!(!msg.is_empty());
        assert!(!msg.contains(&server.base_url), "{msg}");
    }

    #[test]
    fn a_server_that_rejects_the_pin_credential_reports_unauthorized() {
        let server = plex_tv(|_req| Reply::status(401));
        let m = PlexModule;
        let err = m
            .link_start_at(&server.base_url, "test-install")
            .err()
            .unwrap();
        assert!(matches!(err, CoreError::Unauthorized { .. }));
    }

    #[test]
    fn a_transport_error_starting_a_link_names_neither_host_nor_secret() {
        let m = PlexModule;
        // nothing listens on port 1
        let err = m
            .link_start_at("http://127.0.0.1:1", "test-install")
            .err()
            .unwrap();
        let shown = err.to_string();
        assert!(!shown.contains("127.0.0.1"), "{shown}");
    }

    #[test]
    fn polling_a_link_that_was_never_started_is_an_invalid_config() {
        let m = PlexModule;
        assert!(matches!(
            m.link_poll_at("http://127.0.0.1:1", "test-install", &Values::new()),
            Err(CoreError::InvalidConfig { .. })
        ));
    }

    #[test]
    fn the_link_carries_the_install_id_it_is_given_on_every_call() {
        // pin create, pin poll, and the resources call the probe makes once
        // linked: all three name plex.tv's own client, and the fake behind
        // this test would answer 400 to any of them missing the header
        let server = plex_tv(|req| {
            if req.url.starts_with("/api/v2/pins") && req.url.len() == "/api/v2/pins".len() {
                return Reply::json(r#"{"id": 1, "code": "ABCD"}"#);
            }
            if req.url.starts_with("/api/v2/pins/") {
                return Reply::json(r#"{"authToken": "linked-token"}"#);
            }
            Reply::json(
                r#"[{"name": "Tower", "clientIdentifier": "srv1", "provides": "server", "connections": [{"uri": "http://127.0.0.1:1", "local": true}]}]"#,
            )
        });
        let m = PlexModule;
        let started = m.link_start_at(&server.base_url, "install-a").unwrap();
        let (_, state) = m
            .link_poll_at(&server.base_url, "install-a", &started.state)
            .unwrap();
        resolve_choices(&m, &server.base_url, &state).unwrap();

        let ids: Vec<Option<String>> = server
            .requests()
            .iter()
            .map(|r| r.header("X-Plex-Client-Identifier").map(str::to_string))
            .collect();
        assert_eq!(ids.len(), 3, "pin create, pin poll, and resources: {ids:?}");
        assert!(
            ids.iter().all(|id| id.as_deref() == Some("install-a")),
            "{ids:?}"
        );
    }

    /// Polls `link_choices_at` until the background probe answers, the way
    /// the app itself polls `link_choices` after `link_poll` reaches
    /// `Linked`.
    fn resolve_choices(
        m: &PlexModule,
        base: &str,
        state: &Values,
    ) -> Result<Vec<Choice>, CoreError> {
        let (mut current, mut state) = m.link_choices_at(base, state)?;
        for _ in 0..1000 {
            match current {
                ChoicesState::Ready { choices } => return Ok(choices),
                ChoicesState::Probing => {
                    std::thread::sleep(std::time::Duration::from_millis(10));
                    let (next, next_state) = m.link_choices_at(base, &state)?;
                    current = next;
                    state = next_state;
                }
            }
        }
        panic!("the probe never resolved");
    }

    #[test]
    fn link_choices_answers_probing_at_once_and_never_blocks_the_caller() {
        // an identity probe with nothing listening on the other end waits out
        // the full PROBE_TIMEOUT; the first call must not be the one that
        // waits for it
        let plextv = plex_tv(|req| {
            if req.url.contains("resources") {
                return Reply::json(
                    r#"[{"name": "Tower", "clientIdentifier": "srv1", "provides": "server", "connections": [{"uri": "http://127.0.0.1:1", "local": true}]}]"#,
                );
            }
            Reply::status(404)
        });
        let mut state = Values::new();
        state.insert("token".to_string(), "tok".to_string());
        state.insert("client_id".to_string(), "test-install".to_string());

        let start = std::time::Instant::now();
        let (first, state) = PlexModule
            .link_choices_at(&plextv.base_url, &state)
            .unwrap();
        assert!(matches!(first, ChoicesState::Probing));
        assert!(
            start.elapsed() < std::time::Duration::from_millis(200),
            "the first call spawned the probe rather than waiting on it: {:?}",
            start.elapsed()
        );
        assert!(state.contains_key("probe_id"));

        let choices = resolve_choices(&PlexModule, &plextv.base_url, &state).unwrap();
        assert_eq!(choices.len(), 1);
    }

    #[test]
    fn a_second_poll_after_ready_finds_the_probe_gone() {
        let plextv = plex_tv(|req| {
            if req.url.contains("resources") {
                return Reply::json(
                    r#"[{"name": "Tower", "clientIdentifier": "srv1", "provides": "server", "connections": [{"uri": "http://127.0.0.1:1", "local": true}]}]"#,
                );
            }
            Reply::status(404)
        });
        let mut state = Values::new();
        state.insert("token".to_string(), "tok".to_string());
        state.insert("client_id".to_string(), "test-install".to_string());

        let (mut current, mut state_now) = PlexModule
            .link_choices_at(&plextv.base_url, &state)
            .unwrap();
        state = state_now;
        while matches!(current, ChoicesState::Probing) {
            std::thread::sleep(std::time::Duration::from_millis(10));
            let (next, next_state) = PlexModule
                .link_choices_at(&plextv.base_url, &state)
                .unwrap();
            current = next;
            state_now = next_state;
            state = state_now;
        }
        // the registry entry was consumed by the call that read Ready: a
        // repeat call with the same stale probe_id has nothing left to poll
        assert!(PlexModule
            .link_choices_at(&plextv.base_url, &state)
            .is_err());
    }

    #[test]
    fn choices_list_every_server_nearby_before_remote_and_report_reachability() {
        let plextv = plex_tv(|req| {
            if req.url.contains("resources") {
                assert_eq!(req.header("X-Plex-Token"), Some("linked-token"));
                assert_eq!(req.header("X-Plex-Client-Identifier"), Some("test-install"));
                return Reply::json(
                    r#"[{"name": "Tower", "clientIdentifier": "srv1", "provides": "server", "connections": [{"uri": "http://remote.example:32400", "local": false}, {"uri": "http://192.168.1.20:32400", "local": true}]}]"#,
                );
            }
            Reply::status(404)
        });
        let mut state = Values::new();
        state.insert("token".to_string(), "linked-token".to_string());
        state.insert("client_id".to_string(), "test-install".to_string());

        let choices = resolve_choices(&PlexModule, &plextv.base_url, &state).unwrap();
        assert_eq!(choices.len(), 1);
        assert_eq!(choices[0].id, "srv1");
        assert_eq!(choices[0].name, "Tower");
        assert!(choices[0].nearby, "the local connection sorts first");
        assert_eq!(choices[0].detail, "http://192.168.1.20:32400");
    }

    #[test]
    fn an_account_with_no_server_answers_an_empty_list_rather_than_a_failure() {
        // the account is reachable and the token is good; it just holds
        // nothing this module can add, whether it holds nothing at all or
        // only something that is not a server
        let mut state = Values::new();
        state.insert("token".to_string(), "tok".to_string());
        state.insert("client_id".to_string(), "test-install".to_string());
        for resources in [
            r#"[]"#,
            r#"[{"name": "Living Room", "clientIdentifier": "p1", "provides": "player", "connections": []}]"#,
        ] {
            let plextv = plex_tv(move |_req| Reply::json(resources));
            let choices = resolve_choices(&PlexModule, &plextv.base_url, &state)
                .expect("an account with nothing to offer is an answer, not a failure");
            assert!(choices.is_empty(), "{choices:?}");
        }
    }

    #[test]
    fn a_rejected_credential_while_probing_is_reported_as_unauthorized() {
        let plextv = plex_tv(|_req| Reply::status(401));
        let mut state = Values::new();
        state.insert("token".to_string(), "tok".to_string());
        state.insert("client_id".to_string(), "test-install".to_string());
        let err = resolve_choices(&PlexModule, &plextv.base_url, &state).unwrap_err();
        assert!(matches!(err, CoreError::Unauthorized { .. }));
    }

    #[test]
    fn choice_values_carries_the_chosen_connection_and_the_account_token_never_a_typed_one() {
        let plextv = plex_tv(|req| {
            if req.url.contains("resources") {
                return Reply::json(
                    r#"[{"name": "Tower", "clientIdentifier": "srv1", "provides": "server", "connections": [{"uri": "http://192.168.1.20:32400", "local": true}]}]"#,
                );
            }
            Reply::status(404)
        });
        let mut state = Values::new();
        state.insert("token".to_string(), "linked-token".to_string());
        state.insert("account_base".to_string(), plextv.base_url.clone());
        state.insert("client_id".to_string(), "test-install".to_string());

        let values = PlexModule.choice_values_at(&state, "srv1").unwrap();
        assert_eq!(
            values.get("base_url"),
            Some(&"http://192.168.1.20:32400".to_string())
        );
        assert_eq!(values.get("token"), Some(&"linked-token".to_string()));
    }

    #[test]
    fn choice_values_reuses_the_address_link_choices_already_found_and_probes_nothing_again() {
        let plextv = plex_tv(|req| {
            if req.url.contains("resources") {
                return Reply::json(
                    r#"[{"name": "Tower", "clientIdentifier": "srv1", "provides": "server", "connections": [{"uri": "http://192.168.1.20:32400", "local": true}]}]"#,
                );
            }
            Reply::status(404)
        });
        let mut state = Values::new();
        state.insert("token".to_string(), "linked-token".to_string());
        state.insert("account_base".to_string(), plextv.base_url.clone());
        state.insert("client_id".to_string(), "test-install".to_string());

        let (mut current, mut state) = PlexModule
            .link_choices_at(&plextv.base_url, &state)
            .unwrap();
        while matches!(current, ChoicesState::Probing) {
            std::thread::sleep(std::time::Duration::from_millis(10));
            let (next, next_state) = PlexModule
                .link_choices_at(&plextv.base_url, &state)
                .unwrap();
            current = next;
            state = next_state;
        }
        let requests_once_ready = plextv.requests().len();

        // the id offered by the resolved list, looked up as a viewer
        // pressing Select would: no second network call to plex.tv, so
        // add_from_choice never waits on one right after this fix already
        // stopped link_choices from doing so
        let values = PlexModule.choice_values_at(&state, "srv1").unwrap();
        assert_eq!(
            values.get("base_url"),
            Some(&"http://192.168.1.20:32400".to_string())
        );
        assert_eq!(
            plextv.requests().len(),
            requests_once_ready,
            "choice_values_at probed again after link_choices_at already resolved this id"
        );
    }

    #[test]
    fn a_nearby_connection_that_answers_is_reported_reachable() {
        let nearby = FakeServer::start(|_req| Reply::status(200));
        let nearby_base = nearby.base_url.clone();
        let plextv = plex_tv(move |req| {
            if req.url.contains("resources") {
                return Reply::json(&format!(
                    r#"[{{"name": "Tower", "clientIdentifier": "srv1", "provides": "server", "connections": [{{"uri": "http://127.0.0.1:1", "local": false}}, {{"uri": "{nearby_base}", "local": true}}]}}]"#
                ));
            }
            Reply::status(404)
        });
        let mut state = Values::new();
        state.insert("token".to_string(), "tok".to_string());
        state.insert("client_id".to_string(), "test-install".to_string());

        let choices = resolve_choices(&PlexModule, &plextv.base_url, &state).unwrap();
        assert_eq!(choices.len(), 1);
        assert!(choices[0].nearby);
        assert!(choices[0].reachable, "the nearby connection answered");
    }

    #[test]
    fn a_dead_nearby_connection_falls_back_to_a_remote_one_that_answers() {
        let remote = FakeServer::start(|_req| Reply::status(200));
        let remote_base = remote.base_url.clone();
        let plextv = plex_tv(move |req| {
            if req.url.contains("resources") {
                return Reply::json(&format!(
                    r#"[{{"name": "Tower", "clientIdentifier": "srv1", "provides": "server", "connections": [{{"uri": "http://127.0.0.1:1", "local": true}}, {{"uri": "{remote_base}", "local": false}}]}}]"#
                ));
            }
            Reply::status(404)
        });
        let mut state = Values::new();
        state.insert("token".to_string(), "tok".to_string());
        state.insert("client_id".to_string(), "test-install".to_string());

        let choices = resolve_choices(&PlexModule, &plextv.base_url, &state).unwrap();
        assert_eq!(choices.len(), 1);
        assert!(choices[0].reachable, "the remote connection answered");
        assert_eq!(choices[0].detail, remote.base_url);
        assert!(
            !choices[0].nearby,
            "the connection actually used was remote"
        );
    }

    #[test]
    fn several_servers_are_probed_concurrently_and_land_in_the_accounts_own_order() {
        // Tower answers slowly and Attic answers fast: if the servers were
        // probed one after another the wait would be their sum (1600ms:
        // 1000ms + 600ms), and if results were ordered by completion Attic
        // (the faster one) would land first even though the account lists
        // Tower first. Probed concurrently, the whole call takes about as
        // long as Tower alone, ~1000ms; the assertion below checks for
        // under 1300ms, several hundred milliseconds of headroom on both
        // sides, so a failure here means probing went serial, not that the
        // machine briefly ran slow.
        let tower_delay = std::time::Duration::from_millis(1000);
        let attic_delay = std::time::Duration::from_millis(600);
        let tower = FakeServer::start(move |_req| {
            std::thread::sleep(tower_delay);
            Reply::status(200)
        });
        let attic = FakeServer::start(move |_req| {
            std::thread::sleep(attic_delay);
            Reply::status(404)
        });
        let (tower_base, attic_base) = (tower.base_url.clone(), attic.base_url.clone());
        let plextv = plex_tv(move |req| {
            if req.url.contains("resources") {
                return Reply::json(&format!(
                    r#"[{{"name": "Tower", "clientIdentifier": "srv1", "provides": "server", "connections": [{{"uri": "{tower_base}", "local": true}}]}}, {{"name": "Attic", "clientIdentifier": "srv2", "provides": "server", "connections": [{{"uri": "{attic_base}", "local": true}}]}}]"#
                ));
            }
            Reply::status(404)
        });
        let mut state = Values::new();
        state.insert("token".to_string(), "tok".to_string());
        state.insert("client_id".to_string(), "test-install".to_string());

        let start = std::time::Instant::now();
        let choices = resolve_choices(&PlexModule, &plextv.base_url, &state).unwrap();
        let elapsed = start.elapsed();

        assert_eq!(choices.len(), 2);
        assert_eq!(
            choices[0].id, "srv1",
            "the account's own order, not completion order"
        );
        assert!(choices[0].reachable, "Tower's identity answered 200");
        assert_eq!(choices[1].id, "srv2");
        assert!(
            !choices[1].reachable,
            "a 404 identity answer is unreachable"
        );
        let serial_baseline = tower_delay + attic_delay; // 1600ms
        let bound = std::time::Duration::from_millis(1300);
        assert!(
            elapsed < bound,
            "concurrent probing takes about {tower_delay:?} (Tower alone); \
             probing one server after another would take about {serial_baseline:?}; \
             this took {elapsed:?}, over the {bound:?} bound"
        );
    }

    #[test]
    fn a_server_that_answers_nowhere_is_listed_and_marked_unreachable() {
        let plextv = plex_tv(|req| {
            if req.url.contains("resources") {
                return Reply::json(
                    r#"[{"name": "Tower", "clientIdentifier": "srv1", "provides": "server", "connections": [{"uri": "http://127.0.0.1:1", "local": true}, {"uri": "http://127.0.0.1:1", "local": false}]}]"#,
                );
            }
            Reply::status(404)
        });
        let mut state = Values::new();
        state.insert("token".to_string(), "tok".to_string());
        state.insert("client_id".to_string(), "test-install".to_string());

        let choices = resolve_choices(&PlexModule, &plextv.base_url, &state).unwrap();
        assert_eq!(choices.len(), 1);
        assert_eq!(choices[0].id, "srv1");
        assert!(
            !choices[0].reachable,
            "nothing answers at this server's connections"
        );
    }

    #[test]
    fn a_transport_error_fetching_resources_names_neither_host_nor_token() {
        let mut state = Values::new();
        state.insert("token".to_string(), "sekrit-token".to_string());
        state.insert("client_id".to_string(), "test-install".to_string());
        // nothing listens on port 1
        let err = resolve_choices(&PlexModule, "http://127.0.0.1:1", &state).unwrap_err();
        let CoreError::SourceUnavailable { msg, .. } = err else {
            panic!("expected SourceUnavailable, got {err:?}");
        };
        assert!(!msg.contains("127.0.0.1"), "{msg}");
        assert!(!msg.contains("sekrit-token"), "{msg}");
    }

    #[test]
    fn two_streams_to_one_host_share_an_agent() {
        let _ = shared_stream_agent("https://plex-a.example:32400/library/parts/1/1/a.mkv");
        let id_a1 =
            shared_stream_agent_pool_id("https://plex-a.example:32400/library/parts/1/1/a.mkv");
        let _ = shared_stream_agent("https://plex-a.example:32400/library/parts/2/1/b.mkv");
        let id_a2 =
            shared_stream_agent_pool_id("https://plex-a.example:32400/library/parts/2/1/b.mkv");
        let _ = shared_stream_agent("https://plex-b.example:32400/library/parts/3/1/c.mkv");
        let id_b =
            shared_stream_agent_pool_id("https://plex-b.example:32400/library/parts/3/1/c.mkv");

        assert_eq!(
            id_a1, id_a2,
            "two streams to the same host must share one agent"
        );
        assert_ne!(
            id_a1, id_b,
            "streams to different hosts must not share an agent"
        );
    }

    #[test]
    fn chunk_is_the_measured_span() {
        // 2 MiB: the span at which one connection independently cleared
        // 130+ Mbps in the stage-0 measurement (2026-08-17).
        assert_eq!(CHUNK, 2 * 1024 * 1024);
    }
}
