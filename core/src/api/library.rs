use super::{CoreError, LexisCore};
use crate::index::queries::{
    count_titles, library_facets, list_titles, search_titles, title_initials, Filter, MatchField,
    SortOrder,
};
use crate::index::MediaKind;

#[derive(Debug, uniffi::Enum, Clone, Copy)]
pub enum ApiMediaKind {
    Movie,
    Show,
}

impl From<ApiMediaKind> for MediaKind {
    fn from(k: ApiMediaKind) -> Self {
        match k {
            ApiMediaKind::Movie => MediaKind::Movie,
            ApiMediaKind::Show => MediaKind::Show,
        }
    }
}

#[derive(Debug, uniffi::Record)]
pub struct TitleItem {
    pub id: i64,
    pub kind: ApiMediaKind,
    pub name: String,
    pub year: Option<u16>,
    pub file_count: u32,
    /// What `open_stream` takes. None for a title with no files left.
    pub first_file_id: Option<i64>,
}

/// Which shelf the library screen is showing. A new variant goes last: the
/// ordinals are the wire format.
#[derive(Debug, Clone, Copy, uniffi::Enum)]
pub enum LibrarySort {
    Name,
    Year,
    RecentlyAdded,
}

/// What the library screen has narrowed the shelf to. Every field absent is
/// the whole library. The years are inclusive, and a title with no year at all
/// is in no range.
#[derive(Debug, Default, uniffi::Record)]
pub struct LibraryFilter {
    pub genre: Option<String>,
    pub min_year: Option<u16>,
    pub max_year: Option<u16>,
    /// Only what nothing of has been watched.
    pub unwatched: bool,
    /// Only what has a copy in 4K.
    pub uhd: bool,
}

/// Why a title answered a search. The index searches names, genres, billing and
/// the crew alike, so a screen that only draws posters cannot say why any of
/// them is there; this is what lets it say "with Kristen Stewart" instead.
#[derive(Debug, uniffi::Enum)]
pub enum SearchReason {
    Name,
    /// The billed person, spelled the way the metadata spells them.
    Cast {
        who: String,
    },
    /// Who directed it.
    Director {
        who: String,
    },
    /// Who wrote or scored it.
    Crew {
        who: String,
    },
    Genre {
        what: String,
    },
    /// One of the series' episodes is called this.
    Episode {
        name: String,
        season: Option<u16>,
        episode: Option<u16>,
    },
}

#[derive(Debug, uniffi::Record)]
pub struct SearchHit {
    pub item: TitleItem,
    pub reason: SearchReason,
}

/// The answer to one search.
#[derive(Debug, uniffi::Record)]
pub struct SearchResults {
    pub hits: Vec<SearchHit>,
    /// True when nothing carried every word typed and these carry some of
    /// them. Nothing was corrected: each hit still holds a word as typed, and
    /// the screen says the query was not matched whole.
    pub relaxed: bool,
}

impl From<LibraryFilter> for Filter {
    fn from(f: LibraryFilter) -> Self {
        Filter {
            genre: f.genre,
            min_year: f.min_year,
            max_year: f.max_year,
            unwatched: f.unwatched,
            uhd: f.uhd,
        }
    }
}

/// Where one initial starts on the shelf in title order.
#[derive(Debug, uniffi::Record)]
pub struct LibraryLetter {
    /// "A" to "Z", or "#" for the names that open on anything else.
    pub letter: String,
    pub offset: u32,
}

/// What the filter bar can offer for one kind: the genres it holds and the
/// years it spans. Both None when nothing in it carries a year.
#[derive(Debug, uniffi::Record)]
pub struct LibraryFacets {
    pub genres: Vec<String>,
    pub min_year: Option<u16>,
    pub max_year: Option<u16>,
}

pub(super) fn to_item(r: crate::index::queries::TitleRow) -> TitleItem {
    TitleItem {
        id: r.id,
        kind: match r.kind {
            MediaKind::Movie => ApiMediaKind::Movie,
            MediaKind::Show => ApiMediaKind::Show,
        },
        name: r.name,
        year: r.year,
        file_count: r.file_count,
        first_file_id: r.first_file_id,
    }
}

#[uniffi::export]
impl LexisCore {
    pub fn search(&self, query: String, limit: u32) -> Result<SearchResults, CoreError> {
        let db = self.read_db.lock();
        let found = search_titles(&db, &query, limit)?;
        Ok(SearchResults {
            relaxed: found.relaxed,
            hits: found
                .hits
                .into_iter()
                .map(|hit| SearchHit {
                    item: to_item(hit.title),
                    reason: match hit.reason {
                        MatchField::Name => SearchReason::Name,
                        MatchField::Cast(who) => SearchReason::Cast { who },
                        MatchField::Director(who) => SearchReason::Director { who },
                        MatchField::Crew(who) => SearchReason::Crew { who },
                        MatchField::Genre(what) => SearchReason::Genre { what },
                        MatchField::Episode {
                            name,
                            season,
                            episode,
                        } => SearchReason::Episode {
                            name,
                            season,
                            episode,
                        },
                    },
                })
                .collect(),
        })
    }

    /// One page of the library, in one of three orders, narrowed by a genre
    /// and a year range. Every order is an index walk that stops at the page,
    /// so the twentieth page of a 10 000 title library costs what the first
    /// one did (spec: Index).
    pub fn browse_titles(
        &self,
        kind: ApiMediaKind,
        filter: LibraryFilter,
        sort: LibrarySort,
        offset: u32,
        limit: u32,
    ) -> Result<Vec<TitleItem>, CoreError> {
        let filter = Filter::from(filter);
        let sort = match sort {
            LibrarySort::Name => SortOrder::Name,
            LibrarySort::Year => SortOrder::Year,
            LibrarySort::RecentlyAdded => SortOrder::RecentlyAdded,
        };
        let db = self.read_db.lock();
        let rows = list_titles(&db, kind.into(), &filter, sort, offset, limit)?;
        Ok(rows.into_iter().map(to_item).collect())
    }

    /// How many titles a genre and a year range match. No sort, because a
    /// count has no order: one answer serves all three shelves.
    ///
    /// This is what lets a grid draw a library of any size. It asks once, lays
    /// out that many slots, and reads only the pages it is showing - so what
    /// crosses the bridge is a number and a screenful, never the shelf.
    pub fn count_titles(
        &self,
        kind: ApiMediaKind,
        filter: LibraryFilter,
    ) -> Result<u32, CoreError> {
        let filter = Filter::from(filter);
        let db = self.read_db.lock();
        Ok(count_titles(&db, kind.into(), &filter)?)
    }

    /// The index beside the shelf in title order: where each initial starts,
    /// under the same filter as the grid it jumps.
    pub fn library_letters(
        &self,
        kind: ApiMediaKind,
        filter: LibraryFilter,
    ) -> Result<Vec<LibraryLetter>, CoreError> {
        let filter = Filter::from(filter);
        let db = self.read_db.lock();
        Ok(title_initials(&db, kind.into(), &filter)?
            .into_iter()
            .map(|(letter, offset)| LibraryLetter {
                letter: letter.to_string(),
                offset,
            })
            .collect())
    }

    /// What the filter bar may offer for one kind. Read once when the library
    /// screen mounts: it walks that kind, which is the price of the distinct
    /// values of a comma-joined tag column.
    pub fn library_facets(&self, kind: ApiMediaKind) -> Result<LibraryFacets, CoreError> {
        let db = self.read_db.lock();
        let facets = library_facets(&db, kind.into())?;
        Ok(LibraryFacets {
            genres: facets.genres,
            min_year: facets.min_year,
            max_year: facets.max_year,
        })
    }
}

#[cfg(test)]
impl LexisCore {
    /// The library, paged, in name order with nothing narrowed: `browse_titles`
    /// with an empty filter. Most callers want exactly that.
    pub fn list_titles(
        &self,
        kind: ApiMediaKind,
        offset: u32,
        limit: u32,
    ) -> Result<Vec<TitleItem>, CoreError> {
        self.browse_titles(
            kind,
            LibraryFilter::default(),
            LibrarySort::Name,
            offset,
            limit,
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::api::testing::*;
    use crate::source::local::LocalModule;
    use crate::source::module::SourceModule;
    use std::sync::Arc;

    #[test]
    fn the_library_is_browsed_in_the_order_and_the_slice_the_ui_asked_for() {
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

        let names = |sort: LibrarySort, filter: LibraryFilter| -> Vec<String> {
            core.browse_titles(ApiMediaKind::Movie, filter, sort, 0, 10)
                .unwrap()
                .into_iter()
                .map(|t| t.name)
                .collect()
        };

        assert_eq!(
            names(LibrarySort::Name, LibraryFilter::default()),
            ["Alien", "Blade Runner", "Dune"]
        );
        assert_eq!(
            names(LibrarySort::Year, LibraryFilter::default()),
            ["Dune", "Blade Runner", "Alien"]
        );

        // the plain listing is this call with nothing narrowed
        let listed: Vec<String> = core
            .list_titles(ApiMediaKind::Movie, 0, 10)
            .unwrap()
            .into_iter()
            .map(|t| t.name)
            .collect();
        assert_eq!(listed, ["Alien", "Blade Runner", "Dune"]);

        // a decade narrows to what it holds
        assert_eq!(
            names(
                LibrarySort::Name,
                LibraryFilter {
                    genre: None,
                    min_year: Some(1980),
                    max_year: Some(1989),
                    ..LibraryFilter::default()
                }
            ),
            ["Blade Runner"]
        );

        // a filter naming a genre nothing carries empties the shelf rather
        // than ignoring itself: nothing here has been enriched
        assert!(names(
            LibrarySort::Name,
            LibraryFilter {
                genre: Some("Science-Fiction".to_string()),
                ..LibraryFilter::default()
            }
        )
        .is_empty());

        // and a page past the end is empty, not an error
        assert!(core
            .browse_titles(
                ApiMediaKind::Movie,
                LibraryFilter::default(),
                LibrarySort::Name,
                10,
                10
            )
            .unwrap()
            .is_empty());

        // the count answers for the same shelf, without carrying it: this is
        // what a grid lays its slots out against, so it has to agree with the
        // listing under every filter and to ignore the order entirely
        let counted =
            |filter: LibraryFilter| core.count_titles(ApiMediaKind::Movie, filter).unwrap();
        assert_eq!(counted(LibraryFilter::default()), 3);
        assert_eq!(
            counted(LibraryFilter {
                genre: None,
                min_year: Some(1980),
                max_year: Some(1989),
                ..LibraryFilter::default()
            }),
            1
        );
        assert_eq!(
            counted(LibraryFilter {
                genre: Some("Science-Fiction".to_string()),
                ..LibraryFilter::default()
            }),
            0
        );
        assert_eq!(
            core.count_titles(ApiMediaKind::Show, LibraryFilter::default())
                .unwrap(),
            0
        );
    }

    #[test]
    fn the_filter_bar_is_offered_what_the_library_holds() {
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

        let facets = core.library_facets(ApiMediaKind::Movie).unwrap();
        // nothing has been enriched, so the only vocabulary is the years the
        // filenames carried
        assert!(facets.genres.is_empty());
        assert_eq!(facets.min_year, Some(1979));
        assert_eq!(facets.max_year, Some(2021));

        // and a kind the library holds nothing of offers nothing
        let shows = core.library_facets(ApiMediaKind::Show).unwrap();
        assert!(shows.genres.is_empty());
        assert_eq!(shows.min_year, None);
    }
}
