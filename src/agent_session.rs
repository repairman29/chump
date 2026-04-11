//! Thread-local active web/file session id for context retrieval (FTS) inside the provider.

use std::cell::RefCell;

thread_local! {
    static ACTIVE_SESSION: RefCell<Option<String>> = const { RefCell::new(None) };
}

pub fn set_active_session_id(id: Option<&str>) {
    ACTIVE_SESSION.with(|c| {
        *c.borrow_mut() = id.map(|s| s.to_string());
    });
}

pub fn active_session_id() -> Option<String> {
    ACTIVE_SESSION.with(|c| c.borrow().clone())
}
