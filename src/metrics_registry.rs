//! Metrics registry specification — trait interface for registering and
//! updating gauge-style metrics (INFRA-3842 slice).

/// A registry of named gauge metrics.
pub trait MetricsRegistry {
    /// Register a new gauge metric with an initial value.
    fn register_gauge(&mut self, name: &str, value: f64);

    /// Update an existing gauge metric's value.
    fn update_gauge(&mut self, name: &str, value: f64);

    /// Fetch the current value of a gauge metric, if registered.
    fn get_gauge(&self, name: &str) -> Option<f64>;
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashMap;

    struct InMemoryMetricsRegistry {
        gauges: HashMap<String, f64>,
    }

    impl MetricsRegistry for InMemoryMetricsRegistry {
        fn register_gauge(&mut self, name: &str, value: f64) {
            self.gauges.insert(name.to_string(), value);
        }

        fn update_gauge(&mut self, name: &str, value: f64) {
            self.gauges.insert(name.to_string(), value);
        }

        fn get_gauge(&self, name: &str) -> Option<f64> {
            self.gauges.get(name).copied()
        }
    }

    #[test]
    fn register_update_get_roundtrip() {
        let mut registry = InMemoryMetricsRegistry {
            gauges: HashMap::new(),
        };

        assert_eq!(registry.get_gauge("queue_depth"), None);

        registry.register_gauge("queue_depth", 3.0);
        assert_eq!(registry.get_gauge("queue_depth"), Some(3.0));

        registry.update_gauge("queue_depth", 7.0);
        assert_eq!(registry.get_gauge("queue_depth"), Some(7.0));

        assert_eq!(registry.get_gauge("missing"), None);
    }
}
