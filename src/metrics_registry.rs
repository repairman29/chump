//! INFRA-3842 slice: metrics registry specification and interface.
//! Defines the `MetricsRegistry` trait gauge implementations conform to.

use std::collections::HashMap;
use std::sync::RwLock;

/// A registry of named gauge metrics.
pub trait MetricsRegistry {
    /// Registers a gauge with an initial value.
    fn register_gauge(&self, name: &str, value: f64);
    /// Updates an existing (or implicitly registers a new) gauge's value.
    fn update_gauge(&self, name: &str, value: f64);
    /// Returns the current value of a gauge, if it has been registered.
    fn get_gauge(&self, name: &str) -> Option<f64>;
}

/// In-memory `MetricsRegistry` backed by a `RwLock<HashMap>`.
#[derive(Default)]
pub struct InMemoryMetricsRegistry {
    gauges: RwLock<HashMap<String, f64>>,
}

impl InMemoryMetricsRegistry {
    pub fn new() -> Self {
        Self::default()
    }
}

impl MetricsRegistry for InMemoryMetricsRegistry {
    fn register_gauge(&self, name: &str, value: f64) {
        self.gauges
            .write()
            .expect("gauges lock poisoned")
            .insert(name.to_string(), value);
    }

    fn update_gauge(&self, name: &str, value: f64) {
        self.gauges
            .write()
            .expect("gauges lock poisoned")
            .insert(name.to_string(), value);
    }

    fn get_gauge(&self, name: &str) -> Option<f64> {
        self.gauges
            .read()
            .expect("gauges lock poisoned")
            .get(name)
            .copied()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn register_then_get() {
        let registry = InMemoryMetricsRegistry::new();
        registry.register_gauge("gap_backlog", 42.0);
        assert_eq!(registry.get_gauge("gap_backlog"), Some(42.0));
    }

    #[test]
    fn update_overwrites() {
        let registry = InMemoryMetricsRegistry::new();
        registry.register_gauge("ship_rate", 1.0);
        registry.update_gauge("ship_rate", 2.5);
        assert_eq!(registry.get_gauge("ship_rate"), Some(2.5));
    }

    #[test]
    fn missing_gauge_is_none() {
        let registry = InMemoryMetricsRegistry::new();
        assert_eq!(registry.get_gauge("nonexistent"), None);
    }
}
