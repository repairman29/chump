//! INFRA-4493: metrics registry specification and interface (INFRA-3842 slice).
//! Defines the `MetricsRegistry` trait — the common surface future metrics
//! backends (in-memory, Prometheus, etc.) implement against.

use std::collections::HashMap;
use std::sync::Mutex;

/// Common surface for registering, updating, and reading gauge metrics.
pub trait MetricsRegistry {
    fn register_gauge(&self, name: &str, value: f64);
    fn update_gauge(&self, name: &str, value: f64);
    fn get_gauge(&self, name: &str) -> Option<f64>;
}

/// In-memory `MetricsRegistry` implementation backed by a `HashMap`.
#[derive(Default)]
pub struct InMemoryMetricsRegistry {
    gauges: Mutex<HashMap<String, f64>>,
}

impl InMemoryMetricsRegistry {
    pub fn new() -> Self {
        Self::default()
    }
}

impl MetricsRegistry for InMemoryMetricsRegistry {
    fn register_gauge(&self, name: &str, value: f64) {
        self.gauges.lock().unwrap().insert(name.to_string(), value);
    }

    fn update_gauge(&self, name: &str, value: f64) {
        self.gauges.lock().unwrap().insert(name.to_string(), value);
    }

    fn get_gauge(&self, name: &str) -> Option<f64> {
        self.gauges.lock().unwrap().get(name).copied()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn register_update_get_gauge() {
        let registry = InMemoryMetricsRegistry::new();
        registry.register_gauge("queue_depth", 1.0);
        assert_eq!(registry.get_gauge("queue_depth"), Some(1.0));

        registry.update_gauge("queue_depth", 2.0);
        assert_eq!(registry.get_gauge("queue_depth"), Some(2.0));

        assert_eq!(registry.get_gauge("missing"), None);
    }
}
