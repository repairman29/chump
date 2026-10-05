//! `coord-mesh` — INFRA-1815-sideA / INFRA-2264.
//!
//! Local stand-in for the `coord-mesh` crate that will eventually live in
//! the internal sibling repo and be consumed via a git dependency (see
//! `crates/coord-mesh/Cargo.toml` for why that dependency isn't active
//! yet). `MeshBridge` is the minimal public surface `src/dispatch.rs`
//! activates today.

/// Entry point into the coordination mesh substrate.
pub struct MeshBridge;

impl MeshBridge {
    /// Construct a new bridge handle.
    pub fn new() -> Self {
        Self
    }
}

impl Default for MeshBridge {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // INFRA-2264: smoke-tests the public surface dispatch.rs's
    // create_dispatch_worktree activates.
    #[test]
    #[allow(clippy::default_constructed_unit_structs)] // exercises the Default impl on purpose
    fn mesh_bridge_new_and_default_construct() {
        let _ = MeshBridge::new();
        let _ = MeshBridge::default();
    }
}
