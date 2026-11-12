use super::module::{
    Choice, ChoicesState, Field, FieldKind, LinkStart, LinkState, Setup, SourceModule, Values,
};
use super::{Entry, ReadSeek, Source, SourceError};
use crate::api::CoreError;
use std::sync::Arc;

pub fn fixtures() -> Vec<Arc<dyn SourceModule>> {
    vec![
        Arc::new(FieldsTestModule),
        Arc::new(LinkTestModule),
        Arc::new(ExpiredLinkTestModule),
        Arc::new(WaitingLinkTestModule),
    ]
}

struct EmptyTestSource(String);

impl Source for EmptyTestSource {
    fn id(&self) -> &str {
        &self.0
    }
    fn list(&self, _dir_path: &str) -> Result<Vec<Entry>, SourceError> {
        Ok(Vec::new())
    }
    fn open(&self, file_path: &str) -> Result<Box<dyn ReadSeek>, SourceError> {
        Err(SourceError::NotFound(file_path.to_string()))
    }
}

/// Proves the generic Setup::Fields path with no filesystem and no network.
pub struct FieldsTestModule;

impl SourceModule for FieldsTestModule {
    fn id(&self) -> &'static str {
        "test-fields"
    }
    fn setup(&self) -> Setup {
        Setup::Fields(vec![Field {
            key: "label",
            kind: FieldKind::Text,
            required: true,
        }])
    }
    fn detail(&self, values: &Values) -> String {
        values.get("label").cloned().unwrap_or_default()
    }
    fn secret_keys(&self) -> &'static [&'static str] {
        &[]
    }
    fn build(&self, id: &str, _values: &Values) -> Result<Arc<dyn Source>, CoreError> {
        Ok(Arc::new(EmptyTestSource(id.to_string())))
    }
}

/// Proves the generic Setup::Link path: a fixed code, linked on the first
/// poll, one choice.
pub struct LinkTestModule;

impl SourceModule for LinkTestModule {
    fn id(&self) -> &'static str {
        "test-link"
    }
    fn setup(&self) -> Setup {
        Setup::Link
    }
    fn detail(&self, values: &Values) -> String {
        values.get("label").cloned().unwrap_or_default()
    }
    fn secret_keys(&self) -> &'static [&'static str] {
        &["secret"]
    }
    fn build(&self, id: &str, _values: &Values) -> Result<Arc<dyn Source>, CoreError> {
        Ok(Arc::new(EmptyTestSource(id.to_string())))
    }
    fn link_start(&self, _install_id: &str) -> Result<LinkStart, CoreError> {
        Ok(LinkStart {
            code: "TEST".to_string(),
            state: Values::new(),
        })
    }
    fn link_poll(
        &self,
        _install_id: &str,
        state: &Values,
    ) -> Result<(LinkState, Values), CoreError> {
        Ok((LinkState::Linked, state.clone()))
    }
    fn link_choices(&self, state: &Values) -> Result<(ChoicesState, Values), CoreError> {
        Ok((
            ChoicesState::Ready {
                choices: vec![Choice {
                    id: "only".to_string(),
                    name: "Only choice".to_string(),
                    detail: "the one thing this account holds".to_string(),
                    reachable: true,
                    nearby: true,
                }],
            },
            state.clone(),
        ))
    }
    fn choice_values(&self, _state: &Values, choice_id: &str) -> Result<Values, CoreError> {
        let mut v = Values::new();
        v.insert("label".to_string(), choice_id.to_string());
        v.insert("secret".to_string(), "linked-secret".to_string());
        Ok(v)
    }
}

/// A link that never succeeds: proves the Expired path generically.
pub struct ExpiredLinkTestModule;

impl SourceModule for ExpiredLinkTestModule {
    fn id(&self) -> &'static str {
        "test-link-expired"
    }
    fn setup(&self) -> Setup {
        Setup::Link
    }
    fn detail(&self, _values: &Values) -> String {
        String::new()
    }
    fn secret_keys(&self) -> &'static [&'static str] {
        &[]
    }
    fn build(&self, id: &str, _values: &Values) -> Result<Arc<dyn Source>, CoreError> {
        Ok(Arc::new(EmptyTestSource(id.to_string())))
    }
    fn link_start(&self, _install_id: &str) -> Result<LinkStart, CoreError> {
        Ok(LinkStart {
            code: "GONE".to_string(),
            state: Values::new(),
        })
    }
    fn link_poll(
        &self,
        _install_id: &str,
        state: &Values,
    ) -> Result<(LinkState, Values), CoreError> {
        Ok((LinkState::Expired, state.clone()))
    }
}

/// A code nobody ever uses: proves a wait on it ends when the link does.
pub struct WaitingLinkTestModule;

impl SourceModule for WaitingLinkTestModule {
    fn id(&self) -> &'static str {
        "test-link-waiting"
    }
    fn setup(&self) -> Setup {
        Setup::Link
    }
    fn detail(&self, _values: &Values) -> String {
        String::new()
    }
    fn secret_keys(&self) -> &'static [&'static str] {
        &[]
    }
    fn build(&self, id: &str, _values: &Values) -> Result<Arc<dyn Source>, CoreError> {
        Ok(Arc::new(EmptyTestSource(id.to_string())))
    }
    fn link_start(&self, _install_id: &str) -> Result<LinkStart, CoreError> {
        Ok(LinkStart {
            code: "WAIT".to_string(),
            state: Values::new(),
        })
    }
    fn link_poll(
        &self,
        _install_id: &str,
        state: &Values,
    ) -> Result<(LinkState, Values), CoreError> {
        Ok((LinkState::Waiting, state.clone()))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::source::module::FieldKind;

    #[test]
    fn the_registry_carries_both_fixtures_and_nothing_by_name() {
        let ids: Vec<&str> = super::super::modules().iter().map(|m| m.id()).collect();
        assert!(ids.contains(&"test-fields"));
        assert!(ids.contains(&"test-link"));
        assert!(ids.contains(&"test-link-expired"));
    }

    #[test]
    fn a_fields_module_builds_and_describes_from_its_own_values() {
        let m = FieldsTestModule;
        let Setup::Fields(fields) = m.setup() else {
            panic!("expected Fields");
        };
        assert_eq!(fields[0].key, "label");
        assert_eq!(fields[0].kind, FieldKind::Text);
        let mut values = Values::new();
        values.insert("label".to_string(), "a label".to_string());
        assert_eq!(m.detail(&values), "a label");
        let built = m.build("id1", &values).unwrap();
        assert_eq!(built.id(), "id1");
    }

    #[test]
    fn a_link_module_walks_code_then_choice_without_a_typed_id() {
        let m = LinkTestModule;
        let started = m.link_start("test-install").unwrap();
        assert_eq!(started.code, "TEST");
        let (state, next) = m.link_poll("test-install", &started.state).unwrap();
        assert_eq!(state, LinkState::Linked);
        let (choices_state, next) = m.link_choices(&next).unwrap();
        let ChoicesState::Ready { choices } = choices_state else {
            panic!("expected Ready");
        };
        assert_eq!(choices[0].id, "only");
        let values = m.choice_values(&next, &choices[0].id).unwrap();
        assert_eq!(values.get("label"), Some(&"only".to_string()));
        assert!(m.secret_keys().contains(&"secret"));
    }

    #[test]
    fn a_link_that_never_takes_reports_expired() {
        let m = ExpiredLinkTestModule;
        let started = m.link_start("test-install").unwrap();
        let (state, _) = m.link_poll("test-install", &started.state).unwrap();
        assert_eq!(state, LinkState::Expired);
    }

    #[test]
    fn a_fields_module_refuses_to_link() {
        let m = FieldsTestModule;
        assert!(m.link_start("test-install").is_err());
    }
}
