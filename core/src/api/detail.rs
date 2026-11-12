use super::library::{to_item, ApiMediaKind, TitleItem};
use super::verdicts::ApiVerdict;
use super::{unix_now, CoreError, LexisCore};
use crate::index::db::{FileMedia, Score};
use crate::index::rows::{
    credited_to, same_cast, same_genre, same_saga, similar_titles, PERSON_LIMIT, ROW_LIMIT,
};

/// Everything the detail screen shows beyond what a listing already carries. A
/// title nothing has described yet answers with an empty one: an unmatched file
/// stays visible (spec: Metadata).
#[derive(Debug, uniffi::Record)]
pub struct TitleDetail {
    pub overview: Option<String>,
    pub genres: Vec<String>,
    /// Top billing first, empty when nobody knows. Split the same way as
    /// `genres`: the screen decides how many of them fit, not the core.
    pub cast: Vec<CastCredit>,
    pub has_poster: bool,
    pub tmdb_id: Option<i64>,
    /// True when every file of the title is seen. One unwatched episode keeps
    /// a show unwatched.
    pub watched: bool,
    /// How many times it was played through. A screen says so past one: that
    /// it was seen at all is what the tick already says.
    pub plays: u32,
    /// Whether the viewer put this aside to watch later.
    pub in_watchlist: bool,
    /// The file a "Resume" plays, and where it starts. None and 0.0 when there
    /// is nothing to carry on from: never played, played past the finish mark,
    /// or left in its last seconds. Being seen once is not one of those: a
    /// title started again resumes where the viewer is now.
    pub resume_file_id: Option<i64>,
    pub resume_position_secs: f64,
    /// The runtime that position was measured against, so the UI can draw how
    /// far in it is. 0.0 when nothing reported one.
    pub resume_duration_secs: f64,
    /// How long the title runs, whether or not anyone has played it: the
    /// resume duration above is only ever filled by a file that has. 0.0 when
    /// no source reported one.
    pub runtime_secs: f64,
    /// Who directed it, in the source's own order, empty when nobody knows.
    /// Carried like the billing rather than as bare names: a director is
    /// tagged the same way an actor is and opens the same screen.
    pub directors: Vec<CastCredit>,
    /// Who wrote it and who scored it, carried like the direction above. The
    /// part each of them plays is the job itself, which the screen names.
    pub writers: Vec<CastCredit>,
    pub composers: Vec<CastCredit>,
    /// What the critics made of it, None when nothing measured that or nothing
    /// said who did.
    pub critics: Option<TitleScore>,
    /// What the audience made of it, on the same terms. Never a stand-in for
    /// the one above: they count different people, and a screen that cannot
    /// say which it is drawing should draw neither.
    pub audience: Option<TitleScore>,
    /// The picture and the sound of the copy that would play, None when no
    /// source has described any file of this title.
    pub media: Option<TitleMedia>,
    /// What the viewer said about this title, None when they have not said.
    /// Never drawn as a rejection: "no opinion" and "no" are the two things
    /// this whole signal exists to tell apart.
    pub verdict: Option<ApiVerdict>,
    /// The moods this title stands out towards, as `moods` keys, the most
    /// marked first: at most two, and none for a title no more one mood than
    /// the rest of the library.
    pub tones: Vec<String>,
    /// Every copy of a film, the one that plays by default first; empty for a
    /// series. A screen offers the choice only where there is one.
    pub versions: Vec<TitleVersion>,
}

/// One copy of a film: a cut, a picture and a sound a viewer can pick.
#[derive(Debug, uniffi::Record)]
pub struct TitleVersion {
    pub file_id: i64,
    /// The cut it is ("Extended Edition"), empty for the one cut there is.
    pub edition: String,
    pub size_bytes: u64,
    pub runtime_secs: f64,
    pub media: TitleMedia,
}

/// A score and who measured it, the two things a quantity on a screen needs to
/// be readable at all. The core never carries one without the other.
#[derive(Debug, uniffi::Record)]
pub struct TitleScore {
    /// Out of 10, whatever unit its provider states it in: the wire's own
    /// scale, and the one this index stores.
    pub value: f32,
    /// The provider's own token, the way `TitleMedia` carries Plex's for a
    /// resolution: "imdb", "themoviedb", "rottentomatoes". Naming it in words,
    /// and knowing which of them is a percentage, is the screen's job - a
    /// token it does not know draws nothing.
    pub source: String,
}

impl From<Score> for TitleScore {
    fn from(s: Score) -> Self {
        TitleScore {
            value: s.value,
            source: s.source,
        }
    }
}

/// One name on a title's billing. The name is what opens the person and what
/// their filmography is looked up by; `person_id` is only ever the key to
/// their photograph, and 0 means this library has never seen the name tagged.
#[derive(Debug, uniffi::Record)]
pub struct CastCredit {
    pub person_id: i64,
    pub name: String,
    /// The part played, empty when no source named it and for a director.
    pub character: String,
}

/// One person, and what this library holds of their work.
///
/// Their films here, not their filmography: a media app that lists what the
/// viewer does not own is advertising, and every row on this screen opens.
/// The two lists are the two tag kinds a name is written under, so an actor
/// and a director are the same screen asked a different question - which is
/// also why a name that is both comes back with both filled.
#[derive(Debug, uniffi::Record)]
pub struct PersonDetail {
    pub person_id: i64,
    pub name: String,
    pub acted_in: Vec<TitleItem>,
    pub directed: Vec<TitleItem>,
    /// What they wrote and what they scored: the two other kinds a name is
    /// tagged under, so a crew tile opens a page that holds their work.
    pub wrote: Vec<TitleItem>,
    pub scored: Vec<TitleItem>,
}

/// What a viewer would see and hear. Every field carries "the source did not
/// say" as its own empty value, and a screen draws only what is there: a badge
/// asserts a capability, so one drawn from silence is a lie.
#[derive(Debug, uniffi::Record)]
pub struct TitleMedia {
    /// Plex's own token: "4k", "1080", "720", "sd".
    pub video_resolution: String,
    pub video_codec: String,
    /// "hdr10", "hlg", "dolby_vision", or "" for SDR and for a server that
    /// listed no video track to read it off.
    pub dynamic_range: String,
    pub audio_codec: String,
    /// 0 when the source named none.
    pub audio_channels: u32,
    pub atmos: bool,
    /// ISO 639-1 codes in track order, "mul" for tracks a release names
    /// without listing; empty where the source said nothing.
    pub audio_languages: Vec<String>,
    pub subtitle_languages: Vec<String>,
}

impl From<FileMedia> for TitleMedia {
    fn from(m: FileMedia) -> Self {
        let codes = |list: &str| -> Vec<String> {
            list.split(',')
                .filter(|c| !c.is_empty())
                .map(str::to_string)
                .collect()
        };
        TitleMedia {
            audio_languages: codes(&m.audio_languages),
            subtitle_languages: codes(&m.subtitle_languages),
            video_resolution: m.video_resolution,
            video_codec: m.video_codec,
            dynamic_range: m.dynamic_range,
            audio_codec: m.audio_codec,
            audio_channels: m.audio_channels,
            atmos: m.atmos,
        }
    }
}

/// The one sentence worth saying about a title to this viewer: its strongest
/// piece of evidence, in the order `index::evidence` ranks them. The app
/// writes the sentence.
#[derive(Debug, Clone, PartialEq, uniffi::Enum)]
pub enum TitleEvidence {
    Saga {
        name: String,
        done: u32,
    },
    Director {
        name: String,
        seen: u32,
    },
    Streak {
        leader: String,
        count: u32,
    },
    Crew {
        role: CrewRole,
        name: String,
        loved: String,
    },
    Vein {
        leader: String,
    },
    Actor {
        name: String,
        seen: u32,
    },
    NewArrival,
    Acclaimed {
        score: f32,
    },
    Rewatch {
        plays: u32,
        last_watched_at: i64,
    },
}

/// Which credit a `TitleEvidence::Crew` rests on.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum CrewRole {
    Composer,
    Writer,
}

#[uniffi::export]
impl LexisCore {
    /// Files the photographs a title's Plex server holds of its credits, for
    /// a title TMDB never matched and whose lead has no face: the listing the
    /// sync reads carries names alone. Asked once a launch per title, off the
    /// detail screen only, since it is a request to the server. True when
    /// faces were filed, and the credits are worth reading again.
    pub fn learn_faces(&self, title_id: i64) -> bool {
        if !self.faces_asked.lock().insert(title_id) {
            return false;
        }
        let files = {
            let db = self.read_db.lock();
            let Ok(Some(row)) = db.metadata(title_id) else {
                return false;
            };
            let lead = row.cast_names.split(',').next().unwrap_or("").to_string();
            if row.tmdb_id.is_some() || lead.is_empty() {
                return false;
            }
            if matches!(db.person(&lead), Ok(Some((_, face))) if !face.is_empty()) {
                return false;
            }
            db.title_file_refs(title_id).unwrap_or_default()
        };
        let Some((source_id, rating_key)) = files
            .into_iter()
            .find_map(|f| Some((f.source_id, f.rating_key?)))
        else {
            return false;
        };
        let Some(source) = self.built_source(&source_id) else {
            return false;
        };
        let Some(Ok(faces)) = source.catalogue().map(|c| c.cast_faces(&rating_key)) else {
            return false;
        };
        if faces.is_empty() {
            return false;
        }
        let now = unix_now();
        let db = self.db.lock();
        // one transaction for the dozen names a title credits
        let Ok(tx) = db.conn().unchecked_transaction() else {
            return false;
        };
        for (name, url) in &faces {
            let _ = db.set_person(name, 0, url, now);
        }
        tx.commit().is_ok()
    }

    pub fn title_detail(&self, title_id: i64) -> Result<TitleDetail, CoreError> {
        let (watch, row, media, verdict, in_watchlist, tones, versions) = {
            let db = self.read_db.lock();
            (
                db.title_watch(title_id)?,
                db.metadata(title_id)?,
                db.title_media(title_id)?,
                db.verdict(title_id)?,
                db.is_watchlisted(title_id)?,
                db.title_tones(title_id)?,
                db.title_versions(title_id)?,
            )
        };
        let (
            overview,
            genres,
            cast_names,
            has_poster,
            tmdb_id,
            director_names,
            writer_names,
            composer_names,
            critics,
            audience,
        ) = match row {
            Some(row) => (
                // fr-FR with en-US fallback (spec: Metadata)
                row.overview_fr.or(row.overview_en),
                row.genres
                    .split(',')
                    .filter(|g| !g.is_empty())
                    .map(str::to_string)
                    .collect(),
                // unfiltered: the parts are aligned with it by position
                row.cast_names.split(',').map(str::to_string).collect(),
                row.poster_path.is_some(),
                row.tmdb_id,
                row.director_names
                    .split(',')
                    .filter(|d| !d.is_empty())
                    .map(str::to_string)
                    .collect::<Vec<String>>(),
                row.writer_names
                    .split(',')
                    .filter(|w| !w.is_empty())
                    .map(str::to_string)
                    .collect::<Vec<String>>(),
                row.composer_names
                    .split(',')
                    .filter(|c| !c.is_empty())
                    .map(str::to_string)
                    .collect::<Vec<String>>(),
                row.critics.map(TitleScore::from),
                row.audience.map(TitleScore::from),
            ),
            None => (
                None,
                Vec::new(),
                Vec::new(),
                false,
                None,
                Vec::new(),
                Vec::new(),
                Vec::new(),
                None,
                None,
            ),
        };
        // the id keys a photograph and nothing else: a name this library has
        // never tagged is still a credit that opens, just one with no face.
        // One IN query for every name on the screen, not one per name.
        let (cast, directors, writers, composers) = {
            let db = self.read_db.lock();
            let characters = db.cast_characters(title_id).map_err(CoreError::from)?;
            let mut all: Vec<String> = cast_names
                .iter()
                .filter(|n| !n.is_empty())
                .cloned()
                .collect();
            all.extend(director_names.iter().cloned());
            all.extend(writer_names.iter().cloned());
            all.extend(composer_names.iter().cloned());
            let ids = db.person_ids(&all).map_err(CoreError::from)?;
            let credit = |names: Vec<String>, characters: &str| -> Vec<CastCredit> {
                let mut parts = characters.split(',');
                names
                    .into_iter()
                    .filter_map(|name| {
                        let character = parts.next().unwrap_or("").to_string();
                        (!name.is_empty()).then(|| CastCredit {
                            person_id: ids.get(&name).copied().unwrap_or(0),
                            name,
                            character,
                        })
                    })
                    .collect()
            };
            (
                credit(cast_names, &characters),
                credit(director_names, ""),
                credit(writer_names, ""),
                credit(composer_names, ""),
            )
        };
        Ok(TitleDetail {
            overview,
            genres,
            cast,
            has_poster,
            tmdb_id,
            runtime_secs: media.as_ref().map_or(0.0, |m| m.duration_secs),
            directors,
            writers,
            composers,
            critics,
            audience,
            media: media.map(TitleMedia::from),
            verdict: verdict.map(ApiVerdict::from),
            watched: watch.files > 0 && watch.watched_files == watch.files,
            plays: watch.plays,
            in_watchlist,
            resume_file_id: watch.resume.as_ref().map(|w| w.file_id),
            resume_position_secs: watch.resume.as_ref().map_or(0.0, |w| w.position_secs),
            resume_duration_secs: watch.resume.map_or(0.0, |w| w.duration_secs),
            tones,
            versions: versions
                .into_iter()
                .map(|(file_id, size_bytes, mut m)| TitleVersion {
                    file_id,
                    edition: std::mem::take(&mut m.edition),
                    size_bytes,
                    runtime_secs: m.duration_secs,
                    media: m.into(),
                })
                .collect(),
        })
    }

    /// What to watch after this one: the nearest neighbour nothing has
    /// played, which is what the player offers as the credits roll.
    pub fn after_this(&self, title_id: i64) -> Result<Option<TitleItem>, CoreError> {
        let db = self.read_db.lock();
        // the neighbours are ranked; the first of them nothing has played is
        // the one worth proposing, and a viewer who has seen them all gets no
        // proposal rather than one they have already watched
        for row in similar_titles(&db, title_id, ROW_LIMIT)? {
            if db.title_watch(row.id)?.watched_files == 0 {
                return Ok(Some(to_item(row)));
            }
        }
        Ok(None)
    }

    /// Why this title, for this viewer, in one piece of evidence. None when
    /// the index has nothing to say that the title's own facts do not.
    pub fn title_evidence(&self, title_id: i64) -> Result<Option<TitleEvidence>, CoreError> {
        use crate::index::evidence::{title_evidence, CrewRole as Role, Evidence};
        let db = self.read_db.lock();
        Ok(title_evidence(&db, title_id, unix_now())?.map(|e| match e {
            Evidence::Saga { name, done } => TitleEvidence::Saga { name, done },
            Evidence::Director { name, seen } => TitleEvidence::Director { name, seen },
            Evidence::Streak { leader, count } => TitleEvidence::Streak { leader, count },
            Evidence::Crew { role, name, loved } => TitleEvidence::Crew {
                role: match role {
                    Role::Composer => CrewRole::Composer,
                    Role::Writer => CrewRole::Writer,
                },
                name,
                loved,
            },
            Evidence::Vein { leader } => TitleEvidence::Vein { leader },
            Evidence::Actor { name, seen } => TitleEvidence::Actor { name, seen },
            Evidence::NewArrival => TitleEvidence::NewArrival,
            Evidence::Acclaimed { score } => TitleEvidence::Acclaimed { score },
            Evidence::Rewatch {
                plays,
                last_watched_at,
            } => TitleEvidence::Rewatch {
                plays,
                last_watched_at,
            },
        }))
    }

    /// The neighbours of one title, for its own detail screen: the same
    /// `SIMILAR` query the home row runs, with this title as the seed. Empty
    /// until `link_semantic` has reached this title (spec: Recommendations
    /// runs the sweep over the whole library, not only what was watched), or
    /// when nothing in the library passed the similarity floor.
    pub fn similar_titles(&self, title_id: i64) -> Result<Vec<TitleItem>, CoreError> {
        let db = self.read_db.lock();
        let rows = similar_titles(&db, title_id, ROW_LIMIT)?;
        Ok(rows.into_iter().map(to_item).collect())
    }

    /// Titles sharing the most genres with this one, its own kind only. The
    /// caller already has `kind` off the item on screen, so this asks nothing
    /// of the index beyond the one join `same_genre` runs.
    pub fn same_genre(
        &self,
        title_id: i64,
        kind: ApiMediaKind,
    ) -> Result<Vec<TitleItem>, CoreError> {
        let db = self.read_db.lock();
        let rows = same_genre(&db, title_id, kind.into(), ROW_LIMIT)?;
        Ok(rows.into_iter().map(to_item).collect())
    }

    /// Titles a lead actor of this one recurs in. Worth showing even with one
    /// title in it (spec: this rail earns its place short).
    pub fn same_cast(
        &self,
        title_id: i64,
        kind: ApiMediaKind,
    ) -> Result<Vec<TitleItem>, CoreError> {
        let db = self.read_db.lock();
        let rows = same_cast(&db, title_id, kind.into(), ROW_LIMIT)?;
        Ok(rows.into_iter().map(to_item).collect())
    }

    /// Titles Plex tags into the same collection as this one. Empty for the
    /// ordinary title, which belongs to none.
    pub fn same_saga(
        &self,
        title_id: i64,
        kind: ApiMediaKind,
    ) -> Result<Vec<TitleItem>, CoreError> {
        let db = self.read_db.lock();
        let rows = same_saga(&db, title_id, kind.into(), ROW_LIMIT)?;
        Ok(rows.into_iter().map(to_item).collect())
    }

    /// One person, by the name a credit carries, and what this library holds
    /// of their work. Two indexed lookups and nothing else: no request, no
    /// TMDB id, and the same answer for every name in the library rather than
    /// only for the titles something has matched.
    ///
    /// A name nothing has tagged answers with both lists empty rather than an
    /// error - a person is whoever a credit names, and the screen says so.
    pub fn person_detail(&self, name: String) -> Result<PersonDetail, CoreError> {
        let db = self.read_db.lock();
        Ok(PersonDetail {
            person_id: db.person(&name)?.map_or(0, |(id, _)| id),
            acted_in: credited_to(&db, "cast", &name, PERSON_LIMIT)?
                .into_iter()
                .map(to_item)
                .collect(),
            directed: credited_to(&db, "director", &name, PERSON_LIMIT)?
                .into_iter()
                .map(to_item)
                .collect(),
            wrote: credited_to(&db, "writer", &name, PERSON_LIMIT)?
                .into_iter()
                .map(to_item)
                .collect(),
            scored: credited_to(&db, "composer", &name, PERSON_LIMIT)?
                .into_iter()
                .map(to_item)
                .collect(),
            name,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::api::artwork::ArtworkState;
    use crate::api::testing::*;
    use crate::index::db::MetadataSource;
    use crate::index::MediaKind;
    use crate::source::local::LocalModule;
    use crate::source::module::SourceModule;
    use crate::source::plex::PlexModule;
    use std::sync::Arc;

    #[test]
    fn same_genre_same_cast_and_same_saga_carry_the_kind_to_the_index() {
        use crate::index::db::MetadataRecord;

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
        let titles = core.list_titles(ApiMediaKind::Movie, 0, 10).unwrap();
        let dune = titles.iter().find(|t| t.name == "Dune").unwrap().id;
        let blade = titles.iter().find(|t| t.name == "Blade Runner").unwrap().id;
        let alien = titles.iter().find(|t| t.name == "Alien").unwrap().id;
        {
            let db = core.db.lock();
            for (id, genres, cast, collections) in [
                (dune, "Science-Fiction", "Timothee Chalamet", "Dune Saga"),
                (blade, "Science-Fiction", "Timothee Chalamet", ""),
                (alien, "Horreur", "Sigourney Weaver", ""),
            ] {
                db.upsert_metadata(&MetadataRecord {
                    title_id: id,
                    tmdb_id: None,
                    overview_fr: None,
                    overview_en: None,
                    poster_path: None,
                    backdrop_path: None,
                    genres: genres.to_string(),
                    cast_names: cast.to_string(),
                    collections: collections.to_string(),
                    director_names: String::new(),
                    writer_names: String::new(),
                    composer_names: String::new(),
                    source: MetadataSource::Plex,
                    fetched_at: 1,
                    critics: None,
                    audience: None,
                    release_date: None,
                })
                .unwrap();
            }
        }

        assert_eq!(
            core.same_genre(dune, ApiMediaKind::Movie)
                .unwrap()
                .iter()
                .map(|t| t.name.as_str())
                .collect::<Vec<_>>(),
            ["Blade Runner"]
        );
        assert_eq!(
            core.same_cast(dune, ApiMediaKind::Movie)
                .unwrap()
                .iter()
                .map(|t| t.name.as_str())
                .collect::<Vec<_>>(),
            ["Blade Runner"]
        );
        // nothing shares Dune's own saga: the ordinary case, and no rail
        assert!(core
            .same_saga(dune, ApiMediaKind::Movie)
            .unwrap()
            .is_empty());
        // asked as a show, none of these movies answer: kind really is carried
        assert!(core
            .same_genre(dune, ApiMediaKind::Show)
            .unwrap()
            .is_empty());
    }

    #[test]
    fn title_detail_splits_the_stored_cast_the_way_it_splits_genres() {
        use crate::index::db::MetadataRecord;

        let media = media_dir();
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
        {
            let db = core.db.lock();
            db.upsert_metadata(&MetadataRecord {
                title_id: id,
                tmdb_id: Some(438631),
                overview_fr: None,
                overview_en: None,
                poster_path: None,
                backdrop_path: None,
                genres: "Science-Fiction".into(),
                cast_names: "Timothee Chalamet,Rebecca Ferguson".into(),
                collections: String::new(),
                director_names: String::new(),
                writer_names: String::new(),
                composer_names: String::new(),
                source: MetadataSource::Tmdb,
                fetched_at: 1,
                critics: None,
                audience: None,
                release_date: None,
            })
            .unwrap();
        }
        let detail = core.title_detail(id).unwrap();
        let billed: Vec<&str> = detail.cast.iter().map(|c| c.name.as_str()).collect();
        assert_eq!(billed, ["Timothee Chalamet", "Rebecca Ferguson"]);
        // every billed name is one this library can open, whether or not
        // anything has ever found a photograph of them
        assert!(detail.cast.iter().all(|c| c.person_id > 0));
        // a title nothing has rated, timed or described a file of: the screens
        // draw no score, no runtime and no technical block rather than a zero
        assert!(detail.critics.is_none() && detail.audience.is_none());
        assert_eq!(detail.runtime_secs, 0.0);
        assert!(detail.directors.is_empty());
        assert!(detail.media.is_none());
    }

    /// The whole of a person's page on a library that has matched nothing:
    /// their work is there and complete, and the face is the only part that is
    /// not. That is the state the owner's own library is in, so it is the one
    /// worth asserting.
    #[test]
    fn a_person_opens_with_their_work_and_without_a_face_on_an_unmatched_library() {
        use crate::index::db::MetadataRecord;

        let media = media_dir();
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
        {
            let db = core.db.lock();
            db.upsert_metadata(&MetadataRecord {
                title_id: id,
                // no tmdb_id: nothing here has been matched, so no photograph
                // of anybody can exist
                tmdb_id: None,
                overview_fr: None,
                overview_en: None,
                poster_path: None,
                backdrop_path: None,
                genres: "Science-Fiction".into(),
                cast_names: "Timothee Chalamet,Rebecca Ferguson".into(),
                collections: String::new(),
                director_names: "Denis Villeneuve".into(),
                writer_names: String::new(),
                composer_names: String::new(),
                source: MetadataSource::Plex,
                fetched_at: 1,
                critics: None,
                audience: None,
                release_date: None,
            })
            .unwrap();
        }

        let actor = core.person_detail("Timothee Chalamet".into()).unwrap();
        assert_eq!(actor.name, "Timothee Chalamet");
        assert_eq!(
            actor.acted_in.iter().map(|t| t.id).collect::<Vec<_>>(),
            [id]
        );
        assert!(actor.directed.is_empty());

        // the same screen, asked of a name tagged behind the camera
        let director = core.person_detail("Denis Villeneuve".into()).unwrap();
        assert!(director.acted_in.is_empty());
        assert_eq!(
            director.directed.iter().map(|t| t.id).collect::<Vec<_>>(),
            [id]
        );

        // and nobody has a face: Missing is final and queues nothing, so the
        // rail draws itself without waiting on a fetch that will never come
        assert!(actor.person_id > 0);
        assert!(matches!(
            core.face_now(actor.person_id).unwrap(),
            ArtworkState::Missing
        ));
        assert!(core.artwork.work.lock().wanted.is_empty());

        // a name no credit carries is not an error either
        let nobody = core.person_detail("Nobody At All".into()).unwrap();
        assert_eq!(nobody.person_id, 0);
        assert!(nobody.acted_in.is_empty() && nobody.directed.is_empty());
    }

    #[test]
    fn a_show_tmdb_never_matched_learns_its_faces_from_the_show_once() {
        use crate::plex::fake::{library_reply, FakeServer, Reply};

        const FACE: &str = "https://metadata-static.plex.tv/people/strait.jpg";
        let server = FakeServer::start(|req| match req.url.as_str() {
            // an episode's own credits are its guests: the show is one hop up
            "/library/metadata/201" => Reply::json(
                r#"{"MediaContainer":{"Metadata":[{"type":"episode","grandparentRatingKey":"200",
                    "Role":[{"tag":"A Guest","thumb":"https://metadata-static.plex.tv/people/guest.jpg"}]}]}}"#,
            ),
            "/library/metadata/200" => Reply::json(&format!(
                r#"{{"MediaContainer":{{"Metadata":[{{"type":"show",
                    "Role":[{{"tag":"Steven Strait","thumb":"{FACE}"}},
                            {{"tag":"On The Server","thumb":"/library/metadata/9/thumb"}}]}}]}}}}"#
            )),
            _ => library_reply(req, false),
        });
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

        let show = &core.list_titles(ApiMediaKind::Show, 0, 10).unwrap()[0];
        assert!(core.learn_faces(show.id));
        let face = |name: &str| core.read_db.lock().person(name).unwrap().map(|p| p.1);
        assert_eq!(face("Steven Strait").as_deref(), Some(FACE));
        // a guest of one episode is not the show's cast, and a photograph
        // only the server holds would need its token on the way
        assert_eq!(face("A Guest"), None);
        assert_eq!(face("On The Server"), None);
        let asked = server.requests().len();
        assert!(!core.learn_faces(show.id));
        assert_eq!(server.requests().len(), asked);
    }

    #[test]
    fn a_plex_title_carries_its_runtime_its_score_and_the_shape_of_its_copy() {
        use crate::plex::fake::library;

        let server = library();
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

        let movie = &core.list_titles(ApiMediaKind::Movie, 0, 10).unwrap()[0];
        let detail = core.title_detail(movie.id).unwrap();
        // the runtime stands on its own: `resume_duration_secs` is only ever
        // filled by a file somebody has played
        assert_eq!(detail.runtime_secs, 9000.0);
        let directed_by: Vec<&str> = detail.directors.iter().map(|d| d.name.as_str()).collect();
        assert_eq!(directed_by, ["Denis Villeneuve"]);
        // the two scores reach the screens apart, each carrying who measured
        // it: which of them a screen draws is a decision it can only make with
        // both in hand
        let critics = detail.critics.unwrap();
        assert_eq!((critics.value, critics.source.as_str()), (8.0, "imdb"));
        let audience = detail.audience.unwrap();
        assert_eq!(
            (audience.value, audience.source.as_str()),
            (9.1, "themoviedb")
        );
        let media = detail.media.unwrap();
        assert_eq!(media.video_resolution, "4k");
        assert_eq!(media.dynamic_range, "hdr10");
        assert_eq!(media.audio_channels, 6);
        assert!(media.atmos);
    }

    #[test]
    fn a_plex_title_carries_its_servers_description_and_poster() {
        use crate::plex::fake::library;

        let server = library();
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

        let movie = &core.list_titles(ApiMediaKind::Movie, 0, 10).unwrap()[0];
        let detail = core.title_detail(movie.id).unwrap();
        assert_eq!(detail.overview.as_deref(), Some("Dans un futur lointain."));
        assert_eq!(detail.genres, ["Science-Fiction", "Aventure"]);
        assert!(detail.has_poster);
        assert_eq!(detail.tmdb_id, None);

        // the poster is fetched from the Plex server with the token, once
        let title_id = movie.id;
        let poster = core.poster_file(title_id).unwrap().unwrap();
        assert!(
            poster.contains(&format!("artwork/{title_id}-poster-408_")),
            "{poster}"
        );
        assert!(std::fs::metadata(&poster).unwrap().len() > 0);
        // fetched sized rather than at its original resolution, and the token
        // travels as a header, never inside the logged URL
        let art = server
            .requests()
            .iter()
            .find(|r| r.url.starts_with("/photo/:/transcode"))
            .expect("the poster was fetched sized from the Plex server")
            .clone();
        assert_eq!(art.header("X-Plex-Token"), Some("tok"));
        assert!(art.url.contains("width=408"), "{}", art.url);
        assert!(art.url.contains("height=612"), "{}", art.url);
        assert!(art.url.contains("%2Fthumb%2F"), "{}", art.url);
        assert!(!art.url.contains("tok"), "{}", art.url);
        assert_eq!(core.poster_file(title_id).unwrap(), Some(poster));

        // the show's own type=2 item describes it, poster included - its
        // episodes describe episodes, and never stand in for it
        let show = &core.list_titles(ApiMediaKind::Show, 0, 10).unwrap()[0];
        let show_detail = core.title_detail(show.id).unwrap();
        assert_eq!(
            show_detail.overview.as_deref(),
            Some("L'humanite a colonise le systeme solaire.")
        );
        assert!(show_detail.has_poster);
        let show_poster = core.poster_file(show.id).unwrap().unwrap();
        assert!(
            show_poster.contains(&format!("artwork/{}-poster-408_", show.id)),
            "{show_poster}"
        );

        // a title nothing knows of is empty, not an error
        let none = core.title_detail(999_999).unwrap();
        assert!(!none.has_poster);
    }

    #[test]
    fn similar_titles_reuses_the_home_rows_query_with_this_title_as_the_seed() {
        use crate::index::db::MetadataRecord;

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
        let titles = core.list_titles(ApiMediaKind::Movie, 0, 10).unwrap();
        let dune = titles.iter().find(|t| t.name == "Dune").unwrap().id;
        let blade = titles.iter().find(|t| t.name == "Blade Runner").unwrap().id;
        {
            let db = core.db.lock();
            for (id, tmdb_id) in [(dune, 438631), (blade, 78)] {
                db.upsert_metadata(&MetadataRecord {
                    title_id: id,
                    tmdb_id: Some(tmdb_id),
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
                    fetched_at: 1,
                    critics: None,
                    audience: None,
                    release_date: None,
                })
                .unwrap();
            }
            db.upsert_similar(438631, MediaKind::Movie, &[78]).unwrap();
        }

        let near = core.similar_titles(dune).unwrap();
        assert_eq!(
            near.iter().map(|t| t.name.as_str()).collect::<Vec<_>>(),
            ["Blade Runner"]
        );
    }

    #[test]
    fn similar_titles_is_empty_when_the_library_has_named_no_neighbour() {
        // the common case on a real library: most titles are not among the
        // handful the semantic pass has searched from, and TMDB has named
        // nothing for a title still unmatched
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

        assert!(core.similar_titles(id).unwrap().is_empty());
    }
}
