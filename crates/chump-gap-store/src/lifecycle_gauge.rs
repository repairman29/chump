//! CREDIBLE-299 slice: per-gap lifecycle gauge — records which stage a gap
//! reached (reserved -> claimed -> built -> shipped) so credibility audits
//! can answer "did the code actually get built" as a discrete, queryable
//! signal instead of inferring it from PR state.

use std::collections::HashMap;

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub enum LifecycleStage {
    Reserved,
    Claimed,
    Built,
    Shipped,
}

#[derive(Debug, Default)]
pub struct LifecycleGauge {
    stages: HashMap<String, LifecycleStage>,
}

impl LifecycleGauge {
    pub fn new() -> Self {
        Self::default()
    }

    /// Records that `gap_id` reached the `Built` stage.
    pub fn record_built(&mut self, gap_id: &str) {
        self.stages
            .insert(gap_id.to_string(), LifecycleStage::Built);
    }

    /// Invoked when a gap's code path actually builds; advances the gauge
    /// to the `Built` stage for that gap.
    pub fn build(&mut self, gap_id: &str) {
        self.record_built(gap_id);
    }

    pub fn stage(&self, gap_id: &str) -> Option<LifecycleStage> {
        self.stages.get(gap_id).copied()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn build_advances_gauge_to_built_stage() {
        let mut gauge = LifecycleGauge::new();
        assert_eq!(gauge.stage("CREDIBLE-810"), None);

        gauge.build("CREDIBLE-810");

        assert_eq!(gauge.stage("CREDIBLE-810"), Some(LifecycleStage::Built));
    }
}
