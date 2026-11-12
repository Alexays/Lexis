use super::{
    unix_now, CoreError, LexisCore, DISMISSED_KEY, MAX_DISMISSED, MAX_VERDICTS, VERDICTS_KEY,
};
use crate::index::queries::title_by_key;
use crate::index::{MediaKind, Verdict};
use serde::{Deserialize, Serialize};

/// One title the viewer took out of the continue-watching row, as the durable
/// copy stores it. Keyed by the three columns that name a title rather than by
/// its id: a purge rebuilds the index and hands the same ids to other films,
/// while the same scan finds the same title (see `Db::title_key`). The field
/// names are short because every byte counts against the store's budget.
#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
pub(super) struct DismissEntry {
    k: String,
    n: String,
    y: u16,
    t: i64,
}

/// One title the viewer stated an opinion about, as the durable copy stores
/// it. Keyed by the same three columns as a dismissal and for the same reason:
/// a purge hands the ids to other films, and this is the one piece of state
/// here that is meant to outlive several of them. `v` is the stored verdict
/// number, `t` is when it was said.
#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
pub(super) struct VerdictEntry {
    k: String,
    n: String,
    y: u16,
    v: i64,
    t: i64,
}

/// What the viewer said about a title. Three levels and no scale: see
/// `index::Verdict`. Absent is "they have not said", which the UI must never
/// draw as a rejection.
#[derive(Debug, uniffi::Enum, Clone, Copy, PartialEq, Eq)]
pub enum ApiVerdict {
    Down,
    Up,
    Loved,
}

impl From<ApiVerdict> for Verdict {
    fn from(v: ApiVerdict) -> Self {
        match v {
            ApiVerdict::Down => Verdict::Down,
            ApiVerdict::Up => Verdict::Up,
            ApiVerdict::Loved => Verdict::Loved,
        }
    }
}

impl From<Verdict> for ApiVerdict {
    fn from(v: Verdict) -> Self {
        match v {
            Verdict::Down => ApiVerdict::Down,
            Verdict::Up => ApiVerdict::Up,
            Verdict::Loved => ApiVerdict::Loved,
        }
    }
}

#[uniffi::export]
impl LexisCore {
    /// Takes a title out of the continue-watching row, or puts it back.
    ///
    /// Deliberately not `mark_watched`. That one writes watch state and pushes
    /// a scrobble for every file of the title, so a series left at 14% would be
    /// recorded as watched on the server that owns the history and follow the
    /// viewer into every other client they own. This writes one local row: the
    /// watch state is untouched, what the title resumes from still resumes, and
    /// nothing leaves the device.
    ///
    /// The dismissal answers for the progress that is there now and no other,
    /// so playing the title again - here, or anywhere else the sync mirrors -
    /// is what offers it back. That is also what makes a stray press cheap:
    /// one press undoes it, and nothing outlives the next time it is watched.
    pub fn dismiss_resume(&self, title_id: i64, dismissed: bool) -> Result<(), CoreError> {
        let key = {
            let db = self.read_db.lock();
            db.title_key(title_id)?
        };
        let Some((kind, name, year)) = key else {
            return Err(CoreError::NotFound {
                msg: format!("no title with id {title_id} in the index"),
            });
        };
        let now = unix_now();
        {
            let db = self.db.lock();
            if dismissed {
                db.dismiss_resume(title_id, now)?;
            } else {
                db.restore_resume(title_id)?;
            }
        }
        self.store_dismissed(
            DismissEntry {
                k: kind.as_str().to_string(),
                n: name,
                y: year,
                t: now,
            },
            dismissed,
        )
    }

    /// Records what the viewer thinks of a title, or clears it with `None`.
    ///
    /// Nothing is sent anywhere, and that is a decision rather than an
    /// oversight. Plex carries a user rating field; writing to it would put
    /// this viewer's opinion on their account, in every other client they own,
    /// on the strength of a button they pressed in this one. `mark_watched`
    /// pushes to the server because the history is the server's - it is a
    /// record of what happened, and other clients wrote it too - and an
    /// opinion is not a record of anything that happened.
    ///
    /// The recompute is the whole cost of the press, and it is here rather
    /// than deferred. Measured on the owner's library - 3788 vectors, 753
    /// titles played - a full `taste::refresh` is 9 ms warm and 28 ms cold on
    /// an M4 Pro. It is not the sweep: the sweep compares every title with
    /// every other and is the thing that must never be run per press, while
    /// this reads the library once, clusters the few hundred titles with a
    /// weight, and walks the vectors once per facet. What the viewer gets for
    /// it is a home screen that has already moved when they walk back to it.
    pub fn set_verdict(&self, title_id: i64, verdict: Option<ApiVerdict>) -> Result<(), CoreError> {
        let key = {
            let db = self.read_db.lock();
            db.title_key(title_id)?
        };
        let Some((kind, name, year)) = key else {
            return Err(CoreError::NotFound {
                msg: format!("no title with id {title_id} in the index"),
            });
        };
        let now = unix_now();
        {
            let db = self.db.lock();
            db.set_verdict(title_id, verdict.map(Verdict::from), now)?;
        }
        // The visible row is already correct: PICKED applies the verdict
        // filters at read time. The taste recompute rides the worker instead
        // of holding this caller - and every writer queued behind it - for
        // its few milliseconds under the write lock.
        self.kick_taste_refresh();
        self.store_verdict(
            VerdictEntry {
                k: kind.as_str().to_string(),
                n: name,
                y: year,
                v: verdict.map_or(0, |v| Verdict::from(v).as_i64()),
                t: now,
            },
            verdict.is_some(),
        )
    }
}

impl LexisCore {
    /// Merges one press into the durable copy and writes the whole value back.
    /// One title at a time: this runs on a press, not on a loop.
    fn store_dismissed(&self, entry: DismissEntry, dismissed: bool) -> Result<(), CoreError> {
        let bytes = {
            let mut all = self.dismissed.lock();
            let found = all
                .iter()
                .position(|e| e.k == entry.k && e.n == entry.n && e.y == entry.y);
            match (dismissed, found) {
                (true, Some(i)) => all[i].t = entry.t,
                (true, None) => all.push(entry),
                (false, Some(i)) => {
                    all.remove(i);
                }
                // putting back what was never taken out: the copy already agrees
                (false, None) => return Ok(()),
            }
            if all.len() > MAX_DISMISSED {
                // newest first, and the tail goes: the oldest press is the one
                // whose title the viewer is least likely to still be avoiding
                all.sort_by_key(|e| std::cmp::Reverse(e.t));
                all.truncate(MAX_DISMISSED);
            }
            serde_json::to_vec(&*all).map_err(|e| CoreError::Storage { msg: e.to_string() })?
        };
        self.store.set(DISMISSED_KEY.to_string(), bytes);
        Ok(())
    }

    /// Merges one verdict into the durable copy and writes the whole value
    /// back, the same way `store_dismissed` does and for the same reason: this
    /// runs on a press, not on a loop.
    fn store_verdict(&self, entry: VerdictEntry, stated: bool) -> Result<(), CoreError> {
        let bytes = {
            let mut all = self.verdicts.lock();
            let found = all
                .iter()
                .position(|e| e.k == entry.k && e.n == entry.n && e.y == entry.y);
            match (stated, found) {
                // the viewer holds one opinion of a title at a time: the new
                // one replaces the old outright rather than joining it
                (true, Some(i)) => all[i] = entry,
                (true, None) => all.push(entry),
                (false, Some(i)) => {
                    all.remove(i);
                }
                // clearing an opinion never stated: the copy already agrees
                (false, None) => return Ok(()),
            }
            if all.len() > MAX_VERDICTS {
                all.sort_by_key(|e| std::cmp::Reverse(e.t));
                all.truncate(MAX_VERDICTS);
            }
            serde_json::to_vec(&*all).map_err(|e| CoreError::Storage { msg: e.to_string() })?
        };
        self.store.set(VERDICTS_KEY.to_string(), bytes);
        Ok(())
    }

    /// Mirrors the durable copy back into the index, the same way the watch
    /// state comes back after a purge rebuilt the rows it points at.
    ///
    /// A title this scan did not find keeps its entry: the source holding it
    /// may simply have been away, and dropping the press would put the title
    /// back in the row on the scan that finds it again.
    pub(super) fn restore_dismissals(&self, db: &crate::index::db::Db) -> Result<(), CoreError> {
        let entries: Vec<DismissEntry> = self.dismissed.lock().clone();
        if entries.is_empty() {
            return Ok(());
        }
        for entry in &entries {
            let Some(kind) = MediaKind::from_str(&entry.k) else {
                continue;
            };
            let Some(title) = title_by_key(db, kind, &entry.n, entry.y)? else {
                continue;
            };
            db.dismiss_resume(title.id, entry.t)?;
        }
        Ok(())
    }

    /// Mirrors the stated opinions back into the index, exactly as
    /// `restore_dismissals` does. Called on the same scan, and it matters more
    /// here: a dismissal is undone by playing the title again, while a verdict
    /// is meant to hold for years, so this is what makes it survive the purge
    /// that reissues every id it could have been stored under.
    pub(super) fn restore_verdicts(&self, db: &crate::index::db::Db) -> Result<(), CoreError> {
        let entries: Vec<VerdictEntry> = self.verdicts.lock().clone();
        if entries.is_empty() {
            return Ok(());
        }
        for entry in &entries {
            let (Some(kind), Some(verdict)) =
                (MediaKind::from_str(&entry.k), Verdict::from_i64(entry.v))
            else {
                continue;
            };
            let Some(title) = title_by_key(db, kind, &entry.n, entry.y)? else {
                continue;
            };
            db.set_verdict(title.id, Some(verdict), entry.t)?;
        }
        Ok(())
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

    /// Whether the home screen still offers something to carry on with.
    fn resume_row(core: &LexisCore) -> bool {
        core.queue(20)
            .unwrap()
            .iter()
            .any(|q| q.resume_file_id.is_some())
    }

    #[test]
    fn a_title_dismissed_from_the_resume_row_tells_no_server_and_survives_a_purge() {
        use crate::plex::fake::{FakeServer, Reply};

        // one film a third of the way in, which is what the row is for
        let server = FakeServer::start(|req| {
            if req.url == "/library/sections" {
                return Reply::json(
                    r#"{"MediaContainer":{"size":1,"Directory":[
  {"key":"1","type":"movie","title":"Movies"}
]}}"#,
                );
            }
            if req.url.starts_with("/library/sections/1/all") {
                return Reply::json(
                    r#"{"MediaContainer":{"size":1,"totalSize":1,"Metadata":[
  {"ratingKey":"101","title":"Dune","year":2021,"viewOffset":3000000,"duration":9000000,
   "lastViewedAt":1700000000,
   "Media":[{"Part":[{"id":501,"key":"/library/parts/501/1/Dune.mkv","size":42}]}]}
]}}"#,
                );
            }
            Reply::status(404)
        });
        let cache = tempfile::tempdir().unwrap();
        let store = Arc::new(MemStore::default());
        let core =
            LexisCore::new(cache.path().to_string_lossy().into_owned(), store.clone()).unwrap();
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
        assert!(resume_row(&core));

        let asked = server.requests().len();
        core.dismiss_resume(film, true).unwrap();
        assert!(!resume_row(&core));
        // the whole of the difference from mark_watched: the server that owns
        // this history is told nothing, so no other client of it learns that a
        // film left a third of the way in was watched
        assert_eq!(server.requests().len(), asked);
        {
            let db = core.read_db.lock();
            let file = db.title_file_refs(film).unwrap()[0].id;
            let row = db.watch_state(file).unwrap().unwrap();
            assert!(!row.watched, "a dismissal is not a finish");
            assert_eq!(
                row.position_secs, 3000.0,
                "and it still resumes where it was"
            );
        }

        // one press undoes it, which is what a stray press costs
        core.dismiss_resume(film, false).unwrap();
        assert!(resume_row(&core));

        // a tvOS cache purge takes the index; the press is in the store the
        // purge cannot reach, and the rescan that follows puts it back
        core.dismiss_resume(film, true).unwrap();
        drop(core);
        let purged = tempfile::tempdir().unwrap();
        let relaunched =
            LexisCore::new(purged.path().to_string_lossy().into_owned(), store).unwrap();
        relaunched.scan_all(false).unwrap();
        assert!(!resume_row(&relaunched), "a purge must not undo the press");
    }

    #[test]
    fn a_verdict_press_recomputes_taste_off_the_calling_thread() {
        let media = shelf_dir();
        let cache = tempfile::tempdir().unwrap();
        let store = Arc::new(MemStore::default());
        let core = LexisCore::new(cache.path().to_string_lossy().into_owned(), store).unwrap();
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
        let film = core.list_titles(ApiMediaKind::Movie, 0, 10).unwrap()[0].id;

        let before = core.taste_runs();
        core.set_verdict(film, Some(ApiVerdict::Loved)).unwrap();
        // the press itself answers at once; the recompute is the worker's to
        // finish, and the test waits for exactly that
        assert!(core.wait_for_taste(before, std::time::Duration::from_secs(5)));
        assert_eq!(core.taste_runs(), before + 1);
    }

    #[test]
    fn a_verdict_stays_on_this_device_and_survives_a_purge() {
        use crate::plex::fake::{FakeServer, Reply};

        let server = FakeServer::start(|req| {
            if req.url == "/library/sections" {
                return Reply::json(
                    r#"{"MediaContainer":{"size":1,"Directory":[
  {"key":"1","type":"movie","title":"Movies"}
]}}"#,
                );
            }
            if req.url.starts_with("/library/sections/1/all") {
                return Reply::json(
                    r#"{"MediaContainer":{"size":1,"totalSize":1,"Metadata":[
  {"ratingKey":"101","title":"Dune","year":2021,"viewOffset":3000000,"duration":9000000,
   "lastViewedAt":1700000000,
   "Media":[{"Part":[{"id":501,"key":"/library/parts/501/1/Dune.mkv","size":42}]}]}
]}}"#,
                );
            }
            Reply::status(404)
        });
        let cache = tempfile::tempdir().unwrap();
        let store = Arc::new(MemStore::default());
        let core =
            LexisCore::new(cache.path().to_string_lossy().into_owned(), store.clone()).unwrap();
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
        assert_eq!(core.title_detail(film).unwrap().verdict, None);

        let asked = server.requests().len();
        core.set_verdict(film, Some(ApiVerdict::Down)).unwrap();
        assert_eq!(
            core.title_detail(film).unwrap().verdict,
            Some(ApiVerdict::Down)
        );
        // Plex carries a user rating field and this never touches it: an
        // opinion stated on this television does not follow the viewer into
        // every other client of their account
        assert_eq!(server.requests().len(), asked);
        {
            // and the history the server does own is untouched, exactly as a
            // dismissal leaves it
            let db = core.read_db.lock();
            let file = db.title_file_refs(film).unwrap()[0].id;
            let row = db.watch_state(file).unwrap().unwrap();
            assert!(!row.watched);
            assert_eq!(row.position_secs, 3000.0);
        }

        // the viewer changes their mind, and the last thing they said is what
        // stands rather than what they said first
        core.set_verdict(film, Some(ApiVerdict::Loved)).unwrap();
        assert_eq!(
            core.title_detail(film).unwrap().verdict,
            Some(ApiVerdict::Loved)
        );

        // a tvOS cache purge takes the index and reissues every id in it; the
        // opinion is in the store the purge cannot reach
        drop(core);
        let purged = tempfile::tempdir().unwrap();
        let relaunched =
            LexisCore::new(purged.path().to_string_lossy().into_owned(), store).unwrap();
        relaunched.scan_all(false).unwrap();
        let film = relaunched.list_titles(ApiMediaKind::Movie, 0, 10).unwrap()[0].id;
        assert_eq!(
            relaunched.title_detail(film).unwrap().verdict,
            Some(ApiVerdict::Loved),
            "a purge must not take back what the viewer said"
        );

        // and clearing it clears it everywhere, the store included
        relaunched.set_verdict(film, None).unwrap();
        assert_eq!(relaunched.title_detail(film).unwrap().verdict, None);
        assert_eq!(relaunched.verdicts.lock().len(), 0);
    }
}
