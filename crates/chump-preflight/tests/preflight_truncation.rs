use chump_preflight::preflight::truncate_gate_output_in;

#[test]
fn truncated_output_keeps_last_5_lines_and_log_path() {
    let mut full = String::new();
    for i in 0..1000 {
        full.push_str(&format!("   Checking crate-{i} v0.1.0 (padding padding)\n"));
    }
    full.push_str("error: line A\nerror: line B\nerror: line C\nerror: line D\nerror: could not compile `x`\n");
    assert!(full.len() > 30_000);
    let dir = tempfile::tempdir().unwrap();
    let out = truncate_gate_output_in(dir.path(), "clippy", &full);
    let last5: Vec<&str> = full.lines().rev().take(5).collect();
    for l in &last5 {
        assert!(out.contains(l), "missing tail line {l}");
    }
    assert!(out.contains("error: could not compile"));
    let log = dir.path().join("clippy.log");
    assert!(out.contains(&log.display().to_string()));
    assert_eq!(std::fs::read_to_string(log).unwrap(), full);
}
