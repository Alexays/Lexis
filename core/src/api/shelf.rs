//! What the Top Shelf extension reads.
//!
//! The extension is another process with a budget of a second or so and no way
//! to ask the running app anything. It does not open the index: the index is a
//! WAL database this app may be writing to, in a directory tvOS may purge, and
//! a reader that opened it would have to create the `-shm` the app's own
//! connection owns, know a schema that migrates, and finish inside that budget.
//! Instead the app leaves a snapshot in a container both processes can see,
//! and the extension reads that and nothing else.
//!
//! The snapshot is written from the same two calls the home screen makes,
//! the evening's trio and the queue under it, in the same order, so the shelf
//! cannot drift from the screen. Nothing here decides what "still watching"
//! means.

use super::library::{to_item, ApiMediaKind, TitleItem};
use super::{unix_now, CoreError, LexisCore};
use crate::index::queries::{title_by_key, up_next, QueueRow};
use crate::source::ArtKind;
use serde::Serialize;
use std::collections::HashSet;
use std::path::PathBuf;

/// The shape `shelf.json` is written in. An extension that finds another
/// number draws nothing: the two ship in one bundle and so always agree,
/// except across an update, where last version's file is still on disk until
/// this one replaces it, and a shelf read from a shape this build did not
/// write would be wrong rather than absent.
const SNAPSHOT_VERSION: u32 = 2;

/// How many titles one section carries. The shelf shows about six at a time
/// and a viewer holding right past eight of them has stopped reading it.
const SECTION_LIMIT: usize = 8;

/// The names the sections are drawn under, in the viewer's language. The core
/// invents no prose: these are the same two lines out of the app's own
/// catalogs that title the matching parts of the home screen.
#[derive(Debug, uniffi::Record)]
pub struct ShelfTitles {
    pub tonight: String,
    pub up_next: String,
}

#[derive(Serialize)]
struct Snapshot {
    version: u32,
    sections: Vec<Section>,
}

#[derive(Serialize)]
struct Section {
    title: String,
    items: Vec<Item>,
}

/// One tile. It names its title the way `title_by_key` looks one up - never by
/// `titles.id`, which a purged and rescanned index reissues from the start, so
/// a shelf tvOS is still drawing from before a purge would otherwise send the
/// viewer into whatever film inherited the number.
#[derive(Serialize)]
struct Item {
    kind: String,
    name: String,
    /// 0 for a title nothing dated, the encoding the column itself uses.
    year: u16,
    /// Relative to the directory the snapshot sits in: the two processes reach
    /// the same container by different absolute paths, and only one of them
    /// wrote this.
    image: String,
    /// How far into the title the viewer is, in 0..1, for the bar tvOS draws
    /// across the bottom of a tile. 0 when there is nothing to carry on from -
    /// `title_watch` applies `in_progress`, so a title finished or left in its
    /// credits reports nothing here, exactly as the detail screen does.
    progress: f64,
}

#[uniffi::export]
impl LexisCore {
    /// Writes the shelf into `dir`, and returns how many titles it holds.
    ///
    /// Everything the extension needs ends up under `dir`: `shelf.json`, and
    /// beside it a copy of each image it names. The copies are what makes the
    /// artwork readable at all - the cache lives in this app's own container,
    /// which no extension can open - and there are never more of them than the
    /// shelf shows, because every write prunes the ones it did not name.
    ///
    /// A title whose art has not been fetched yet is left out rather than
    /// drawn as an empty tile, and a section left with nothing that way is
    /// left out too. Writing no sections at all is the deliberate answer: the
    /// extension then offers no content and tvOS falls back to the static
    /// image in the asset catalog, which is what an app with nothing to say
    /// should show.
    pub fn write_shelf_snapshot(
        &self,
        dir: String,
        titles: ShelfTitles,
        tz_offset_secs: i32,
    ) -> Result<u32, CoreError> {
        let now = unix_now();
        let sources: Vec<(&str, Vec<QueueRow>)> = {
            let db = self.read_db.lock();
            // composed only: the shelf is not the viewer looking at the trio,
            // and this connection could not record it anyway
            let ambient = self.ambient_at(now);
            let trio = crate::index::tonight::compose_tonight(&db, now, tz_offset_secs, ambient)?
                .map(|(t, _)| {
                    t.cards
                        .into_iter()
                        .map(|c| QueueRow {
                            title: c.title,
                            resume_file_id: None,
                            position_secs: 0.0,
                            duration_secs: 0.0,
                        })
                        .collect()
                })
                .unwrap_or_default();
            vec![
                (titles.tonight.as_str(), trio),
                (
                    titles.up_next.as_str(),
                    up_next(&db, SECTION_LIMIT as u32, now)?,
                ),
            ]
        };

        let dir = PathBuf::from(dir);
        let art_dir = dir.join("artwork");
        std::fs::create_dir_all(&art_dir).map_err(storage)?;

        let mut sections = Vec::new();
        let mut named = HashSet::new();
        for (title, rows) in sources {
            // one watch summary query for the whole section, not one per tile:
            // the tiles are known before any of them is drawn
            let wanted: Vec<i64> = rows
                .iter()
                .take(SECTION_LIMIT)
                .map(|q| q.title.id)
                .collect();
            // a shelf snapshot is a big lot too: heavy connection, so the
            // interactive reads never wait for it
            let watch = self.heavy_db.lock().title_watch_many(&wanted)?;
            let mut items = Vec::new();
            for item in rows.into_iter().take(SECTION_LIMIT).map(|q| q.title) {
                let Some(src) = self.artwork_on_disk(item.id, ArtKind::Thumb) else {
                    continue;
                };
                let Some(name) = src.file_name().and_then(|n| n.to_str()) else {
                    continue;
                };
                let dest = art_dir.join(name);
                // the name carries the title, the slot and the size, so a file
                // already here under it is the same image: re-copying it every
                // time the app goes to the background would be megabytes of
                // writes for a shelf that did not change
                if !dest.exists() {
                    std::fs::copy(&src, &dest).map_err(storage)?;
                }
                let resume = watch.get(&item.id).and_then(|w| w.resume.as_ref());
                named.insert(name.to_string());
                items.push(Item {
                    kind: item.kind.as_str().to_string(),
                    name: item.name,
                    year: item.year.unwrap_or(0),
                    image: format!("artwork/{name}"),
                    progress: resume
                        .filter(|w| w.duration_secs > 0.0)
                        .map_or(0.0, |w| (w.position_secs / w.duration_secs).clamp(0.0, 1.0)),
                });
            }
            if !items.is_empty() {
                sections.push(Section {
                    title: title.to_string(),
                    items,
                });
            }
        }

        // what the shelf stopped naming stops being stored: this directory is
        // a copy of a cache that already has an eviction policy of its own,
        // and nothing here should outlive the one write that put it there
        if let Ok(entries) = std::fs::read_dir(&art_dir) {
            for entry in entries.flatten() {
                let keep = entry
                    .file_name()
                    .to_str()
                    .is_some_and(|name| named.contains(name));
                if !keep {
                    let _ = std::fs::remove_file(entry.path());
                }
            }
        }

        let count = sections.iter().map(|s| s.items.len()).sum::<usize>() as u32;
        let json = serde_json::to_vec(&Snapshot {
            version: SNAPSHOT_VERSION,
            sections,
        })
        .map_err(storage)?;
        // written aside and renamed: the extension may be reading while this
        // runs, and a half-written shelf must never be a shelf it can parse
        let part = dir.join("shelf.json.part");
        std::fs::write(&part, &json).map_err(storage)?;
        std::fs::rename(&part, dir.join("shelf.json")).map_err(|e| {
            let _ = std::fs::remove_file(&part);
            storage(e)
        })?;
        Ok(count)
    }

    /// The title a shelf tile names, for a caller holding nothing but the
    /// tile: a press on the Top Shelf launches the app cold, and it has to
    /// open that title's screen with only what the snapshot carried.
    ///
    /// None when nothing in the index carries that key any more, which is the
    /// honest answer for a tile drawn from a shelf older than the library
    /// under it: the app opens on its own home screen rather than on some
    /// other film. `year` is 0 for a title nothing dated.
    pub fn title_by_shelf_key(
        &self,
        kind: ApiMediaKind,
        name: String,
        year: u16,
    ) -> Result<Option<TitleItem>, CoreError> {
        let db = self.read_db.lock();
        Ok(title_by_key(&db, kind.into(), &name, year)?.map(to_item))
    }
}

fn storage(e: impl std::fmt::Display) -> CoreError {
    CoreError::Storage { msg: e.to_string() }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::api::library::ApiMediaKind;
    use crate::api::testing::MemStore;
    use crate::index::db::{MetadataRecord, MetadataSource};
    use crate::source::local::LocalModule;
    use crate::source::module::SourceModule;
    use crate::source::PlaybackState;
    use std::collections::BTreeMap;
    use std::fs;
    use std::sync::Arc;

    fn media_dir() -> tempfile::TempDir {
        let tmp = tempfile::tempdir().unwrap();
        fs::create_dir_all(tmp.path().join("Movies")).unwrap();
        for name in [
            "Alien (1979).mkv",
            "Blade Runner (1982).mkv",
            "Dune (2021).mkv",
        ] {
            fs::write(tmp.path().join("Movies").join(name), b"x").unwrap();
        }
        tmp
    }

    fn scanned(media: &tempfile::TempDir, cache: &tempfile::TempDir) -> Arc<LexisCore> {
        let core = LexisCore::new(
            cache.path().to_string_lossy().into_owned(),
            Arc::new(MemStore::default()),
        )
        .unwrap();
        core.add_or_replace(
            LocalModule.id(),
            "local1".into(),
            BTreeMap::from([(
                "root".to_string(),
                media.path().to_string_lossy().into_owned(),
            )]),
        )
        .unwrap();
        core.scan_all(false).unwrap();
        core
    }

    /// Describes `title_id` from TMDB and puts the wide image the shelf asks
    /// for on disk, which is what `artwork_on_disk` answers from.
    /// The name the cache keeps the backdrop `with_artwork` stores under.
    fn thumb_name(title_id: i64) -> String {
        format!(
            "{title_id}-backdrop-{}.jpg",
            super::super::artwork::sized("w780", "/b.jpg")
        )
    }

    fn with_artwork(core: &LexisCore, cache: &tempfile::TempDir, title_id: i64) {
        core.db
            .lock()
            .upsert_metadata(&MetadataRecord {
                title_id,
                tmdb_id: Some(1000 + title_id),
                overview_fr: None,
                overview_en: None,
                poster_path: Some("/p.jpg".into()),
                backdrop_path: Some("/b.jpg".into()),
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
        let dir = cache.path().join("artwork");
        fs::create_dir_all(&dir).unwrap();
        fs::write(dir.join(thumb_name(title_id)), b"jpegbytes").unwrap();
    }

    /// Puts a title on the shelf the only way there is now: the queue. The
    /// shelf carries the evening and what is left running, and a library
    /// nobody has opened has neither.
    fn left_running(core: &LexisCore, item: &TitleItem) {
        core.report_playback(
            item.first_file_id.unwrap(),
            600.0,
            6000.0,
            PlaybackState::Playing,
        )
        .unwrap();
    }

    fn titles() -> ShelfTitles {
        ShelfTitles {
            tonight: "Ce soir".into(),
            up_next: "A suivre".into(),
        }
    }

    fn read(dir: &tempfile::TempDir) -> serde_json::Value {
        serde_json::from_slice(&fs::read(dir.path().join("shelf.json")).unwrap()).unwrap()
    }

    /// The shelf is the home screen itself: the evening's trio, then the
    /// queue under it, in that order.
    #[test]
    fn the_shelf_carries_what_the_home_screen_puts_first() {
        let media = media_dir();
        let cache = tempfile::tempdir().unwrap();
        let out = tempfile::tempdir().unwrap();
        let core = scanned(&media, &cache);

        let films = core.list_titles(ApiMediaKind::Movie, 0, 10).unwrap();
        for film in &films {
            with_artwork(&core, &cache, film.id);
        }
        let running = films.iter().find(|f| f.name == "Dune").unwrap();
        core.report_playback(
            running.first_file_id.unwrap(),
            600.0,
            6000.0,
            PlaybackState::Playing,
        )
        .unwrap();

        let count = core
            .write_shelf_snapshot(out.path().to_string_lossy().into_owned(), titles(), 0)
            .unwrap();
        assert!(count > 0);

        let shelf = read(&out);
        assert_eq!(shelf["version"], 2);
        let sections = shelf["sections"].as_array().unwrap();
        assert_eq!(sections[0]["title"], "A suivre");
        let first = &sections[0]["items"].as_array().unwrap()[0];
        assert_eq!(first["name"], "Dune");
        assert_eq!(first["year"], 2021);
        assert_eq!(first["kind"], "movie");
        // the bar tvOS draws is where the viewer actually stopped
        assert_eq!(first["progress"], 0.1);
        assert_eq!(
            first["image"],
            format!("artwork/{}", thumb_name(running.id))
        );

        // the image the shelf names is beside it, readable without the cache
        // this process alone can open
        let copied = out.path().join("artwork").join(thumb_name(running.id));
        assert_eq!(fs::read(&copied).unwrap(), b"jpegbytes");

        // and what is on the shelf is a title the app can open from the tile
        let item = core
            .title_by_shelf_key(ApiMediaKind::Movie, "Dune".into(), 2021)
            .unwrap()
            .unwrap();
        assert_eq!(item.id, running.id);
    }

    /// A title whose art has not been fetched is not drawn as an empty tile,
    /// and a shelf that can draw nothing at all writes no sections rather
    /// than sections of nothing - which is what makes tvOS keep the static
    /// image instead.
    #[test]
    fn a_title_with_no_artwork_yet_is_left_off_the_shelf() {
        let media = media_dir();
        let cache = tempfile::tempdir().unwrap();
        let out = tempfile::tempdir().unwrap();
        let core = scanned(&media, &cache);

        let films = core.list_titles(ApiMediaKind::Movie, 0, 10).unwrap();
        for film in &films {
            left_running(&core, film);
        }
        let count = core
            .write_shelf_snapshot(out.path().to_string_lossy().into_owned(), titles(), 0)
            .unwrap();
        assert_eq!(count, 0);
        assert_eq!(read(&out)["sections"].as_array().unwrap().len(), 0);

        // one of the three gets its image, and it is the only one on the shelf
        with_artwork(&core, &cache, films[0].id);
        let count = core
            .write_shelf_snapshot(out.path().to_string_lossy().into_owned(), titles(), 0)
            .unwrap();
        assert_eq!(count, 1);
        let shelf = read(&out);
        let items = shelf["sections"][0]["items"].as_array().unwrap();
        assert_eq!(items.len(), 1);
        assert_eq!(items[0]["name"], films[0].name.as_str());
    }

    /// tvOS keeps drawing the last shelf it was given while the app is not
    /// running, so a tile can outlive the index it was written from. A cache
    /// purge and a rescan reissue `titles.id` from the start, which is exactly
    /// when an id kept on a shelf would come back naming a different film -
    /// so the tile does not carry one.
    #[test]
    fn a_tile_that_outlived_a_rescan_opens_its_own_title_or_nothing() {
        let media = media_dir();
        let cache = tempfile::tempdir().unwrap();
        let out = tempfile::tempdir().unwrap();
        let core = scanned(&media, &cache);

        let before = core.list_titles(ApiMediaKind::Movie, 0, 10).unwrap();
        for film in &before {
            with_artwork(&core, &cache, film.id);
            left_running(&core, film);
        }
        core.write_shelf_snapshot(out.path().to_string_lossy().into_owned(), titles(), 0)
            .unwrap();
        let shelf = read(&out);
        let tile = &shelf["sections"][0]["items"][0];
        let name = tile["name"].as_str().unwrap().to_string();
        let year = tile["year"].as_u64().unwrap() as u16;

        // the purge tvOS may make of the cache directory, and the scan that
        // rebuilds it: every title is numbered again from scratch
        drop(core);
        std::fs::remove_dir_all(cache.path()).unwrap();
        let core = scanned(&media, &cache);
        let after = core.list_titles(ApiMediaKind::Movie, 0, 10).unwrap();
        assert_eq!(
            after.iter().map(|t| &t.name).collect::<Vec<_>>(),
            before.iter().map(|t| &t.name).collect::<Vec<_>>()
        );

        // the tile still opens the film it was drawn for
        let opened = core
            .title_by_shelf_key(ApiMediaKind::Movie, name.clone(), year)
            .unwrap()
            .expect("the title is still in the library");
        assert_eq!(opened.name, name);

        // and one whose title the rescan dropped opens nothing at all
        assert!(core
            .title_by_shelf_key(ApiMediaKind::Movie, "Gone Since".into(), 1999)
            .unwrap()
            .is_none());
    }

    /// The copies are a copy of a cache, not a second cache: a write keeps
    /// only the images the shelf it just wrote names.
    #[test]
    fn a_write_prunes_the_images_it_no_longer_names() {
        let media = media_dir();
        let cache = tempfile::tempdir().unwrap();
        let out = tempfile::tempdir().unwrap();
        let core = scanned(&media, &cache);

        let films = core.list_titles(ApiMediaKind::Movie, 0, 10).unwrap();
        with_artwork(&core, &cache, films[0].id);
        left_running(&core, &films[0]);
        core.write_shelf_snapshot(out.path().to_string_lossy().into_owned(), titles(), 0)
            .unwrap();

        let stale = out.path().join("artwork").join("4242-backdrop-w780.jpg");
        fs::write(&stale, b"last week").unwrap();
        core.write_shelf_snapshot(out.path().to_string_lossy().into_owned(), titles(), 0)
            .unwrap();

        assert!(!stale.exists());
        assert!(out
            .path()
            .join("artwork")
            .join(thumb_name(films[0].id))
            .exists());
    }
}
