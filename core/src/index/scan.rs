use super::db::{Db, FileMedia, FileRecord, IndexError};
use super::MediaKind;
use crate::naming::parse_filename;
use crate::source::{Source, SourceError};
use std::time::{SystemTime, UNIX_EPOCH};

#[derive(Debug, thiserror::Error)]
pub enum ScanError {
    #[error("source error: {0}")]
    Source(#[from] SourceError),
    #[error("index error: {0}")]
    Index(#[from] IndexError),
}

#[derive(Debug, Default, Clone, PartialEq, Eq)]
pub struct ScanStats {
    pub files_seen: u32,
    pub files_upserted: u32,
    pub files_removed: u32,
    pub dirs_skipped: u32,
}

const VIDEO_EXTS: &[&str] = &["mkv", "mp4", "m4v", "avi", "mov", "ts", "m2ts", "wmv"];

fn is_video(name: &str) -> bool {
    name.rsplit_once('.')
        .map(|(_, ext)| VIDEO_EXTS.contains(&ext.to_ascii_lowercase().as_str()))
        .unwrap_or(false)
}

/// A directory naming a season rather than a show: "Season 3", "Saison 3",
/// "S03", and the specials every convention files as season zero.
fn is_season_dir(name: &str) -> bool {
    let lower = name.to_ascii_lowercase();
    if lower == "specials" {
        return true;
    }
    let Some(rest) = lower
        .strip_prefix("season")
        .or_else(|| lower.strip_prefix("saison"))
        .or_else(|| lower.strip_prefix('s'))
    else {
        return false;
    };
    let number = rest.trim_matches([' ', '.', '_', '-']);
    !number.is_empty() && number.bytes().all(|b| b.is_ascii_digit())
}

/// The directory a file carrying no title of its own is named after: the
/// nearest one above it that names something other than a season, so an
/// episode under "The Expanse/Season 3" is the show's and not the season's.
/// None for a file at the root, which has no directory to be named after.
fn show_dir(path: &str) -> Option<&str> {
    let mut rest = path;
    loop {
        let (parent, name) = rest.rsplit_once('/').unwrap_or(("", rest));
        if name.is_empty() {
            return None;
        }
        // a season directory at the root has no show above it to climb to
        if parent.is_empty() || !is_season_dir(name) {
            return Some(name);
        }
        rest = parent;
    }
}

struct DirTask {
    path: String,
    mtime: i64,
}

/// One transaction per scan: a partial walk must not leave a half-indexed
/// library, and per-upsert commits would fsync thousands of times.
/// `full` asks the source for everything it holds, whatever its own stamps
/// say a walk would find. What a viewer pressing Scan gets: the automatic
/// sweep is the one allowed to take a directory's word that nothing under it
/// changed, and a viewer who presses Scan is saying they do not believe it.
pub fn scan(db: &Db, source: &dyn Source, full: bool) -> Result<ScanStats, ScanError> {
    db.conn()
        .execute_batch("BEGIN IMMEDIATE")
        .map_err(IndexError::from)?;
    let result = walk(db, source, full).and_then(|stats| {
        db.conn()
            .execute_batch("COMMIT")
            .map_err(IndexError::from)?;
        Ok(stats)
    });
    // a COMMIT that fails leaves the transaction open, and every later scan
    // would then fail to BEGIN on the same connection
    if result.is_err() {
        let _ = db.conn().execute_batch("ROLLBACK");
    }
    result
}

fn walk(db: &Db, source: &dyn Source, full: bool) -> Result<ScanStats, ScanError> {
    let sid = source.id().to_string();
    let gen = db.next_scan_gen(&sid)?;
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0);
    let mut stats = ScanStats::default();
    // the root has no parent listing to give us an mtime; -1 forces processing
    let mut stack = vec![DirTask {
        path: String::new(),
        mtime: -1,
    }];

    while let Some(dir) = stack.pop() {
        // mtimes have second granularity, so one within the last 2 seconds may
        // still gain siblings without changing: never trust it, and never record
        // it either, or a write landing later in the same second is skipped forever
        let settled = dir.mtime >= 0 && dir.mtime + 2 < now;
        // a dir whose mtime matches the stored one has the same direct children
        let unchanged = !full && settled && db.dir_mtime(&sid, &dir.path)? == Some(dir.mtime);

        // listing always happens (subdirs may have changed deeper down);
        // incremental only skips the parse-and-write work
        let entries = match source.list(&dir.path) {
            Ok(entries) => entries,
            // a subtree can be moved or deleted mid-scan; only a missing root is fatal
            Err(SourceError::NotFound(_)) if !dir.path.is_empty() => continue,
            Err(e) => return Err(e.into()),
        };
        for e in entries {
            if e.is_dir {
                stack.push(DirTask {
                    path: e.path,
                    mtime: e.mtime,
                });
                continue;
            }
            if !is_video(&e.name) {
                continue;
            }
            stats.files_seen += 1;
            if unchanged {
                continue;
            }
            let parsed = parse_filename(&e.name);
            let (kind, season, episode) = match parsed.episode {
                Some((s, ep)) => (MediaKind::Show, Some(s), Some(ep)),
                None => (MediaKind::Movie, None, None),
            };
            // a name carrying no title ("S01E01.mkv") would otherwise collapse
            // every such file across shows into one empty title
            let title = if parsed.title.is_empty() {
                show_dir(&dir.path).unwrap_or(&sid)
            } else {
                &parsed.title
            };
            let title_id = db.upsert_title(kind, title, parsed.year)?;
            db.upsert_file(&FileRecord {
                source_id: sid.clone(),
                dir: dir.path.clone(),
                path: e.path,
                size: e.size,
                mtime: e.mtime,
                seen_gen: gen,
                title_id,
                season,
                episode,
                rating_key: None,
                media: FileMedia {
                    audio_languages: parsed.audio_languages,
                    subtitle_languages: parsed.subtitle_languages,
                    ..FileMedia::default()
                },
            })?;
            stats.files_upserted += 1;
        }

        if unchanged {
            db.touch_dir_files(&sid, &dir.path, gen)?;
            stats.dirs_skipped += 1;
        } else if settled {
            db.set_dir_mtime(&sid, &dir.path, dir.mtime)?;
        }
    }

    // a root that lists as empty reads the same, from here, whether the
    // library was genuinely cleared out or the mount behind it vanished
    // without ever raising an error: only the first is safe to sweep, so a
    // source that held files before must show at least one again before its
    // silence is trusted
    if stats.files_seen == 0 && db.has_files(&sid)? {
        return Err(SourceError::Refused(
            "this source came back empty; the cached files are kept".to_string(),
        )
        .into());
    }

    stats.files_removed = db.delete_files_not_seen(&sid, gen)?;
    db.prune_orphan_titles()?;
    Ok(stats)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::index::db::Db;
    use crate::source::local::LocalDirSource;
    use filetime::FileTime;
    use std::fs;
    use std::path::Path;

    fn set_mtime(p: &Path, secs: i64) {
        filetime::set_file_mtime(p, FileTime::from_unix_time(secs, 0)).unwrap();
    }

    fn fixture() -> (tempfile::TempDir, LocalDirSource, Db) {
        let tmp = tempfile::tempdir().unwrap();
        let root = tmp.path().to_path_buf();
        fs::create_dir_all(root.join("Movies")).unwrap();
        fs::create_dir_all(root.join("Shows/The Expanse/Season 3")).unwrap();
        fs::write(root.join("Movies/Dune (2021) 2160p.mkv"), b"x").unwrap();
        fs::write(root.join("Movies/cover.jpg"), b"x").unwrap();
        fs::write(
            root.join("Shows/The Expanse/Season 3/The.Expanse.S03E05.mkv"),
            b"x",
        )
        .unwrap();
        set_mtime(&root.join("Movies"), 1000);
        set_mtime(&root.join("Shows"), 1000);
        set_mtime(&root.join("Shows/The Expanse"), 1000);
        set_mtime(&root.join("Shows/The Expanse/Season 3"), 1000);
        let db = Db::open_in_memory().unwrap();
        (tmp, LocalDirSource::new("s1", root), db)
    }

    /// A source whose listing of one subdir fails, as if it changed mid-scan.
    struct FlakyDirSource {
        inner: LocalDirSource,
        dir: &'static str,
        error: fn(&str) -> SourceError,
    }

    impl Source for FlakyDirSource {
        fn id(&self) -> &str {
            self.inner.id()
        }

        fn list(&self, dir_path: &str) -> Result<Vec<crate::source::Entry>, SourceError> {
            if dir_path == self.dir {
                return Err((self.error)(dir_path));
            }
            self.inner.list(dir_path)
        }

        fn open(&self, file_path: &str) -> Result<Box<dyn crate::source::ReadSeek>, SourceError> {
            self.inner.open(file_path)
        }
    }

    #[test]
    fn a_failed_scan_leaves_the_index_untouched() {
        let (_tmp, src, db) = fixture();
        // Movies is walked last, so the show is already written when this fails
        let flaky = FlakyDirSource {
            inner: src,
            dir: "Movies",
            error: |_| SourceError::Io(std::io::Error::other("disk gone")),
        };
        assert!(scan(&db, &flaky, false).is_err());
        let titles: i64 = db
            .conn()
            .query_row("SELECT COUNT(*) FROM titles", [], |r| r.get(0))
            .unwrap();
        assert_eq!(titles, 0);
    }

    #[test]
    fn a_vanished_subdir_skips_its_subtree_but_a_missing_root_fails() {
        let (tmp, src, db) = fixture();
        let flaky = FlakyDirSource {
            inner: src,
            dir: "Shows/The Expanse",
            error: |p| SourceError::NotFound(p.to_string()),
        };
        let stats = scan(&db, &flaky, false).unwrap();
        assert_eq!(stats.files_seen, 1); // Dune only, the show subtree was skipped
        assert_eq!(title_names(&db, MediaKind::Show), []);

        drop(tmp);
        let gone = LocalDirSource::new("s2", "/nonexistent/lexis-root".into());
        match scan(&db, &gone, false) {
            // the root has no relative path of its own to name, so the message
            // must carry the source's own absolute root instead of an empty one
            Err(ScanError::Source(SourceError::NotFound(msg))) => {
                assert_eq!(msg, "/nonexistent/lexis-root")
            }
            other => panic!("expected a NotFound source error, got {other:?}"),
        }
    }

    fn title_names(db: &Db, kind: MediaKind) -> Vec<(String, i64)> {
        let conn = db.conn();
        let mut stmt = conn
            .prepare(
                "SELECT t.name, (SELECT COUNT(*) FROM files f WHERE f.title_id = t.id)
                 FROM titles t WHERE t.kind = ?1 ORDER BY t.name",
            )
            .unwrap();
        let rows = stmt
            .query_map([kind.as_str()], |r| Ok((r.get(0)?, r.get(1)?)))
            .unwrap();
        rows.map(|r| r.unwrap()).collect()
    }

    #[test]
    fn nameless_episode_takes_its_directory_as_title() {
        let tmp = tempfile::tempdir().unwrap();
        fs::create_dir_all(tmp.path().join("Shows/Foo")).unwrap();
        fs::write(tmp.path().join("Shows/Foo/S01E01.mkv"), b"x").unwrap();
        let db = Db::open_in_memory().unwrap();
        let src = LocalDirSource::new("s1", tmp.path().to_path_buf());
        scan(&db, &src, false).unwrap();
        assert_eq!(title_names(&db, MediaKind::Show), [("Foo".to_string(), 1)]);
    }

    /// The layout the owner's shows are filed in: an episode whose filename
    /// carries no title is the show's, never the season directory's, and the
    /// seasons of one show stay one title instead of one per season.
    #[test]
    fn nameless_episodes_under_season_directories_are_named_after_the_show() {
        let tmp = tempfile::tempdir().unwrap();
        for dir in ["Shows/Severance/Season 1", "Shows/Severance/Saison 2"] {
            fs::create_dir_all(tmp.path().join(dir)).unwrap();
        }
        fs::write(tmp.path().join("Shows/Severance/Season 1/S01E01.mkv"), b"x").unwrap();
        fs::write(tmp.path().join("Shows/Severance/Saison 2/S02E01.mkv"), b"x").unwrap();
        // a show filing its episodes flat, which must keep its own directory
        fs::create_dir_all(tmp.path().join("Shows/Kaamelott")).unwrap();
        fs::write(tmp.path().join("Shows/Kaamelott/S02E03.mkv"), b"x").unwrap();
        let db = Db::open_in_memory().unwrap();
        let src = LocalDirSource::new("s1", tmp.path().to_path_buf());
        scan(&db, &src, false).unwrap();
        assert_eq!(
            title_names(&db, MediaKind::Show),
            [("Kaamelott".to_string(), 1), ("Severance".to_string(), 2)]
        );
    }

    #[test]
    fn nameless_file_at_the_root_takes_the_source_id_as_title() {
        let tmp = tempfile::tempdir().unwrap();
        fs::write(tmp.path().join("S01E01.mkv"), b"x").unwrap();
        let db = Db::open_in_memory().unwrap();
        let src = LocalDirSource::new("s1", tmp.path().to_path_buf());
        scan(&db, &src, false).unwrap();
        assert_eq!(title_names(&db, MediaKind::Show), [("s1".to_string(), 1)]);
    }

    #[test]
    fn episodes_with_and_without_a_year_share_one_title() {
        let tmp = tempfile::tempdir().unwrap();
        fs::create_dir_all(tmp.path().join("Shows")).unwrap();
        fs::write(tmp.path().join("Shows/Show.2015.S01E01.mkv"), b"x").unwrap();
        fs::write(tmp.path().join("Shows/Show.S01E02.mkv"), b"x").unwrap();
        let db = Db::open_in_memory().unwrap();
        let src = LocalDirSource::new("s1", tmp.path().to_path_buf());
        let stats = scan(&db, &src, false).unwrap();
        assert_eq!(stats.files_upserted, 2);
        assert_eq!(title_names(&db, MediaKind::Show), [("Show".to_string(), 2)]);
    }

    #[test]
    fn initial_scan_indexes_videos_only() {
        let (_tmp, src, db) = fixture();
        let stats = scan(&db, &src, false).unwrap();
        assert_eq!(stats.files_seen, 2);
        assert_eq!(stats.files_upserted, 2);
        assert_eq!(stats.files_removed, 0);
        let titles: i64 = db
            .conn()
            .query_row("SELECT COUNT(*) FROM titles", [], |r| r.get(0))
            .unwrap();
        assert_eq!(titles, 2); // Dune (movie) + The Expanse (show)
        let (season, episode): (u16, u16) = db
            .conn()
            .query_row(
                "SELECT f.season, f.episode FROM files f
                 JOIN titles t ON t.id = f.title_id WHERE t.kind = 'show'",
                [],
                |r| Ok((r.get(0)?, r.get(1)?)),
            )
            .unwrap();
        assert_eq!((season, episode), (3, 5));
    }

    #[test]
    fn unchanged_rescan_skips_dirs_and_removes_nothing() {
        let (_tmp, src, db) = fixture();
        scan(&db, &src, false).unwrap();
        let stats = scan(&db, &src, false).unwrap();
        assert_eq!(stats.files_upserted, 0);
        assert_eq!(stats.files_removed, 0);
        assert!(stats.dirs_skipped >= 2); // Movies and Season 3 at least
    }

    #[test]
    fn fresh_dir_mtime_is_neither_trusted_nor_recorded() {
        let (tmp, src, db) = fixture();
        let now = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_secs() as i64;
        set_mtime(&tmp.path().join("Movies"), now);

        scan(&db, &src, false).unwrap();
        // an unsettled mtime must not be recorded, or a write landing later in
        // the same second would be skipped forever
        assert_eq!(db.dir_mtime("s1", "Movies").unwrap(), None);
        assert_eq!(
            db.dir_mtime("s1", "Shows/The Expanse/Season 3").unwrap(),
            Some(1000)
        );

        let stats = scan(&db, &src, false).unwrap();
        assert_eq!(stats.files_upserted, 1); // Movies reprocessed
        assert_eq!(stats.files_removed, 0);
        assert_eq!(stats.dirs_skipped, 3); // Shows, The Expanse, Season 3, not Movies
    }

    #[test]
    fn added_and_removed_files_are_detected() {
        let (tmp, src, db) = fixture();
        scan(&db, &src, false).unwrap();
        let root = tmp.path();
        fs::write(root.join("Movies/Alien (1979).mkv"), b"x").unwrap();
        fs::remove_file(root.join("Movies/Dune (2021) 2160p.mkv")).unwrap();
        set_mtime(&root.join("Movies"), 1010);
        let stats = scan(&db, &src, false).unwrap();
        assert_eq!(stats.files_upserted, 1);
        assert_eq!(stats.files_removed, 1);
        let names: Vec<String> = {
            let conn = db.conn();
            let mut stmt = conn
                .prepare("SELECT name FROM titles WHERE kind = 'movie' ORDER BY name")
                .unwrap();
            let rows = stmt.query_map([], |r| r.get(0)).unwrap();
            rows.map(|r| r.unwrap()).collect()
        };
        assert_eq!(names, ["Alien"]); // Dune's title was pruned as orphan
    }

    #[test]
    fn a_root_that_lists_empty_after_being_indexed_keeps_every_file_it_had() {
        let (tmp, src, db) = fixture();
        scan(&db, &src, false).unwrap();
        // the root itself is still there and still lists fine, the way a
        // mount point does once whatever was mounted on it is gone: this
        // never raises NotFound, so nothing else here tells it apart from a
        // library genuinely emptied out
        fs::remove_dir_all(tmp.path().join("Movies")).unwrap();
        fs::remove_dir_all(tmp.path().join("Shows")).unwrap();

        let err = scan(&db, &src, false).unwrap_err();
        assert!(matches!(err, ScanError::Source(SourceError::Refused(_))));
        let files: i64 = db
            .conn()
            .query_row("SELECT COUNT(*) FROM files", [], |r| r.get(0))
            .unwrap();
        assert_eq!(files, 2); // the sweep and the prune never ran
    }
}
