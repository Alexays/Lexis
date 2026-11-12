use super::library::{to_item, ApiMediaKind, TitleItem};
use super::{unix_now, CoreError, LexisCore};
use crate::index::ask;
use crate::index::MediaKind;

/// What a question asked in words was understood to mean, one filter per
/// field: the screen draws each as a chip, and a chip removed is this record
/// sent back through `ask_with` without it.
#[derive(Debug, Clone, uniffi::Record)]
pub struct AskFilters {
    pub max_minutes: Option<u32>,
    pub kind: Option<ApiMediaKind>,
    /// Never played and never judged.
    pub unseen: bool,
    /// Watched through at least once.
    pub rewatch: bool,
    /// The decade's first year: 1980 for the eighties.
    pub decade: Option<u16>,
    /// People credited on the title, as the library names them.
    pub people: Vec<String>,
    /// A key of the moods `moods` lists.
    pub mood: Option<String>,
    /// Fits what is left of this evening.
    pub tonight: bool,
    /// The words no rule read, which the encoder ranks by when the device
    /// has it.
    pub text: String,
}

#[derive(Debug, uniffi::Record)]
pub struct AskResult {
    pub filters: AskFilters,
    pub items: Vec<TitleItem>,
}

#[uniffi::export]
impl LexisCore {
    /// The library under a question asked in words, French or English: a
    /// length, a kind, a decade, a person, a mood, seen or not, and whatever
    /// else was said, ranked by the encoder when the device holds one and by
    /// the taste otherwise. Never an error for want of a model.
    pub fn ask(&self, query: String, tz_offset_secs: i32) -> Result<AskResult, CoreError> {
        let now = unix_now();
        let filters = {
            let db = self.heavy_db.lock();
            ask::parse(&db, &query, now, tz_offset_secs)?
        };
        self.answer(filters, now, tz_offset_secs)
    }

    /// The same, for filters the viewer edited: a chip taken off.
    pub fn ask_with(
        &self,
        filters: AskFilters,
        tz_offset_secs: i32,
    ) -> Result<AskResult, CoreError> {
        let filters = ask::AskFilters {
            max_minutes: filters.max_minutes,
            kind: filters.kind.map(MediaKind::from),
            unseen: filters.unseen,
            rewatch: filters.rewatch,
            decade: filters.decade,
            people: filters.people,
            mood: filters.mood,
            tonight: filters.tonight,
            text: filters.text,
        };
        self.answer(filters, unix_now(), tz_offset_secs)
    }
}

impl LexisCore {
    pub(crate) fn answer(
        &self,
        filters: ask::AskFilters,
        now: i64,
        tz_offset_secs: i32,
    ) -> Result<AskResult, CoreError> {
        // the encoder reads the words off the index lock: a forward pass is
        // milliseconds nobody else should wait on
        let query = if filters.text.is_empty() {
            None
        } else {
            self.ask_model()
                .and_then(|model| model.embed(&filters.text).ok().flatten())
        };
        let rows = {
            let db = self.heavy_db.lock();
            ask::ask(&db, &filters, query.as_deref(), now, tz_offset_secs)?
        };
        Ok(AskResult {
            items: rows.into_iter().map(to_item).collect(),
            filters: AskFilters {
                max_minutes: filters.max_minutes,
                kind: filters.kind.map(|k| match k {
                    MediaKind::Movie => ApiMediaKind::Movie,
                    MediaKind::Show => ApiMediaKind::Show,
                }),
                unseen: filters.unseen,
                rewatch: filters.rewatch,
                decade: filters.decade,
                people: filters.people,
                mood: filters.mood,
                tonight: filters.tonight,
                text: filters.text,
            },
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::api::testing::MemStore;
    use crate::index::db::{Db, FileMedia, FileRecord};
    use std::sync::Arc;

    #[test]
    fn without_a_model_a_question_still_answers_with_what_its_filters_keep() {
        let cache = tempfile::tempdir().unwrap();
        let core = LexisCore::new(
            cache.path().to_string_lossy().into_owned(),
            Arc::new(MemStore::default()),
        )
        .unwrap();
        let db = Db::open(&cache.path().join("index.sqlite")).unwrap();
        for (kind, name) in [(MediaKind::Movie, "Dune"), (MediaKind::Show, "Dark")] {
            let id = db.upsert_title(kind, name, Some(2021)).unwrap();
            db.upsert_file(&FileRecord {
                source_id: "s1".into(),
                dir: "Media".into(),
                path: format!("Media/{name}.mkv"),
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
        }
        let answer = core
            .ask("un film pas vu avec du sable et des vers géants".into(), 0)
            .unwrap();
        assert!(matches!(answer.filters.kind, Some(ApiMediaKind::Movie)));
        assert!(answer.filters.unseen);
        assert_eq!(answer.filters.text, "sable vers géants");
        let names: Vec<String> = answer.items.into_iter().map(|t| t.name).collect();
        assert_eq!(names, vec!["Dune".to_string()]);

        // a chip taken off widens the answer
        let mut filters = core.ask("un film pas vu".into(), 0).unwrap().filters;
        filters.kind = None;
        assert_eq!(core.ask_with(filters, 0).unwrap().items.len(), 2);
    }
}
