//! The chantier's promise is that adding a source kind touches one file
//! under `core/src/source/` and nothing else. This walks the crate's own
//! sources and fails if the literal "plex" or "local" appears outside that
//! directory: a hit there means a kind leaked into code that is supposed to
//! stay generic.

use std::fs;
use std::path::{Path, PathBuf};

/// (path relative to `src/`, the line's trimmed text) pairs where the kind
/// literal is legitimate. Nothing else may be added here: the fix for a new
/// hit is to move the behaviour behind a module in `core/src/source/`, not
/// to whitelist the line that names it.
const ALLOWED: &[(&str, &str)] = &[
    // maps a stored format that already exists on disk; the format cannot be
    // renamed, only read once and carried forward as the new shape.
    ("api/sources.rs", r#"module: "local".to_string(),"#),
    ("api/sources.rs", r#"module: "plex".to_string(),"#),
    // MetadataSource is artwork provenance (which service a poster came
    // from), a different concept that merely shares a word with a source kind.
    ("index/db.rs", r#"MetadataSource::Plex => "plex","#),
    ("index/db.rs", r#""plex" => Some(MetadataSource::Plex),"#),
];

fn collect_rs_files(dir: &Path, out: &mut Vec<PathBuf>) {
    for entry in fs::read_dir(dir).unwrap() {
        let path = entry.unwrap().path();
        if path.is_dir() {
            collect_rs_files(&path, out);
        } else if path.extension().is_some_and(|e| e == "rs") {
            out.push(path);
        }
    }
}

#[test]
fn no_source_kind_literal_lives_outside_the_source_module() {
    let src_dir = Path::new(env!("CARGO_MANIFEST_DIR")).join("src");
    let source_dir = src_dir.join("source");
    let mut files = Vec::new();
    collect_rs_files(&src_dir, &mut files);

    let mut violations = Vec::new();
    for file in &files {
        if file.starts_with(&source_dir) {
            continue;
        }
        let rel = file
            .strip_prefix(&src_dir)
            .unwrap()
            .to_string_lossy()
            .replace('\\', "/");
        let content = fs::read_to_string(file).unwrap();
        for (n, line) in content.lines().enumerate() {
            if !(line.contains("\"plex\"") || line.contains("\"local\"")) {
                continue;
            }
            let trimmed = line.trim();
            let allowed = ALLOWED.iter().any(|(f, l)| *f == rel && *l == trimmed);
            if !allowed {
                violations.push(format!("{rel}:{}: {trimmed}", n + 1));
            }
        }
    }

    assert!(
        violations.is_empty(),
        "a source kind is named as a literal outside core/src/source/:\n{}\n\n\
         The fix is to put the behaviour behind a module in core/src/source/, \
         so it reads the kind from the registry instead of naming it here. \
         Adding the line to this test's ALLOWED list is not a fix.",
        violations.join("\n")
    );
}
