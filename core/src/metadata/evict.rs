//! What the artwork directory keeps when it cannot keep everything.
//!
//! The kinds of image in it differ twentyfold in size and inversely in how
//! often they are wanted: a 48 KB poster is drawn in every rail, a 935 KB
//! backdrop once behind a detail screen. Ranking those by recency alone throws
//! twenty useful posters away to hold one backdrop seen once, so the rank here
//! is GDSF's - hits per byte - and the budget is bytes rather than files.
//!
//! A logo needs no thumb on that scale. It weighs about what a poster does
//! (61 KB against 48 KB, measured) and is asked for more often than any one of
//! them: there is a single hero, and it is drawn every time the home screen
//! is. So value-per-byte already puts it above the median poster and about
//! nineteen times above a backdrop, which is the order a viewer would choose.
//!
//! The one thing that could have argued for a thumb does not, and only because
//! of where the state sits: re-fetching a logo would cost a TMDB API call as
//! well as a download, except that the call's answer - which logo, and its
//! shape - is stored in the index rather than here. Evicting the file costs a
//! download and never a second query, so a logo is as cheap to lose as a
//! poster and is ranked as one.

use parking_lot::Mutex;
use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};

/// What share of the space it could have the cache may hold, as a divisor.
/// This is the one figure here that is a judgement rather than a measurement:
/// everything else is asked of the device or measured off the files.
///
/// The cache is disposable and the system reclaims `Library/Caches` under
/// pressure anyway, so the risk of taking too much is not a full disk, it is
/// being the reason the system purges - which costs the whole directory, not
/// the quarter that was excessive. Three quarters left for the film being
/// buffered, the index and everything else is what keeps this cache from
/// being that reason.
const SHARE_OF_FREE: u64 = 4;

/// How far under budget a sweep goes. Stopping exactly at the budget would put
/// the next image fetched back over it, and sweep once per fetch from then on.
const SWEEP_TO: f64 = 0.9;

/// What a sweep multiplies every hit count by. Ageing happens per sweep rather
/// than per hour: a sweep is what pressure looks like, and pressure is the only
/// time an old favourite has to justify itself against a new one.
const AGE: f32 = 0.5;

/// How many asks back the cache still calls "on screen". A tile asks once, when
/// it mounts, so this counts tiles rather than frames: a home screen is a few
/// dozen posters and one backdrop, a detail screen one backdrop and rails of
/// `ROW_LIMIT` under it. Wider than any screenful on purpose, because being
/// wrong this way costs a few posters held and being wrong the other way blanks
/// a tile the viewer is looking at.
const HELD_ASKS: u64 = 256;

/// The hit counts, beside the images they count. In the artwork directory on
/// purpose: a tvOS purge takes `Library/Caches` whole, so it takes this with
/// the files it describes rather than leaving a census of a directory that is
/// gone. The directory is always the authority - a name here with no file is
/// dropped at the next sweep, and a file with no name here is one nothing has
/// asked for yet.
const ACCESS_FILE: &str = "access.v1.json";

/// The size segment a file may carry and still be one this build would serve.
/// Sizes, not dimensions: the segment is what `artwork_file` writes into the
/// name, so "408" for a Plex poster and "original" for a TMDB backdrop.
#[derive(Default)]
pub struct Asked {
    pub poster: HashSet<String>,
    pub backdrop: HashSet<String>,
    pub logo: HashSet<String>,
    pub face: HashSet<String>,
    pub still: HashSet<String>,
}

impl Asked {
    fn holds(&self, kind: &str, size: &str) -> bool {
        match kind {
            "poster" => self.poster.contains(size),
            "backdrop" => self.backdrop.contains(size),
            "logo" => self.logo.contains(size),
            "face" => self.face.contains(size),
            "still" => self.still.contains(size),
            _ => false,
        }
    }
}

/// What one sweep did, for a test to read.
#[derive(Debug, Default, PartialEq)]
pub struct Swept {
    pub deleted: usize,
    pub freed: u64,
    /// What the directory holds now.
    pub bytes: u64,
    pub budget: u64,
}

/// One file as the policy sees it.
struct Entry {
    name: String,
    bytes: u64,
    /// When it was written. The tie-break between two files of equal value,
    /// and the only recency a filesystem gives for free: atime is not
    /// maintained on the volumes this runs on, and touching mtime on every
    /// read would be a write per tile drawn.
    mtime: i64,
    hits: f32,
    /// Asked for recently enough to be on screen right now.
    held: bool,
}

#[derive(Default)]
struct Seen {
    hits: f32,
    /// Which ask this file was last answered to. 0 for one that has not been
    /// asked for in this process, including everything read back from the
    /// record: the count is the process's own and means nothing across a
    /// launch, while the hits beside it mean the same thing in every one.
    ask: u64,
}

#[derive(Default)]
struct State {
    seen: HashMap<String, Seen>,
    asks: u64,
    /// What the last sweep found, plus what has been written since. A purge
    /// makes it wrong in the safe direction - too large - so the next sweep
    /// runs and reads the truth off the directory.
    bytes: u64,
    /// What the directory has to grow back to before another sweep is worth
    /// running. The budget, or what the last sweep was left holding when it
    /// could not reach it: a directory that is all held is over budget and
    /// stays over, and must not put the sweep in a loop with itself.
    sweep_at: u64,
    swept: bool,
    /// The record on disk has been folded in. Once per process, at the first
    /// sweep, because reading it is file IO and the sweep is the part of this
    /// that is allowed to do file IO.
    loaded: bool,
}

/// The artwork directory's bookkeeping. Locks internally and never across IO:
/// `hit` is called from the thread answering the remote and must not wait
/// behind a sweep walking four thousand files.
pub struct ArtworkCache {
    dir: PathBuf,
    state: Mutex<State>,
}

impl ArtworkCache {
    pub fn new(dir: PathBuf) -> Self {
        Self {
            dir,
            state: Mutex::new(State::default()),
        }
    }

    /// One answered ask for `name`, which is the file's own name in the
    /// directory. Counted once per name per session rather than once per
    /// frame, because a tile asks once when it mounts: what this measures is
    /// how many sessions wanted this title, which is the recurrence the
    /// policy is after.
    pub fn hit(&self, name: &str) {
        let mut state = self.state.lock();
        state.asks += 1;
        let ask = state.asks;
        match state.seen.get_mut(name) {
            Some(seen) => {
                seen.hits += 1.0;
                seen.ask = ask;
            }
            None => {
                state.seen.insert(name.to_string(), Seen { hits: 1.0, ask });
            }
        }
    }

    /// A file just written into the directory. It counts as asked for without
    /// counting as a hit: nothing is downloaded that nothing wanted, and the
    /// sweep this very write sets off must not take the image back before the
    /// tile waiting on it has drawn it once.
    pub fn wrote(&self, name: &str, bytes: u64) {
        let mut state = self.state.lock();
        state.bytes += bytes;
        state.asks += 1;
        let ask = state.asks;
        state.seen.entry(name.to_string()).or_default().ask = ask;
    }

    /// Whether a sweep is worth running: over budget, or never swept at all.
    /// The first one is what reclaims the files older builds left behind, so
    /// it happens whether or not anything is over budget.
    pub fn due(&self) -> bool {
        let state = self.state.lock();
        !state.swept || state.bytes > state.sweep_at
    }

    /// Reclaims what nothing serves and, if the directory is still over
    /// budget, the least valuable of what is left.
    ///
    /// `asked` is every size this build would write; a file at any other size
    /// answers nothing and goes first. None means the build cannot say - a
    /// configured source it could not build - and then nothing is called
    /// stale, only over budget.
    ///
    /// `free` is what the volume says it has left, or None when it will not
    /// say, in which case there is no budget to be over and only the stale
    /// files go: a filesystem that cannot be read is not a reason to delete a
    /// viewer's artwork.
    pub fn sweep(&self, asked: Option<&Asked>, free: Option<u64>) -> Swept {
        // read before the lock is taken: this is the IO the lock exists to
        // keep off the thread answering the remote
        let stored = if self.state.lock().loaded {
            None
        } else {
            self.load()
        };
        let (mut seen, asks) = {
            let mut state = self.state.lock();
            state.loaded = true;
            (std::mem::take(&mut state.seen), state.asks)
        };
        if let Some(stored) = stored {
            for (name, hits) in stored {
                seen.entry(name).or_default().hits += hits;
            }
        }

        let mut swept = Swept::default();
        let mut entries: Vec<Entry> = Vec::new();
        if let Ok(dir) = std::fs::read_dir(&self.dir) {
            for file in dir.flatten() {
                let Ok(name) = file.file_name().into_string() else {
                    continue;
                };
                if name == ACCESS_FILE {
                    continue;
                }
                let Ok(meta) = file.metadata() else {
                    continue;
                };
                if !meta.is_file() {
                    continue;
                }
                let stale = match parse(&name) {
                    Some((kind, size)) => asked.is_some_and(|a| !a.holds(kind, size)),
                    // a half-written temporary a dead process left, or a name
                    // an older build wrote: nothing on this build serves it
                    None => true,
                };
                if stale {
                    if std::fs::remove_file(file.path()).is_ok() {
                        swept.freed += meta.len();
                        swept.deleted += 1;
                    }
                    continue;
                }
                let seen = seen.get(&name);
                entries.push(Entry {
                    bytes: meta.len(),
                    mtime: meta
                        .modified()
                        .ok()
                        .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
                        .map_or(0, |d| d.as_secs() as i64),
                    hits: seen.map_or(0.0, |s| s.hits),
                    held: seen.is_some_and(|s| s.ask > 0 && s.ask + HELD_ASKS > asks),
                    name,
                });
            }
        }

        let held: u64 = entries.iter().map(|e| e.bytes).sum();
        let budget = free.map_or(u64::MAX, |free| (free + held) / SHARE_OF_FREE);
        let mut gone = HashSet::new();
        for i in evictions(&entries, budget) {
            let entry = &entries[i];
            if std::fs::remove_file(self.dir.join(&entry.name)).is_ok() {
                swept.freed += entry.bytes;
                swept.deleted += 1;
                gone.insert(i);
            }
        }
        swept.bytes = entries
            .iter()
            .enumerate()
            .filter(|(i, _)| !gone.contains(i))
            .map(|(_, e)| e.bytes)
            .sum();
        swept.budget = budget;

        // the directory is the authority: a name the record holds with no file
        // behind it counts for nothing, and would otherwise accumulate for the
        // life of the install
        let survivors: HashSet<&str> = entries
            .iter()
            .enumerate()
            .filter(|(i, _)| !gone.contains(i))
            .map(|(_, e)| e.name.as_str())
            .collect();
        seen.retain(|name, _| survivors.contains(name.as_str()));
        for seen in seen.values_mut() {
            seen.hits *= AGE;
        }
        self.save(&seen);

        let mut state = self.state.lock();
        for (name, fresh) in state.seen.drain() {
            let seen = seen.entry(name).or_default();
            seen.hits += fresh.hits;
            seen.ask = seen.ask.max(fresh.ask);
        }
        state.seen = seen;
        // no fetch runs while a sweep does (see `api::library`), so nothing
        // was written into the directory while this ran
        state.bytes = swept.bytes;
        state.sweep_at = budget.max(swept.bytes);
        state.swept = true;
        swept
    }

    fn load(&self) -> Option<HashMap<String, f32>> {
        let bytes = std::fs::read(self.dir.join(ACCESS_FILE)).ok()?;
        serde_json::from_slice(&bytes).ok()
    }

    fn save(&self, seen: &HashMap<String, Seen>) {
        let hits: HashMap<&str, f32> = seen
            .iter()
            .filter(|(_, s)| s.hits > 0.0)
            .map(|(name, s)| (name.as_str(), s.hits))
            .collect();
        if let Ok(bytes) = serde_json::to_vec(&hits) {
            let _ = std::fs::write(self.dir.join(ACCESS_FILE), bytes);
        }
    }
}

/// `{id}-{kind}-{size}.{ext}`, the name `artwork_file` writes under, as
/// (kind, size). None for anything else in the directory.
///
/// The id is a title's for `poster`, `backdrop` and `logo`, a person's for
/// `face` and a file's for `still`. The three namespaces share their numbers
/// and never collide, because the kind sits between the number and the size
/// and is what is matched on.
///
/// The extension belongs to the kind and says nothing about the format: a
/// logo goes under `png` and the other two under `jpg` whatever bytes the
/// server sent, so a logo written as a jpeg by some older build answers
/// nothing this build would ask for and goes. A name this cannot parse is one
/// the sweep deletes, so a kind or an extension added to `artwork_file` and
/// not to this list is artwork thrown away as fast as it is fetched.
fn parse(name: &str) -> Option<(&str, &str)> {
    let (stem, ext) = name.rsplit_once('.')?;
    let (rest, size) = stem.rsplit_once('-')?;
    // "408_1a2b3c4d": the size, and the hash of the path the image came from
    let size = size.split_once('_').map_or(size, |(size, _)| size);
    let (id, kind) = rest.rsplit_once('-')?;
    id.parse::<i64>().ok()?;
    let drawable = match kind {
        "poster" | "backdrop" | "face" | "still" => ext == "jpg",
        "logo" => ext == "png",
        _ => false,
    };
    drawable.then_some((kind, size))
}

/// Which entries to delete, and the whole of the policy.
///
/// The rank is GDSF's: what the next hit on a file is worth per byte it costs
/// to keep. A backdrop has to be wanted twenty times as often as a poster to
/// hold its place, which is the trade the sizes describe and the one recency
/// alone gets backwards. Files of equal value go oldest first, which is the
/// FIFO order the modern queue-based policies rank by and costs nothing to
/// know: it is the file's own mtime.
fn evictions(entries: &[Entry], budget: u64) -> Vec<usize> {
    let mut held: u64 = entries.iter().map(|e| e.bytes).sum();
    if held <= budget {
        return Vec::new();
    }
    let target = (budget as f64 * SWEEP_TO) as u64;
    let mut order: Vec<usize> = (0..entries.len()).filter(|&i| !entries[i].held).collect();
    order.sort_by(|&a, &b| {
        value(&entries[a])
            .total_cmp(&value(&entries[b]))
            .then(entries[a].mtime.cmp(&entries[b].mtime))
    });
    let mut out = Vec::new();
    for i in order {
        if held <= target {
            break;
        }
        held -= entries[i].bytes;
        out.push(i);
    }
    out
}

fn value(entry: &Entry) -> f64 {
    (1.0 + entry.hits as f64) / entry.bytes.max(1) as f64
}

/// What the volume holding `dir` still has free for this process, or None when
/// it will not say. Asked rather than assumed: a 64 GB Apple TV with a library
/// on it and a 4 TB one answer differently, and so does the same Apple TV next
/// month, which is the point - no figure derived from this needs revisiting
/// when either changes.
pub fn free_bytes(dir: &Path) -> Option<u64> {
    use std::os::unix::ffi::OsStrExt;
    let path = std::ffi::CString::new(dir.as_os_str().as_bytes()).ok()?;
    let mut stat: libc::statvfs = unsafe { std::mem::zeroed() };
    // SAFETY: `path` is a NUL-terminated C string alive for the call, and
    // `stat` is a zeroed statvfs the call fills in.
    if unsafe { libc::statvfs(path.as_ptr(), &mut stat) } != 0 {
        return None;
    }
    // f_bavail, not f_bfree: the reserve a filesystem keeps for root is not
    // space this process can have
    (stat.f_bavail as u64).checked_mul(stat.f_frsize as u64)
}

#[cfg(test)]
mod tests {
    use super::*;

    const POSTER: u64 = 48 * 1024;
    const BACKDROP: u64 = 935 * 1024;

    fn entry(name: &str, bytes: u64, hits: f32, mtime: i64) -> Entry {
        Entry {
            name: name.to_string(),
            bytes,
            mtime,
            hits,
            held: false,
        }
    }

    fn write(dir: &Path, name: &str, bytes: u64) {
        std::fs::write(dir.join(name), vec![7u8; bytes as usize]).unwrap();
    }

    fn names(dir: &Path) -> Vec<String> {
        let mut names: Vec<String> = std::fs::read_dir(dir)
            .unwrap()
            .map(|e| e.unwrap().file_name().to_string_lossy().into_owned())
            .collect();
        names.sort();
        names
    }

    fn asked() -> Asked {
        Asked {
            poster: HashSet::from(["408".to_string()]),
            backdrop: HashSet::from(["3840".to_string()]),
            logo: HashSet::from(["w500".to_string()]),
            face: HashSet::from(["w185".to_string()]),
            still: HashSet::from(["640".to_string()]),
        }
    }

    /// The median logo across a sample of this library's own titles, which is
    /// a poster's weight and a fifteenth of a backdrop's.
    const LOGO: u64 = 61 * 1024;

    #[test]
    fn a_logo_is_kept_as_a_poster_is_and_survives_a_backdrop() {
        // one of each, the logo and the poster asked for once, the backdrop
        // twice: even ahead on hits the backdrop is the worst value per byte
        let entries = [
            entry("1-poster-408.jpg", POSTER, 1.0, 10),
            entry("1-logo-w500.png", LOGO, 1.0, 10),
            entry("1-backdrop-3840.jpg", BACKDROP, 2.0, 30),
        ];
        // room for the two small ones and nothing like room for the third
        let gone = evictions(&entries, 200 * 1024);
        assert_eq!(gone, vec![2]);
    }

    /// A w185 profile, which is a fraction of a poster: a rail asks for a
    /// dozen at once and they are the cheapest thing in the directory.
    const FACE: u64 = 12 * 1024;

    #[test]
    fn a_face_is_not_swept_as_a_name_the_policy_cannot_read() {
        let dir = tempfile::tempdir().unwrap();
        write(dir.path(), "7-face-w185.jpg", FACE);
        write(dir.path(), "1-poster-408.jpg", POSTER);
        // a face at a size this build no longer asks for, and one written
        // under the logo's extension: both answer nothing now
        write(dir.path(), "8-face-w45.jpg", FACE);
        write(dir.path(), "9-face-w185.png", FACE);

        let cache = ArtworkCache::new(dir.path().to_path_buf());
        let swept = cache.sweep(Some(&asked()), None);

        assert_eq!(swept.deleted, 2);
        // the face kind is read on both sides of the policy: without it, every
        // face is deleted on the sweep that follows the rail that fetched it
        assert_eq!(
            names(dir.path()),
            ["1-poster-408.jpg", "7-face-w185.jpg", ACCESS_FILE]
                .iter()
                .map(|n| n.to_string())
                .collect::<Vec<_>>()
        );
    }

    /// The number before the kind is a person's for a face and a title's for
    /// everything else. They share one namespace, and the kind is what tells
    /// two files with the same number apart.
    #[test]
    fn a_face_and_a_poster_numbered_alike_are_two_files() {
        let dir = tempfile::tempdir().unwrap();
        write(dir.path(), "42-face-w185.jpg", FACE);
        write(dir.path(), "42-poster-408.jpg", POSTER);

        let cache = ArtworkCache::new(dir.path().to_path_buf());
        let swept = cache.sweep(Some(&asked()), None);

        assert_eq!(swept.deleted, 0);
        assert_eq!(
            names(dir.path()),
            ["42-face-w185.jpg", "42-poster-408.jpg", ACCESS_FILE]
                .iter()
                .map(|n| n.to_string())
                .collect::<Vec<_>>()
        );
    }

    #[test]
    fn a_logo_drawn_on_every_home_screen_outranks_a_poster_seen_once() {
        // the hero is one tile and it is drawn every time the screen is, so a
        // logo accrues hits no single poster in a rail of twenty does
        let entries = [
            entry("1-logo-w500.png", LOGO, 8.0, 10),
            entry("2-poster-408.jpg", POSTER, 1.0, 30),
        ];
        // room for one of the two, and the poster is the one that goes
        let gone = evictions(&entries, 80 * 1024);
        assert_eq!(gone, vec![1]);
    }

    #[test]
    fn a_logo_is_not_swept_as_a_name_the_policy_cannot_read() {
        let dir = tempfile::tempdir().unwrap();
        write(dir.path(), "1-logo-w500.png", LOGO);
        write(dir.path(), "1-poster-408.jpg", POSTER);
        // a logo at a size this build no longer asks for, and one an older
        // build wrote as a jpeg: both answer nothing now
        write(dir.path(), "2-logo-w300.png", LOGO);
        write(dir.path(), "3-logo-w500.jpg", LOGO);

        let cache = ArtworkCache::new(dir.path().to_path_buf());
        let swept = cache.sweep(Some(&asked()), None);

        assert_eq!(swept.deleted, 2);
        // the .png suffix and the logo kind are both read: without either, the
        // logo just fetched is deleted before the hero has drawn it
        assert_eq!(
            names(dir.path()),
            ["1-logo-w500.png", "1-poster-408.jpg", ACCESS_FILE]
                .iter()
                .map(|n| n.to_string())
                .collect::<Vec<_>>()
        );
    }

    #[test]
    fn a_backdrop_gives_way_before_the_posters_it_is_worth_the_bytes_of() {
        // one backdrop and twenty posters, every one of them asked for once:
        // ranked by recency the backdrop is the newest and survives, which is
        // the trade this policy exists to refuse
        let mut entries = vec![entry("1-backdrop-3840.jpg", BACKDROP, 1.0, 100)];
        for i in 0..20 {
            entries.push(entry(&format!("{i}-poster-408.jpg"), POSTER, 1.0, i as i64));
        }
        // room for every poster and most of the backdrop
        let out = evictions(&entries, 20 * POSTER + BACKDROP / 2);
        assert_eq!(out, vec![0]);
    }

    #[test]
    fn a_backdrop_wanted_often_enough_outranks_a_poster_nobody_asks_for() {
        let mut entries = vec![entry("1-backdrop-3840.jpg", BACKDROP, 40.0, 1)];
        for i in 0..5 {
            entries.push(entry(&format!("{i}-poster-408.jpg"), POSTER, 0.0, i as i64));
        }
        let out = evictions(&entries, BACKDROP + 3 * POSTER);
        // every poster, and the backdrop the household keeps coming back to
        // is not one of them
        assert_eq!(out.len(), 5);
        assert!(!out.contains(&0));
    }

    #[test]
    fn a_file_on_screen_is_never_the_one_that_goes() {
        let mut entries = vec![Entry {
            held: true,
            ..entry("1-backdrop-3840.jpg", BACKDROP, 0.0, 1)
        }];
        for i in 0..40 {
            entries.push(entry(
                &format!("{i}-poster-408.jpg"),
                POSTER,
                50.0,
                i as i64,
            ));
        }
        // a budget under what the held backdrop alone costs: everything else
        // goes and the sweep still stops short rather than blanking a tile
        let out = evictions(&entries, POSTER);
        assert_eq!(out.len(), 40);
        assert!(!out.contains(&0));
    }

    #[test]
    fn a_name_no_build_asks_for_any_more_is_reclaimed() {
        let dir = tempfile::tempdir().unwrap();
        write(dir.path(), "1.jpg", POSTER);
        write(dir.path(), "2-backdrop.jpg", BACKDROP);
        write(dir.path(), "3-backdrop-2560.jpg", BACKDROP);
        write(dir.path(), "4-poster-408.jpg", POSTER);
        write(dir.path(), "5-backdrop-3840.jpg", BACKDROP);
        write(dir.path(), "6-poster-408.jpg.part", POSTER);

        let cache = ArtworkCache::new(dir.path().to_path_buf());
        // free space enough that nothing is over budget: only the stale go
        let swept = cache.sweep(Some(&asked()), Some(u64::MAX / 8));
        assert_eq!(swept.deleted, 4);
        assert_eq!(
            names(dir.path()),
            ["4-poster-408.jpg", "5-backdrop-3840.jpg", ACCESS_FILE]
        );
    }

    #[test]
    fn a_build_that_cannot_say_what_it_asks_for_calls_nothing_stale() {
        let dir = tempfile::tempdir().unwrap();
        write(dir.path(), "3-backdrop-2560.jpg", BACKDROP);
        write(dir.path(), "4-poster-408.jpg", POSTER);
        let cache = ArtworkCache::new(dir.path().to_path_buf());
        let swept = cache.sweep(None, Some(u64::MAX / 8));
        assert_eq!(swept.deleted, 0);
        assert_eq!(
            names(dir.path()),
            ["3-backdrop-2560.jpg", "4-poster-408.jpg", ACCESS_FILE]
        );
    }

    #[test]
    fn a_filesystem_that_will_not_say_how_full_it_is_evicts_nothing() {
        let dir = tempfile::tempdir().unwrap();
        for i in 0..10 {
            write(dir.path(), &format!("{i}-backdrop-3840.jpg"), BACKDROP);
        }
        let cache = ArtworkCache::new(dir.path().to_path_buf());
        let swept = cache.sweep(Some(&asked()), None);
        assert_eq!(swept.deleted, 0);
        assert_eq!(swept.bytes, 10 * BACKDROP);
    }

    #[test]
    fn the_sweep_takes_the_directory_down_under_the_budget() {
        let dir = tempfile::tempdir().unwrap();
        for i in 0..20 {
            write(dir.path(), &format!("{i}-backdrop-3840.jpg"), BACKDROP);
        }
        let cache = ArtworkCache::new(dir.path().to_path_buf());
        // a full volume: the budget is a quarter of what the cache itself is
        // holding, because that is all it could ever get back
        let swept = cache.sweep(Some(&asked()), Some(0));
        assert_eq!(swept.budget, 5 * BACKDROP);
        assert!(swept.bytes <= 5 * BACKDROP, "{} bytes left", swept.bytes);
        assert!(!cache.due());
    }

    #[test]
    fn an_image_just_fetched_survives_the_sweep_its_own_bytes_set_off() {
        let dir = tempfile::tempdir().unwrap();
        write(dir.path(), "1-backdrop-3840.jpg", BACKDROP);
        let cache = ArtworkCache::new(dir.path().to_path_buf());
        cache.wrote("1-backdrop-3840.jpg", BACKDROP);
        assert!(cache.due());

        // a full volume, so the budget is a quarter of the one file: the tile
        // that asked for it has not drawn it yet, and it stays
        let swept = cache.sweep(Some(&asked()), Some(0));
        assert_eq!(swept.deleted, 0);
        assert_eq!(names(dir.path()), ["1-backdrop-3840.jpg", ACCESS_FILE]);
    }

    #[test]
    fn a_purge_under_the_bookkeeping_costs_the_bookkeeping_and_not_the_launch() {
        let dir = tempfile::tempdir().unwrap();
        write(dir.path(), "1-poster-408.jpg", POSTER);
        let cache = ArtworkCache::new(dir.path().to_path_buf());
        cache.hit("1-poster-408.jpg");
        cache.wrote("1-poster-408.jpg", POSTER);
        cache.sweep(Some(&asked()), Some(u64::MAX / 8));

        // the system takes Library/Caches, record and images together
        std::fs::remove_dir_all(dir.path()).unwrap();
        let swept = cache.sweep(Some(&asked()), Some(u64::MAX / 8));
        assert_eq!(
            swept,
            Swept {
                deleted: 0,
                freed: 0,
                bytes: 0,
                budget: u64::MAX / 8 / 4,
            }
        );

        // and the directory coming back empty is a cache that starts again
        std::fs::create_dir_all(dir.path()).unwrap();
        write(dir.path(), "1-poster-408.jpg", POSTER);
        let swept = cache.sweep(Some(&asked()), Some(u64::MAX / 8));
        assert_eq!(swept.bytes, POSTER);
    }

    #[test]
    fn hits_are_carried_across_a_launch_but_being_on_screen_is_not() {
        let dir = tempfile::tempdir().unwrap();
        write(dir.path(), "1-poster-408.jpg", POSTER);
        let first = ArtworkCache::new(dir.path().to_path_buf());
        for _ in 0..8 {
            first.hit("1-poster-408.jpg");
        }
        first.sweep(Some(&asked()), Some(u64::MAX / 8));

        let second = ArtworkCache::new(dir.path().to_path_buf());
        second.sweep(Some(&asked()), Some(u64::MAX / 8));
        let state = second.state.lock();
        // eight hits, halved by the sweep that wrote them and again by the
        // one that read them back
        assert_eq!(state.seen["1-poster-408.jpg"].hits, 2.0);
        // and nothing this process has asked for is on screen in it
        assert_eq!(state.seen["1-poster-408.jpg"].ask, 0);
    }

    #[test]
    fn a_record_naming_files_that_are_gone_is_pruned_to_the_directory() {
        let dir = tempfile::tempdir().unwrap();
        write(dir.path(), "1-poster-408.jpg", POSTER);
        std::fs::write(
            dir.path().join(ACCESS_FILE),
            br#"{"1-poster-408.jpg":6.0,"999-backdrop-3840.jpg":40.0}"#,
        )
        .unwrap();
        let cache = ArtworkCache::new(dir.path().to_path_buf());
        cache.sweep(Some(&asked()), Some(u64::MAX / 8));
        let state = cache.state.lock();
        assert_eq!(state.seen.len(), 1);
        assert_eq!(state.seen["1-poster-408.jpg"].hits, 3.0);
    }

    /// A browse over the owner's own library: 3798 titles, of which 3781 carry
    /// a backdrop, posters at 48 KB and backdrops at 935 KB (spec: measured in
    /// `4395ad7`). One session is a home screen of rails, a few detail screens
    /// off it, and a small set of titles the household comes back to.
    ///
    /// Every arm sees the same trace and the same byte budget, and each asks
    /// its own policy what to drop. What is compared is the share of asks the
    /// cache answered and what it was holding at the end.
    mod browsing {
        use super::*;
        use std::collections::VecDeque;

        const TITLES: i64 = 3798;
        const WITH_BACKDROP: i64 = 3781;
        /// The titles a household is part way through, which is what the
        /// resume rail is drawn from and what the hero is picked out of.
        const IN_PROGRESS: i64 = 40;
        /// Poster rails on the home screen, beside the resume rail.
        const RAILS: usize = 7;
        const RAIL: i64 = 20;
        /// Detail screens opened per session, each one a backdrop from the
        /// long tail and two rails of neighbours under it.
        const OPENED: usize = 3;
        const SESSIONS: usize = 120;
        /// Two devices: one with about 400 MB left on it and one with a
        /// gigabyte, which is what the budget is a quarter of. The whole
        /// library's posters are 178 MB, so the first has to choose between
        /// the two kinds of image and the second only nearly does.
        const BUDGETS: [u64; 2] = [100 * 1024 * 1024, 250 * 1024 * 1024];

        struct Random(u64);

        impl Random {
            /// xorshift64*: a trace has to be the same one for every arm, and
            /// a test has no business pulling in a generator crate for it.
            fn next(&mut self) -> u64 {
                self.0 ^= self.0 >> 12;
                self.0 ^= self.0 << 25;
                self.0 ^= self.0 >> 27;
                self.0.wrapping_mul(0x2545_F491_4F6C_DD1D)
            }

            fn below(&mut self, n: i64) -> i64 {
                (self.next() % n as u64) as i64
            }

            /// A title off a rail, drawn the way a library is browsed: a small
            /// set the household keeps returning to `favoured` percent of the
            /// time, the long tail the rest.
            fn title(&mut self, favoured: u64) -> i64 {
                if self.next() % 100 < favoured {
                    self.below(IN_PROGRESS)
                } else {
                    self.below(TITLES)
                }
            }
        }

        /// (name, bytes) for every image one browse asks for, in order.
        ///
        /// The resume rail is drawn in landscape, so each of its cards asks
        /// for a backdrop rather than a poster (`HomeScreen`, `PosterCard`):
        /// the first screen of the app is twenty backdrops and a hero, which
        /// is most of what this cache is asked to hold.
        fn trace() -> Vec<(String, u64)> {
            let mut random = Random(0x5EED_1E77);
            let mut asks = Vec::new();
            let poster = |asks: &mut Vec<(String, u64)>, id: i64| {
                asks.push((format!("{id}-poster-408.jpg"), POSTER));
            };
            for session in 0..SESSIONS {
                // the rail rotates as titles are finished and others started
                let first = (session as i64 * 3) % IN_PROGRESS;
                for card in 0..RAIL {
                    let id = (first + card) % IN_PROGRESS;
                    asks.push((format!("{id}-backdrop-3840.jpg"), BACKDROP));
                }
                for _ in 0..RAILS {
                    for _ in 0..RAIL {
                        poster(&mut asks, random.title(30));
                    }
                }
                for _ in 0..OPENED {
                    let id = random.title(35);
                    poster(&mut asks, id);
                    if id < WITH_BACKDROP {
                        asks.push((format!("{id}-backdrop-3840.jpg"), BACKDROP));
                    }
                    for _ in 0..(2 * RAIL) {
                        poster(&mut asks, random.title(20));
                    }
                }
            }
            asks
        }

        #[derive(Debug)]
        struct Run {
            hits: usize,
            asks: usize,
            bytes: u64,
        }

        impl Run {
            fn rate(&self) -> f64 {
                self.hits as f64 / self.asks as f64
            }
        }

        /// The policy this module ships, driven over the trace the way the
        /// sweep drives it: hits counted per ask, a sweep whenever the
        /// directory goes over budget.
        fn gdsf(asks: &[(String, u64)], budget: u64) -> Run {
            let mut hits = HashMap::<String, f32>::new();
            let mut held = HashMap::<String, (u64, i64)>::new();
            let mut bytes = 0u64;
            let mut run = Run {
                hits: 0,
                asks: asks.len(),
                bytes: 0,
            };
            for (clock, (name, size)) in asks.iter().enumerate() {
                if held.contains_key(name) {
                    run.hits += 1;
                    *hits.entry(name.clone()).or_default() += 1.0;
                    continue;
                }
                held.insert(name.clone(), (*size, clock as i64));
                bytes += size;
                if bytes <= budget {
                    continue;
                }
                let entries: Vec<Entry> = held
                    .iter()
                    .map(|(name, (size, written))| Entry {
                        name: name.clone(),
                        bytes: *size,
                        mtime: *written,
                        hits: hits.get(name).copied().unwrap_or(0.0),
                        // the one just asked for is the one on screen
                        held: name == &asks[clock].0,
                    })
                    .collect();
                for i in evictions(&entries, budget) {
                    bytes -= entries[i].bytes;
                    held.remove(&entries[i].name);
                    hits.remove(&entries[i].name);
                }
                for hits in hits.values_mut() {
                    *hits *= AGE;
                }
            }
            run.bytes = bytes;
            run
        }

        /// Recency alone, which is what reaching for the familiar policy gets.
        fn lru(asks: &[(String, u64)], budget: u64) -> Run {
            let mut order = VecDeque::<String>::new();
            let mut held = HashMap::<String, u64>::new();
            let mut bytes = 0u64;
            let mut run = Run {
                hits: 0,
                asks: asks.len(),
                bytes: 0,
            };
            for (name, size) in asks {
                if held.contains_key(name) {
                    run.hits += 1;
                    order.retain(|held| held != name);
                    order.push_back(name.clone());
                    continue;
                }
                held.insert(name.clone(), *size);
                order.push_back(name.clone());
                bytes += size;
                while bytes > budget {
                    let Some(oldest) = order.pop_front() else {
                        break;
                    };
                    if &oldest == name {
                        order.push_back(oldest);
                        continue;
                    }
                    if let Some(size) = held.remove(&oldest) {
                        bytes -= size;
                    }
                }
            }
            run.bytes = bytes;
            run
        }

        /// SIEVE: one FIFO queue, a visited bit set on every hit, and a hand
        /// that walks from the old end past everything visited. The cheapest
        /// of the modern queue policies and the strongest of the size-blind
        /// ones on a workload shaped like this.
        fn sieve(asks: &[(String, u64)], budget: u64) -> Run {
            let mut order = VecDeque::<String>::new();
            let mut held = HashMap::<String, (u64, bool)>::new();
            let mut bytes = 0u64;
            let mut run = Run {
                hits: 0,
                asks: asks.len(),
                bytes: 0,
            };
            for (name, size) in asks {
                if let Some(entry) = held.get_mut(name) {
                    run.hits += 1;
                    entry.1 = true;
                    continue;
                }
                held.insert(name.clone(), (*size, false));
                order.push_back(name.clone());
                bytes += size;
                while bytes > budget {
                    let Some(candidate) = order.pop_front() else {
                        break;
                    };
                    let Some(entry) = held.get_mut(&candidate) else {
                        continue;
                    };
                    if entry.1 || &candidate == name {
                        entry.1 = false;
                        order.push_back(candidate);
                        continue;
                    }
                    bytes -= entry.0;
                    held.remove(&candidate);
                }
            }
            run.bytes = bytes;
            run
        }

        #[test]
        fn value_per_byte_beats_recency_and_beats_a_size_blind_queue() {
            let asks = trace();
            println!("asks {}", asks.len());
            for budget in BUDGETS {
                let gdsf = gdsf(&asks, budget);
                let lru = lru(&asks, budget);
                let sieve = sieve(&asks, budget);
                println!("budget {budget}");
                println!("  gdsf  {:.3} {} bytes", gdsf.rate(), gdsf.bytes);
                println!("  lru   {:.3} {} bytes", lru.rate(), lru.bytes);
                println!("  sieve {:.3} {} bytes", sieve.rate(), sieve.bytes);
                assert!(
                    gdsf.rate() > lru.rate(),
                    "budget {budget}: gdsf {:.3} lru {:.3}",
                    gdsf.rate(),
                    lru.rate()
                );
                assert!(
                    gdsf.rate() > sieve.rate(),
                    "budget {budget}: gdsf {:.3} sieve {:.3}",
                    gdsf.rate(),
                    sieve.rate()
                );
                // and every arm stayed inside the budget it was given
                for run in [&gdsf, &lru, &sieve] {
                    assert!(run.bytes <= budget, "budget {budget}: {run:?}");
                }
            }
        }
    }
}
