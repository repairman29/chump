//! Metrics registry specification — trait interface for gauge-style metrics
//! (INFRA-3842 slice). Defines the contract only; concrete storage backends
//! implement `MetricsRegistry` in follow-up slices.

pub trait MetricsRegistry {
    fn register_gauge(&mut self, name: &str, value: f64);
    fn update_gauge(&mut self, name: &str, value: f64);
    fn get_gauge(&self, name: &str) -> Option<f64>;
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashMap;

    #[derive(Default)]
    struct InMemoryRegistry {
        gauges: HashMap<String, f64>,
    }

    impl MetricsRegistry for InMemoryRegistry {
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

    // INFRA-4493: MetricsRegistry trait registers/updates/reads gauges.
    #[test]
    fn infra_4493_register_update_get_gauge() {
        let mut registry = InMemoryRegistry::default();
        assert_eq!(registry.get_gauge("queue_depth"), None);

        registry.register_gauge("queue_depth", 1.0);
        assert_eq!(registry.get_gauge("queue_depth"), Some(1.0));

        registry.update_gauge("queue_depth", 2.0);
        assert_eq!(registry.get_gauge("queue_depth"), Some(2.0));
    }
}
