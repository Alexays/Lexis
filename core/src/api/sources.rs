use super::{on_thread, unix_now, CoreError, HostStore, LexisCore, SOURCES_KEY};
use crate::source::module::{Choice, ChoicesState, LinkState};
use crate::source::Source;
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::sync::Arc;
use std::time::Duration;

/// How often a waiting link asks its module whether the code was used: the
/// pace plex.tv expects of a device polling a PIN.
const LINK_POLL_EVERY: Duration = Duration::from_secs(2);
/// How often a linked session looks again at its module's server search, a
/// read of local state that costs no request.
const CHOICES_POLL_EVERY: Duration = Duration::from_millis(250);

/// A configured source as the UI may show it. `detail` is the root path or the
/// base URL; a module's secret_keys() never appear here.
#[derive(uniffi::Record)]
pub struct SourceInfo {
    pub id: String,
    /// The id of the module that built this source, one of
    /// `source_modules()`'s own ids.
    pub module: String,
    /// The name the server itself answered with, for a module that links by
    /// account (`add_from_choice`'s `name`). None for a `Setup::Fields`
    /// source, which names nothing of its own: a viewer reads its `id`
    /// instead, the same stable key it was stored under.
    pub name: Option<String>,
    pub detail: String,
    pub titles: u32,
    pub files: u32,
    /// Unix seconds of the last scan this source was part of. None before
    /// its first.
    pub last_scan: Option<i64>,
    pub last_error: Option<String>,
}

/// Persisted in the host store under `sources.v1`. One shape for every
/// module. A payload naming a module this build does not have fails loudly
/// in LexisCore::new.
///
/// The Plex token lives here, inside `values`. The host may back this store
/// with the Keychain (spec: credentials in Keychain); the core keeps no
/// second store.
#[derive(Serialize, Deserialize, Clone)]
pub(super) struct SourceConfig {
    pub(super) module: String,
    pub(super) id: String,
    /// The server's own name, carried in from a link's `Choice`. Absent from
    /// every payload before this field existed, and from a `Setup::Fields`
    /// source, which `add_source` never has one to store.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub(super) name: Option<String>,
    pub(super) values: std::collections::BTreeMap<String, String>,
}

impl SourceConfig {
    pub(super) fn id(&self) -> &str {
        &self.id
    }
}

/// The one place that turns a config into the concrete `Source` its module
/// names. Everything past this point (a scan, a stream, a writeback) reaches
/// it only through `Source`, `Catalogue` or `WatchSync`, never by asking which
/// module it is. None when the module is not registered, or refuses the
/// values it was stored with.
/// The key a module reads this install's identity out of.
///
/// Injected at build time rather than stored with the source: it belongs to
/// the install and not to the server, so every config written before this
/// existed still builds with it, and a source moved between installs does not
/// carry a stale one.
pub(crate) const CLIENT_ID_KEY: &str = "client_id";

fn build_source(config: &SourceConfig, install_id: &str) -> Option<Arc<dyn Source>> {
    let mut values = config.values.clone();
    values.insert(CLIENT_ID_KEY.to_string(), install_id.to_string());
    crate::source::module(&config.module)?
        .build(&config.id, &values)
        .ok()
}

/// The smallest unused id built from `module`: `module` itself, then
/// `module-2`, `module-3`, ... No id is ever typed by a viewer.
fn fresh_id(module: &str, configs: &[SourceConfig]) -> String {
    if configs.iter().all(|c| c.id() != module) {
        return module.to_string();
    }
    let mut n = 2;
    loop {
        let candidate = format!("{module}-{n}");
        if configs.iter().all(|c| c.id() != candidate) {
            return candidate;
        }
        n += 1;
    }
}

/// The externally tagged shape every payload before this build used. Read
/// only as a migration fallback: the next persist writes the new shape.
#[derive(Deserialize)]
pub(super) enum LegacySourceConfig {
    Local {
        id: String,
        root: String,
    },
    Plex {
        id: String,
        base_url: String,
        token: String,
    },
}

impl From<LegacySourceConfig> for SourceConfig {
    fn from(c: LegacySourceConfig) -> Self {
        match c {
            LegacySourceConfig::Local { id, root } => SourceConfig {
                module: "local".to_string(),
                id,
                name: None,
                values: std::collections::BTreeMap::from([("root".to_string(), root)]),
            },
            LegacySourceConfig::Plex {
                id,
                base_url,
                token,
            } => SourceConfig {
                module: "plex".to_string(),
                id,
                name: None,
                values: std::collections::BTreeMap::from([
                    ("base_url".to_string(), base_url),
                    ("token".to_string(), token),
                ]),
            },
        }
    }
}

#[derive(Clone)]
pub(super) struct LinkSession {
    module: String,
    state: crate::source::module::Values,
}

/// What `link_start` hands the viewer: the code to show, and the handle every
/// later call in the same session names.
#[derive(uniffi::Record)]
pub struct Link {
    pub code: String,
    pub handle: String,
}

#[derive(Debug, Clone, Copy, uniffi::Enum)]
pub enum FieldKindInfo {
    Text,
    Path,
    Url,
    Secret,
}

impl From<crate::source::module::FieldKind> for FieldKindInfo {
    fn from(k: crate::source::module::FieldKind) -> Self {
        use crate::source::module::FieldKind;
        match k {
            FieldKind::Text => FieldKindInfo::Text,
            FieldKind::Path => FieldKindInfo::Path,
            FieldKind::Url => FieldKindInfo::Url,
            FieldKind::Secret => FieldKindInfo::Secret,
        }
    }
}

/// One control the app draws for a `Setup::Fields` module. `key` is both the
/// stored key in `values` and the message key's last segment.
#[derive(Debug, uniffi::Record)]
pub struct FieldInfo {
    pub key: String,
    pub kind: FieldKindInfo,
    pub required: bool,
}

impl From<&crate::source::module::Field> for FieldInfo {
    fn from(f: &crate::source::module::Field) -> Self {
        FieldInfo {
            key: f.key.to_string(),
            kind: f.kind.into(),
            required: f.required,
        }
    }
}

/// How a module is configured: a form the app draws from `fields`, or a code
/// shown on screen with servers offered once it links.
#[derive(Debug, uniffi::Enum)]
pub enum SetupInfo {
    Fields { fields: Vec<FieldInfo> },
    Link,
}

/// One kind of source this build has, for the add flow to draw itself from:
/// no module id is ever written into the app.
#[derive(Debug, uniffi::Record)]
pub struct SourceModuleInfo {
    pub id: String,
    /// One of the drawn glyphs' ids, or any other id: the app falls back to
    /// its generic glyph for one it does not recognise.
    pub glyph: String,
    pub setup: SetupInfo,
}

/// Clears the stored source list. This is a free function, not a method,
/// because the case it exists for is a `sources.v1` payload that
/// LexisCore::new refuses to load: a method would be unreachable exactly when
/// it is needed.
#[uniffi::export]
pub fn reset_sources(store: Arc<dyn HostStore>) {
    store.set(SOURCES_KEY.to_string(), b"[]".to_vec());
}

#[uniffi::export]
impl LexisCore {
    pub fn list_sources(&self) -> Vec<SourceInfo> {
        let configs = self.configs.lock();
        let status = self.status.lock();
        let db = self.read_db.lock();
        configs
            .iter()
            .map(|c| {
                let detail = crate::source::module(&c.module)
                    .map(|m| m.detail(&c.values))
                    .unwrap_or_default();
                let counts = db.source_counts(c.id()).unwrap_or_default();
                let s = status.get(c.id());
                SourceInfo {
                    id: c.id().to_string(),
                    module: c.module.clone(),
                    name: c.name.clone(),
                    detail,
                    titles: counts.titles,
                    files: counts.files,
                    last_scan: s.filter(|s| s.last_scan > 0).map(|s| s.last_scan),
                    last_error: s.and_then(|s| s.last_error.clone()),
                }
            })
            .collect()
    }

    /// True when the id was there. The source's files leave the index with it,
    /// because nothing scans that id again to prune them later.
    pub fn remove_source(&self, id: String) -> Result<bool, CoreError> {
        let mut configs = self.configs.lock();
        let before = configs.len();
        configs.retain(|c| c.id() != id);
        if configs.len() == before {
            return Ok(false);
        }
        self.built_sources.lock().remove(&id);
        self.forget_queue(&id);
        self.db.lock().purge_source(&id)?;
        // the index is cleared first: a failed persist leaves the source still
        // stored but with no rows, which the next launch rescans. The other
        // order would leave rows behind that no configured source owns.
        self.persist(&configs)?;
        Ok(true)
    }

    /// Every module this build has, for the app to draw the "add a source"
    /// flow from. Adding a kind means adding one entry to `source::modules`;
    /// the app reads this list instead of naming a kind itself.
    pub fn source_modules(&self) -> Vec<SourceModuleInfo> {
        crate::source::modules()
            .into_iter()
            .map(|m| SourceModuleInfo {
                id: m.id().to_string(),
                glyph: m.glyph().to_string(),
                setup: match m.setup() {
                    crate::source::module::Setup::Fields(fields) => SetupInfo::Fields {
                        fields: fields.iter().map(FieldInfo::from).collect(),
                    },
                    crate::source::module::Setup::Link => SetupInfo::Link,
                },
            })
            .collect()
    }

    /// Adds a source for a `Setup::Fields` module, and returns the id it was
    /// given: the app never types one.
    pub fn add_source(
        &self,
        module: String,
        values: HashMap<String, String>,
    ) -> Result<String, CoreError> {
        let m = crate::source::module(&module).ok_or_else(|| CoreError::InvalidConfig {
            msg: format!("no such source module: {module}"),
        })?;
        if !matches!(m.setup(), crate::source::module::Setup::Fields(_)) {
            return Err(CoreError::InvalidConfig {
                msg: format!("{module} links by code; add_source does not apply"),
            });
        }
        let values: crate::source::module::Values = values.into_iter().collect();
        let mut configs = self.configs.lock();
        let id = fresh_id(&module, &configs);
        // validated before it is stored: a bad value must not persist
        m.build(&id, &values)?;
        configs.push(SourceConfig {
            module,
            id: id.clone(),
            name: None,
            values,
        });
        self.persist(&configs)?;
        Ok(id)
    }

    /// Starts a link with `module` and returns the code to show, and the
    /// handle every later call in the session names it by.
    pub fn link_start(&self, module: String) -> Result<Link, CoreError> {
        let m = crate::source::module(&module).ok_or_else(|| CoreError::InvalidConfig {
            msg: format!("no such source module: {module}"),
        })?;
        let started = m.link_start(&self.install_id)?;
        let handle = self.fresh_handle();
        self.link_sessions.lock().insert(
            handle.clone(),
            LinkSession {
                module,
                state: started.state,
            },
        );
        Ok(Link {
            code: started.code,
            handle,
        })
    }

    /// Waits until the code is used or runs out, asking the module on a
    /// thread of its own: never answers `Waiting`. `link_cancel` ends the wait
    /// with an error at its next ask. Never answers with a secret: only the
    /// module's own opaque state, carried forward, ever holds one.
    pub async fn link_wait(self: Arc<Self>, handle: String) -> Result<LinkState, CoreError> {
        on_thread(move || loop {
            match self.link_poll(&handle)? {
                LinkState::Waiting => std::thread::sleep(LINK_POLL_EVERY),
                done => return Ok(done),
            }
        })
        .await
    }

    /// What the linked account holds, once `link_wait` answers `Linked`,
    /// waiting on a thread of its own while the module's background search
    /// runs. An empty list is a real answer: the account holds nothing this
    /// module can add.
    pub async fn link_choices(self: Arc<Self>, handle: String) -> Result<Vec<Choice>, CoreError> {
        on_thread(move || loop {
            match self.link_choices_once(&handle)? {
                ChoicesState::Probing => std::thread::sleep(CHOICES_POLL_EVERY),
                ChoicesState::Ready { choices } => return Ok(choices),
            }
        })
        .await
    }

    /// Builds and stores the source for one of `link_choices`' answers, and
    /// spends the handle: it answers `link_wait`/`link_choices` no more.
    /// `name` is that same choice's own `name` - the app already holds it
    /// from the `link_choices` answer this id came from, and it is carried
    /// through here rather than re-derived, since the session keeps no list
    /// of the choices it once offered.
    pub fn add_from_choice(
        &self,
        handle: String,
        choice_id: String,
        name: String,
    ) -> Result<String, CoreError> {
        let session = self.link_session(&handle)?;
        let m = crate::source::module(&session.module).ok_or_else(|| CoreError::InvalidConfig {
            msg: format!("no such source module: {}", session.module),
        })?;
        let values = m.choice_values(&session.state, &choice_id)?;
        m.build(&choice_id, &values)?;
        let dropped = self.replace_source(SourceConfig {
            module: session.module,
            id: choice_id.clone(),
            name: Some(name),
            values,
        })?;
        self.link_sessions.lock().remove(&handle);
        match dropped {
            Some(e) => Err(e),
            None => Ok(choice_id),
        }
    }

    /// Drops a link session before it ever reaches `add_from_choice`: the
    /// viewer cancelled the step or left it. The account token it carries
    /// stops existing in this process the moment this returns. Idempotent,
    /// so cancelling a handle already spent or already gone costs nothing.
    pub fn link_cancel(&self, handle: String) {
        self.link_sessions.lock().remove(&handle);
    }
}

impl LexisCore {
    /// The built source for a configured id, cached across calls: a report
    /// every few seconds must not reconnect every time. `built_sources` is
    /// dropped whenever the source list changes, so a stale entry never
    /// outlives the config it was built from.
    pub(super) fn built_source(&self, source_id: &str) -> Option<Arc<dyn Source>> {
        if let Some(s) = self.built_sources.lock().get(source_id) {
            return Some(s.clone());
        }
        // the source list stays held until the insert: a removal in between
        // would otherwise find nothing to drop, and its source stay cached
        let configs = self.configs.lock();
        let config = configs.iter().find(|c| c.id() == source_id)?;
        let built = build_source(config, &self.install_id)?;
        self.built_sources
            .lock()
            .insert(source_id.to_string(), built.clone());
        Some(built)
    }

    fn persist(&self, configs: &[SourceConfig]) -> Result<(), CoreError> {
        let bytes =
            serde_json::to_vec(configs).map_err(|e| CoreError::Storage { msg: e.to_string() })?;
        self.store.set(SOURCES_KEY.to_string(), bytes);
        Ok(())
    }

    /// Replaces whatever source held `config.id` before, and reports whether
    /// writes this device still owed the old address were dropped: a
    /// ratingKey names an item on one server, and a source that just changed
    /// under the same id would otherwise file this device's history against
    /// someone else's items.
    ///
    /// `config.id` is refused empty here, once, for every module: it is the
    /// one piece of a source a caller ever chooses, through `add_from_choice`.
    ///
    /// A re-link at the same address is not a move: a viewer relinking to the
    /// account already configured, or a token merely refreshing, keeps the
    /// same server on the other end. `moved` compares the module and every
    /// non-secret value, so a changed credential alone never counts.
    pub(super) fn replace_source(
        &self,
        config: SourceConfig,
    ) -> Result<Option<CoreError>, CoreError> {
        if config.id.is_empty() {
            return Err(CoreError::InvalidConfig {
                msg: "a source id must not be empty".to_string(),
            });
        }
        let mut configs = self.configs.lock();
        let secret_keys = crate::source::module(&config.module)
            .map(|m| m.secret_keys())
            .unwrap_or(&[]);
        let moved = configs.iter().any(|c| {
            c.id() == config.id()
                && (c.module != config.module
                    || !c
                        .values
                        .iter()
                        .filter(|(k, _)| !secret_keys.contains(&k.as_str()))
                        .eq(config
                            .values
                            .iter()
                            .filter(|(k, _)| !secret_keys.contains(&k.as_str()))))
        });
        configs.retain(|c| c.id() != config.id());
        self.built_sources.lock().remove(config.id());
        let dropped = if moved {
            let forgotten = self.forget_queue(config.id());
            self.db.lock().clear_rating_keys(config.id())?;
            (forgotten > 0).then(|| CoreError::SourceUnavailable {
                source_id: config.id().to_string(),
                msg: format!(
                    "{forgotten} write(s) this device still owed the old address were dropped"
                ),
            })
        } else {
            None
        };
        configs.push(config);
        self.persist(&configs)?;
        Ok(dropped)
    }

    /// Test-only stand-in for a viewer-facing add flow: unlike `add_source`
    /// (a fresh id, `Setup::Fields` only) or `add_from_choice` (an id the
    /// module itself offered), a test needs to name a source and reuse that
    /// name across a scan, a report and a reopen, for any module and any
    /// setup kind. Validates exactly as those two do, then upserts by id.
    #[cfg(test)]
    pub(super) fn add_or_replace(
        &self,
        module: &str,
        id: String,
        values: crate::source::module::Values,
    ) -> Result<(), CoreError> {
        let m = crate::source::module(module).ok_or_else(|| CoreError::InvalidConfig {
            msg: format!("no such source module: {module}"),
        })?;
        m.build(&id, &values)?;
        match self.replace_source(SourceConfig {
            module: module.to_string(),
            id,
            name: None,
            values,
        })? {
            Some(e) => Err(e),
            None => Ok(()),
        }
    }

    fn link_poll(&self, handle: &str) -> Result<LinkState, CoreError> {
        let session = self.link_session(handle)?;
        let m = crate::source::module(&session.module).ok_or_else(|| CoreError::InvalidConfig {
            msg: format!("no such source module: {}", session.module),
        })?;
        let (next, state) = m.link_poll(&self.install_id, &session.state)?;
        self.carry_link_state(handle, state);
        Ok(next)
    }

    fn link_choices_once(&self, handle: &str) -> Result<ChoicesState, CoreError> {
        let session = self.link_session(handle)?;
        let m = crate::source::module(&session.module).ok_or_else(|| CoreError::InvalidConfig {
            msg: format!("no such source module: {}", session.module),
        })?;
        let (result, state) = m.link_choices(&session.state)?;
        self.carry_link_state(handle, state);
        Ok(result)
    }

    /// Only into a session still there: one `link_cancel` dropped while the
    /// module was asked stays dropped, and so does the token it held.
    fn carry_link_state(&self, handle: &str, state: crate::source::module::Values) {
        if let Some(session) = self.link_sessions.lock().get_mut(handle) {
            session.state = state;
        }
    }

    fn fresh_handle(&self) -> String {
        let mut seq = self.link_seq.lock();
        *seq += 1;
        format!("link-{}-{}", unix_now(), seq)
    }

    fn link_session(&self, handle: &str) -> Result<LinkSession, CoreError> {
        self.link_sessions
            .lock()
            .get(handle)
            .cloned()
            .ok_or_else(|| CoreError::InvalidConfig {
                msg: "this link is no longer waiting".to_string(),
            })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::api::library::ApiMediaKind;
    use crate::api::testing::*;
    use crate::api::{HostStore, SOURCES_KEY};
    use crate::source::local::LocalModule;
    use crate::source::module::SourceModule;
    use crate::source::plex::PlexModule;
    use std::collections::HashMap;
    use std::fs;

    #[test]
    fn sources_survive_a_cache_purge() {
        let media = media_dir();
        let cache = tempfile::tempdir().unwrap();
        let store = Arc::new(MemStore::default());
        {
            let core =
                LexisCore::new(cache.path().to_string_lossy().into_owned(), store.clone()).unwrap();
            core.add_or_replace(
                LocalModule.id(),
                "local1".into(),
                std::collections::BTreeMap::from([(
                    "root".to_string(),
                    media.path().to_string_lossy().into_owned(),
                )]),
            )
            .unwrap();
        }
        // the purge: the cache dir is gone entirely, only the host store survives
        let cache2 = tempfile::tempdir().unwrap();
        let purged = cache2.path().join("lexis");
        let core = LexisCore::new(purged.to_string_lossy().into_owned(), store).unwrap();
        let report = core.scan_all(false).unwrap();
        assert_eq!(report.files_upserted, 1); // source was restored, scan works
    }

    #[test]
    fn a_source_that_cannot_work_is_rejected_before_it_is_stored() {
        let cache = tempfile::tempdir().unwrap();
        let store = Arc::new(MemStore::default());
        let core =
            LexisCore::new(cache.path().to_string_lossy().into_owned(), store.clone()).unwrap();

        // no id is ever empty here: add_source mints its own, and
        // add_from_choice's comes from the module's own reported choices
        assert!(matches!(
            core.add_or_replace(
                PlexModule.id(),
                "plex1".into(),
                std::collections::BTreeMap::from([
                    ("base_url".to_string(), "plex.local:32400".into()),
                    ("token".to_string(), "tok".into()),
                ]),
            ),
            Err(CoreError::InvalidConfig { .. })
        ));
        assert_eq!(store.get(SOURCES_KEY.to_string()), None);
    }

    #[test]
    fn a_plex_source_is_synced_and_survives_a_cache_purge() {
        use crate::plex::fake::library;

        let server = library();
        let cache = tempfile::tempdir().unwrap();
        let store = Arc::new(MemStore::default());
        {
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
            let report = core.scan_all(false).unwrap();
            assert_eq!(report.files_seen, 3);
            assert_eq!(report.files_upserted, 3);
            assert_eq!(report.sources_failed, 0);

            let movies = core.list_titles(ApiMediaKind::Movie, 0, 10).unwrap();
            assert_eq!(movies[0].name, "Dune");
            let shows = core.list_titles(ApiMediaKind::Show, 0, 10).unwrap();
            assert_eq!(shows[0].name, "The Expanse");
            assert_eq!(shows[0].file_count, 2);
        }

        // the purge: a brand new cache dir, only the host store survives
        let cache2 = tempfile::tempdir().unwrap();
        let core = LexisCore::new(cache2.path().to_string_lossy().into_owned(), store).unwrap();
        assert_eq!(core.scan_all(false).unwrap().files_upserted, 3);
    }

    #[test]
    fn an_old_sources_payload_still_loads_and_gains_plex() {
        let cache = tempfile::tempdir().unwrap();
        let store = Arc::new(MemStore::default());
        store.set(
            SOURCES_KEY.to_string(),
            br#"[{"Local":{"id":"local1","root":"/media"}}]"#.to_vec(),
        );
        let core =
            LexisCore::new(cache.path().to_string_lossy().into_owned(), store.clone()).unwrap();
        core.add_or_replace(
            PlexModule.id(),
            "plex1".into(),
            std::collections::BTreeMap::from([
                ("base_url".to_string(), "http://plex.local:32400".into()),
                ("token".to_string(), "tok".into()),
            ]),
        )
        .unwrap();

        let saved = String::from_utf8(store.get(SOURCES_KEY.to_string()).unwrap()).unwrap();
        assert!(
            saved.contains(&format!(r#""module":"{}","id":"local1""#, LocalModule.id())),
            "{saved}"
        );
        assert!(
            saved.contains(&format!(r#""module":"{}","id":"plex1""#, PlexModule.id())),
            "{saved}"
        );
    }

    #[test]
    fn an_old_payload_is_rewritten_to_the_new_shape_on_the_next_persist() {
        let cache = tempfile::tempdir().unwrap();
        let store = Arc::new(MemStore::default());
        store.set(
            SOURCES_KEY.to_string(),
            br#"[{"Local":{"id":"local1","root":"/media"}},{"Plex":{"id":"plex1","base_url":"http://plex.local:32400","token":"tok"}}]"#.to_vec(),
        );
        let core =
            LexisCore::new(cache.path().to_string_lossy().into_owned(), store.clone()).unwrap();
        // read fine before anything is written back: both sources are there
        let sources = core.list_sources();
        assert_eq!(sources.len(), 2);

        // nothing has persisted yet: the store still holds the old bytes
        let before = String::from_utf8(store.get(SOURCES_KEY.to_string()).unwrap()).unwrap();
        assert!(before.contains(r#""Local":{"#), "{before}");

        core.add_or_replace(
            LocalModule.id(),
            "local2".into(),
            std::collections::BTreeMap::from([("root".to_string(), "/more".into())]),
        )
        .unwrap();

        let after = String::from_utf8(store.get(SOURCES_KEY.to_string()).unwrap()).unwrap();
        assert!(!after.contains(r#""Local":{"#), "{after}");
        assert!(!after.contains(r#""Plex":{"#), "{after}");
        assert!(
            after.contains(&format!(r#""module":"{}""#, LocalModule.id())),
            "{after}"
        );
        assert!(
            after.contains(&format!(r#""module":"{}""#, PlexModule.id())),
            "{after}"
        );
        assert!(
            after.contains(r#""base_url":"http://plex.local:32400""#),
            "{after}"
        );
        // a token lost in the migration would log the family out with nothing
        // to say why
        assert!(after.contains(r#""token":"tok""#), "{after}");
    }

    #[test]
    fn a_payload_naming_an_unknown_module_fails_loudly() {
        let cache = tempfile::tempdir().unwrap();
        let store = Arc::new(MemStore::default());
        store.set(
            SOURCES_KEY.to_string(),
            br#"[{"module":"smb","id":"nas","values":{}}]"#.to_vec(),
        );
        let result = LexisCore::new(cache.path().to_string_lossy().into_owned(), store.clone());
        assert!(matches!(result, Err(CoreError::InvalidConfig { .. })));

        reset_sources(store.clone());
        assert!(LexisCore::new(cache.path().to_string_lossy().into_owned(), store).is_ok());
    }

    #[test]
    fn re_adding_a_source_id_replaces_it_whatever_its_kind() {
        let cache = tempfile::tempdir().unwrap();
        let store = Arc::new(MemStore::default());
        let core =
            LexisCore::new(cache.path().to_string_lossy().into_owned(), store.clone()).unwrap();
        core.add_or_replace(
            PlexModule.id(),
            "s".into(),
            std::collections::BTreeMap::from([
                ("base_url".to_string(), "http://old:32400".into()),
                ("token".to_string(), "old".into()),
            ]),
        )
        .unwrap();
        core.add_or_replace(
            PlexModule.id(),
            "s".into(),
            std::collections::BTreeMap::from([
                ("base_url".to_string(), "http://new:32400".into()),
                ("token".to_string(), "new".into()),
            ]),
        )
        .unwrap();
        core.add_or_replace(
            LocalModule.id(),
            "s".into(),
            std::collections::BTreeMap::from([("root".to_string(), "/media".into())]),
        )
        .unwrap();

        let saved = String::from_utf8(store.get(SOURCES_KEY.to_string()).unwrap()).unwrap();
        assert!(!saved.contains("old"));
        assert!(!saved.contains("32400"));
        assert!(saved.contains(&format!(
            r#""module":"{}","id":"s","values":{{"root":"/media"}}"#,
            LocalModule.id()
        )));
    }

    #[test]
    fn sources_can_be_listed_without_leaking_the_token() {
        let cache = tempfile::tempdir().unwrap();
        let store = Arc::new(MemStore::default());
        let core =
            LexisCore::new(cache.path().to_string_lossy().into_owned(), store.clone()).unwrap();
        core.add_or_replace(
            LocalModule.id(),
            "local1".into(),
            std::collections::BTreeMap::from([("root".to_string(), "/media".into())]),
        )
        .unwrap();
        core.add_or_replace(
            PlexModule.id(),
            "plex1".into(),
            std::collections::BTreeMap::from([
                ("base_url".to_string(), "http://plex.local:32400".into()),
                ("token".to_string(), "s3cr3t".into()),
            ]),
        )
        .unwrap();

        let sources = core.list_sources();
        assert_eq!(sources.len(), 2);
        assert_eq!(sources[0].id, "local1");
        assert_eq!(sources[0].module, LocalModule.id());
        assert_eq!(sources[0].detail, "/media");
        assert_eq!(sources[1].id, "plex1");
        assert_eq!(sources[1].module, PlexModule.id());
        assert_eq!(sources[1].detail, "http://plex.local:32400");
        assert!(!sources.iter().any(|s| s.detail.contains("s3cr3t")));
    }

    #[test]
    fn a_source_carries_its_own_counts_and_last_scan_with_no_secret() {
        let media = media_dir();
        let cache = tempfile::tempdir().unwrap();
        let store = Arc::new(MemStore::default());
        let core =
            LexisCore::new(cache.path().to_string_lossy().into_owned(), store.clone()).unwrap();
        core.add_source(
            LocalModule.id().to_string(),
            HashMap::from([(
                "root".to_string(),
                media.path().to_string_lossy().into_owned(),
            )]),
        )
        .unwrap();

        let before = &core.list_sources()[0];
        assert_eq!(before.titles, 0);
        assert_eq!(before.files, 0);
        assert_eq!(before.last_scan, None);
        assert_eq!(before.last_error, None);

        core.scan_all(false).unwrap();

        let after = &core.list_sources()[0];
        assert_eq!(after.titles, 1);
        assert_eq!(after.files, 1);
        assert!(after.last_scan.unwrap() > 0);
        assert_eq!(after.last_error, None);
    }

    #[test]
    fn a_failed_scan_is_the_sources_own_last_error_and_survives_a_reopen() {
        let cache = tempfile::tempdir().unwrap();
        let store = Arc::new(MemStore::default());
        let core =
            LexisCore::new(cache.path().to_string_lossy().into_owned(), store.clone()).unwrap();
        core.add_or_replace(
            PlexModule.id(),
            "plex1".into(),
            std::collections::BTreeMap::from([
                ("base_url".to_string(), "http://127.0.0.1:1".into()),
                ("token".to_string(), "s3cr3t".into()),
            ]),
        )
        .unwrap();
        core.scan_all(false).unwrap();

        let info = &core.list_sources()[0];
        assert!(info.last_error.is_some());
        assert!(!info.last_error.as_ref().unwrap().contains("s3cr3t"));
        assert!(info.last_scan.unwrap() > 0);

        let reopened = LexisCore::new(cache.path().to_string_lossy().into_owned(), store).unwrap();
        assert!(reopened.list_sources()[0].last_scan.is_some());
    }

    #[test]
    fn removing_a_source_is_persisted_and_says_whether_it_was_there() {
        let cache = tempfile::tempdir().unwrap();
        let store = Arc::new(MemStore::default());
        {
            let core =
                LexisCore::new(cache.path().to_string_lossy().into_owned(), store.clone()).unwrap();
            core.add_or_replace(
                LocalModule.id(),
                "local1".into(),
                std::collections::BTreeMap::from([("root".to_string(), "/media".into())]),
            )
            .unwrap();
            core.add_or_replace(
                PlexModule.id(),
                "plex1".into(),
                std::collections::BTreeMap::from([
                    ("base_url".to_string(), "http://plex.local:32400".into()),
                    ("token".to_string(), "tok".into()),
                ]),
            )
            .unwrap();
            assert!(core.remove_source("local1".into()).unwrap());
            assert!(!core.remove_source("local1".into()).unwrap());
            assert_eq!(core.list_sources().len(), 1);
        }

        let reopened =
            LexisCore::new(cache.path().to_string_lossy().into_owned(), store.clone()).unwrap();
        let sources = reopened.list_sources();
        assert_eq!(sources.len(), 1);
        assert_eq!(sources[0].id, "plex1");
    }

    #[test]
    fn removing_a_source_takes_its_titles_out_of_the_library() {
        let gone = media_dir(); // Dune
        let kept = tempfile::tempdir().unwrap();
        fs::create_dir_all(kept.path().join("Movies")).unwrap();
        fs::write(kept.path().join("Movies/Alien (1979).mkv"), b"x").unwrap();
        // settled mtimes, so the second scan can legitimately skip these dirs
        for dir in [gone.path().join("Movies"), kept.path().join("Movies")] {
            filetime::set_file_mtime(dir, filetime::FileTime::from_unix_time(1000, 0)).unwrap();
        }

        let cache = tempfile::tempdir().unwrap();
        let store = Arc::new(MemStore::default());
        let core =
            LexisCore::new(cache.path().to_string_lossy().into_owned(), store.clone()).unwrap();
        core.add_or_replace(
            LocalModule.id(),
            "gone".into(),
            std::collections::BTreeMap::from([(
                "root".to_string(),
                gone.path().to_string_lossy().into_owned(),
            )]),
        )
        .unwrap();
        core.add_or_replace(
            LocalModule.id(),
            "kept".into(),
            std::collections::BTreeMap::from([(
                "root".to_string(),
                kept.path().to_string_lossy().into_owned(),
            )]),
        )
        .unwrap();
        core.scan_all(false).unwrap();
        assert_eq!(
            core.list_titles(ApiMediaKind::Movie, 0, 10).unwrap().len(),
            2
        );

        assert!(core.remove_source("gone".into()).unwrap());
        let movies = core.list_titles(ApiMediaKind::Movie, 0, 10).unwrap();
        assert_eq!(movies.len(), 1);
        assert_eq!(movies[0].name, "Alien");

        // the same id added back indexes from scratch: its directory
        // bookkeeping went with it, so nothing reads as unchanged
        core.add_or_replace(
            LocalModule.id(),
            "gone".into(),
            std::collections::BTreeMap::from([(
                "root".to_string(),
                gone.path().to_string_lossy().into_owned(),
            )]),
        )
        .unwrap();
        let report = core.scan_all(false).unwrap();
        let row = report.per_source.iter().find(|s| s.id == "gone").unwrap();
        assert_eq!(row.files_upserted, 1, "{row:?}");
        assert_eq!(
            core.list_titles(ApiMediaKind::Movie, 0, 10).unwrap().len(),
            2
        );
    }

    #[test]
    fn unreadable_sources_are_an_error_that_names_the_way_out() {
        let cache = tempfile::tempdir().unwrap();
        let store = Arc::new(MemStore::default());
        store.set(SOURCES_KEY.to_string(), b"not json".to_vec());
        let err = LexisCore::new(cache.path().to_string_lossy().into_owned(), store.clone())
            .err()
            .expect("a corrupt store must not read as an empty source list");
        assert!(matches!(err, CoreError::InvalidConfig { .. }));
        assert!(err.to_string().contains("reset_sources"), "{err}");
        // the bad value stays put: overwriting it would destroy the user's sources
        assert_eq!(
            store.get(SOURCES_KEY.to_string()),
            Some(b"not json".to_vec())
        );
    }

    #[test]
    fn reset_sources_clears_a_payload_no_core_could_load() {
        let cache = tempfile::tempdir().unwrap();
        let store = Arc::new(MemStore::default());
        store.set(SOURCES_KEY.to_string(), b"not json".to_vec());
        assert!(
            LexisCore::new(cache.path().to_string_lossy().into_owned(), store.clone()).is_err()
        );

        reset_sources(store.clone());

        let core =
            LexisCore::new(cache.path().to_string_lossy().into_owned(), store.clone()).unwrap();
        assert!(core.list_sources().is_empty());
        assert_eq!(store.get(SOURCES_KEY.to_string()), Some(b"[]".to_vec()));
    }

    #[test]
    fn a_link_walks_code_choice_and_add_with_no_typed_id() {
        let cache = tempfile::tempdir().unwrap();
        let store = Arc::new(MemStore::default());
        let core = LexisCore::new(cache.path().to_string_lossy().into_owned(), store).unwrap();

        let link = core.link_start("test-link".into()).unwrap();
        assert_eq!(link.code, "TEST");

        let state = wait(core.clone().link_wait(link.handle.clone())).unwrap();
        assert_eq!(state, LinkState::Linked);

        let choices = wait(core.clone().link_choices(link.handle.clone())).unwrap();
        assert_eq!(choices.len(), 1);
        assert_eq!(choices[0].id, "only");

        let id = core
            .add_from_choice(
                link.handle.clone(),
                choices[0].id.clone(),
                choices[0].name.clone(),
            )
            .unwrap();
        assert_eq!(id, "only");
        assert_eq!(core.list_sources()[0].module, "test-link");
        // the name the server itself answered with, carried through to storage
        assert_eq!(core.list_sources()[0].name, Some("Only choice".to_string()));

        // the handle is spent
        assert!(wait(core.clone().link_wait(link.handle)).is_err());
    }

    #[test]
    fn an_empty_choice_id_is_rejected_before_it_is_stored() {
        let cache = tempfile::tempdir().unwrap();
        let store = Arc::new(MemStore::default());
        let core = LexisCore::new(cache.path().to_string_lossy().into_owned(), store).unwrap();

        // neither the fixture module nor its build ever refuses an empty id:
        // only the shared storage path does
        let link = core.link_start("test-link".into()).unwrap();
        wait(core.clone().link_wait(link.handle.clone())).unwrap();
        assert!(matches!(
            core.add_from_choice(link.handle, String::new(), "whatever".into()),
            Err(CoreError::InvalidConfig { .. })
        ));
        assert!(core.list_sources().is_empty());
    }

    #[test]
    fn an_expired_link_reports_it_generically() {
        let cache = tempfile::tempdir().unwrap();
        let store = Arc::new(MemStore::default());
        let core = LexisCore::new(cache.path().to_string_lossy().into_owned(), store).unwrap();
        let link = core.link_start("test-link-expired".into()).unwrap();
        let state = wait(core.clone().link_wait(link.handle)).unwrap();
        assert_eq!(state, LinkState::Expired);
    }

    #[test]
    fn a_fields_module_cannot_be_added_from_a_choice_and_a_link_module_cannot_add_source() {
        let cache = tempfile::tempdir().unwrap();
        let store = Arc::new(MemStore::default());
        let core = LexisCore::new(cache.path().to_string_lossy().into_owned(), store).unwrap();
        assert!(matches!(
            core.add_source("test-link".into(), HashMap::new()),
            Err(CoreError::InvalidConfig { .. })
        ));
        assert!(matches!(
            core.link_start("test-fields".into()),
            Err(CoreError::InvalidConfig { .. })
        ));
    }

    #[test]
    fn source_modules_describes_every_registered_kind_by_its_own_setup() {
        let cache = tempfile::tempdir().unwrap();
        let store = Arc::new(MemStore::default());
        let core = LexisCore::new(cache.path().to_string_lossy().into_owned(), store).unwrap();
        let modules = core.source_modules();

        let fields = modules.iter().find(|m| m.id == "test-fields").unwrap();
        match &fields.setup {
            SetupInfo::Fields { fields } => {
                assert_eq!(fields[0].key, "label");
                assert!(matches!(fields[0].kind, FieldKindInfo::Text));
                assert!(fields[0].required);
            }
            SetupInfo::Link => panic!("expected Fields"),
        }

        let link = modules.iter().find(|m| m.id == "test-link").unwrap();
        assert!(matches!(link.setup, SetupInfo::Link));
        // no glyph override on the fixture: falls back to the generic id
        assert_eq!(link.glyph, "server");
    }

    #[test]
    fn an_unknown_handle_is_an_invalid_config_not_a_panic() {
        let cache = tempfile::tempdir().unwrap();
        let store = Arc::new(MemStore::default());
        let core = LexisCore::new(cache.path().to_string_lossy().into_owned(), store).unwrap();
        assert!(wait(core.clone().link_wait("nope".into())).is_err());
        assert!(wait(core.clone().link_choices("nope".into())).is_err());
        assert!(core
            .add_from_choice("nope".into(), "x".into(), "y".into())
            .is_err());
    }

    #[test]
    fn link_cancel_drops_the_session_and_its_token_with_it() {
        let cache = tempfile::tempdir().unwrap();
        let store = Arc::new(MemStore::default());
        let core = LexisCore::new(cache.path().to_string_lossy().into_owned(), store).unwrap();

        let link = core.link_start("test-link".into()).unwrap();
        wait(core.clone().link_wait(link.handle.clone())).unwrap();
        assert!(wait(core.clone().link_choices(link.handle.clone())).is_ok());

        core.link_cancel(link.handle.clone());

        // the session, and the account token it carried, is gone: every call
        // naming the handle answers as it would for one the core never issued
        assert!(wait(core.clone().link_wait(link.handle.clone())).is_err());
        assert!(wait(core.clone().link_choices(link.handle.clone())).is_err());
        assert!(core
            .add_from_choice(link.handle.clone(), "only".into(), "Only choice".into())
            .is_err());

        // idempotent: a second cancel, from a viewer who both pressed Cancel
        // and then left the step, costs nothing
        core.link_cancel(link.handle);
    }

    #[test]
    fn link_cancel_ends_a_wait_on_a_code_nobody_used() {
        let cache = tempfile::tempdir().unwrap();
        let store = Arc::new(MemStore::default());
        let core = LexisCore::new(cache.path().to_string_lossy().into_owned(), store).unwrap();

        let link = core.link_start("test-link-waiting".into()).unwrap();
        let waiting = started(core.clone().link_wait(link.handle.clone()));
        core.link_cancel(link.handle);

        assert!(wait(waiting).is_err());
        assert!(core.link_sessions.lock().is_empty());
    }

    /// The generic path, driven by the fixture whose `secret_keys()` names a
    /// field other than "token": every string an FFI caller can see across a
    /// full link (the code, the handle, every choice field, the added id)
    /// must not carry the value `choice_values` put behind that key.
    #[test]
    fn no_secret_crosses_the_ffi_across_a_full_link() {
        let cache = tempfile::tempdir().unwrap();
        let store = Arc::new(MemStore::default());
        let core = LexisCore::new(cache.path().to_string_lossy().into_owned(), store).unwrap();
        let leaked = "linked-secret";

        let link = core.link_start("test-link".into()).unwrap();
        assert!(!link.code.contains(leaked));
        assert!(!link.handle.contains(leaked));

        wait(core.clone().link_wait(link.handle.clone())).unwrap();

        let choices = wait(core.clone().link_choices(link.handle.clone())).unwrap();
        for c in &choices {
            assert!(!c.id.contains(leaked));
            assert!(!c.name.contains(leaked));
            assert!(!c.detail.contains(leaked));
        }

        let id = core
            .add_from_choice(link.handle, choices[0].id.clone(), choices[0].name.clone())
            .unwrap();
        assert!(!id.contains(leaked));
    }
}
