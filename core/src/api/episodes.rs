use super::{CoreError, LexisCore};
use crate::index::db::{in_progress, EpisodeRow};
use crate::metadata::introdb;

/// What a stretch of a file is, for the player to offer passing it.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum SkipKind {
    Intro,
    Recap,
    Credits,
}

/// One stretch of a file, in seconds from its start. Credits nobody timed the
/// end of run to the file's own end.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct SkipMark {
    pub kind: SkipKind,
    pub start_secs: f64,
    pub end_secs: f64,
}

/// One episode as the continuity queries answer it. `name` is the show's and
/// `title` is this episode's own; a screen draws both, and neither stands in
/// for the other.
#[derive(Debug, PartialEq, uniffi::Record)]
pub struct EpisodeRef {
    pub file_id: i64,
    pub title_id: i64,
    pub name: String,
    /// What this episode is called, empty when no source named it. Empty is
    /// the ordinary answer on a library nothing has described, so a screen
    /// falls back to the numbers rather than drawing a gap.
    pub title: String,
    /// The episode's own sentence, empty under the same rule as `title`.
    pub summary: String,
    pub season: Option<u16>,
    pub episode: Option<u16>,
    /// The year it first aired, None when no source said.
    pub year: Option<u16>,
    /// Sticky: an episode seen once stays seen. This says what the past holds,
    /// it is never a reason to skip the episode.
    pub watched: bool,
    /// Where to start it, under the same rule as `TitleDetail`: 0.0 when it was
    /// never played, when it ran past the finish mark, or when it was left in
    /// its last seconds.
    pub resume_position_secs: f64,
    /// The runtime `resume_position_secs` was measured against. Always paired
    /// with it from this same row, so a screen drawing a fraction of the two
    /// never divides one episode's position by another's duration. 0 on an
    /// episode never played, which is what `runtime_secs` is beside it for.
    pub resume_duration_secs: f64,
    /// How long the episode runs, whatever has been watched of it. This is the
    /// one to label a row with: the pair above is a fraction and nothing else,
    /// and it is empty for exactly the episodes nobody has started. 0 when no
    /// source answered for the file at all.
    pub runtime_secs: f64,
}

fn to_episode(r: EpisodeRow) -> EpisodeRef {
    // the same rule title_watch applies: an episode already finished, or left
    // in its last seconds, starts over rather than resuming into the credits
    let resume = if in_progress(r.position_secs, r.duration_secs) {
        r.position_secs
    } else {
        0.0
    };
    EpisodeRef {
        file_id: r.file_id,
        title_id: r.title_id,
        name: r.name,
        title: r.title,
        summary: r.summary,
        season: r.season,
        episode: r.episode,
        year: r.air_year,
        watched: r.watched,
        resume_position_secs: resume,
        resume_duration_secs: r.duration_secs,
        runtime_secs: r.runtime_secs,
    }
}

#[uniffi::export]
impl LexisCore {
    /// Every episode of a show, in air order, for its own detail screen. A
    /// movie has one file and no reason to call this.
    pub fn episodes(&self, title_id: i64) -> Result<Vec<EpisodeRef>, CoreError> {
        let db = self.read_db.lock();
        Ok(db.episodes(title_id)?.into_iter().map(to_episode).collect())
    }

    /// Where a file's intro, recap and credits run, as TheIntroDB has them
    /// timed, and what it has not timed as the file's own catalogue marked it
    /// (Plex's intro and credits detection): empty where nobody has. The
    /// first ask about a file goes to the network, so a caller runs it off
    /// the main thread; the answer is kept for the process, an empty one
    /// included, and a service that did not answer is asked again next time.
    pub fn skip_marks(&self, file_id: i64) -> Result<Vec<SkipMark>, CoreError> {
        if let Some(known) = self.skip_marks.lock().get(&file_id) {
            return Ok(known.clone());
        }
        let (lookup, file) = {
            let db = self.read_db.lock();
            (db.skip_lookup(file_id)?, db.file_ref(file_id)?)
        };
        let mut marks = match lookup {
            None => Vec::new(),
            Some(lookup) => {
                let agent = self
                    .tmdb_api_agent
                    .get_or_init(crate::metadata::client::TmdbClient::api_agent)
                    .clone();
                let base = self.introdb_base.lock().clone();
                introdb::segments(
                    &agent,
                    &base,
                    lookup.tmdb_id,
                    lookup.kind,
                    lookup.season_episode,
                    lookup.duration_secs,
                )
                .map_err(|msg| CoreError::SourceUnavailable {
                    source_id: "theintrodb".to_string(),
                    msg,
                })?
                .into_iter()
                .map(|segment| SkipMark {
                    kind: match segment.kind {
                        introdb::SegmentKind::Intro => SkipKind::Intro,
                        introdb::SegmentKind::Recap => SkipKind::Recap,
                        introdb::SegmentKind::Credits => SkipKind::Credits,
                    },
                    start_secs: segment.start_secs,
                    end_secs: segment
                        .end_secs
                        .unwrap_or(lookup.duration_secs)
                        .max(segment.start_secs),
                })
                .collect()
            }
        };
        let timed = |kind: SkipKind, marks: &[SkipMark]| marks.iter().any(|m| m.kind == kind);
        if !timed(SkipKind::Intro, &marks) || !timed(SkipKind::Credits, &marks) {
            // a catalogue that did not answer leaves the marks as they are
            let catalogued = file
                .and_then(|f| Some((self.built_source(&f.source_id)?, f.rating_key?)))
                .and_then(|(source, key)| source.catalogue()?.markers(&key).ok())
                .unwrap_or_default();
            for marker in catalogued {
                let kind = if marker.credits {
                    SkipKind::Credits
                } else {
                    SkipKind::Intro
                };
                if !timed(kind, &marks) {
                    marks.push(SkipMark {
                        kind,
                        start_secs: marker.start_secs,
                        end_secs: marker.end_secs,
                    });
                }
            }
        }
        self.skip_marks.lock().insert(file_id, marks.clone());
        Ok(marks)
    }

    /// The episode that follows this file in its show, for the player to offer
    /// when one ends. None for a movie, for the last episode of a show, and for
    /// a file the index no longer holds.
    ///
    /// This is continuity, not a recommendation: it never reaches the home
    /// rows, and the watched flag it carries describes the episode rather than
    /// filtering it out.
    pub fn next_episode(&self, file_id: i64) -> Result<Option<EpisodeRef>, CoreError> {
        let db = self.read_db.lock();
        Ok(db.next_episode(file_id)?.map(to_episode))
    }

    /// The file a title's play button opens, and where it starts: the episode
    /// left running most recently, else the first one never seen, else the
    /// first one at all. A movie answers with its own file.
    pub fn up_next(&self, title_id: i64) -> Result<Option<EpisodeRef>, CoreError> {
        let db = self.read_db.lock();
        Ok(db.up_next(title_id)?.map(to_episode))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::api::artwork::ArtworkState;
    use crate::api::library::ApiMediaKind;
    use crate::api::testing::*;
    use crate::index::db::MetadataSource;
    use crate::source::local::LocalModule;
    use crate::source::module::SourceModule;
    use crate::source::PlaybackState;
    use parking_lot::Mutex;
    use std::sync::Arc;

    /// The list is the viewer's: newest first, a second press idempotent, a
    /// title whose files have all gone left out, and the detail screen
    /// answering for it.
    /// An episode's marks come from TheIntroDB, asked by the show's TMDB id,
    /// the file's season and episode and its length; credits with no end run
    /// to the file's own, and a second ask is answered from memory.
    #[test]
    fn an_episodes_marks_are_asked_once_by_show_season_episode() {
        use crate::index::db::{Db, FileMedia, FileRecord, MetadataRecord};
        use crate::index::MediaKind;

        let server = tiny_http::Server::http("127.0.0.1:0").unwrap();
        let base = format!("http://{}", server.server_addr().to_ip().unwrap());
        let asked = Arc::new(Mutex::new(Vec::<String>::new()));
        let seen = asked.clone();
        std::thread::spawn(move || {
            for request in server.incoming_requests() {
                seen.lock().push(request.url().to_string());
                let body = r#"{"intro":[{"start_ms":30000,"end_ms":90000}],"recap":[],"credits":[{"start_ms":2580000,"end_ms":null}]}"#;
                let _ = request.respond(tiny_http::Response::from_string(body));
            }
        });

        let cache = tempfile::tempdir().unwrap();
        let store = Arc::new(MemStore::default());
        let core = LexisCore::new(cache.path().to_string_lossy().into_owned(), store).unwrap();
        base.clone_into(&mut core.introdb_base.lock());
        let db = Db::open(&cache.path().join("index.sqlite")).unwrap();
        let show = db.upsert_title(MediaKind::Show, "Le Bureau", None).unwrap();
        db.upsert_file(&FileRecord {
            source_id: "s1".into(),
            dir: "Shows".into(),
            path: "Shows/Le Bureau/S02E03.mkv".into(),
            size: 1,
            mtime: 0,
            seen_gen: 1,
            title_id: show,
            season: Some(2),
            episode: Some(3),
            rating_key: None,
            media: FileMedia {
                duration_secs: 2640.0,
                ..FileMedia::default()
            },
        })
        .unwrap();
        db.upsert_metadata(&MetadataRecord {
            title_id: show,
            tmdb_id: Some(62852),
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
        let file = db.title_file_refs(show).unwrap()[0].id;
        drop(db);

        let marks = core.skip_marks(file).unwrap();
        assert_eq!(
            marks,
            [
                SkipMark {
                    kind: SkipKind::Intro,
                    start_secs: 30.0,
                    end_secs: 90.0
                },
                SkipMark {
                    kind: SkipKind::Credits,
                    start_secs: 2580.0,
                    end_secs: 2640.0
                },
            ]
        );
        assert_eq!(core.skip_marks(file).unwrap(), marks);
        let asked = asked.lock();
        assert_eq!(asked.len(), 1);
        for part in [
            "tmdb_id=62852",
            "season=2",
            "episode=3",
            "duration_ms=2640000",
        ] {
            assert!(asked[0].contains(part), "{} lacks {part}", asked[0]);
        }
    }

    /// What TheIntroDB has not timed comes from the server's own intro and
    /// credits detection, for an episode TMDB never matched.
    #[test]
    fn plex_markers_stand_in_where_theintrodb_has_nothing() {
        use crate::plex::fake::{library_reply, FakeServer, Reply};
        use crate::source::plex::PlexModule;

        let server = FakeServer::start(|req| {
            if req.url.starts_with("/library/metadata/201?") {
                return Reply::json(
                    r#"{"MediaContainer":{"Metadata":[{"type":"episode","Marker":[
                        {"type":"intro","startTimeOffset":12000,"endTimeOffset":71500},
                        {"type":"commercial","startTimeOffset":500000,"endTimeOffset":530000},
                        {"type":"credits","startTimeOffset":2940000,"endTimeOffset":3084000}]}]}}"#,
                );
            }
            library_reply(req, false)
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
        let file = core
            .episodes(show.id)
            .unwrap()
            .into_iter()
            .find(|e| e.title == "Dulcinea")
            .unwrap()
            .file_id;

        assert_eq!(
            core.skip_marks(file).unwrap(),
            [
                SkipMark {
                    kind: SkipKind::Intro,
                    start_secs: 12.0,
                    end_secs: 71.5
                },
                SkipMark {
                    kind: SkipKind::Credits,
                    start_secs: 2940.0,
                    end_secs: 3084.0
                },
            ]
        );
    }

    #[test]
    fn the_next_episode_is_what_the_player_advances_to() {
        let media = show_dir();
        let cache = tempfile::tempdir().unwrap();
        let (core, show) = scanned_show(&media, &cache);

        let first = core.up_next(show).unwrap().expect("a show with files");
        assert_eq!(first.name, "Berserk");
        assert_eq!((first.season, first.episode), (Some(1), Some(1)));
        assert_eq!(first.resume_position_secs, 0.0);

        let second = core.next_episode(first.file_id).unwrap().unwrap();
        assert_eq!((second.season, second.episode), (Some(1), Some(2)));
        let third = core.next_episode(second.file_id).unwrap().unwrap();
        assert_eq!((third.season, third.episode), (Some(2), Some(1)));
        // the last episode ends the show, and a file no row has ends nothing
        assert_eq!(core.next_episode(third.file_id).unwrap(), None);
        assert_eq!(core.next_episode(9999).unwrap(), None);
    }

    #[test]
    fn episodes_lists_a_shows_files_in_air_order() {
        let media = show_dir();
        let cache = tempfile::tempdir().unwrap();
        let (core, show) = scanned_show(&media, &cache);

        let all = core.episodes(show).unwrap();
        assert_eq!(
            all.iter()
                .map(|e| (e.season, e.episode))
                .collect::<Vec<_>>(),
            [(Some(1), Some(1)), (Some(1), Some(2)), (Some(2), Some(1))]
        );
        assert!(all.iter().all(|e| e.name == "Berserk"));

        // a movie has one file and nothing here to answer with either way
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
        let dune = core
            .list_titles(ApiMediaKind::Movie, 0, 10)
            .unwrap()
            .into_iter()
            .find(|t| t.name == "Dune")
            .unwrap();
        assert_eq!(core.episodes(dune.id).unwrap().len(), 1);
    }

    #[test]
    fn an_episode_nothing_described_carries_no_words_and_asks_for_no_still() {
        let media = show_dir();
        let cache = tempfile::tempdir().unwrap();
        let (core, show) = scanned_show(&media, &cache);

        // a directory scanner opens nothing and names nothing, which is the
        // ordinary state of this library: the screen composes a label from the
        // numbers and draws its own plate rather than waiting on a fetch
        let all = core.episodes(show).unwrap();
        assert!(all
            .iter()
            .all(|e| e.title.is_empty() && e.summary.is_empty()));
        for episode in &all {
            assert!(matches!(
                core.still_now(episode.file_id).unwrap(),
                ArtworkState::Missing
            ));
        }
        assert!(core.artwork.work.lock().wanted.is_empty());
    }

    #[test]
    fn up_next_follows_the_watch_state_and_never_skips_forward() {
        let media = show_dir();
        let cache = tempfile::tempdir().unwrap();
        let (core, show) = scanned_show(&media, &cache);
        let first = core.up_next(show).unwrap().unwrap();
        let second = core.next_episode(first.file_id).unwrap().unwrap();

        // the 90 percent rule finishes the first episode
        core.report_playback(first.file_id, 950.0, 1000.0, PlaybackState::Playing)
            .unwrap();
        assert_eq!(core.up_next(show).unwrap().unwrap().file_id, second.file_id);
        // and the episode list offers no resume into what it finished: the
        // position outlives the report that crossed the mark
        let listed = core.episodes(show).unwrap();
        let done = listed
            .iter()
            .find(|e| e.file_id == first.file_id)
            .expect("the first episode is listed");
        assert_eq!(done.resume_position_secs, 0.0);
        assert!(done.watched);

        // and one left running is what a play button opens, where it stopped
        core.report_playback(second.file_id, 300.0, 1000.0, PlaybackState::Playing)
            .unwrap();
        let running = core.up_next(show).unwrap().unwrap();
        assert_eq!(running.file_id, second.file_id);
        assert_eq!(running.resume_position_secs, 300.0);
        assert_eq!(running.resume_duration_secs, 1000.0);

        // an episode left in its last seconds starts over rather than resuming
        // into the credits, the same rule title_detail applies
        core.report_playback(second.file_id, 980.0, 1000.0, PlaybackState::Playing)
            .unwrap();
        let tail = core.up_next(show).unwrap().unwrap();
        assert_eq!(tail.resume_position_secs, 0.0);

        // marked through by hand, the show offers its first episode again
        core.mark_watched(show, true).unwrap();
        let again = core.up_next(show).unwrap().unwrap();
        assert_eq!(again.file_id, first.file_id);
        assert!(again.watched);
        // and continuity is unchanged by any of it
        assert_eq!(
            core.next_episode(first.file_id).unwrap().unwrap().file_id,
            second.file_id
        );
    }

    #[test]
    fn a_near_finish_resume_is_clamped_to_zero_without_being_marked_watched() {
        // a duration short enough that the last 30 seconds fall below the 90
        // percent mark: the tail clamp and the watched threshold are two
        // different rules, and this is the only place they disagree
        let media = show_dir();
        let cache = tempfile::tempdir().unwrap();
        let (core, show) = scanned_show(&media, &cache);
        let first = core.up_next(show).unwrap().unwrap();

        core.report_playback(first.file_id, 80.0, 100.0, PlaybackState::Playing)
            .unwrap();
        let running = core.up_next(show).unwrap().unwrap();
        assert_eq!(running.file_id, first.file_id);
        assert!(!running.watched);
        assert_eq!(running.resume_position_secs, 0.0);
    }

    #[test]
    fn a_movie_is_its_own_up_next_and_has_nothing_after_it() {
        let media = media_dir();
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
        let dune = core.list_titles(ApiMediaKind::Movie, 0, 10).unwrap();
        let up = core.up_next(dune[0].id).unwrap().unwrap();
        assert_eq!(up.name, "Dune");
        assert_eq!((up.season, up.episode), (None, None));
        assert_eq!(core.next_episode(up.file_id).unwrap(), None);
    }
}
