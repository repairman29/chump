//! FRONTIER-002: TDA replacement for phi_proxy.
//!
//! Computes Betti numbers β₀, β₁, β₂ from blackboard module-interaction traffic
//! using a Vietoris-Rips-style simplicial complex.
//!
//! β₀ = number of connected components (isolated module clusters).
//! β₁ = number of independent interaction cycles (feedback loops).
//! β₂ = number of independent "voids" (unfilled triangulated gaps).
//!
//! Higher β₁ indicates richer feedback topology.  tda_score() combines all three
//! into a single complexity metric comparable to phi_proxy.phi_proxy.
//!
//! No external crates — boundary matrices are reduced over 𝔽₂ by hand.

use std::collections::HashMap;

/// One interaction record: (source_module, reader_module, count).
pub type TrafficRecord = (String, String, u64);

/// Vietoris-Rips-style simplicial complex built from blackboard traffic.
pub struct TdaComplex {
    /// Vertex labels (module names); indices used in simplex tuples.
    pub vertices: Vec<String>,
    /// 1-simplices: sorted pairs (i, j) with i < j.
    pub edges: Vec<(usize, usize)>,
    /// 2-simplices: sorted triples (i, j, k) with i < j < k.
    pub triangles: Vec<(usize, usize, usize)>,
}

impl TdaComplex {
    /// Build complex from interaction traffic at the given count threshold.
    ///
    /// An edge (u, v) is included when the combined u↔v traffic ≥ threshold.
    /// A triangle (u, v, w) is included when all three pairwise edges are present.
    pub fn from_traffic(traffic: &[TrafficRecord], threshold: u64) -> Self {
        let mut module_set = std::collections::BTreeSet::new();
        for (src, dst, _) in traffic {
            module_set.insert(src.clone());
            module_set.insert(dst.clone());
        }
        let vertices: Vec<String> = module_set.into_iter().collect();
        let idx: HashMap<&str, usize> = vertices
            .iter()
            .enumerate()
            .map(|(i, s)| (s.as_str(), i))
            .collect();

        // Accumulate bidirectional weights.
        let mut edge_weights: HashMap<(usize, usize), u64> = HashMap::new();
        for (src, dst, count) in traffic {
            if let (Some(&i), Some(&j)) = (idx.get(src.as_str()), idx.get(dst.as_str())) {
                if i != j {
                    let key = (i.min(j), i.max(j));
                    *edge_weights.entry(key).or_insert(0) += count;
                }
            }
        }

        let mut edge_set = std::collections::BTreeSet::new();
        for (&(i, j), &w) in &edge_weights {
            if w >= threshold {
                edge_set.insert((i, j));
            }
        }
        let edges: Vec<(usize, usize)> = edge_set.iter().cloned().collect();

        // 2-simplices: cliques of size 3.
        let n = vertices.len();
        let mut triangles = Vec::new();
        for i in 0..n {
            for j in (i + 1)..n {
                if !edge_set.contains(&(i, j)) {
                    continue;
                }
                for k in (j + 1)..n {
                    if edge_set.contains(&(i, k)) && edge_set.contains(&(j, k)) {
                        triangles.push((i, j, k));
                    }
                }
            }
        }

        TdaComplex {
            vertices,
            edges,
            triangles,
        }
    }

    /// Compute Betti numbers (β₀, β₁, β₂) via boundary-matrix rank reduction over 𝔽₂.
    ///
    /// β₀ = |V| − rank(∂₁)
    /// β₁ = |E| − rank(∂₁) − rank(∂₂)
    /// β₂ = |T| − rank(∂₂)   (no 3-simplices, so rank(∂₃) = 0)
    pub fn betti_numbers(&self) -> (usize, usize, usize) {
        let n = self.vertices.len();
        let e = self.edges.len();
        let t = self.triangles.len();

        if n == 0 {
            return (0, 0, 0);
        }

        // ∂₁: n rows × e cols — column j has 1s at the two endpoint rows.
        let rank1 = {
            let mut mat: Vec<Vec<u8>> = vec![vec![0u8; e]; n];
            for (col, &(vi, vj)) in self.edges.iter().enumerate() {
                mat[vi][col] = 1;
                mat[vj][col] = 1;
            }
            f2_rank(mat, n, e)
        };

        // ∂₂: e rows × t cols — column k has 1s at the three bounding-edge rows.
        let rank2 = if t == 0 {
            0
        } else {
            let edge_idx: HashMap<(usize, usize), usize> = self
                .edges
                .iter()
                .enumerate()
                .map(|(i, &ed)| (ed, i))
                .collect();
            let mut mat: Vec<Vec<u8>> = vec![vec![0u8; t]; e];
            for (col, &(i, j, k)) in self.triangles.iter().enumerate() {
                for pair in [(i, j), (i, k), (j, k)] {
                    if let Some(&row) = edge_idx.get(&pair) {
                        mat[row][col] = 1;
                    }
                }
            }
            f2_rank(mat, e, t)
        };

        let b0 = n - rank1;
        let b1 = e.saturating_sub(rank1 + rank2);
        let b2 = t.saturating_sub(rank2);

        (b0, b1, b2)
    }

    /// Composite TDA score analogous to phi_proxy.phi_proxy (range 0–1).
    ///
    /// β₁ (cycle richness) is the primary signal; β₀ > 1 penalises fragmentation;
    /// β₂ contributes a smaller bonus for closed higher-order topology.
    pub fn tda_score(&self) -> f64 {
        let (b0, b1, b2) = self.betti_numbers();
        let n = self.vertices.len().max(1);
        let frag_penalty = b0.saturating_sub(1) as f64 / n as f64;
        let cycle_score = b1 as f64 / n as f64;
        let void_score = b2 as f64 / n as f64;
        (cycle_score + 0.5 * void_score - 0.5 * frag_penalty).clamp(0.0, 1.0)
    }
}

/// Gaussian elimination over 𝔽₂ on a `rows × cols` matrix; returns column rank.
fn f2_rank(mut mat: Vec<Vec<u8>>, rows: usize, cols: usize) -> usize {
    let mut rank = 0usize;
    let mut pivot_row = 0usize;
    for col in 0..cols {
        let found = (pivot_row..rows).find(|&r| mat[r][col] == 1);
        let Some(r) = found else { continue };
        mat.swap(pivot_row, r);
        rank += 1;
        for other in 0..rows {
            if other != pivot_row && mat[other][col] == 1 {
                let pivot_row_copy = mat[pivot_row].clone();
                for (dst, &src) in mat[other].iter_mut().zip(pivot_row_copy.iter()) {
                    *dst ^= src;
                }
            }
        }
        pivot_row += 1;
    }
    rank
}

/// Compute Betti numbers from the global blackboard at the given traffic threshold.
pub fn betti_from_global_blackboard(threshold: u64) -> (usize, usize, usize) {
    let bb = crate::blackboard::global();
    let reads = bb.cross_module_reads();
    let traffic: Vec<TrafficRecord> = reads
        .iter()
        .map(|((reader, source), &count)| (source.to_string(), reader.to_string(), count))
        .collect();
    TdaComplex::from_traffic(&traffic, threshold).betti_numbers()
}

/// Compute the TDA score from the global blackboard at the given threshold.
pub fn tda_score_from_global(threshold: u64) -> f64 {
    let bb = crate::blackboard::global();
    let reads = bb.cross_module_reads();
    let traffic: Vec<TrafficRecord> = reads
        .iter()
        .map(|((reader, source), &count)| (source.to_string(), reader.to_string(), count))
        .collect();
    TdaComplex::from_traffic(&traffic, threshold).tda_score()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn mk(src: &str, dst: &str, n: u64) -> TrafficRecord {
        (src.to_string(), dst.to_string(), n)
    }

    #[test]
    fn empty_traffic_gives_zero_betti() {
        let c = TdaComplex::from_traffic(&[], 1);
        assert_eq!(c.betti_numbers(), (0, 0, 0));
    }

    #[test]
    fn single_edge_one_component_no_cycles() {
        let t = vec![mk("A", "B", 5)];
        let c = TdaComplex::from_traffic(&t, 1);
        let (b0, b1, b2) = c.betti_numbers();
        assert_eq!(b0, 1, "connected pair is one component");
        assert_eq!(b1, 0, "no cycles");
        assert_eq!(b2, 0);
    }

    #[test]
    fn triangle_graph_filled_by_2simplex() {
        // All 3 edges present → 2-simplex added → cycle filled → β₁ = 0.
        let t = vec![mk("A", "B", 5), mk("B", "C", 5), mk("A", "C", 5)];
        let c = TdaComplex::from_traffic(&t, 1);
        assert_eq!(c.edges.len(), 3);
        assert_eq!(c.triangles.len(), 1, "triangle 2-simplex should be added");
        let (b0, b1, b2) = c.betti_numbers();
        assert_eq!(b0, 1);
        assert_eq!(b1, 0, "2-simplex fills the cycle");
        assert_eq!(b2, 0);
    }

    #[test]
    fn four_cycle_has_one_independent_cycle() {
        // A-B-C-D-A without diagonals → no 2-simplices → β₁ = 1.
        let t = vec![
            mk("A", "B", 5),
            mk("B", "C", 5),
            mk("C", "D", 5),
            mk("A", "D", 5),
        ];
        let c = TdaComplex::from_traffic(&t, 1);
        assert_eq!(c.triangles.len(), 0, "no triangles in a 4-cycle");
        let (b0, b1, b2) = c.betti_numbers();
        assert_eq!(b0, 1);
        assert_eq!(b1, 1, "one independent 4-cycle");
        assert_eq!(b2, 0);
    }

    #[test]
    fn below_threshold_edge_excluded() {
        let t = vec![mk("A", "B", 1), mk("B", "C", 10)];
        let c = TdaComplex::from_traffic(&t, 5);
        assert_eq!(c.edges.len(), 1, "only B-C meets threshold");
        let (b0, b1, _) = c.betti_numbers();
        assert_eq!(b0, 2, "A is an isolated component");
        assert_eq!(b1, 0);
    }

    #[test]
    fn two_disconnected_components() {
        let t = vec![mk("A", "B", 5), mk("C", "D", 5)];
        let c = TdaComplex::from_traffic(&t, 1);
        let (b0, b1, _) = c.betti_numbers();
        assert_eq!(b0, 2);
        assert_eq!(b1, 0);
    }

    #[test]
    fn tda_score_higher_for_cyclic_topology() {
        // 4-cycle (β₁=1) should score higher than a linear path (β₁=0).
        let cyclic = vec![
            mk("A", "B", 5),
            mk("B", "C", 5),
            mk("C", "D", 5),
            mk("A", "D", 5),
        ];
        let linear = vec![mk("A", "B", 5), mk("B", "C", 5), mk("C", "D", 5)];
        let score_c = TdaComplex::from_traffic(&cyclic, 1).tda_score();
        let score_l = TdaComplex::from_traffic(&linear, 1).tda_score();
        assert!(
            score_c > score_l,
            "cyclic {score_c} should beat linear {score_l}"
        );
    }

    #[test]
    fn f2_rank_full_identity_3x3() {
        let mat = vec![vec![1u8, 0, 0], vec![0, 1, 0], vec![0, 0, 1]];
        assert_eq!(f2_rank(mat, 3, 3), 3);
    }

    #[test]
    fn f2_rank_all_same_rows_is_one() {
        let mat = vec![vec![1u8, 1, 1], vec![1, 1, 1], vec![1, 1, 1]];
        assert_eq!(f2_rank(mat, 3, 3), 1);
    }

    #[test]
    fn bidirectional_traffic_merges_weights() {
        // A→B with 3 + B→A with 3 = 6 total, threshold 5 → edge present.
        let t = vec![mk("A", "B", 3), mk("B", "A", 3)];
        let c = TdaComplex::from_traffic(&t, 5);
        assert_eq!(c.edges.len(), 1);
    }
}
