use super::module::{Field, FieldKind, Setup, SourceModule, Values};
use super::{Entry, ReadSeek, Source, SourceError};
use crate::api::CoreError;
use std::fs;
use std::path::PathBuf;
use std::sync::Arc;
use std::time::UNIX_EPOCH;

pub struct LocalDirSource {
    id: String,
    root: PathBuf,
}

impl LocalDirSource {
    pub fn new(id: &str, root: PathBuf) -> Self {
        Self {
            id: id.to_string(),
            root,
        }
    }

    fn resolve(&self, rel: &str) -> Result<PathBuf, SourceError> {
        if rel.starts_with('/') || rel.contains('\\') || rel.split('/').any(|c| c == "..") {
            return Err(SourceError::InvalidPath(rel.to_string()));
        }
        Ok(if rel.is_empty() {
            self.root.clone()
        } else {
            self.root.join(rel)
        })
    }
}

impl Source for LocalDirSource {
    fn id(&self) -> &str {
        &self.id
    }

    fn list(&self, dir_path: &str) -> Result<Vec<Entry>, SourceError> {
        let dir = self.resolve(dir_path)?;
        let mut out = Vec::new();
        // named by the resolved absolute path, never by dir_path: at the
        // root that is empty, and "not found: " with nothing after the colon
        // says less than no error at all
        let items = fs::read_dir(&dir).map_err(|e| match e.kind() {
            std::io::ErrorKind::NotFound => SourceError::NotFound(dir.display().to_string()),
            _ => SourceError::Io(e),
        })?;
        for item in items {
            let item = item?;
            let meta = item.metadata()?;
            let name = item.file_name().to_string_lossy().into_owned();
            let path = if dir_path.is_empty() {
                name.clone()
            } else {
                format!("{dir_path}/{name}")
            };
            let mtime = meta
                .modified()?
                .duration_since(UNIX_EPOCH)
                .map(|d| d.as_secs() as i64)
                .unwrap_or(0);
            out.push(Entry {
                path,
                name,
                is_dir: meta.is_dir(),
                size: meta.len(),
                mtime,
            });
        }
        out.sort_by(|a, b| a.name.cmp(&b.name));
        Ok(out)
    }

    fn open(&self, file_path: &str) -> Result<Box<dyn ReadSeek>, SourceError> {
        let path = self.resolve(file_path)?;
        let f = fs::File::open(&path).map_err(|e| match e.kind() {
            std::io::ErrorKind::NotFound => SourceError::NotFound(path.display().to_string()),
            _ => SourceError::Io(e),
        })?;
        Ok(Box::new(f))
    }
}

pub struct LocalModule;

impl SourceModule for LocalModule {
    fn id(&self) -> &'static str {
        "local"
    }
    fn glyph(&self) -> &'static str {
        "folder"
    }
    fn setup(&self) -> Setup {
        Setup::Fields(vec![Field {
            key: "root",
            kind: FieldKind::Path,
            required: true,
        }])
    }
    fn detail(&self, values: &Values) -> String {
        values.get("root").cloned().unwrap_or_default()
    }
    fn secret_keys(&self) -> &'static [&'static str] {
        &[]
    }
    fn build(&self, id: &str, values: &Values) -> Result<Arc<dyn Source>, CoreError> {
        let root = values.get("root").ok_or_else(|| CoreError::InvalidConfig {
            msg: "a local source needs a root path".to_string(),
        })?;
        Ok(Arc::new(LocalDirSource::new(id, root.into())))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::source::Source;
    use std::fs;
    use std::io::Read;

    fn fixture() -> (tempfile::TempDir, LocalDirSource) {
        let tmp = tempfile::tempdir().unwrap();
        fs::create_dir_all(tmp.path().join("Movies")).unwrap();
        fs::write(tmp.path().join("Movies/Dune (2021).mkv"), b"fake").unwrap();
        fs::write(tmp.path().join("notes.txt"), b"x").unwrap();
        let src = LocalDirSource::new("local1", tmp.path().to_path_buf());
        (tmp, src)
    }

    #[test]
    fn lists_root_sorted_with_metadata() {
        let (_tmp, src) = fixture();
        let entries = src.list("").unwrap();
        let names: Vec<&str> = entries.iter().map(|e| e.name.as_str()).collect();
        assert_eq!(names, ["Movies", "notes.txt"]);
        assert!(entries[0].is_dir);
        assert!(entries[0].mtime > 0);
        let files = src.list("Movies").unwrap();
        assert_eq!(files[0].path, "Movies/Dune (2021).mkv");
        assert_eq!(files[0].size, 4);
    }

    #[test]
    fn opens_file_for_reading() {
        let (_tmp, src) = fixture();
        let mut r = src.open("Movies/Dune (2021).mkv").unwrap();
        let mut buf = String::new();
        r.read_to_string(&mut buf).unwrap();
        assert_eq!(buf, "fake");
    }

    #[test]
    fn rejects_parent_traversal() {
        let (_tmp, src) = fixture();
        assert!(matches!(
            src.list("../etc"),
            Err(SourceError::InvalidPath(_))
        ));
        assert!(matches!(src.open("../x"), Err(SourceError::InvalidPath(_))));
        assert!(matches!(src.list("/abs"), Err(SourceError::InvalidPath(_))));
        assert!(matches!(
            src.open("/etc/hosts"),
            Err(SourceError::InvalidPath(_))
        ));
        assert!(matches!(
            src.list("..\\etc"),
            Err(SourceError::InvalidPath(_))
        ));
        assert!(matches!(
            src.open("Movies\\Dune (2021).mkv"),
            Err(SourceError::InvalidPath(_))
        ));
    }

    #[test]
    fn missing_dir_is_not_found() {
        let (_tmp, src) = fixture();
        assert!(matches!(src.list("nope"), Err(SourceError::NotFound(_))));
    }

    /// The root itself gone (a drive unplugged) is the one case `dir_path` is
    /// empty for: the message must still name the actual path missing, not
    /// read "not found: " with nothing after the colon.
    #[test]
    fn a_missing_root_names_the_absolute_path_that_is_gone() {
        let tmp = tempfile::tempdir().unwrap();
        let root = tmp.path().join("unplugged");
        let src = LocalDirSource::new("local1", root.clone());
        match src.list("") {
            Err(SourceError::NotFound(msg)) => assert_eq!(msg, root.display().to_string()),
            other => panic!("expected NotFound, got {other:?}"),
        }
        match src.open("movie.mkv") {
            Err(SourceError::NotFound(msg)) => {
                assert_eq!(msg, root.join("movie.mkv").display().to_string())
            }
            Err(other) => panic!("expected NotFound, got {other:?}"),
            Ok(_) => panic!("expected NotFound, opened a file under a missing root"),
        }
    }

    #[test]
    fn a_local_source_answers_neither_catalogue_nor_watch_sync() {
        let (_tmp, src) = fixture();
        assert!(src.catalogue().is_none());
        assert!(src.watch_sync().is_none());
    }

    #[test]
    fn the_local_module_builds_from_a_root_value_and_describes_it() {
        let m = LocalModule;
        assert_eq!(m.id(), "local");
        assert_eq!(m.glyph(), "folder");
        let mut values = Values::new();
        values.insert("root".to_string(), "/some/path".to_string());
        assert_eq!(m.detail(&values), "/some/path");
        let built = m.build("local1", &values).unwrap();
        assert_eq!(built.id(), "local1");
    }

    #[test]
    fn the_local_module_refuses_to_build_without_a_root() {
        let m = LocalModule;
        assert!(m.build("local1", &Values::new()).is_err());
    }
}
