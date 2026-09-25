//! INFRA-4493 (INFRA-3842 slice): metrics registry specification and interface.
//! Defines the `MetricsRegistry` trait — a minimal gauge-style metrics interface
//! that concrete registries (in-memory, Prometheus-backed, etc.) can implement.

/// A registry of named gauge metrics.
pub trait MetricsRegistry {
    /// Register a new gauge metric with an initial value.
    fn register_gauge(&mut self, name: &str, value: f64);

    /// Update the value of an existing gauge metric.
    fn update_gauge(&mut self, name: &str, value: f64);

    /// Get the current value of a gauge metric, if it exists.
    fn get_gauge(&self, name: &str) -> Option<f64>;
}
