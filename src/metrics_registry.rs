//! INFRA-4493: metrics registry specification (INFRA-3842 slice).
//! Defines the `MetricsRegistry` trait interface — a minimal contract for
//! registering, updating, and reading named gauge metrics. Concrete
//! implementations (in-memory, persisted, etc.) land in follow-up slices.

/// A registry of named gauge metrics.
pub trait MetricsRegistry {
    /// Register a new gauge with an initial value.
    fn register_gauge(&mut self, name: &str, value: f64);

    /// Update an existing gauge to a new value.
    fn update_gauge(&mut self, name: &str, value: f64);

    /// Read the current value of a gauge, if it has been registered.
    fn get_gauge(&self, name: &str) -> Option<f64>;
}
