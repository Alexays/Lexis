//! The host store and the media tree the api tests are all built on.

use super::library::ApiMediaKind;
use super::{HostStore, LexisCore};
use crate::source::local::LocalModule;
use crate::source::module::SourceModule;
use parking_lot::Mutex;
use std::collections::HashMap;
use std::fs;
use std::future::Future;
use std::pin::Pin;
use std::sync::atomic::{AtomicU32, Ordering};
use std::sync::Arc;
use std::task::{Context, Waker};
use std::time::Duration;

#[derive(Default)]
pub(super) struct MemStore {
    pub(super) data: Mutex<HashMap<String, Vec<u8>>>,
    /// Counted, not just recorded: a report on every tick must not grow it.
    pub(super) writes: AtomicU32,
}

impl HostStore for MemStore {
    fn get(&self, key: String) -> Option<Vec<u8>> {
        self.data.lock().get(&key).cloned()
    }
    fn set(&self, key: String, value: Vec<u8>) {
        self.writes.fetch_add(1, Ordering::Relaxed);
        self.data.lock().insert(key, value);
    }
}

/// Drives `future` to its answer on a thread of its own, bounded so a broken
/// one fails the test instead of hanging the suite.
pub(super) fn wait<T: Send + 'static>(future: impl Future<Output = T> + Send + 'static) -> T {
    let (tx, rx) = std::sync::mpsc::channel();
    std::thread::spawn(move || {
        let _ = tx.send(futures_executor::block_on(future));
    });
    rx.recv_timeout(Duration::from_secs(5))
        .expect("the future never resolved")
}

/// Polls `future` once, as a foreign caller's first poll does: whatever runs
/// before its first wait has run by the time this returns.
pub(super) fn started<F: Future>(future: F) -> Pin<Box<F>> {
    let mut future = Box::pin(future);
    let first = future
        .as_mut()
        .poll(&mut Context::from_waker(Waker::noop()));
    assert!(first.is_pending(), "resolved on its first poll");
    future
}

pub(super) fn media_dir() -> tempfile::TempDir {
    let tmp = tempfile::tempdir().unwrap();
    fs::create_dir_all(tmp.path().join("Movies")).unwrap();
    fs::write(tmp.path().join("Movies/Dune (2021).mkv"), b"x").unwrap();
    tmp
}

/// Three films whose name order and year order disagree, so an order that
/// did nothing would still be visible.
pub(super) fn shelf_dir() -> tempfile::TempDir {
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

pub(super) fn show_dir() -> tempfile::TempDir {
    let tmp = tempfile::tempdir().unwrap();
    fs::create_dir_all(tmp.path().join("Shows")).unwrap();
    for name in [
        "Berserk S01E01.mkv",
        "Berserk S01E02.mkv",
        "Berserk S02E01.mkv",
    ] {
        fs::write(tmp.path().join("Shows").join(name), b"x").unwrap();
    }
    tmp
}

/// A core over one scanned show, with its title id.
pub(super) fn scanned_show(
    media: &tempfile::TempDir,
    cache: &tempfile::TempDir,
) -> (Arc<LexisCore>, i64) {
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
    let shows = core.list_titles(ApiMediaKind::Show, 0, 10).unwrap();
    assert_eq!(shows.len(), 1);
    let id = shows[0].id;
    (core, id)
}
