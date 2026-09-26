//! Local placeholder for the coord-mesh substrate (INFRA-1815-sideA / INFRA-2264).
//! See crates/coord-mesh/Cargo.toml for why this is local rather than a git dep.

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

    // INFRA-2264: MeshBridge::new() must construct without panicking so
    // create_dispatch_worktree's `let _bridge = MeshBridge::new();` compiles
    // and runs cleanly.
    #[test]
    fn mesh_bridge_new_constructs() {
        let _bridge = MeshBridge::new();
        let _default = MeshBridge::default();
    }
}
