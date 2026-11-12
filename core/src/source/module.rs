use super::Source;
use crate::api::CoreError;
use std::collections::BTreeMap;
use std::sync::Arc;

/// What a stored source's own config holds beyond its id: `"root"` for a
/// local source, `"base_url"`/`"token"` for one a module built from a link.
pub type Values = BTreeMap<String, String>;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FieldKind {
    Text,
    Path,
    Url,
    Secret,
}

/// One control the app draws for a `Setup::Fields` module. `key` is both the
/// stored key in `Values` and the message key's last segment.
#[derive(Debug, Clone)]
pub struct Field {
    pub key: &'static str,
    pub kind: FieldKind,
    pub required: bool,
}

pub enum Setup {
    /// A form the app draws from this description.
    Fields(Vec<Field>),
    /// The module authenticates by a code shown on screen, then offers what
    /// the account holds.
    Link,
}

/// What `SourceModule::link_start` hands back: the code to show, and
/// whatever the module needs remembered until the next call. Opaque to the
/// core past this point.
pub struct LinkStart {
    pub code: String,
    pub state: Values,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum LinkState {
    Waiting,
    Linked,
    Expired,
}

/// One thing a linked account holds, offered by a `Setup::Link` module.
#[derive(Debug, Clone, uniffi::Record)]
pub struct Choice {
    pub id: String,
    pub name: String,
    pub detail: String,
    pub reachable: bool,
    pub nearby: bool,
}

/// What `link_choices` hands back: a module with background work left to do
/// answers `Probing` at once and is polled again, the way `link_poll` itself
/// is; one with nothing to wait on can answer `Ready` on the very first call.
///
/// `Ready` with an empty list is a real answer, and the one a caller has to
/// draw something for: the account linked and holds nothing this module can
/// add. It is not an error, so nothing about it crosses as prose.
#[derive(Debug, Clone)]
pub enum ChoicesState {
    Probing,
    Ready { choices: Vec<Choice> },
}

fn not_linkable(id: &str) -> CoreError {
    CoreError::InvalidConfig {
        msg: format!("{id} does not link"),
    }
}

/// One kind of source. Stateless: a session's own state is threaded through
/// `Values`, never held on `self`, because one instance is shared by every
/// caller through the registry.
pub trait SourceModule: Send + Sync {
    /// Stable, stored, and never shown: "plex", "local".
    fn id(&self) -> &'static str;
    /// One of the drawn glyphs' ids ("chevron", "folder", "server"), or any
    /// other id: an id the app does not know draws the generic server glyph.
    fn glyph(&self) -> &'static str {
        "server"
    }
    /// How a viewer configures one.
    fn setup(&self) -> Setup;
    /// What the card shows under the name: a root path, a base URL.
    fn detail(&self, values: &Values) -> String;
    /// Value keys that never leave the core: tokens, passwords.
    fn secret_keys(&self) -> &'static [&'static str];
    fn build(&self, id: &str, values: &Values) -> Result<Arc<dyn Source>, CoreError>;

    /// `Setup::Link` modules only: starts a fresh link and returns a code to
    /// show, plus opaque state carried into every call that follows.
    /// `install_id` is this install's own id, for a module whose account API
    /// tells devices apart by it; a module with no such API ignores it.
    fn link_start(&self, _install_id: &str) -> Result<LinkStart, CoreError> {
        Err(not_linkable(self.id()))
    }
    /// Polls once. Returns the next state and the state to carry forward.
    fn link_poll(
        &self,
        _install_id: &str,
        _state: &Values,
    ) -> Result<(LinkState, Values), CoreError> {
        Err(not_linkable(self.id()))
    }
    /// What the linked account holds, once `link_poll` answers `Linked`.
    /// Starts whatever background work finding it takes on the first call,
    /// and hands back the state a repeat call names that same work by.
    fn link_choices(&self, _state: &Values) -> Result<(ChoicesState, Values), CoreError> {
        Err(not_linkable(self.id()))
    }
    /// The values `build` needs for the chosen id, keyed the same way
    /// `Setup::Fields` values are.
    fn choice_values(&self, _state: &Values, _choice_id: &str) -> Result<Values, CoreError> {
        Err(not_linkable(self.id()))
    }
}
