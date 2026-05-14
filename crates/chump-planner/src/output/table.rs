//! Plain-text table output for `chump plan --format table`.

use crate::plan::PlanItem;
use crate::reconcile::ReconcileReport;
use std::fmt::Write;

const TITLE_MAX: usize = 70;

pub fn render(plan: &[PlanItem], reconcile: &ReconcileReport) -> String {
    let mut out = String::new();

    if !reconcile.entries.is_empty() {
        write_reconcile_block(&mut out, reconcile);
    }

    if plan.is_empty() {
        out.push_str("(no pickable gaps under current filters)\n");
        return out;
    }

    let _ = writeln!(
        out,
        "{:<5} {:<14} {:<3} {:<3} {:<7} {:<5} TITLE",
        "RANK", "GAP-ID", "P", "EFF", "SCORE", "UNBLK"
    );
    let _ = writeln!(out, "{}", "-".repeat(50));

    for (i, item) in plan.iter().enumerate() {
        let rank = i + 1;
        let title = truncate(&item.gap.title, TITLE_MAX);
        let _ = writeln!(
            out,
            "{:<5} {:<14} {:<3} {:<3} {:<7.1} {:<5} {}",
            format!("{rank}."),
            item.gap.id,
            item.gap.priority.as_str(),
            item.gap.effort.as_str(),
            item.score.total,
            item.score.unblocks_count,
            title,
        );
    }

    out
}

fn write_reconcile_block(out: &mut String, r: &ReconcileReport) {
    let _ = writeln!(
        out,
        "⚠  {} gap(s) need reconciliation (status:open with closed_pr set)",
        r.entries.len()
    );
    let preview: Vec<String> = r
        .entries
        .iter()
        .take(5)
        .map(|e| {
            format!(
                "   {} → #{} {}",
                e.gap_id,
                e.closed_pr,
                truncate(&e.title, 60)
            )
        })
        .collect();
    if !preview.is_empty() {
        out.push_str(&preview.join("\n"));
        out.push('\n');
        if r.entries.len() > 5 {
            let _ = writeln!(out, "   …and {} more", r.entries.len() - 5);
        }
    }
    out.push_str("   Run scripts/coord/gap-doctor-reconcile.py to clear.\n\n");
}

fn truncate(s: &str, max: usize) -> String {
    if s.chars().count() <= max {
        s.to_string()
    } else {
        let mut t: String = s.chars().take(max.saturating_sub(1)).collect();
        t.push('…');
        t
    }
}
