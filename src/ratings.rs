//! Math algorithms for skill evolution and Bradley-Terry A/B competition matching.
//!
//! Exposes Elo and Bradley-Terry functions for shifting variant scores based on outcome.
//! Expected base rating is 1500.0.

use serde::Serialize;

/// Computes the expected probability of A winning against B in a Bradley-Terry model.
/// `rating_a` and `rating_b` are absolute ratings (e.g., 1500.0).
pub fn expected_probability(rating_a: f64, rating_b: f64) -> f64 {
    1.0 / (1.0 + 10.0_f64.powf((rating_b - rating_a) / 400.0))
}

/// A single win-probability prediction, namespaced for cross-table
/// reconciliation (INFRA-3850, parent INFRA-3841): the field is `p_win`,
/// never a bare `p`, so joining rating predictions against the pr_book
/// (`p_merge`) and nba (`p`) tables in a shared log can't collide on a bare
/// `ev`/`p` column name.
#[derive(Debug, Serialize, PartialEq)]
pub struct MatchPrediction {
    pub p_win: f64,
}

/// Same computation as `expected_probability`, returned as the namespaced
/// `p_win` column instead of a bare `f64`.
pub fn predict_win(rating_a: f64, rating_b: f64) -> MatchPrediction {
    MatchPrediction {
        p_win: expected_probability(rating_a, rating_b),
    }
}

/// Updates Bradley-Terry / Elo ratings based on the outcome of a contest between A and B.
///
/// `outcome_a`: 1.0 if A wins, 0.5 for a draw, 0.0 if B wins (A loses).
/// `k_factor`: Max shift per match (commonly 32.0).
///
/// Returns a tuple `(new_rating_a, new_rating_b)`.
pub fn update_ratings(rating_a: f64, rating_b: f64, outcome_a: f64, k_factor: f64) -> (f64, f64) {
    let outcome_a = outcome_a.clamp(0.0, 1.0);
    let outcome_b = 1.0 - outcome_a;

    let prob_a = expected_probability(rating_a, rating_b);
    let prob_b = expected_probability(rating_b, rating_a);

    let new_rating_a = rating_a + k_factor * (outcome_a - prob_a);
    let new_rating_b = rating_b + k_factor * (outcome_b - prob_b);

    (new_rating_a, new_rating_b)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_expected_probability() {
        // Equal ratings = 50% probability
        let prob = expected_probability(1500.0, 1500.0);
        assert!((prob - 0.5).abs() < 1e-6);

        // A is much better than B
        let prob_a = expected_probability(1900.0, 1500.0);
        assert!(prob_a > 0.90);
    }

    #[test]
    fn test_update_ratings() {
        let (new_a, new_b) = update_ratings(1500.0, 1500.0, 1.0, 32.0);
        assert_eq!(new_a, 1516.0);
        assert_eq!(new_b, 1484.0);

        // A draw between equals should result in no net shift
        let (new_a, new_b) = update_ratings(1500.0, 1500.0, 0.5, 32.0);
        assert_eq!(new_a, 1500.0);
        assert_eq!(new_b, 1500.0);
    }

    #[test]
    fn test_predict_win_uses_namespaced_p_win_column() {
        let pred = predict_win(1500.0, 1500.0);
        assert!((pred.p_win - 0.5).abs() < 1e-6);

        // Serialized column must be the namespaced `p_win`, never a bare `p`
        // that could collide with pr_book/nba tables sharing the same log.
        let json = serde_json::to_string(&pred).unwrap();
        assert!(
            json.contains("\"p_win\""),
            "expected namespaced p_win field, got: {json}"
        );
        assert!(
            !json.contains("\"p\":"),
            "must not emit a bare `p` column, got: {json}"
        );
    }
}
