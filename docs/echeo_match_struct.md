# echeo `Match` struct — field reference

Source: `repairman29/echeo`, `src/matchmaker.rs::Match` (lines 22-28), per the
almanac index for `echeo` (INFRA-1816 slice). See also
[`docs/echeo_ship_velocity_score.md`](./echeo_ship_velocity_score.md) for the
`score` field's scoring formula and
[`docs/arsenal/cross-pollination/CP-005-echeo-ship-velocity-score.md`](./arsenal/cross-pollination/CP-005-echeo-ship-velocity-score.md)
for full cross-pollination context.

```rust
// echeo/src/matchmaker.rs:22-28 (verbatim)
pub struct Match {
    pub need: Need,
    pub capability: EmbeddedCapability,
    pub score: f32,           // Ship Velocity Score (0.0 - 1.0)
    pub reasons: Vec<String>, // Why this is a match
}
```

## Fields

| Field | Type | Meaning |
|---|---|---|
| `need` | [`Need`](#related-need-struct) | The need this match was produced for — a candidate demand/bounty the matcher tried to fill. |
| `capability` | [`EmbeddedCapability`](#related-embeddedcapability-struct) | The capability (code snippet + embedding) selected as satisfying `need`. |
| `score` | `f32` | The Ship Velocity Score, range `0.0`–`1.0`. Computed by `calculate_ship_velocity_score` — see [`docs/echeo_ship_velocity_score.md`](./echeo_ship_velocity_score.md) for the exact formula (cosine base + language/kind boosts, clamped to `1.0`). |
| `reasons` | `Vec<String>` | Human-readable explanations for why the match scored as it did (e.g. `"High semantic similarity (82%)"`, `"Language match: rust"`), accumulated alongside `score` in the same scoring pass. |

## Related: `Need` struct

`src/matchmaker.rs:13-21`, referenced by `Match.need`:

```rust
pub struct Need {
    pub id: String,
    pub title: String,
    pub description: String,
    pub bounty: Option<String>, // e.g., "$2,500 (USDC)"
    pub embedding: Vec<f32>,
}
```

## Related: `EmbeddedCapability` struct

`src/vectorizer.rs`, referenced by `Match.capability`:

```rust
pub struct EmbeddedCapability {
    pub name: String,
    pub code_snippet: String,
    pub embedding: Vec<f32>,
    pub language: String,
    pub kind: String,
    pub path: String,
    pub line: usize,
    // Authorship fields (optional for backward compatibility)
    pub author_email: Option<String>,
    pub author_name: Option<String>,
    pub commit_sha: Option<String>,
    pub authorship_confidence: Option<f64>,
    pub is_self_authored: Option<bool>,
    pub contribution_percentage: Option<f64>,
}
```
