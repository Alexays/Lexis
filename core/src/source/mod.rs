use std::io::{Read, Seek};
use std::sync::Arc;

pub mod local;
pub mod module;
pub mod plex;
#[cfg(test)]
pub mod testkit;

use module::SourceModule;

/// The playback brake a scan parks on: a flag with a condvar beside it, so a
/// parked scan sleeps until the brake is released rather than polling it.
#[derive(Default)]
pub struct Pause {
    paused: parking_lot::Mutex<bool>,
    released: parking_lot::Condvar,
}

impl Pause {
    pub const fn new() -> Pause {
        Pause {
            paused: parking_lot::Mutex::new(false),
            released: parking_lot::Condvar::new(),
        }
    }

    pub fn set(&self, paused: bool) {
        *self.paused.lock() = paused;
        self.released.notify_all();
    }

    /// Returns once the brake is off: at once when it already is.
    pub fn wait(&self) {
        let mut paused = self.paused.lock();
        self.released.wait_while(&mut paused, |paused| *paused);
    }
}

#[derive(Debug, thiserror::Error)]
pub enum SourceError {
    #[error("not found: {0}")]
    NotFound(String),
    #[error("invalid path: {0}")]
    InvalidPath(String),
    #[error("the credentials were rejected")]
    Unauthorized,
    #[error("io error: {0}")]
    Io(#[from] std::io::Error),
    /// The source understood the request and refused it for a reason a
    /// retry cannot fix: an item it no longer has, a malformed request.
    #[error("{0}")]
    Refused(String),
}

/// Read and Seek only speak io::Error, and the kind is what a caller can act on.
impl From<SourceError> for std::io::Error {
    fn from(e: SourceError) -> std::io::Error {
        use std::io::{Error, ErrorKind};
        match e {
            SourceError::NotFound(p) => Error::new(ErrorKind::NotFound, p),
            SourceError::InvalidPath(p) => Error::new(ErrorKind::InvalidInput, p),
            SourceError::Unauthorized => {
                Error::new(ErrorKind::PermissionDenied, "the credentials were rejected")
            }
            SourceError::Refused(msg) => Error::other(msg),
            SourceError::Io(e) => e,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Entry {
    /// Path relative to the source root, "/"-separated, no leading slash.
    pub path: String,
    pub name: String,
    pub is_dir: bool,
    pub size: u64,
    /// Unix seconds.
    pub mtime: i64,
}

pub trait ReadSeek: Read + Seek + Send {}
impl<T: Read + Seek + Send> ReadSeek for T {}

/// A sized request for an image, and the plain path it falls back to when the
/// server cannot honour the size. `fallback` always fetches: it is the same
/// path `art_url` returned before a source could shrink its own images.
/// `width` names the size in the cache key, so that changing it here misses
/// the file the old one left behind rather than serving it forever.
pub struct ArtUrl {
    pub url: String,
    pub fallback: String,
    pub width: u32,
}

/// Which of a title's images is wanted. `Thumb` and `Backdrop` are the same
/// picture at two sizes, and they are two sizes because they are drawn at two:
/// a backdrop fills a 3840x2160 hero, a thumb a 400x225pt card in a rail.
/// Serving the hero's file to the card costs twenty times the bytes and a 4K
/// resize on the server for a twentieth of the pixels ever drawn.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum ArtKind {
    Poster,
    Thumb,
    Backdrop,
    /// The title's own lettering. The one kind no catalogue serves: it is
    /// TMDB's whatever described the title, so it never reaches `art_url`.
    Logo,
    /// A performer's photograph. Like the logo it is always TMDB's and never
    /// a catalogue's, and unlike every other kind the number beside it is a
    /// person's rather than a title's - `people.id`, which is why that table
    /// carries a rowid at all.
    Face,
    /// One episode's own frame. The number beside it is a file's, the way a
    /// face's is a person's, because a file row is the only thing in this
    /// index an episode is. It comes from the catalogue that enumerated the
    /// file and never from TMDB: the path is one the source stored, and a
    /// per-episode still from anywhere else would be a request per season of
    /// every show for a picture the server already holds.
    Still,
}

impl ArtKind {
    /// Whether this is the wide image. The two wide sizes share a cache name
    /// and a stored path; only the size segment tells them apart.
    pub fn wide(self) -> bool {
        matches!(self, ArtKind::Thumb | ArtKind::Backdrop)
    }
}

/// A source that enumerates its own titles, and serves the poster or
/// backdrop it stored a path to for one of them: the source that knows a
/// title's images is the one that enumerated it. None is the default, and a
/// source without one is walked as a directory tree instead, its titles'
/// images from Tmdb.
pub trait Catalogue: Send + Sync {
    /// Pulls the source's own catalogue into the index. The write connection
    /// arrives behind its mutex: the implementation takes the guard per
    /// transaction, never across its network calls. `paused` is the playback
    /// brake: a pull asked to stand aside parks between pages. `full` asks the
    /// server for everything it holds, whatever its own stamps say a pull
    /// would find - what a viewer pressing Scan gets.
    fn pull(
        &self,
        db: &parking_lot::Mutex<crate::index::db::Db>,
        paused: &Pause,
        full: bool,
    ) -> Result<crate::index::scan::ScanStats, crate::index::scan::ScanError>;
    fn art_url(&self, art_path: &str, kind: ArtKind) -> ArtUrl;
    /// The width `art_url` asks for, without a title to ask about: what the
    /// cache sweep needs to tell a file this build would still serve from one
    /// an older build left behind.
    fn art_width(&self, kind: ArtKind) -> u32;
    fn agent(&self) -> ureq::Agent;
    fn token(&self) -> &str;
    /// The people credited on the item a file's `rating_key` names, each
    /// with the address of a photograph of them, for a title nothing else
    /// has faces for. Empty where the catalogue keeps none.
    fn cast_faces(&self, _rating_key: &str) -> Result<Vec<(String, String)>, SourceError> {
        Ok(Vec::new())
    }
    /// Where the item a file's `rating_key` names has its intro and its
    /// credits, as the catalogue's own analysis found them. Empty where it
    /// keeps none.
    fn markers(&self, _rating_key: &str) -> Result<Vec<Marker>, SourceError> {
        Ok(Vec::new())
    }
}

/// A stretch of a file a catalogue has marked, in seconds from its start.
#[derive(Debug, Clone, PartialEq)]
pub struct Marker {
    pub credits: bool,
    pub start_secs: f64,
    pub end_secs: f64,
}

/// What a timeline report says the player is doing.
///
/// A server keeps two different things from these: the resume point, which
/// any of the three carries, and the session on its own dashboard, which only
/// `Playing` and `Paused` open and only `Stopped` closes. A player that only
/// ever reported `Stopped` writes history correctly and never appears to be
/// watching anything.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum PlaybackState {
    Playing,
    Paused,
    /// The last report of a playback. Closes the session rather than leaving
    /// the server to time it out, which is what leaves a stale row on the
    /// dashboard for a quarter of an hour.
    Stopped,
}

/// A server that holds watch state of its own: playback position, scrobbles.
/// None is the default, and a source without one keeps no state past what
/// `list`/`open` already answer.
pub trait WatchSync: Send + Sync {
    fn timeline(
        &self,
        rating_key: &str,
        state: PlaybackState,
        position_secs: f64,
        duration_secs: f64,
    ) -> Result<(), SourceError>;
    fn scrobble(&self, rating_key: &str) -> Result<(), SourceError>;
    fn unscrobble(&self, rating_key: &str) -> Result<(), SourceError>;
}

pub trait Source: Send + Sync {
    fn id(&self) -> &str;
    fn list(&self, dir_path: &str) -> Result<Vec<Entry>, SourceError>;
    fn open(&self, file_path: &str) -> Result<Box<dyn ReadSeek>, SourceError>;
    /// Kept separate from `watch_sync`: a source can enumerate its own
    /// catalogue without holding any watch state, and vice versa.
    fn catalogue(&self) -> Option<&dyn Catalogue> {
        None
    }
    fn watch_sync(&self) -> Option<&dyn WatchSync> {
        None
    }
    /// Puts a live connection to this source in the pool `open` draws from,
    /// so that a press on play pays for no name lookup and no handshake.
    /// Nothing for a source whose files are already on this device.
    fn warm(&self) {}
}

/// Every module this build has. Adding a kind means adding one entry here.
/// The order here is the order the viewer sees on the add-source screen: Plex
/// comes first because a family watching through the app links a Plex server,
/// not a local path.
pub fn modules() -> Vec<Arc<dyn SourceModule>> {
    #[allow(unused_mut)]
    let mut m: Vec<Arc<dyn SourceModule>> =
        vec![Arc::new(plex::PlexModule), Arc::new(local::LocalModule)];
    #[cfg(test)]
    m.extend(testkit::fixtures());
    m
}

pub fn module(id: &str) -> Option<Arc<dyn SourceModule>> {
    modules().into_iter().find(|m| m.id() == id)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn local_and_plex_resolve_by_id_through_the_registry() {
        assert!(module("local").is_some());
        assert!(module("plex").is_some());
    }

    /// The add-source screen draws its pills in this order, undecided by the
    /// app: Plex is the path the owner's family uses, so it comes first.
    #[test]
    fn plex_is_offered_ahead_of_local_files() {
        let ids: Vec<&str> = modules().iter().map(|m| m.id()).collect();
        assert_eq!(&ids[..2], &["plex", "local"]);
    }
}
