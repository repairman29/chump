//! `chump gap` command helpers (`link-pr` canonical-store guard, RESILIENT-1650).
//!
//! Ensures `chump gap link-pr` refuses to write `gap_prs` into a store whose
//! directory carries a `NONCANONICAL` or `CHUMP_STORE_ARCHIVED` marker file.

use anyhow::{bail, Result};
use std::path::{Path, PathBuf};

/// RESILIENT-1650 (Phase R R4): return the marker path if `store_dir_or_db`
/// sits in or points to a `.chump` directory carrying a `NONCANONICAL` or
/// `CHUMP_STORE_ARCHIVED` marker.
pub fn noncanonical_store_marker(store_dir_or_db: &Path) -> Option<PathBuf> {
    if store_dir_or_db.is_dir() {
        if let Some(m) =
            chump_gap_store::GapStore::store_noncanonical_marker_in_dir(store_dir_or_db)
        {
            return Some(m);
        }
        return chump_gap_store::GapStore::store_noncanonical_marker_in_dir(
            &store_dir_or_db.join(".chump"),
        );
    }
    chump_gap_store::GapStore::store_noncanonical_marker(store_dir_or_db)
}

/// RESILIENT-1650: guard + write a `gap_prs` link via `GapStore::link_pr_opts`,
/// refusing when the target store carries a `NONCANONICAL` or
/// `CHUMP_STORE_ARCHIVED` marker.
pub fn link_pr_into_store(
    repo_root: &Path,
    gap_id: &str,
    pr_number: i64,
    head_sha: &str,
    multi: bool,
    move_link: bool,
) -> Result<()> {
    if let Some(marker) = noncanonical_store_marker(repo_root) {
        bail!(
            "RESILIENT-1650: chump gap link-pr refused — target store at {} carries non-canonical marker {}",
            repo_root.display(),
            marker.display()
        );
    }
    let store = chump_gap_store::GapStore::open(repo_root)?;
    store.link_pr_opts(gap_id, pr_number, head_sha, multi, move_link)
}

/// INFRA-8108: emit a `kind=gap_shipped` event to `.chump-locks/ambient.jsonl`
/// whenever `chump gap ship` transitions a gap to `done`.
/// # scanner-anchor: "kind":"gap_shipped"
pub fn emit_gap_shipped(
    repo_root: &Path,
    gap_id: &str,
    session_id: &str,
    closed_pr: Option<i64>,
) -> Result<()> {
    use std::io::Write as _;
    let ts = chrono::Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string();
    let pr_str = closed_pr
        .map(|pr| format!(",\"closed_pr\":{pr},\"pr_number\":{pr}"))
        .unwrap_or_default();
    let line = format!(
        "{{\"ts\":\"{ts}\",\"kind\":\"gap_shipped\",\"gap_id\":\"{gap_id}\",\"session\":\"{session_id}\"{pr_str}}}\n"
    );
    let locks = repo_root.join(".chump-locks");
    std::fs::create_dir_all(&locks)?;
    let amb = locks.join("ambient.jsonl");
    let mut f = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&amb)?;
    f.write_all(line.as_bytes())?;
    Ok(())
}

/// CREDIBLE-1647: Validate a product-delivery receipt JSON (`probe_status == "ok"`
/// and non-empty `deploy_id`) for a `PRODUCT-*` gap and emit
/// `kind=product_delivery_verified` to `.chump-locks/ambient.jsonl`.
/// # scanner-anchor: "kind":"product_delivery_verified"
pub fn verify_product_delivery_receipt(
    repo_root: &Path,
    gap_id: &str,
    receipt_json: &str,
) -> Result<()> {
    use std::io::Write as _;
    let parsed: serde_json::Value = serde_json::from_str(receipt_json).map_err(|e| {
        anyhow::anyhow!("CREDIBLE-1647: invalid product delivery receipt JSON for {gap_id}: {e}")
    })?;
    let probe_status = parsed
        .get("probe_status")
        .and_then(|v| v.as_str())
        .unwrap_or("");
    let deploy_id = parsed
        .get("deploy_id")
        .and_then(|v| v.as_str())
        .unwrap_or("")
        .trim();
    if probe_status != "ok" || deploy_id.is_empty() {
        bail!(
            "CREDIBLE-1647: product gap {gap_id} requires live delivery receipt with probe_status=\"ok\" and non-empty deploy_id (got probe_status={probe_status:?}, deploy_id={deploy_id:?})"
        );
    }
    let ts = chrono::Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string();
    let line = format!(
        "{{\"ts\":\"{ts}\",\"kind\":\"product_delivery_verified\",\"gap_id\":\"{gap_id}\",\"deploy_id\":\"{deploy_id}\",\"probe_status\":\"ok\"}}\n"
    );
    let locks = repo_root.join(".chump-locks");
    std::fs::create_dir_all(&locks)?;
    let amb = locks.join("ambient.jsonl");
    let mut f = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&amb)?;
    f.write_all(line.as_bytes())?;
    Ok(())
}

/// INFRA-8108 / CREDIBLE-1647: execute `GapStore::ship_with_external_repo` and emit
/// `kind=gap_shipped` on the first transition to `done` (idempotent on re-ship).
/// When `gap_id` is a `PRODUCT-*` gap and `CHUMP_ENFORCE_PRODUCT_DELIVERY=1` (or
/// `CHUMP_PRODUCT_DELIVERY_RECEIPT_JSON` is provided), validates the live delivery
/// receipt before finalizing `status=done`.
pub fn ship_gap(
    store: &chump_gap_store::GapStore,
    repo_root: &Path,
    gap_id: &str,
    session_id: &str,
    closed_pr: Option<i64>,
    external_repo: Option<&str>,
) -> Result<()> {
    if gap_id.starts_with("PRODUCT-") {
        let enforce = std::env::var("CHUMP_ENFORCE_PRODUCT_DELIVERY")
            .ok()
            .as_deref()
            == Some("1");
        let receipt_env = std::env::var("CHUMP_PRODUCT_DELIVERY_RECEIPT_JSON")
            .ok()
            .filter(|s| !s.trim().is_empty());
        if enforce || receipt_env.is_some() {
            let receipt_json = receipt_env.ok_or_else(|| {
                anyhow::anyhow!(
                    "CREDIBLE-1647: PRODUCT gap {gap_id} requires CHUMP_PRODUCT_DELIVERY_RECEIPT_JSON when product delivery verification is active"
                )
            })?;
            verify_product_delivery_receipt(repo_root, gap_id, &receipt_json)?;
        }
    }
    let was_terminal = store.already_terminal(gap_id)?.is_some();
    store.ship_with_external_repo(gap_id, session_id, closed_pr, external_repo)?;
    if !was_terminal {
        let _ = emit_gap_shipped(repo_root, gap_id, session_id, closed_pr);
    }
    Ok(())
}

/// INFRA-1582: Hint line appended when `chump gap show <ID>` finds neither an
/// active row in `state.db` nor a matching commit in git history.
pub const GAP_SHOW_NOT_FOUND_HINT: &str =
    "no record in active registry or recent commit history — check spelling or chump gap list --include-done";

/// INFRA-1582: When `<ID>` is not in active `state.db`, scan git commit history
/// (`git log --all --grep=<ID> --format="%h|%ad|%s" --date=short -n 1`) and return
/// `"closed via PR #<N> (commit <sha>) on <YYYY-MM-DD>, reaped"` or
/// `"closed in commit <sha> on <YYYY-MM-DD>, reaped"` if found.
pub fn lookup_reaped_gap_in_git_history(repo_root: &Path, gap_id: &str) -> Option<String> {
    let out = std::process::Command::new("git")
        .args([
            "log",
            "--all",
            &format!("--grep={gap_id}"),
            "--format=%h|%ad|%s",
            "--date=short",
            "-n",
            "1",
        ])
        .current_dir(repo_root)
        .output()
        .ok()
        .filter(|o| o.status.success())?;
    let line = String::from_utf8_lossy(&out.stdout).trim().to_string();
    if line.is_empty() {
        return None;
    }
    let mut parts = line.splitn(3, '|');
    let sha = parts.next()?.trim();
    let date = parts.next()?.trim();
    let subject = parts.next().unwrap_or("").trim();
    if sha.is_empty() || date.is_empty() {
        return None;
    }
    let pr_num = extract_pr_number_from_subject(subject);
    if let Some(n) = pr_num {
        Some(format!(
            "closed via PR #{n} (commit {sha}) on {date}, reaped"
        ))
    } else {
        Some(format!("closed in commit {sha} on {date}, reaped"))
    }
}

fn extract_pr_number_from_subject(subject: &str) -> Option<u64> {
    let bytes = subject.as_bytes();
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'#' {
            let start = i + 1;
            let mut end = start;
            while end < bytes.len() && bytes[end].is_ascii_digit() {
                end += 1;
            }
            if end > start {
                if let Ok(n) = subject[start..end].parse::<u64>() {
                    if n > 0 {
                        return Some(n);
                    }
                }
            }
            i = end;
        } else {
            i += 1;
        }
    }
    None
}

/// INFRA-1582: List gaps from `store`, honoring `--include-done` (which includes
/// `done`/`closed` gaps alongside open ones).
pub fn list_gaps_with_include_done(
    store: &chump_gap_store::GapStore,
    status_filter: Option<&str>,
    include_done: bool,
) -> Result<Vec<chump_gap_store::GapRow>> {
    if include_done {
        store.list(None)
    } else {
        store.list(status_filter)
    }
}

/// INFRA-2038: Detect whether a `chump gap ship` invocation is a metadata-only
/// status flip (when `state.db` already has `closed_pr` set matching `--closed-pr`
/// or when `--closed-pr` is passed on an already-merged PR and `--update-yaml` is
/// not passed).
pub fn is_metadata_only_ship(
    store: &chump_gap_store::GapStore,
    repo_root: &Path,
    gap_id: &str,
    closed_pr: Option<i64>,
    update_yaml: bool,
) -> bool {
    if update_yaml {
        return false;
    }
    let Some(pr_num) = closed_pr else {
        return false;
    };
    if let Ok(Some(row)) = store.get(gap_id) {
        if row.closed_pr == Some(pr_num) {
            return true;
        }
    }
    if let Ok(prs) = store.list_prs_for_gap(gap_id) {
        if prs.iter().any(|p| p.pr_number == pr_num) {
            return true;
        }
    }
    chump_gap_store::pr_references_gap(repo_root, gap_id, pr_num) == Some(true)
}

/// INFRA-2038: Emit `kind=gap_ship_metadata_only` to `.chump-locks/ambient.jsonl`.
/// # scanner-anchor: "kind":"gap_ship_metadata_only"
pub fn emit_gap_ship_metadata_only(
    repo_root: &Path,
    gap_id: &str,
    session_id: &str,
    closed_pr: Option<i64>,
) -> Result<()> {
    use std::io::Write as _;
    let ts = chrono::Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string();
    let pr_str = closed_pr
        .map(|pr| format!(",\"closed_pr\":{pr}"))
        .unwrap_or_default();
    let line = format!(
        "{{\"ts\":\"{ts}\",\"kind\":\"gap_ship_metadata_only\",\"gap\":\"{gap_id}\",\"session\":\"{session_id}\"{pr_str}}}\n"
    );
    let locks = repo_root.join(".chump-locks");
    std::fs::create_dir_all(&locks)?;
    let amb = locks.join("ambient.jsonl");
    let mut f = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&amb)?;
    f.write_all(line.as_bytes())?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use serial_test::serial;

    #[test]
    #[serial]
    fn gap_cmd_link_pr_refuses_noncanonical_marker() {
        let prev = std::env::var("CHUMP_STATE_DB").ok();
        std::env::remove_var("CHUMP_STATE_DB");

        let tmp = tempfile::tempdir().unwrap();
        let chump_dir = tmp.path().join(".chump");
        std::fs::create_dir_all(&chump_dir).unwrap();
        let _store = chump_gap_store::GapStore::open(tmp.path()).unwrap();

        let marker = chump_dir.join("NONCANONICAL");
        std::fs::write(&marker, "non-canonical store copy\n").unwrap();

        let err = link_pr_into_store(tmp.path(), "RESILIENT-1650", 5650, "deadbeef", false, false)
            .expect_err("link_pr_into_store must refuse NONCANONICAL store");
        let msg = format!("{err:#}");
        assert!(
            msg.contains("NONCANONICAL") && msg.contains("RESILIENT-1650"),
            "expected NONCANONICAL refusal, got: {msg}"
        );

        let verify = chump_gap_store::GapStore::open(tmp.path()).unwrap();
        assert!(
            verify
                .list_prs_for_gap("RESILIENT-1650")
                .unwrap()
                .is_empty(),
            "refused link-pr must not write gap_prs into NONCANONICAL store"
        );

        if let Some(v) = prev {
            std::env::set_var("CHUMP_STATE_DB", v);
        }
    }

    #[test]
    #[serial]
    fn gap_cmd_link_pr_refuses_archived_marker_and_allows_canonical() {
        let prev = std::env::var("CHUMP_STATE_DB").ok();
        std::env::remove_var("CHUMP_STATE_DB");

        let tmp = tempfile::tempdir().unwrap();
        let chump_dir = tmp.path().join(".chump");
        std::fs::create_dir_all(&chump_dir).unwrap();
        let store = chump_gap_store::GapStore::open(tmp.path()).unwrap();

        let marker = chump_dir.join("CHUMP_STORE_ARCHIVED");
        std::fs::write(&marker, "CHUMP_STORE_ARCHIVED\n").unwrap();

        // Both the CLI helper and GapStore::link_pr_opts directly must refuse.
        assert!(
            link_pr_into_store(tmp.path(), "RESILIENT-1650", 5651, "cafebabe", false, false)
                .is_err()
        );
        assert!(store.link_pr("RESILIENT-1650", 5651, "cafebabe").is_err());

        // Removing the marker makes the store canonical again.
        std::fs::remove_file(&marker).unwrap();
        link_pr_into_store(tmp.path(), "RESILIENT-1650", 5651, "cafebabe", false, false)
            .expect("canonical store without marker accepts link-pr");
        assert_eq!(store.list_prs_for_gap("RESILIENT-1650").unwrap().len(), 1);

        if let Some(v) = prev {
            std::env::set_var("CHUMP_STATE_DB", v);
        }
    }

    #[test]
    fn infra1582_lookup_reaped_gap_in_git_history_and_include_done() {
        let tmp = tempfile::tempdir().unwrap();
        let status = std::process::Command::new("git")
            .args(["init", "-q"])
            .current_dir(tmp.path())
            .status()
            .unwrap();
        assert!(status.success());
        let _ = std::process::Command::new("git")
            .args(["config", "user.email", "test@example.com"])
            .current_dir(tmp.path())
            .status();
        let _ = std::process::Command::new("git")
            .args(["config", "user.name", "Test"])
            .current_dir(tmp.path())
            .status();
        let _ = std::process::Command::new("git")
            .args([
                "commit",
                "-q",
                "--allow-empty",
                "-m",
                "feat(TEST-A): ship reaped gap (#1967)",
            ])
            .current_dir(tmp.path())
            .status();

        let found = lookup_reaped_gap_in_git_history(tmp.path(), "TEST-A")
            .expect("TEST-A should be found in git log");
        assert!(
            found.contains("closed via PR #1967 (commit ") && found.ends_with(", reaped"),
            "unexpected reaped message: {found}"
        );
        assert!(lookup_reaped_gap_in_git_history(tmp.path(), "NEVER-9999").is_none());
        assert!(GAP_SHOW_NOT_FOUND_HINT.contains("chump gap list --include-done"));

        let store = chump_gap_store::GapStore::open(tmp.path()).unwrap();
        let conn =
            rusqlite::Connection::open(chump_gap_store::GapStore::db_path(tmp.path())).unwrap();
        conn.execute(
            "INSERT INTO gaps (id, domain, title, status, priority, effort) VALUES ('TEST-OPEN', 'TEST', 'open', 'open', 'P2', 'xs')",
            [],
        )
        .unwrap();
        conn.execute(
            "INSERT INTO gaps (id, domain, title, status, priority, effort) VALUES ('TEST-DONE', 'TEST', 'done', 'done', 'P2', 'xs')",
            [],
        )
        .unwrap();
        let all = list_gaps_with_include_done(&store, Some("open"), true).unwrap();
        assert_eq!(
            all.len(),
            2,
            "--include-done must include done and open gaps"
        );
    }

    #[test]
    fn infra2038_metadata_only_ship_detection_and_ambient_emit() {
        let tmp = tempfile::tempdir().unwrap();
        let store = chump_gap_store::GapStore::open(tmp.path()).unwrap();
        let conn =
            rusqlite::Connection::open(chump_gap_store::GapStore::db_path(tmp.path())).unwrap();
        conn.execute(
            "INSERT INTO gaps (id, domain, title, status, priority, effort, closed_pr) VALUES ('INFRA-2038', 'INFRA', 'metadata flip', 'open', 'P2', 'xs', 2525)",
            [],
        )
        .unwrap();
        assert!(is_metadata_only_ship(
            &store,
            tmp.path(),
            "INFRA-2038",
            Some(2525),
            false
        ));
        assert!(!is_metadata_only_ship(
            &store,
            tmp.path(),
            "INFRA-2038",
            Some(2525),
            true
        ));
        emit_gap_ship_metadata_only(tmp.path(), "INFRA-2038", "sess-1", Some(2525)).unwrap();
        let amb = std::fs::read_to_string(tmp.path().join(".chump-locks/ambient.jsonl")).unwrap();
        assert!(amb.contains("\"kind\":\"gap_ship_metadata_only\""));
    }

    #[test]
    #[serial]
    fn credible_1647_product_gap_requires_delivery_receipt_when_enforced() {
        let tmp = tempfile::tempdir().unwrap();
        let store = chump_gap_store::GapStore::open(tmp.path()).unwrap();
        let conn =
            rusqlite::Connection::open(chump_gap_store::GapStore::db_path(tmp.path())).unwrap();
        conn.execute(
            "INSERT INTO gaps (id, domain, title, status, priority, effort) VALUES ('PRODUCT-399', 'PRODUCT', 'Product delivery gap', 'open', 'P2', 's')",
            [],
        )
        .unwrap();
        store
            .claim("PRODUCT-399", "sess-prod", "/wt", 3600)
            .unwrap();
        store.link_pr("PRODUCT-399", 7777, "abc1234").unwrap();

        std::env::set_var("CHUMP_ENFORCE_PRODUCT_DELIVERY", "1");
        std::env::remove_var("CHUMP_PRODUCT_DELIVERY_RECEIPT_JSON");

        // 1. Missing receipt refuses ship_gap when enforced.
        let err = ship_gap(
            &store,
            tmp.path(),
            "PRODUCT-399",
            "sess-prod",
            Some(7777),
            None,
        )
        .expect_err("PRODUCT gap without delivery receipt must fail when enforced");
        assert!(format!("{err:#}").contains("CREDIBLE-1647"));

        // 2. Failed probe receipt also refuses ship_gap.
        std::env::set_var(
            "CHUMP_PRODUCT_DELIVERY_RECEIPT_JSON",
            r#"{"gap_id":"PRODUCT-399","deploy_id":"dep-1","probe_status":"failed"}"#,
        );
        let err2 = ship_gap(
            &store,
            tmp.path(),
            "PRODUCT-399",
            "sess-prod",
            Some(7777),
            None,
        )
        .expect_err("PRODUCT gap with failed probe receipt must fail");
        assert!(format!("{err2:#}").contains("CREDIBLE-1647"));

        // 3. Valid receipt allows ship_gap and emits product_delivery_verified.
        std::env::set_var(
            "CHUMP_PRODUCT_DELIVERY_RECEIPT_JSON",
            r#"{"gap_id":"PRODUCT-399","deploy_id":"dep-live-42","probe_status":"ok"}"#,
        );
        ship_gap(
            &store,
            tmp.path(),
            "PRODUCT-399",
            "sess-prod",
            Some(7777),
            None,
        )
        .expect("PRODUCT gap with valid delivery receipt must succeed");

        std::env::remove_var("CHUMP_ENFORCE_PRODUCT_DELIVERY");
        std::env::remove_var("CHUMP_PRODUCT_DELIVERY_RECEIPT_JSON");

        let amb = std::fs::read_to_string(tmp.path().join(".chump-locks/ambient.jsonl")).unwrap();
        assert!(amb.contains("\"kind\":\"product_delivery_verified\""));
        assert!(amb.contains("\"deploy_id\":\"dep-live-42\""));
    }
}
