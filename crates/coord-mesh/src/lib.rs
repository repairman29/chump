//! INFRA-2264 (INFRA-1815-sideA) activation shim.
//!
//! `MeshBridge` is a local placeholder standing in for the real coord-mesh
//! types that will eventually be re-exported from the internal sibling
//! repo's `coord-mesh` crate (see Cargo.toml for why the git dependency
//! itself isn't wired in yet).

pub struct MeshBridge;

impl MeshBridge {
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

    // INFRA-2264: coord-mesh crate builds and MeshBridge::new() constructs.
    #[test]
    fn mesh_bridge_new_constructs() {
        let _bridge = MeshBridge::new();
        let _default = MeshBridge::default();
    }
}
