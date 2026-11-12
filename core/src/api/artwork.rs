use super::{unix_now, CoreError, LexisCore};
use crate::index::db::MetadataSource;
use crate::metadata::artwork::{
    artwork_file, CacheName, TMDB_BACKDROP_BASE, TMDB_POSTER_BASE, TMDB_PROFILE_BASE,
    TMDB_THUMB_BASE,
};
use crate::metadata::client::TmdbError;
use crate::metadata::evict::{free_bytes, ArtworkCache, Asked};
use crate::metadata::logo::{logo, png_aspect, LogoError, SOURCE_LOGO_PREFIX, TMDB_LOGO_BASE};
use crate::metadata::trailer::{trailer, TrailerError, RECHECK_SECS as TRAILER_RECHECK_SECS};
use crate::source::ArtKind;
use parking_lot::{Condvar, Mutex};
use std::collections::{HashMap, HashSet};
use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Weak};
use std::time::Duration;

/// How long the artwork thread waits on an empty queue before ending. The next
/// ask starts another: a library nobody is browsing keeps no thread.
const ARTWORK_IDLE: Duration = Duration::from_secs(5);

/// How many images are fetched at once. Almost all of an artwork fetch is a
/// wait: a server resizing an image and a link carrying it. Four is what a
/// rail's worth of cards fills in without asking a home server for more
/// simultaneous transcodes than it will do well.
const ARTWORK_FETCHERS: usize = 4;

#[uniffi::export]
impl LexisCore {
    /// The local path of this title's poster, downloading it on first ask.
    /// None when nothing knows of a poster, or when the Plex source that holds
    /// it is gone. One title at a time: the UI asks for what it is showing.
    /// A failed TMDB image carries the pseudo-source id "tmdb", a Plex one the
    /// id of the source that holds it.
    ///
    /// The call blocks for the whole download, so nothing that also has to
    /// answer a remote press may make it: `poster_now` is the one for a
    /// caller drawing tiles, and it waits for nothing.
    pub fn poster_file(&self, title_id: i64) -> Result<Option<String>, CoreError> {
        self.artwork(title_id, ArtKind::Poster)
    }
}

#[cfg(test)]
impl LexisCore {
    /// The local path of this title's backdrop, the wide image a detail screen
    /// is built on, under the same rules as `poster_file`. A title whose only
    /// artwork is a poster answers None; an episode-derived show usually does.
    pub fn backdrop_file(&self, title_id: i64) -> Result<Option<String>, CoreError> {
        self.artwork(title_id, ArtKind::Backdrop)
    }
}

/// What a tile can draw for a title without waiting for anything.
#[derive(Debug, uniffi::Enum)]
pub enum ArtworkState {
    /// The image is on disk, at this path.
    Ready { path: String },
    /// Queued, or being fetched right now. Ask again.
    Fetching,
    /// Nothing knows of one, or the source that held it is gone. Final.
    Missing,
    /// The fetch failed. Reported once, to the ask that reads it; the ask
    /// after that queues the title again, so the backoff is the caller's.
    Failed { msg: String },
}

/// The same four answers for a title's own lettering, with the shape to draw
/// it in. A logo carries more than a path: its aspect ratio is TMDB's own
/// measurement of the file, so a screen can lay the logo out before the PNG
/// is decoded and never move what sits under it.
#[derive(Debug, uniffi::Enum)]
pub enum LogoState {
    Ready {
        path: String,
        aspect: f32,
    },
    Fetching,
    /// TMDB holds no logo for this title, or nothing has matched it to TMDB
    /// yet, or no key is stored at all. The ordinary answer for most of a
    /// library, and the screens are built for it rather than around it.
    Missing,
    Failed {
        msg: String,
    },
}

/// Where a title's trailer plays, under the same four answers as the artwork
/// above. A key on YouTube and never a stream: that is all TMDB names, and
/// nothing here can turn it into something the player could open. Which of
/// YouTube's two ways in to use - the app on the television or the site - is
/// the app's to decide, so the key crosses as it is stored.
#[derive(Debug, uniffi::Enum)]
pub enum TrailerState {
    Ready {
        youtube_key: String,
    },
    Fetching,
    /// TMDB lists no trailer for this title, or nothing has matched it to
    /// TMDB, or no key is stored at all. The ordinary answer for a good part
    /// of any library, and the screen draws no button rather than a dead one.
    Missing,
    Failed {
        msg: String,
    },
}

/// Which titles a trailer is being asked TMDB about, and what came back when
/// the answer was not worth storing. A found key and a "there is none" both go
/// to the index, where the next ask reads them; only a failure lives here, and
/// only until the ask that reads it.
#[derive(Default)]
pub(super) struct TrailerWork {
    /// In flight, so an ask repeated on every poll asks TMDB once.
    asking: HashSet<i64>,
    failed: HashMap<i64, String>,
}

/// The titles waiting for an image, and what the thread that fetches them had
/// to say. A download is seconds of somebody else's network on a thread that
/// also has to answer the remote, so it happens on none of the caller's.
#[derive(Default)]
pub(super) struct ArtworkWork {
    /// Newest last: the thread pops the back, so the tile the viewer just
    /// reached is fetched before the ones they scrolled past. Bounded by the
    /// caller: only a title it is showing is ever asked for.
    pub(super) wanted: Vec<(i64, ArtKind)>,
    /// Queued or in flight, so an ask repeated every tick queues it once.
    holding: HashSet<(i64, ArtKind)>,
    /// Set while a film plays: the player owns the network then.
    paused: bool,
    /// How many threads are alive to drain `wanted`.
    working: usize,
    /// The cache has grown past its budget, or has never been looked at.
    sweep: bool,
    /// Fetches in flight. A sweep waits for none and holds new ones back: it
    /// would otherwise delete a download's `.part` file under it.
    fetching: usize,
    sweeping: bool,
}

pub(super) struct ArtworkQueue {
    pub(super) work: Mutex<ArtworkWork>,
    woken: Condvar,
    /// What a fetch that produced no file had to say: `Some(msg)` for one that
    /// failed, `None` for a title whose source is gone. Taken by the ask that
    /// reports it, so the one after re-queues rather than reading it again.
    answered: Mutex<HashMap<(i64, ArtKind), Option<String>>>,
    /// What the artwork directory holds, and what it gives up when it holds
    /// too much.
    cache: ArtworkCache,
    /// How many fetches have finished, ever. A caller drawing tiles reads this
    /// once a frame and asks about its titles again only when it moves, which
    /// is one call rather than one per waiting tile per frame.
    settled: AtomicU64,
}

impl ArtworkQueue {
    pub(super) fn new(dir: PathBuf) -> Self {
        Self {
            work: Mutex::new(ArtworkWork::default()),
            woken: Condvar::new(),
            answered: Mutex::new(HashMap::new()),
            cache: ArtworkCache::new(dir),
            settled: AtomicU64::new(0),
        }
    }
}

impl ArtworkQueue {
    /// Whether a tile is still waiting for an image, queued or in flight. The
    /// background pass stands aside while one is: artwork is what the viewer
    /// is looking at, and both go out over the same network.
    pub(super) fn busy(&self) -> bool {
        !self.work.lock().holding.is_empty()
    }
}

#[uniffi::export]
impl LexisCore {
    /// This title's poster if the cache already holds it, and the fetch that
    /// will put it there if it does not: it never waits on the network, which
    /// is what a caller that also has to answer a remote press needs.
    /// `poster_file` is the blocking one, for callers drawing nothing.
    pub fn poster_now(&self, title_id: i64) -> ArtworkState {
        self.artwork_now(title_id, ArtKind::Poster)
    }

    /// The wide image at the size a rail's landscape card draws it, under the
    /// same rules as `poster_now`. A card that took `backdrop_now` would pull
    /// the hero's 3840x2160 file for a 400x225pt tile.
    pub fn thumb_now(&self, title_id: i64) -> ArtworkState {
        self.artwork_now(title_id, ArtKind::Thumb)
    }

    /// The wide image at the size a full-bleed hero draws it, under the same
    /// rules as `poster_now`.
    pub fn backdrop_now(&self, title_id: i64) -> ArtworkState {
        self.artwork_now(title_id, ArtKind::Backdrop)
    }

    /// Where this title's trailer plays, under the same rules as `poster_now`:
    /// never a wait on the network, and the ask put on a thread behind the
    /// answer. A screen that gets `Fetching` asks again.
    pub fn trailer_now(&self, title_id: i64) -> Result<TrailerState, CoreError> {
        if let Some(msg) = self.trailers.lock().failed.remove(&title_id) {
            return Ok(TrailerState::Failed { msg });
        }
        let Some(state) = self.read_db.lock().trailer_state(title_id)? else {
            return Ok(TrailerState::Missing);
        };
        if let Some(key) = state.key {
            return Ok(TrailerState::Ready { youtube_key: key });
        }
        // asked and answered "there is none" is Missing until it goes stale;
        // never asked is an ask
        if state.checked_at > 0 && unix_now() - state.checked_at < TRAILER_RECHECK_SECS {
            return Ok(TrailerState::Missing);
        }
        // a title TMDB has not placed, or a library with no key, is not a
        // question anything can answer: nothing is stored, so the day either
        // lands this asks
        if state.tmdb_id.is_none() || self.tmdb_key().is_none() {
            return Ok(TrailerState::Missing);
        }
        // The player owns the network while a film is up, which is the same
        // brake the artwork queue stands behind. Nothing is written, so the
        // next screen that asks about this title asks TMDB for real.
        if self.artwork.work.lock().paused {
            return Ok(TrailerState::Missing);
        }
        self.ask_trailer(title_id);
        Ok(TrailerState::Fetching)
    }

    /// Puts one title on a thread of its own unless one is already asking
    /// about it. No pool and no queue, unlike the artwork beside it: a detail
    /// screen asks about the one title it is showing, so there is never a
    /// fleet of these to hold back.
    fn ask_trailer(&self, title_id: i64) {
        if !self.trailers.lock().asking.insert(title_id) {
            return;
        }
        // None only while the core itself is being dropped, which cannot be
        // happening: this is running on a live instance
        let Some(this) = self.self_ref.upgrade() else {
            return;
        };
        std::thread::spawn(move || {
            let found = this.fetch_trailer(title_id);
            let mut work = this.trailers.lock();
            if let Err(e) = found {
                work.failed.insert(title_id, e.to_string());
            }
            // last, so the ask that finds the title gone from here also finds
            // the row it wrote
            work.asking.remove(&title_id);
        });
    }

    fn fetch_trailer(&self, title_id: i64) -> Result<(), CoreError> {
        let Some(key) = self.tmdb_key() else {
            return Ok(());
        };
        let client = self.tmdb_client(&key);
        trailer(&self.db, &client, title_id, unix_now()).map_err(|e| match e {
            TrailerError::Index(e) => CoreError::Storage { msg: e.to_string() },
            TrailerError::Tmdb(TmdbError::Unauthorized) => CoreError::Unauthorized {
                source_id: "tmdb".to_string(),
            },
            TrailerError::Tmdb(e) => CoreError::SourceUnavailable {
                source_id: "tmdb".to_string(),
                msg: e.to_string(),
            },
        })?;
        Ok(())
    }

    /// This title's own lettering, under the same rules as `poster_now`: never
    /// a wait on the network, and the fetch queued behind the answer.
    ///
    /// A logo is the source's own when the sync found one (a Plex
    /// `clearLogo`), and TMDB's otherwise, whatever described the title: a
    /// Plex-described library still gets its lettering where Plex has none.
    pub fn logo_now(&self, title_id: i64) -> Result<LogoState, CoreError> {
        let key = (title_id, ArtKind::Logo);
        if let Some(answer) = self.artwork.answered.lock().remove(&key) {
            return Ok(match answer {
                Some(msg) => LogoState::Failed { msg },
                None => LogoState::Missing,
            });
        }
        // the row is the authority on whether there is anything to draw: the
        // path TMDB chose, and the shape it measured, are both stored
        let Some(state) = self.read_db.lock().logo_state(title_id)? else {
            return Ok(LogoState::Missing);
        };
        let Some(stored) = state.path else {
            // asked and answered "none" is Missing; never asked is a fetch
            return Ok(if state.checked_at > 0 {
                LogoState::Missing
            } else {
                self.queue_artwork(key);
                LogoState::Fetching
            });
        };
        let name = format!(
            "{}-{}.png",
            artwork_name(title_id, ArtKind::Logo),
            sized(tmdb_size(TMDB_LOGO_BASE), &stored)
        );
        let path = self.cache_dir.join("artwork").join(&name);
        // a source's logo is measured once fetched: until then it has no shape
        if path.exists() && state.aspect > 0.0 {
            self.artwork.cache.hit(&name);
            if self.artwork.cache.due() {
                self.ask_sweep();
            }
            return Ok(LogoState::Ready {
                path: path.to_string_lossy().into_owned(),
                aspect: state.aspect,
            });
        }
        // the choice is stored and the file is not: a sweep took it, and the
        // download that brings it back asks TMDB nothing
        self.queue_artwork(key);
        Ok(LogoState::Fetching)
    }

    /// A performer's photograph, by `people.id` rather than by a title.
    ///
    /// `Missing` is the ordinary answer and costs nothing: the path is learned
    /// from the credits of a title that matched TMDB, so a person in a library
    /// nothing has matched has none, for ever, and this never queues a fetch
    /// for them. A cast rail is built to read as a cast rail in that state
    /// rather than as one that failed to load.
    pub fn face_now(&self, person_id: i64) -> Result<ArtworkState, CoreError> {
        let key = (person_id, ArtKind::Face);
        if let Some(answer) = self.artwork.answered.lock().remove(&key) {
            return Ok(match answer {
                Some(msg) => ArtworkState::Failed { msg },
                None => ArtworkState::Missing,
            });
        }
        // the row is the authority: no path stored is nothing to fetch, and
        // no request is made to find that out
        let profile = self
            .read_db
            .lock()
            .person_profile(person_id)?
            .unwrap_or_default();
        if profile.is_empty() {
            return Ok(ArtworkState::Missing);
        }
        let name = format!(
            "{}-{}.jpg",
            artwork_name(person_id, ArtKind::Face),
            sized(tmdb_size(TMDB_PROFILE_BASE), &profile)
        );
        let path = self.cache_dir.join("artwork").join(&name);
        if path.exists() {
            self.artwork.cache.hit(&name);
            if self.artwork.cache.due() {
                self.ask_sweep();
            }
            return Ok(ArtworkState::Ready {
                path: path.to_string_lossy().into_owned(),
            });
        }
        self.queue_artwork(key);
        Ok(ArtworkState::Fetching)
    }

    /// One episode's own frame, by `files.id` rather than by a title.
    ///
    /// `Missing` is the ordinary answer and costs one indexed lookup: the
    /// still is a path the source that enumerated the file stored, so a file
    /// nothing named a frame for has none and this queues no fetch for it. A
    /// list of episodes is built to read as one in that state - an episode
    /// with no still is most of what a library holds, not the exception.
    pub fn still_now(&self, file_id: i64) -> Result<ArtworkState, CoreError> {
        let key = (file_id, ArtKind::Still);
        if let Some(answer) = self.artwork.answered.lock().remove(&key) {
            return Ok(match answer {
                Some(msg) => ArtworkState::Failed { msg },
                None => ArtworkState::Missing,
            });
        }
        // the row is the authority on whether there is anything to draw, and
        // the source it names is the authority on what size it was asked for
        let Some((source_id, still_path)) = self.read_db.lock().still_source(file_id)? else {
            return Ok(ArtworkState::Missing);
        };
        let Some(size) = self
            .built_source(&source_id)
            .and_then(|s| Some(s.catalogue()?.art_width(ArtKind::Still)))
        else {
            // the source was removed while its rows waited to be pruned
            return Ok(ArtworkState::Missing);
        };
        let name = format!(
            "{}-{}.jpg",
            artwork_name(file_id, ArtKind::Still),
            sized(&size.to_string(), &still_path)
        );
        let path = self.cache_dir.join("artwork").join(&name);
        if path.exists() {
            self.artwork.cache.hit(&name);
            if self.artwork.cache.due() {
                self.ask_sweep();
            }
            return Ok(ArtworkState::Ready {
                path: path.to_string_lossy().into_owned(),
            });
        }
        self.queue_artwork(key);
        Ok(ArtworkState::Fetching)
    }

    /// How many artwork fetches have finished since this core was built. It
    /// only ever grows, and a caller with tiles waiting watches it rather than
    /// asking after each of them: the answer to "has anything arrived" costs
    /// one call, whether ten tiles are waiting or two hundred.
    pub fn artwork_settled(&self) -> u64 {
        self.artwork.settled.load(Ordering::Relaxed)
    }

    /// Holds the artwork thread while something else owns the network,
    /// playback above all. What is already queued stays queued.
    pub fn pause_artwork(&self, paused: bool) {
        self.artwork.work.lock().paused = paused;
        self.artwork.woken.notify_all();
    }
}

impl LexisCore {
    fn artwork_now(&self, title_id: i64, kind: ArtKind) -> ArtworkState {
        let key = (title_id, kind);
        if let Some(answer) = self.artwork.answered.lock().remove(&key) {
            return match answer {
                Some(msg) => ArtworkState::Failed { msg },
                None => ArtworkState::Missing,
            };
        }
        // The size belongs to the name `artwork` writes under, so it belongs
        // here too: looking for the bare name would miss every file on disk,
        // and looking for any size would serve last build's dimensions for
        // ever, which is what putting the size in the key is meant to stop.
        let Some(size) = self.artwork_size(title_id, kind) else {
            return ArtworkState::Missing;
        };
        let name = format!("{}-{size}.jpg", artwork_name(title_id, kind));
        let path = self.cache_dir.join("artwork").join(&name);
        if path.exists() {
            // the one signal the policy runs on, and the one place it can be
            // taken: a filesystem does not maintain atime, and touching mtime
            // here would be a write for every tile the viewer scrolls past
            self.artwork.cache.hit(&name);
            if self.artwork.cache.due() {
                self.ask_sweep();
            }
            return ArtworkState::Ready {
                path: path.to_string_lossy().into_owned(),
            };
        }
        self.queue_artwork(key);
        ArtworkState::Fetching
    }

    /// This title's image if the cache already holds it, and nothing at all if
    /// it does not: no fetch queued, no cache hit recorded, no sweep asked
    /// for. `artwork_now` is the one for a caller drawing a tile, which wants
    /// all three; a snapshot of what is already on disk must leave the cache
    /// exactly as it found it.
    pub(super) fn artwork_on_disk(&self, title_id: i64, kind: ArtKind) -> Option<PathBuf> {
        let size = self.artwork_size(title_id, kind)?;
        let name = format!("{}-{size}.jpg", artwork_name(title_id, kind));
        let path = self.cache_dir.join("artwork").join(name);
        path.exists().then_some(path)
    }

    /// The size segment the cached file carries, resolved exactly as
    /// `artwork` resolves it and from the same rows. Every lookup here is a
    /// memoised source or a constant, never the network, so the tile path
    /// stays as cheap as the cache check it serves.
    fn artwork_size(&self, title_id: i64, kind: ArtKind) -> Option<String> {
        let ((poster, backdrop, source), source_ids) = {
            let db = self.read_db.lock();
            let paths = db.artwork_paths(title_id).ok()??;
            (paths, db.title_source_ids(title_id).ok()?)
        };
        // a title nothing stored a path for holds no file at any size
        let path = if kind.wide() { backdrop } else { poster }?;
        let size = match source {
            MetadataSource::Tmdb => tmdb_size(tmdb_base(kind)).to_string(),
            MetadataSource::Plex => source_ids.iter().find_map(|sid| {
                let source = self.built_source(sid)?;
                Some(source.catalogue()?.art_width(kind).to_string())
            })?,
        };
        Some(sized(&size, &path))
    }

    /// Every size segment a file may carry and still be one this build would
    /// serve. Both TMDB sizes are always in it: any title may be described
    /// from there, and the CDN names the size in the path.
    ///
    /// None when a configured source cannot be built. Nothing on disk can be
    /// called stale by a build that cannot say what it would ask for, and the
    /// answer that costs least when it is wrong is the one that deletes
    /// nothing.
    fn asked_sizes(&self) -> Option<Asked> {
        let mut asked = Asked::default();
        asked.poster.insert(tmdb_size(TMDB_POSTER_BASE).to_string());
        asked
            .backdrop
            .insert(tmdb_size(TMDB_THUMB_BASE).to_string());
        asked
            .backdrop
            .insert(tmdb_size(TMDB_BACKDROP_BASE).to_string());
        // no source contributes a logo size: a logo is TMDB's whatever
        // described the title, so this one entry is the whole of it
        asked.logo.insert(tmdb_size(TMDB_LOGO_BASE).to_string());
        // and a face is TMDB's the same way, at the one size a rail draws
        asked.face.insert(tmdb_size(TMDB_PROFILE_BASE).to_string());
        let ids: Vec<String> = self
            .configs
            .lock()
            .iter()
            .map(|c| c.id().to_string())
            .collect();
        for id in ids {
            let source = self.built_source(&id)?;
            let Some(catalogue) = source.catalogue() else {
                continue;
            };
            asked
                .poster
                .insert(catalogue.art_width(ArtKind::Poster).to_string());
            for kind in [ArtKind::Thumb, ArtKind::Backdrop] {
                asked.backdrop.insert(catalogue.art_width(kind).to_string());
            }
            // no TMDB entry beside this one: a still is the catalogue's alone
            asked
                .still
                .insert(catalogue.art_width(ArtKind::Still).to_string());
        }
        Some(asked)
    }

    /// The sweep, on the artwork thread and never on the caller's: it walks
    /// every file in the directory.
    fn sweep_artwork(&self) {
        // the cache directory rather than the artwork one inside it: they are
        // on the same volume, and `new` creates this one while the other does
        // not exist until the first image lands in it
        self.artwork
            .cache
            .sweep(self.asked_sizes().as_ref(), free_bytes(&self.cache_dir));
    }

    fn ask_sweep(&self) {
        let mut work = self.artwork.work.lock();
        if work.sweep {
            return;
        }
        work.sweep = true;
        self.start_artwork(&mut work);
        drop(work);
        self.artwork.woken.notify_one();
    }

    fn queue_artwork(&self, key: (i64, ArtKind)) {
        let mut work = self.artwork.work.lock();
        if !work.holding.insert(key) {
            return;
        }
        work.wanted.push(key);
        self.start_artwork(&mut work);
        drop(work);
        self.artwork.woken.notify_one();
    }

    /// Puts another fetcher on the queue if there is work for one. A thread
    /// per waiting title up to the ceiling: the wait is a server's, not this
    /// device's, and one at a time makes a rail of twenty cards twenty round
    /// trips end to end.
    fn start_artwork(&self, work: &mut ArtworkWork) {
        let wanted = work.wanted.len() + usize::from(work.sweep);
        if work.working >= ARTWORK_FETCHERS || work.working >= wanted {
            return;
        }
        // None only while the core itself is being dropped, which cannot be
        // happening: this is running on a live instance
        if let Some(this) = self.self_ref.upgrade() {
            work.working += 1;
            std::thread::Builder::new()
                .name("lexis.artwork".into())
                .spawn(move || {
                    crate::lower_thread_qos();
                    fetch_artwork(Arc::downgrade(&this))
                })
                .expect("spawn a thread");
        }
    }
}

/// One artwork fetcher, of at most `ARTWORK_FETCHERS`: an image at a time for
/// as long as titles are waiting. It holds no reference to the core between
/// images, so a core dropped while this runs takes the thread with it at the
/// next one.
fn fetch_artwork(core: Weak<LexisCore>) {
    loop {
        let Some(this) = core.upgrade() else {
            return;
        };
        let job = {
            let mut work = this.artwork.work.lock();
            loop {
                if !work.paused {
                    // a sweep asks nothing of the network, but it reads a
                    // directory and unlinks files, and the pause hands the
                    // player the disk as much as the network. Nothing grows
                    // the cache while it holds either: the fetches that write
                    // to it are held by the same flag.
                    if work.sweep && work.fetching == 0 {
                        work.sweep = false;
                        work.sweeping = true;
                        break Job::Sweep;
                    }
                    if !work.sweeping {
                        if let Some(key) = work.wanted.pop() {
                            work.fetching += 1;
                            break Job::Fetch(key);
                        }
                    }
                }
                let waited = this.artwork.woken.wait_for(&mut work, ARTWORK_IDLE);
                if waited.timed_out() && !work.sweep && (work.paused || work.wanted.is_empty()) {
                    // nothing to do for a whole idle stretch: the next ask
                    // starts a thread again
                    work.working -= 1;
                    return;
                }
            }
        };
        let key = match job {
            Job::Sweep => {
                this.sweep_artwork();
                this.artwork.work.lock().sweeping = false;
                this.artwork.woken.notify_all();
                continue;
            }
            Job::Fetch(key) => key,
        };
        let fetched = this.artwork(key.0, key.1);
        let mut answered = this.artwork.answered.lock();
        match &fetched {
            // the file is on disk now, and the next ask reads it from there
            Ok(Some(_)) => {
                answered.remove(&key);
            }
            Ok(None) => {
                answered.insert(key, None);
            }
            Err(e) => {
                answered.insert(key, Some(e.to_string()));
            }
        }
        drop(answered);
        if let Ok(Some(path)) = &fetched {
            let path = std::path::Path::new(path);
            let bytes = std::fs::metadata(path).map_or(0, |m| m.len());
            let name = path.file_name().unwrap_or_default().to_string_lossy();
            this.artwork.cache.wrote(&name, bytes);
            if this.artwork.cache.due() {
                this.ask_sweep();
            }
        }
        {
            let mut work = this.artwork.work.lock();
            work.holding.remove(&key);
            work.fetching -= 1;
        }
        // last, so a caller woken by this finds the answer already in place
        this.artwork.settled.fetch_add(1, Ordering::Release);
    }
}

/// What the artwork thread woke up to do.
enum Job {
    Fetch((i64, ArtKind)),
    Sweep,
}

/// The cache key, and the only thing that keeps the two images of one title
/// from overwriting each other.
fn artwork_name(title_id: i64, kind: ArtKind) -> String {
    match kind {
        // the thumb and the hero share this: the size segment `artwork_file`
        // appends is what keeps them two files
        ArtKind::Thumb | ArtKind::Backdrop => format!("{title_id}-backdrop"),
        ArtKind::Poster => format!("{title_id}-poster"),
        ArtKind::Logo => format!("{title_id}-logo"),
        // the number here is a person's, not a title's: see `ArtKind::Face`
        ArtKind::Face => format!("{title_id}-face"),
        // and here it is a file's: see `ArtKind::Still`
        ArtKind::Still => format!("{title_id}-still"),
    }
}

/// The size segment a TMDB cache name carries: the last path segment of the
/// CDN base, which is the size the CDN was asked for.
/// The size segment of a cached image's name: the size asked for, and a hash
/// of the path it came from, so an image its source replaced misses the cache.
pub(super) fn sized(size: &str, path: &str) -> String {
    // FNV-1a: the name has to come out the same in every build and process
    let hash = path.bytes().fold(0xcbf2_9ce4_8422_2325u64, |h, b| {
        (h ^ u64::from(b)).wrapping_mul(0x0100_0000_01b3)
    });
    format!("{size}_{:08x}", hash as u32)
}

fn tmdb_size(base: &str) -> &str {
    base.rsplit('/').next().unwrap_or(base)
}

impl LexisCore {
    /// The one agent every TMDB image goes through, faces and logos included.
    /// An agent is a connection pool, so an agent per image is a TCP
    /// connection and a TLS handshake per image - and a cast rail is a screenful
    /// of faces asked for at once.
    fn art_agent(&self) -> ureq::Agent {
        self.tmdb_art_agent
            .get_or_init(|| {
                ureq::AgentBuilder::new()
                    .timeout_connect(Duration::from_secs(10))
                    .timeout_read(Duration::from_secs(30))
                    // an artwork fetch takes a 3xx for an answer rather than
                    // following it, whatever the host it names
                    .redirects(0)
                    .max_idle_connections_per_host(ARTWORK_FETCHERS)
                    .build()
            })
            .clone()
    }

    /// The logo half of `artwork`, on the same fetcher thread: it asks TMDB
    /// which logo to draw the first time and downloads it, and on every later
    /// miss downloads the one already chosen. Both are network, which is why
    /// this is here rather than on the thread answering the remote.
    fn logo_artwork(&self, title_id: i64) -> Result<Option<String>, CoreError> {
        let state = self.read_db.lock().logo_state(title_id)?;
        if let Some(state) = state.filter(|s| {
            s.path
                .as_deref()
                .is_some_and(|p| p.starts_with(SOURCE_LOGO_PREFIX))
        }) {
            return self.source_logo_artwork(title_id, state);
        }
        let Some(key) = self.tmdb_key() else {
            return Ok(None);
        };
        let client = self.tmdb_client(&key);
        let found = logo(&self.db, &client, title_id, unix_now()).map_err(|e| match e {
            LogoError::Index(e) => CoreError::Storage { msg: e.to_string() },
            LogoError::Tmdb(TmdbError::Unauthorized) => CoreError::Unauthorized {
                source_id: "tmdb".to_string(),
            },
            LogoError::Tmdb(e) => CoreError::SourceUnavailable {
                source_id: "tmdb".to_string(),
                msg: e.to_string(),
            },
        })?;
        let Some(found) = found else {
            return Ok(None);
        };
        let path = artwork_file(
            &self.art_agent(),
            &self.cache_dir,
            CacheName {
                name: &artwork_name(title_id, ArtKind::Logo),
                size: &sized(tmdb_size(TMDB_LOGO_BASE), &found.path),
                ext: "png",
            },
            &format!("{TMDB_LOGO_BASE}{}", found.path),
            None,
            None,
        )
        .map_err(|e| CoreError::SourceUnavailable {
            source_id: "tmdb".to_string(),
            msg: e.to_string(),
        })?;
        Ok(Some(path.to_string_lossy().into_owned()))
    }

    /// A logo the source holds, downloaded from it and measured, since no
    /// source says the shape of its lettering. One it cannot measure is
    /// given up, which leaves TMDB to answer.
    fn source_logo_artwork(
        &self,
        title_id: i64,
        state: crate::index::db::LogoState,
    ) -> Result<Option<String>, CoreError> {
        let logo_path = state.path.unwrap_or_default();
        let source_ids = self.read_db.lock().title_source_ids(title_id)?;
        let found = source_ids.iter().find_map(|sid| {
            let source = self.built_source(sid)?;
            let catalogue = source.catalogue()?;
            Some((
                sid.clone(),
                catalogue.art_url(&logo_path, ArtKind::Logo),
                catalogue.token().to_string(),
                catalogue.agent(),
            ))
        });
        // the source was removed while its rows waited to be pruned
        let Some((source_id, art, token, agent)) = found else {
            return Ok(None);
        };
        let path = artwork_file(
            &agent,
            &self.cache_dir,
            CacheName {
                name: &artwork_name(title_id, ArtKind::Logo),
                size: &sized(tmdb_size(TMDB_LOGO_BASE), &logo_path),
                ext: "png",
            },
            &art.url,
            Some(&art.fallback),
            Some(&token),
        )
        .map_err(|e| CoreError::SourceUnavailable {
            source_id,
            msg: e.to_string(),
        })?;
        if state.aspect > 0.0 {
            return Ok(Some(path.to_string_lossy().into_owned()));
        }
        let mut head = [0u8; 24];
        let read = std::fs::File::open(&path)
            .and_then(|mut f| std::io::Read::read_exact(&mut f, &mut head))
            .ok();
        match read.and_then(|_| png_aspect(&head)) {
            Some(aspect) => {
                self.db
                    .lock()
                    .set_logo(title_id, Some(&logo_path), aspect, state.checked_at)?;
                Ok(Some(path.to_string_lossy().into_owned()))
            }
            None => {
                let _ = std::fs::remove_file(&path);
                self.db.lock().set_logo(title_id, None, 0.0, 0)?;
                Ok(None)
            }
        }
    }

    /// The face half of `artwork`. Simpler than the logo's: the path was
    /// already learned from the credits of a title that was enriched, so this
    /// asks TMDB nothing and is a download and nothing else. No key is needed
    /// either - the image CDN wants none.
    fn face_artwork(&self, person_id: i64) -> Result<Option<String>, CoreError> {
        let profile = self
            .read_db
            .lock()
            .person_profile(person_id)?
            .unwrap_or_default();
        if profile.is_empty() {
            return Ok(None);
        }
        let path = artwork_file(
            &self.art_agent(),
            &self.cache_dir,
            CacheName {
                name: &artwork_name(person_id, ArtKind::Face),
                size: &sized(tmdb_size(TMDB_PROFILE_BASE), &profile),
                ext: "jpg",
            },
            // a Plex server's photograph is stored as its whole address
            &if profile.starts_with("https://") {
                profile
            } else {
                format!("{TMDB_PROFILE_BASE}{profile}")
            },
            None,
            None,
        )
        .map_err(|e| CoreError::SourceUnavailable {
            source_id: "tmdb".to_string(),
            msg: e.to_string(),
        })?;
        Ok(Some(path.to_string_lossy().into_owned()))
    }

    /// The still half of `artwork`, on the same fetcher thread: the path comes
    /// off the file's own `episode_meta` row and the URL from the catalogue
    /// that enumerated the file. No TMDB call and no query of any kind - the
    /// server already holds the frame, and the path to it was stored by the
    /// sync that found the file.
    fn still_artwork(&self, file_id: i64) -> Result<Option<String>, CoreError> {
        let Some((source_id, still_path)) = self.read_db.lock().still_source(file_id)? else {
            return Ok(None);
        };
        let found = self.built_source(&source_id).and_then(|source| {
            let catalogue = source.catalogue()?;
            Some((
                catalogue.art_url(&still_path, ArtKind::Still),
                catalogue.token().to_string(),
                catalogue.agent(),
            ))
        });
        // the source was removed while its rows waited to be pruned
        let Some((art, token, agent)) = found else {
            return Ok(None);
        };
        let path = artwork_file(
            &agent,
            &self.cache_dir,
            CacheName {
                name: &artwork_name(file_id, ArtKind::Still),
                size: &sized(&art.width.to_string(), &still_path),
                ext: "jpg",
            },
            &art.url,
            Some(&art.fallback),
            Some(&token),
        )
        .map_err(|e| CoreError::SourceUnavailable {
            source_id,
            msg: e.to_string(),
        })?;
        Ok(Some(path.to_string_lossy().into_owned()))
    }
}

/// Where this kind of image comes from on TMDB's CDN. The size is the last
/// segment of the path, so it is also the size segment of the cache name.
fn tmdb_base(kind: ArtKind) -> &'static str {
    match kind {
        ArtKind::Poster => TMDB_POSTER_BASE,
        ArtKind::Thumb => TMDB_THUMB_BASE,
        ArtKind::Backdrop => TMDB_BACKDROP_BASE,
        ArtKind::Logo => TMDB_LOGO_BASE,
        ArtKind::Face => TMDB_PROFILE_BASE,
        // a still is the catalogue's, so `artwork` answers one before any CDN
        // base is looked at: reaching here is a bug
        ArtKind::Still => {
            debug_assert!(false, "TMDB was asked for a still");
            TMDB_THUMB_BASE
        }
    }
}

impl LexisCore {
    /// One of a title's two images. Which stored path is fetched and which CDN
    /// size it comes from is all that differs between them: the credential, the
    /// cache, the timeouts and the failures are the same, and a Plex server
    /// serves both from the same host with the same token.
    fn artwork(&self, title_id: i64, kind: ArtKind) -> Result<Option<String>, CoreError> {
        // answered before the row's own source is looked at: a logo is the
        // source's or TMDB's whatever described the title
        if kind == ArtKind::Logo {
            return self.logo_artwork(title_id);
        }
        // and a face the same way, except that the number is a person's
        if kind == ArtKind::Face {
            return self.face_artwork(title_id);
        }
        // a still is a catalogue's, but keyed on a file rather than a title,
        // so it reads its path from its own row before the branch below
        if kind == ArtKind::Still {
            return self.still_artwork(title_id);
        }
        let (row, source_ids) = {
            let db = self.read_db.lock();
            let Some(row) = db.metadata(title_id)? else {
                return Ok(None);
            };
            (row, db.title_source_ids(title_id)?)
        };
        let stored = if kind.wide() {
            row.backdrop_path
        } else {
            row.poster_path
        };
        let Some(art_path) = stored else {
            return Ok(None);
        };
        let (url, size, fallback, token, agent, source_id) = match row.source {
            MetadataSource::Tmdb => {
                let base = tmdb_base(kind);
                (
                    format!("{base}{art_path}"),
                    // the CDN names the size in the path, so the last segment
                    // of the base is it: "w500", "original"
                    base.rsplit('/').next().unwrap_or(base).to_string(),
                    None,
                    None,
                    self.art_agent(),
                    "tmdb".to_string(),
                )
            }
            MetadataSource::Plex => {
                let found = source_ids.iter().find_map(|sid| {
                    let source = self.built_source(sid)?;
                    let catalogue = source.catalogue()?;
                    let art = catalogue.art_url(&art_path, kind);
                    Some((
                        sid.clone(),
                        art,
                        catalogue.token().to_string(),
                        catalogue.agent(),
                    ))
                });
                // the source was removed while its rows waited to be pruned
                let Some((id, art, token, agent)) = found else {
                    return Ok(None);
                };
                (
                    art.url,
                    art.width.to_string(),
                    Some(art.fallback),
                    Some(token),
                    agent,
                    id,
                )
            }
        };
        // the cache key, and the only thing that keeps the two images of one
        // title from overwriting each other. The size rides beside it, so a
        // build that asks for other dimensions misses what this one cached.
        let name = artwork_name(title_id, kind);
        let path = artwork_file(
            &agent,
            &self.cache_dir,
            CacheName {
                name: &name,
                size: &sized(&size, &art_path),
                ext: "jpg",
            },
            &url,
            fallback.as_deref(),
            token.as_deref(),
        )
        .map_err(|e| CoreError::SourceUnavailable {
            source_id,
            msg: e.to_string(),
        })?;
        Ok(Some(path.to_string_lossy().into_owned()))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::api::library::ApiMediaKind;
    use crate::api::testing::*;
    use crate::source::local::LocalModule;
    use crate::source::module::SourceModule;
    use crate::source::plex::PlexModule;
    use std::sync::Arc;

    /// The trio crosses the FFI: three cards in role order, seeds and
    /// runtimes carried, bedtime converted to minutes after midnight, and a
    /// deferral answered with the refreshed trio.
    #[test]
    fn a_trailer_is_not_asked_for_while_a_film_is_playing() {
        use crate::index::db::{Db, FileMedia, FileRecord, MetadataRecord, MetadataSource};
        use crate::index::MediaKind;

        // every background reach in this core stands aside for the player:
        // the artwork queue, the passes, a scan. This is one more of them.
        let cache = tempfile::tempdir().unwrap();
        let store = Arc::new(MemStore::default());
        let core = LexisCore::new(cache.path().to_string_lossy().into_owned(), store).unwrap();
        core.set_tmdb_key("eyJhbGciOiJIUzI1NiJ9.token".into())
            .unwrap();
        let db = Db::open(&cache.path().join("index.sqlite")).unwrap();
        let title_id = db
            .upsert_title(MediaKind::Movie, "Dune", Some(2021))
            .unwrap();
        db.upsert_file(&FileRecord {
            source_id: "s1".into(),
            dir: "Movies".into(),
            path: "Movies/Dune.mkv".into(),
            size: 1,
            mtime: 0,
            seen_gen: 1,
            title_id,
            season: None,
            episode: None,
            rating_key: None,
            media: FileMedia::default(),
        })
        .unwrap();
        db.upsert_metadata(&MetadataRecord {
            title_id,
            tmdb_id: Some(438631),
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
        drop(db);

        // a title TMDB can be asked about, a key to ask with: without the
        // brake this answers Fetching and puts a request on the network
        core.pause_artwork(true);
        assert!(matches!(
            core.trailer_now(title_id).unwrap(),
            TrailerState::Missing
        ));

        // and nothing was written off, so the film ending is all it takes
        core.pause_artwork(false);
        assert!(matches!(
            core.trailer_now(title_id).unwrap(),
            TrailerState::Fetching
        ));
    }

    #[test]
    fn a_backdrop_is_fetched_beside_the_poster_and_never_instead_of_it() {
        use crate::plex::fake::library;

        let server = library();
        let cache = tempfile::tempdir().unwrap();
        let store = Arc::new(MemStore::default());
        let core = LexisCore::new(cache.path().to_string_lossy().into_owned(), store).unwrap();
        // the fake server serves artwork to this token and 401s any other
        core.add_or_replace(
            PlexModule.id(),
            "plex1".into(),
            std::collections::BTreeMap::from([
                ("base_url".to_string(), server.base_url.clone()),
                ("token".to_string(), "tok".into()),
            ]),
        )
        .unwrap();
        core.scan_all(false).unwrap();
        let title_id = core.list_titles(ApiMediaKind::Movie, 0, 10).unwrap()[0].id;

        let backdrop = core.backdrop_file(title_id).unwrap().unwrap();
        assert!(
            backdrop.contains(&format!("artwork/{title_id}-backdrop-3840_")),
            "{backdrop}"
        );
        assert!(std::fs::metadata(&backdrop).unwrap().len() > 0);
        let art = server
            .requests()
            .iter()
            .find(|r| r.url.starts_with("/photo/:/transcode"))
            .expect("the backdrop was fetched sized from the Plex server")
            .clone();
        // the credential rides in the header, never in the URL
        assert_eq!(art.header("X-Plex-Token"), Some("tok"));
        assert!(art.url.contains("width=3840"), "{}", art.url);
        assert!(art.url.contains("height=2160"), "{}", art.url);
        assert!(art.url.contains("%2Fart%2F"), "{}", art.url);
        assert!(!art.url.contains("tok"), "{}", art.url);

        // the poster is still its own file
        let poster = core.poster_file(title_id).unwrap().unwrap();
        assert!(
            poster.contains(&format!("artwork/{title_id}-poster-408_")),
            "{poster}"
        );
        assert_eq!(core.backdrop_file(title_id).unwrap(), Some(backdrop));

        // the show's own type=2 item carries a backdrop too, from the same
        // pass that gave it a poster - its episodes never stand in for it
        let show = core.list_titles(ApiMediaKind::Show, 0, 10).unwrap()[0].id;
        let show_backdrop = core.backdrop_file(show).unwrap().unwrap();
        assert!(
            show_backdrop.contains(&format!("artwork/{show}-backdrop-3840_")),
            "{show_backdrop}"
        );
    }

    #[test]
    fn a_rail_thumbnail_is_a_second_file_at_the_size_a_card_draws_it() {
        use crate::plex::fake::library;

        let server = library();
        let cache = tempfile::tempdir().unwrap();
        let store = Arc::new(MemStore::default());
        let core = LexisCore::new(cache.path().to_string_lossy().into_owned(), store).unwrap();
        core.add_or_replace(
            PlexModule.id(),
            "plex1".into(),
            std::collections::BTreeMap::from([
                ("base_url".to_string(), server.base_url.clone()),
                ("token".to_string(), "tok".into()),
            ]),
        )
        .unwrap();
        core.scan_all(false).unwrap();
        let title_id = core.list_titles(ApiMediaKind::Movie, 0, 10).unwrap()[0].id;

        let thumb = ready(&core, title_id, ArtKind::Thumb);
        let backdrop = ready(&core, title_id, ArtKind::Backdrop);
        assert!(
            thumb.contains(&format!("artwork/{title_id}-backdrop-800_")),
            "{thumb}"
        );
        assert!(
            backdrop.contains(&format!("artwork/{title_id}-backdrop-3840_")),
            "{backdrop}"
        );

        // each was asked of the server at its own size: the card's file is not
        // the hero's, which is the whole point of there being two
        let sized: Vec<String> = server
            .requests()
            .iter()
            .filter(|r| r.url.starts_with("/photo/:/transcode") && r.url.contains("%2Fart%2F"))
            .map(|r| r.url.clone())
            .collect();
        assert!(
            sized
                .iter()
                .any(|u| u.contains("width=800") && u.contains("height=450")),
            "{sized:?}"
        );
        assert!(
            sized
                .iter()
                .any(|u| u.contains("width=3840") && u.contains("height=2160")),
            "{sized:?}"
        );

        // and a sweep keeps both: the card's size is one this build asks for,
        // not an older build's leftover
        core.sweep_artwork();
        assert!(
            std::path::Path::new(&thumb).exists(),
            "the sweep took the card's own file"
        );
        assert!(std::path::Path::new(&backdrop).exists());
    }

    /// Plex's own lettering is drawn before TMDB is asked: fetched from the
    /// server with its token, unconverted, and measured from the file. A
    /// title Plex has none for is left to TMDB, which here has no key.
    #[test]
    fn a_plex_clear_logo_is_the_logo_and_a_title_without_one_falls_to_tmdb() {
        use crate::plex::fake::library;

        let server = library();
        let cache = tempfile::tempdir().unwrap();
        let store = Arc::new(MemStore::default());
        let core = LexisCore::new(cache.path().to_string_lossy().into_owned(), store).unwrap();
        core.add_or_replace(
            PlexModule.id(),
            "plex1".into(),
            std::collections::BTreeMap::from([
                ("base_url".to_string(), server.base_url.clone()),
                ("token".to_string(), "tok".into()),
            ]),
        )
        .unwrap();
        core.scan_all(false).unwrap();
        let film = core.list_titles(ApiMediaKind::Movie, 0, 10).unwrap()[0].id;
        let show = core.list_titles(ApiMediaKind::Show, 0, 10).unwrap()[0].id;

        let answer = |id: i64| {
            for _ in 0..600 {
                match core.logo_now(id).unwrap() {
                    LogoState::Fetching => std::thread::sleep(Duration::from_millis(20)),
                    other => return other,
                }
            }
            panic!("the logo never settled")
        };
        match answer(film) {
            LogoState::Ready { path, aspect } => {
                assert!(
                    path.contains(&format!("artwork/{film}-logo-w500_")),
                    "{path}"
                );
                assert_eq!(aspect, 4.0);
            }
            other => panic!("{other:?}"),
        }
        let asked = server
            .requests()
            .iter()
            .find(|r| r.url.contains("/clearLogo/"))
            .expect("the logo was fetched from the Plex server")
            .clone();
        assert_eq!(asked.url, "/library/metadata/101/clearLogo/1");
        assert_eq!(asked.header("X-Plex-Token"), Some("tok"));
        assert!(matches!(answer(show), LogoState::Missing));
    }

    /// Waits for an image the queue fetches on a thread of its own, and
    /// answers its path. `poster_now` and friends never block, so a test that
    /// wants the file has to ask again until it is there.
    fn ready(core: &Arc<LexisCore>, title_id: i64, kind: ArtKind) -> String {
        for _ in 0..600 {
            match core.artwork_now(title_id, kind) {
                ArtworkState::Ready { path } => return path,
                ArtworkState::Fetching => std::thread::sleep(Duration::from_millis(20)),
                other => panic!("{other:?}"),
            }
        }
        panic!("the image never arrived")
    }

    /// A Plex whose artwork takes `delay_ms` to answer, holding the one movie
    /// of MOVIES_JSON. `library()` answers instantly, which is the one thing
    /// this cannot use: what is under test is who waits for the download.
    fn slow_artwork(delay_ms: u64) -> crate::plex::fake::FakeServer {
        use crate::plex::fake::{FakeServer, Reply, MOVIES_JSON, SECTIONS_JSON};
        FakeServer::start(move |req| {
            if req.url == "/library/sections" {
                return Reply::json(SECTIONS_JSON);
            }
            if req.url.starts_with("/library/sections/1/all") {
                return Reply::json(MOVIES_JSON);
            }
            if req.url.starts_with("/photo/:/transcode")
                || req.url.starts_with("/library/metadata/")
            {
                std::thread::sleep(std::time::Duration::from_millis(delay_ms));
                return Reply {
                    status: 200,
                    headers: vec![("Content-Type".to_string(), "image/jpeg".to_string())],
                    body: vec![0xff, 0xd8, 0xff, 0xe0, 7, 7, 7, 7],
                };
            }
            Reply::json(r#"{"MediaContainer":{"size":0,"totalSize":0}}"#)
        })
    }

    #[test]
    fn a_tile_is_answered_at_once_and_the_download_happens_on_another_thread() {
        // 300 ms is a poster over somebody's network; the ask has to cost the
        // caller a query and a stat whatever the server is doing, or a thread
        // that also answers the remote answers it that late
        let server = slow_artwork(300);
        let cache = tempfile::tempdir().unwrap();
        let core = LexisCore::new(
            cache.path().to_string_lossy().into_owned(),
            Arc::new(MemStore::default()),
        )
        .unwrap();
        core.add_or_replace(
            PlexModule.id(),
            "plex1".into(),
            std::collections::BTreeMap::from([
                ("base_url".to_string(), server.base_url.clone()),
                ("token".to_string(), "tok".into()),
            ]),
        )
        .unwrap();
        core.scan_all(false).unwrap();
        let id = core.list_titles(ApiMediaKind::Movie, 0, 10).unwrap()[0].id;

        let start = std::time::Instant::now();
        let first = core.poster_now(id);
        let asked = start.elapsed();
        assert!(matches!(first, ArtworkState::Fetching), "{first:?}");
        assert!(
            asked < std::time::Duration::from_millis(100),
            "poster_now waited for the download: {asked:?}"
        );

        // and the file lands anyway, without the caller ever having blocked
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(10);
        let path = loop {
            match core.poster_now(id) {
                ArtworkState::Ready { path } => break path,
                other => {
                    assert!(
                        std::time::Instant::now() < deadline,
                        "the poster never landed: {other:?}"
                    );
                    std::thread::sleep(std::time::Duration::from_millis(20));
                }
            }
        };
        assert!(std::path::Path::new(&path).exists(), "{path}");
        assert_eq!(core.poster_file(id).unwrap(), Some(path));
        // one download, however many times the tile asked
        assert_eq!(
            server
                .requests()
                .iter()
                .filter(|r| r.url.starts_with("/photo/:/transcode"))
                .count(),
            1
        );
    }

    #[test]
    fn browsing_reclaims_what_older_builds_left_in_the_cache() {
        let server = slow_artwork(0);
        let cache = tempfile::tempdir().unwrap();
        let core = LexisCore::new(
            cache.path().to_string_lossy().into_owned(),
            Arc::new(MemStore::default()),
        )
        .unwrap();
        core.add_or_replace(
            PlexModule.id(),
            "plex1".into(),
            std::collections::BTreeMap::from([
                ("base_url".to_string(), server.base_url.clone()),
                ("token".to_string(), "tok".into()),
            ]),
        )
        .unwrap();
        core.scan_all(false).unwrap();
        let id = core.list_titles(ApiMediaKind::Movie, 0, 10).unwrap()[0].id;

        // what a device that has run every build of this app is holding: names
        // from before the size was part of one, a backdrop at dimensions this
        // build stopped asking for, and a temporary a dead process left
        let art = cache.path().join("artwork");
        std::fs::create_dir_all(&art).unwrap();
        let stale = [
            "11.jpg",
            "12-backdrop.jpg",
            "13-backdrop-2560.jpg",
            "14-poster-408.jpg.part",
            // a logo at a size this build no longer asks for, and one an
            // older build wrote as a jpeg: neither is served now
            "15-logo-w300.png",
            "16-logo-w500.jpg",
        ];
        for name in stale {
            std::fs::write(art.join(name), vec![7u8; 4096]).unwrap();
        }
        // and one at the size this build does ask for, which must survive: the
        // sweep deletes every name it cannot place, so a logo the size list
        // forgot would be thrown away as fast as it is fetched
        let logo = format!("{id}-logo-w500.png");
        std::fs::write(art.join(&logo), vec![7u8; 4096]).unwrap();

        // browsing is the whole trigger: the tile asks, the thread that
        // fetches for it is the one that sweeps, and the caller waits for
        // neither
        core.poster_now(id);
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(10);
        loop {
            let left: Vec<String> = std::fs::read_dir(&art)
                .unwrap()
                .map(|e| e.unwrap().file_name().to_string_lossy().into_owned())
                .collect();
            if stale.iter().all(|name| !left.contains(&name.to_string())) {
                // and the two this build does ask for are still there
                assert!(
                    left.iter()
                        .any(|n| n.starts_with(&format!("{id}-poster-408_"))),
                    "{left:?}"
                );
                assert!(left.contains(&logo), "{left:?}");
                break;
            }
            assert!(
                std::time::Instant::now() < deadline,
                "the sweep never ran: {left:?}"
            );
            std::thread::sleep(std::time::Duration::from_millis(20));
        }
    }

    #[test]
    fn a_film_holds_the_cache_sweep_as_well_as_the_downloads() {
        // the sweep asks nothing of the network, which is how it used to run
        // straight through a pause. It still reads a directory and unlinks
        // files, and a pause hands the player the disk as much as the line -
        // at no cost to the sweep, since the fetches that would grow the cache
        // are held by the same flag.
        let server = slow_artwork(400);
        let cache = tempfile::tempdir().unwrap();
        let core = LexisCore::new(
            cache.path().to_string_lossy().into_owned(),
            Arc::new(MemStore::default()),
        )
        .unwrap();
        core.add_or_replace(
            PlexModule.id(),
            "plex1".into(),
            std::collections::BTreeMap::from([
                ("base_url".to_string(), server.base_url.clone()),
                ("token".to_string(), "tok".into()),
            ]),
        )
        .unwrap();
        core.scan_all(false).unwrap();
        let id = core.list_titles(ApiMediaKind::Movie, 0, 10).unwrap()[0].id;

        let art = cache.path().join("artwork");
        std::fs::create_dir_all(&art).unwrap();
        let stale = art.join("11.jpg");
        std::fs::write(&stale, vec![7u8; 4096]).unwrap();

        // the film starts while the poster is still coming down, so the sweep
        // that fetch asks for when it lands is asked for against a held queue
        core.poster_now(id);
        std::thread::sleep(std::time::Duration::from_millis(100));
        core.pause_artwork(true);

        // long enough that the fetch landed and asked for its sweep
        std::thread::sleep(std::time::Duration::from_millis(800));
        assert!(
            stale.exists(),
            "the cache was swept while a film was playing"
        );

        core.pause_artwork(false);
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(10);
        while stale.exists() {
            assert!(
                std::time::Instant::now() < deadline,
                "the sweep never ran once the film was over"
            );
            std::thread::sleep(std::time::Duration::from_millis(20));
        }
    }

    #[test]
    fn a_title_with_no_artwork_is_answered_missing_and_nothing_is_queued() {
        // a local file nothing has described: there is no image to wait for,
        // and a tile told "fetching" would poll for one forever
        let media = shelf_dir();
        let cache = tempfile::tempdir().unwrap();
        let core = LexisCore::new(
            cache.path().to_string_lossy().into_owned(),
            Arc::new(MemStore::default()),
        )
        .unwrap();
        core.add_or_replace(
            LocalModule.id(),
            "local1".into(),
            std::collections::BTreeMap::from([(
                "root".to_string(),
                media.path().to_string_lossy().into_owned(),
            )]),
        )
        .unwrap();
        core.scan_all(false).unwrap();
        let id = core.list_titles(ApiMediaKind::Movie, 0, 10).unwrap()[0].id;

        assert!(matches!(core.poster_now(id), ArtworkState::Missing));
        assert!(matches!(core.backdrop_now(id), ArtworkState::Missing));
        assert!(core.artwork.work.lock().wanted.is_empty());
    }

    #[test]
    fn a_server_that_refuses_the_sized_request_still_yields_a_poster() {
        use crate::plex::fake::library_transcode_refused;

        let server = library_transcode_refused();
        let cache = tempfile::tempdir().unwrap();
        let store = Arc::new(MemStore::default());
        let core = LexisCore::new(cache.path().to_string_lossy().into_owned(), store).unwrap();
        core.add_or_replace(
            PlexModule.id(),
            "plex1".into(),
            std::collections::BTreeMap::from([
                ("base_url".to_string(), server.base_url.clone()),
                ("token".to_string(), "tok".into()),
            ]),
        )
        .unwrap();
        core.scan_all(false).unwrap();
        let title_id = core.list_titles(ApiMediaKind::Movie, 0, 10).unwrap()[0].id;

        let poster = core.poster_file(title_id).unwrap().unwrap();
        assert!(std::fs::metadata(&poster).unwrap().len() > 0);
        let requests = server.requests();
        assert!(
            requests
                .iter()
                .any(|r| r.url.starts_with("/photo/:/transcode")),
            "the sized request was attempted first"
        );
        assert!(
            requests
                .iter()
                .any(|r| r.url.starts_with("/library/metadata/101/thumb")),
            "the plain path was fetched once the sized one was refused"
        );
    }
}
