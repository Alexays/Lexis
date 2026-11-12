use super::library::{to_item, TitleItem};
use super::{unix_now, CoreError, LexisCore};
use crate::index::duo;

/// Someone the viewer watches with. Their votes are kept, so the next
/// evening with them starts from what they already said.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct Guest {
    pub id: i64,
    pub name: String,
}

#[uniffi::export]
impl LexisCore {
    pub fn guests(&self) -> Result<Vec<Guest>, CoreError> {
        let db = self.read_db.lock();
        Ok(db
            .guests()?
            .into_iter()
            .map(|(id, name)| Guest { id, name })
            .collect())
    }

    /// The guest of that name, added when there is none yet.
    pub fn add_guest(&self, name: String) -> Result<Guest, CoreError> {
        let name = name.trim();
        if name.is_empty() {
            return Err(CoreError::InvalidConfig {
                msg: "a guest needs a name".to_string(),
            });
        }
        let id = self.db.lock().add_guest(name, unix_now())?;
        Ok(Guest {
            id,
            name: name.to_string(),
        })
    }

    /// The guest and everything they said.
    pub fn remove_guest(&self, id: i64) -> Result<(), CoreError> {
        self.db.lock().remove_guest(id)?;
        Ok(())
    }

    /// Twelve titles for the guest to say yes or no to, none they already
    /// judged. Dealing a deck forgets the votes of a guest nobody named.
    pub fn duo_deck(
        &self,
        tz_offset_secs: i32,
        guest_id: Option<i64>,
    ) -> Result<Vec<TitleItem>, CoreError> {
        self.duo_votes.lock().clear();
        let db = self.heavy_db.lock();
        let rows = duo::deck(&db, unix_now(), tz_offset_secs, guest_id)?;
        Ok(rows.into_iter().map(to_item).collect())
    }

    /// One vote on the deck: kept for good with a guest, for the session
    /// without one.
    pub fn duo_vote(
        &self,
        guest_id: Option<i64>,
        title_id: i64,
        liked: bool,
    ) -> Result<(), CoreError> {
        match guest_id {
            Some(guest) => {
                let db = self.db.lock();
                db.set_guest_verdict(guest, title_id, liked, unix_now())?;
            }
            None => {
                self.duo_votes.lock().insert(title_id, liked);
            }
        }
        Ok(())
    }

    /// What both would watch tonight, best first: the guest's votes so far
    /// and `liked` and `disliked`, against the owner's taste, the veto
    /// holding for each. Empty without vectors, never an error.
    pub fn duo_rank(
        &self,
        guest_id: Option<i64>,
        liked: Vec<i64>,
        disliked: Vec<i64>,
        tz_offset_secs: i32,
    ) -> Result<Vec<TitleItem>, CoreError> {
        self.duo_rank_at(guest_id, liked, disliked, unix_now(), tz_offset_secs)
    }
}

impl LexisCore {
    pub(crate) fn duo_rank_at(
        &self,
        guest_id: Option<i64>,
        liked: Vec<i64>,
        disliked: Vec<i64>,
        now: i64,
        tz_offset_secs: i32,
    ) -> Result<Vec<TitleItem>, CoreError> {
        let (liked, disliked) = match guest_id {
            Some(_) => (liked, disliked),
            None => {
                let mut votes = self.duo_votes.lock().clone();
                votes.extend(liked.into_iter().map(|id| (id, true)));
                votes.extend(disliked.into_iter().map(|id| (id, false)));
                let (yes, no): (Vec<_>, Vec<_>) = votes.into_iter().partition(|(_, v)| *v);
                (
                    yes.into_iter().map(|(id, _)| id).collect(),
                    no.into_iter().map(|(id, _)| id).collect(),
                )
            }
        };
        // the sweep reads on the heavy connection; the write lock is only
        // taken for what a named guest's taste leaves behind
        let ranked = {
            let db = self.heavy_db.lock();
            duo::rank(&db, now, tz_offset_secs, guest_id, &liked, &disliked)?
        };
        if let Some(guest) = guest_id {
            self.db.lock().replace_guest_taste(guest, &ranked.taste)?;
        }
        Ok(ranked.titles.into_iter().map(to_item).collect())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::api::testing::MemStore;
    use crate::index::db::{Db, FileMedia, FileRecord};
    use crate::index::MediaKind;
    use std::sync::Arc;

    /// A Thursday, 21:00 at tz 0.
    const NOW: i64 = 20_685 * 86_400 + 21 * 3_600;

    fn film(db: &Db, name: &str) -> i64 {
        let id = db.upsert_title(MediaKind::Movie, name, None).unwrap();
        db.upsert_file(&FileRecord {
            source_id: "s1".into(),
            dir: "Movies".into(),
            path: format!("Movies/{name}.mkv"),
            size: 1,
            mtime: 0,
            seen_gen: 1,
            title_id: id,
            season: None,
            episode: None,
            rating_key: None,
            media: FileMedia::default(),
        })
        .unwrap();
        id
    }

    /// Two titles a guest likes, one both would watch, and singles that give
    /// the library a centre: vectors and the owner's affinity, as a pass
    /// would have left them. Returns the two liked and the shared one.
    fn shelf(db: &Db) -> ([i64; 2], i64) {
        use crate::index::db::{EmbeddingRecord, TastePassOutput, TitleTasteRow};
        let placed = |name: &str, axes: &[(usize, i8)]| {
            let id = film(db, name);
            db.conn()
                .execute(
                    "UPDATE files SET duration_secs = 6000 WHERE title_id = ?1",
                    [id],
                )
                .unwrap();
            let mut vector = vec![0i8; 40];
            vector[0] = 80;
            for (axis, value) in axes {
                vector[*axis] = *value;
            }
            db.upsert_embedding(&EmbeddingRecord {
                title_id: id,
                model_version: crate::embed::Encoder::Small.version(),
                source_hash: 0,
                vector,
                computed_at: 1,
            })
            .unwrap();
            id
        };
        let liked = [
            placed("Liked One", &[(1, 100)]),
            placed("Liked Two", &[(1, 100), (2, 10)]),
        ];
        let shared = placed("Shared", &[(1, 90), (3, 20)]);
        for axis in 4..40 {
            placed(&format!("Single {axis}"), &[(axis, 100)]);
        }
        db.replace_taste(&TastePassOutput {
            title_taste: vec![TitleTasteRow {
                title_id: shared,
                facet: 0,
                affinity: 0.5,
                rejected: String::new(),
            }],
            ..Default::default()
        })
        .unwrap();
        (liked, shared)
    }

    #[test]
    fn a_guest_s_votes_survive_a_relaunch_and_leave_with_the_guest() {
        let cache = tempfile::tempdir().unwrap();
        let store = Arc::new(MemStore::default());
        let path = cache.path().to_string_lossy().into_owned();
        let core = LexisCore::new(path.clone(), store.clone()).unwrap();
        let dune = film(
            &Db::open(&cache.path().join("index.sqlite")).unwrap(),
            "Dune",
        );
        assert!(core.add_guest("  ".into()).is_err());
        let sam = core.add_guest(" Sam ".into()).unwrap();
        assert_eq!(sam.name, "Sam");
        core.duo_vote(Some(sam.id), dune, true).unwrap();
        drop(core);

        let core = LexisCore::new(path, store).unwrap();
        assert_eq!(core.guests().unwrap(), vec![sam.clone()]);
        assert_eq!(
            core.read_db.lock().guest_verdicts(sam.id).unwrap(),
            vec![(dune, true)]
        );
        core.remove_guest(sam.id).unwrap();
        assert!(core.guests().unwrap().is_empty());
        assert!(core
            .read_db
            .lock()
            .guest_verdicts(sam.id)
            .unwrap()
            .is_empty());
    }

    #[test]
    fn votes_with_no_guest_last_until_the_next_deck() {
        let cache = tempfile::tempdir().unwrap();
        let core = LexisCore::new(
            cache.path().to_string_lossy().into_owned(),
            Arc::new(MemStore::default()),
        )
        .unwrap();
        let (liked, shared) = shelf(&Db::open(&cache.path().join("index.sqlite")).unwrap());
        assert!(core
            .duo_rank_at(None, vec![], vec![], NOW, 0)
            .unwrap()
            .is_empty());
        for id in liked {
            core.duo_vote(None, id, true).unwrap();
        }
        assert_eq!(core.duo_votes.lock().get(&liked[0]), Some(&true));
        // nothing was written: an unnamed guest leaves no trace
        let stored: i64 = core
            .read_db
            .lock()
            .conn()
            .query_row("SELECT COUNT(*) FROM guest_verdict", [], |r| r.get(0))
            .unwrap();
        assert_eq!(stored, 0);
        // the session's votes are the guest's taste
        let proposal = core.duo_rank_at(None, vec![], vec![], NOW, 0).unwrap();
        assert_eq!(proposal.first().map(|t| t.id), Some(shared));
        // and a new deck forgets them
        core.duo_deck(0, None).unwrap();
        assert!(core.duo_votes.lock().is_empty());
        assert!(core
            .duo_rank_at(None, vec![], vec![], NOW, 0)
            .unwrap()
            .is_empty());
    }

    #[test]
    fn choosing_a_guest_for_the_evening_is_company_and_is_said_back() {
        let cache = tempfile::tempdir().unwrap();
        let core = LexisCore::new(
            cache.path().to_string_lossy().into_owned(),
            Arc::new(MemStore::default()),
        )
        .unwrap();
        let (liked, shared) = shelf(&Db::open(&cache.path().join("index.sqlite")).unwrap());
        let sam = core.add_guest("Sam".into()).unwrap();
        for id in liked {
            core.duo_vote(Some(sam.id), id, true).unwrap();
        }
        core.set_evening_at(false, None, None, Some(sam.id), NOW, 0)
            .unwrap();
        let evening = core.evening_at(NOW, 0).unwrap();
        assert_eq!(evening.guest_id, Some(sam.id));
        assert!(evening.together);
        // the choice measured the guest, so the trio has their taste to read
        let measured: Vec<i64> = core
            .read_db
            .lock()
            .conn()
            .prepare("SELECT title_id FROM guest_taste WHERE guest_id = ?1")
            .unwrap()
            .query_map([sam.id], |r| r.get(0))
            .unwrap()
            .collect::<Result<_, _>>()
            .unwrap();
        assert!(measured.contains(&shared), "{measured:?}");
        core.remove_guest(sam.id).unwrap();
        assert_eq!(core.evening_at(NOW, 0).unwrap().guest_id, None);
    }
}
