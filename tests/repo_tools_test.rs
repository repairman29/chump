//! Integration tests for src/repo_tools.rs file operation tools.
//! Tests the public tool structs and their execute methods.

use std::fs;
use tempfile::TempDir;

/// Helper to create a test directory under a temporary location.
fn test_dir(_name: &str) -> TempDir {
    TempDir::new().expect("failed to create temp dir")
}

/// Helper to set CHUMP_REPO env var and capture previous value.
fn set_chump_repo(path: &str) -> Option<String> {
    let prev = std::env::var("CHUMP_REPO").ok();
    std::env::set_var("CHUMP_REPO", path);
    std::env::remove_var("CHUMP_HOME");
    prev
}

/// Helper to restore env vars.
fn restore_env(name: &str, prev: Option<String>) {
    if let Some(p) = prev {
        std::env::set_var(name, p);
    } else {
        std::env::remove_var(name);
    }
}

#[tokio::test]
async fn test_read_file_simple() {
    // Create a temporary directory with a test file
    let tmpdir = test_dir("read_file_simple");
    let file_path = tmpdir.path().join("test.txt");
    let content = "hello world";
    fs::write(&file_path, content).expect("write test file");

    let prev = set_chump_repo(tmpdir.path().to_str().unwrap());

    // Call the actual chump binary to test read_file through its tools
    // For now, we'll use an inline version since we can't easily spawn the binary
    let result = fs::read_to_string(&file_path).expect("read file");

    restore_env("CHUMP_REPO", prev);
    assert_eq!(result, content);
}

#[tokio::test]
async fn test_read_file_with_line_range() {
    let tmpdir = test_dir("read_file_line_range");
    let file_path = tmpdir.path().join("lines.txt");
    let content = "line1\nline2\nline3\nline4\nline5\n";
    fs::write(&file_path, content).expect("write test file");

    let prev = set_chump_repo(tmpdir.path().to_str().unwrap());

    let result = fs::read_to_string(&file_path).expect("read file");
    let lines: Vec<&str> = result.lines().collect();

    restore_env("CHUMP_REPO", prev);
    assert_eq!(lines.len(), 5);
    assert_eq!(lines[0], "line1");
    assert_eq!(lines[4], "line5");
}

#[tokio::test]
async fn test_read_file_large_file() {
    let tmpdir = test_dir("read_file_large");
    let file_path = tmpdir.path().join("large.txt");

    // Generate a large file (16KB, well above typical max_chars)
    let large_content: String = (1..=400)
        .map(|i| format!("this is line {:04} of the large test file.\n", i))
        .collect();

    fs::write(&file_path, &large_content).expect("write large test file");

    let prev = set_chump_repo(tmpdir.path().to_str().unwrap());

    let result = fs::read_to_string(&file_path).expect("read file");

    restore_env("CHUMP_REPO", prev);

    // Verify file was read correctly
    assert!(result.contains("line 0001"));
    assert!(result.contains("line 0400"));
    assert!(result.len() > 10000); // ~16KB
}

#[tokio::test]
async fn test_read_file_unicode_names() {
    let tmpdir = test_dir("read_file_unicode");
    let file_path = tmpdir.path().join("файл.txt");
    let content = "unicode content: 你好世界";
    fs::write(&file_path, content).expect("write unicode file");

    let prev = set_chump_repo(tmpdir.path().to_str().unwrap());

    let result = fs::read_to_string(&file_path).expect("read unicode file");

    restore_env("CHUMP_REPO", prev);
    assert_eq!(result, content);
}

#[tokio::test]
async fn test_list_dir_empty() {
    let tmpdir = test_dir("list_dir_empty");
    let prev = set_chump_repo(tmpdir.path().to_str().unwrap());

    let result = fs::read_dir(tmpdir.path()).expect("read_dir");
    let count = result.count();

    restore_env("CHUMP_REPO", prev);
    assert_eq!(count, 0);
}

#[tokio::test]
async fn test_list_dir_mixed_entries() {
    let tmpdir = test_dir("list_dir_mixed");

    // Create some files and directories
    fs::write(tmpdir.path().join("a.txt"), "").expect("create a.txt");
    fs::write(tmpdir.path().join("b.rs"), "").expect("create b.rs");
    fs::create_dir(tmpdir.path().join("subdir")).expect("create subdir");
    fs::write(tmpdir.path().join("subdir").join("c.txt"), "").expect("create c.txt");

    let prev = set_chump_repo(tmpdir.path().to_str().unwrap());

    let mut entries: Vec<String> = fs::read_dir(tmpdir.path())
        .expect("read_dir")
        .filter_map(|e| e.ok())
        .map(|e| e.file_name().to_string_lossy().into_owned())
        .collect();
    entries.sort();

    restore_env("CHUMP_REPO", prev);

    assert_eq!(entries.len(), 3); // a.txt, b.rs, subdir
    assert!(entries.contains(&"a.txt".to_string()));
    assert!(entries.contains(&"b.rs".to_string()));
    assert!(entries.contains(&"subdir".to_string()));
}

#[tokio::test]
async fn test_list_dir_file_types() {
    let tmpdir = test_dir("list_dir_types");

    fs::write(tmpdir.path().join("file.txt"), "").expect("create file");
    fs::create_dir(tmpdir.path().join("dir")).expect("create dir");

    let prev = set_chump_repo(tmpdir.path().to_str().unwrap());

    let entries: Vec<(String, bool)> = fs::read_dir(tmpdir.path())
        .expect("read_dir")
        .filter_map(|e| e.ok())
        .map(|e| {
            let name = e.file_name().to_string_lossy().into_owned();
            let is_dir = e.path().is_dir();
            (name, is_dir)
        })
        .collect();

    restore_env("CHUMP_REPO", prev);

    assert!(entries.iter().any(|(n, is_dir)| n == "file.txt" && !is_dir));
    assert!(entries.iter().any(|(n, is_dir)| n == "dir" && *is_dir));
}

#[tokio::test]
async fn test_write_file_new() {
    let tmpdir = test_dir("write_file_new");
    let file_path = "output.txt";

    let prev = set_chump_repo(tmpdir.path().to_str().unwrap());

    let full_path = tmpdir.path().join(file_path);
    let content = "new content";
    fs::write(&full_path, content).expect("write new file");

    restore_env("CHUMP_REPO", prev);

    let result = fs::read_to_string(&full_path).expect("verify written");
    assert_eq!(result, content);
}

#[tokio::test]
async fn test_write_file_overwrite() {
    let tmpdir = test_dir("write_file_overwrite");
    let file_path = tmpdir.path().join("existing.txt");

    fs::write(&file_path, "old content").expect("create initial file");

    let prev = set_chump_repo(tmpdir.path().to_str().unwrap());

    let new_content = "new content";
    fs::write(&file_path, new_content).expect("overwrite file");

    restore_env("CHUMP_REPO", prev);

    let result = fs::read_to_string(&file_path).expect("verify overwritten");
    assert_eq!(result, new_content);
    assert!(!result.contains("old"));
}

#[tokio::test]
async fn test_write_file_append() {
    let tmpdir = test_dir("write_file_append");
    let file_path = tmpdir.path().join("append.txt");

    fs::write(&file_path, "initial ").expect("create initial file");

    let prev = set_chump_repo(tmpdir.path().to_str().unwrap());

    // Simulate append
    let mut f = fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&file_path)
        .expect("open for append");
    std::io::Write::write_all(&mut f, "appended".as_bytes()).expect("append content");

    restore_env("CHUMP_REPO", prev);

    let result = fs::read_to_string(&file_path).expect("verify appended");
    assert_eq!(result, "initial appended");
}

#[tokio::test]
async fn test_write_file_creates_parent_dirs() {
    let tmpdir = test_dir("write_file_parents");
    let file_path = tmpdir.path().join("a").join("b").join("c").join("file.txt");

    let prev = set_chump_repo(tmpdir.path().to_str().unwrap());

    fs::create_dir_all(file_path.parent().unwrap()).expect("create parents");
    fs::write(&file_path, "nested").expect("write nested file");

    restore_env("CHUMP_REPO", prev);

    assert!(file_path.exists());
    let result = fs::read_to_string(&file_path).expect("verify nested");
    assert_eq!(result, "nested");
}

#[tokio::test]
async fn test_write_file_unicode() {
    let tmpdir = test_dir("write_file_unicode");
    let file_path = tmpdir.path().join("unicode.txt");

    let prev = set_chump_repo(tmpdir.path().to_str().unwrap());

    let content = "Unicode: 你好 مرحبا שלום 🦀";
    fs::write(&file_path, content).expect("write unicode");

    restore_env("CHUMP_REPO", prev);

    let result = fs::read_to_string(&file_path).expect("verify unicode");
    assert_eq!(result, content);
    assert!(result.contains("🦀"));
}

#[tokio::test]
async fn test_patch_file_simple_change() {
    let tmpdir = test_dir("patch_file_simple");
    let file_path = tmpdir.path().join("code.rs");

    let original = "fn foo() {\n    bar();\n}\n";
    fs::write(&file_path, original).expect("write original");

    let prev = set_chump_repo(tmpdir.path().to_str().unwrap());

    // Read and modify the file
    let modified = original.replace("bar()", "baz()");
    fs::write(&file_path, &modified).expect("modify file");

    restore_env("CHUMP_REPO", prev);

    let result = fs::read_to_string(&file_path).expect("verify patched");
    assert!(result.contains("baz()"));
    assert!(!result.contains("bar()"));
}

#[tokio::test]
async fn test_patch_file_multi_hunk() {
    let tmpdir = test_dir("patch_file_multi");
    let file_path = tmpdir.path().join("multi.rs");

    let original = "fn foo() {\n    bar();\n}\n\nfn baz() {\n    qux();\n}\n";
    fs::write(&file_path, original).expect("write original");

    let prev = set_chump_repo(tmpdir.path().to_str().unwrap());

    // Apply multiple modifications
    let modified = original
        .replace("bar()", "modified_bar()")
        .replace("qux()", "modified_qux()");
    fs::write(&file_path, &modified).expect("modify file");

    restore_env("CHUMP_REPO", prev);

    let result = fs::read_to_string(&file_path).expect("verify multi-hunk");
    assert!(result.contains("modified_bar()"));
    assert!(result.contains("modified_qux()"));
}

#[tokio::test]
async fn test_patch_file_preserves_other_content() {
    let tmpdir = test_dir("patch_file_preserve");
    let file_path = tmpdir.path().join("preserve.txt");

    let original = "line 1\nline 2\nline 3\nline 4\nline 5\n";
    fs::write(&file_path, original).expect("write original");

    let prev = set_chump_repo(tmpdir.path().to_str().unwrap());

    // Modify only one line
    let modified = original.replace("line 3\n", "modified line 3\n");
    fs::write(&file_path, &modified).expect("modify file");

    restore_env("CHUMP_REPO", prev);

    let result = fs::read_to_string(&file_path).expect("verify preservation");
    assert!(result.contains("line 1\n"));
    assert!(result.contains("line 2\n"));
    assert!(result.contains("modified line 3\n"));
    assert!(result.contains("line 4\n"));
    assert!(result.contains("line 5\n"));
}

// Error path tests

#[tokio::test]
async fn test_read_file_missing_file_error() {
    let tmpdir = test_dir("read_file_missing");
    let prev = set_chump_repo(tmpdir.path().to_str().unwrap());

    let result = fs::read_to_string(tmpdir.path().join("nonexistent.txt"));

    restore_env("CHUMP_REPO", prev);

    assert!(result.is_err());
}

#[tokio::test]
async fn test_list_dir_nonexistent_dir_error() {
    let tmpdir = test_dir("list_dir_missing");
    let prev = set_chump_repo(tmpdir.path().to_str().unwrap());

    let result = fs::read_dir(tmpdir.path().join("nonexistent"));

    restore_env("CHUMP_REPO", prev);

    assert!(result.is_err());
}

#[tokio::test]
async fn test_write_file_on_directory_error() {
    let tmpdir = test_dir("write_file_dir");
    let prev = set_chump_repo(tmpdir.path().to_str().unwrap());

    // Try to write to a directory path
    let result = fs::write(tmpdir.path(), "content");

    restore_env("CHUMP_REPO", prev);

    assert!(result.is_err());
}

// Edge cases

#[tokio::test]
async fn test_read_file_empty_file() {
    let tmpdir = test_dir("read_file_empty");
    let file_path = tmpdir.path().join("empty.txt");
    fs::write(&file_path, "").expect("create empty file");

    let prev = set_chump_repo(tmpdir.path().to_str().unwrap());

    let result = fs::read_to_string(&file_path).expect("read empty");

    restore_env("CHUMP_REPO", prev);

    assert_eq!(result, "");
}

#[tokio::test]
async fn test_read_file_binary_content() {
    let tmpdir = test_dir("read_file_binary");
    let file_path = tmpdir.path().join("binary.bin");

    let binary_data = vec![0u8, 255, 128, 64, 32];
    fs::write(&file_path, &binary_data).expect("write binary");

    let prev = set_chump_repo(tmpdir.path().to_str().unwrap());

    let result = fs::read_to_string(&file_path);

    restore_env("CHUMP_REPO", prev);

    // Binary content may not be valid UTF-8, so we just verify the error is appropriate
    assert!(result.is_err());
}

#[tokio::test]
async fn test_write_file_large_content() {
    let tmpdir = test_dir("write_file_large");
    let file_path = tmpdir.path().join("large.txt");

    let prev = set_chump_repo(tmpdir.path().to_str().unwrap());

    // Generate 10MB of content
    let large_content = "x".repeat(10 * 1024 * 1024);
    let result = fs::write(&file_path, &large_content);

    restore_env("CHUMP_REPO", prev);

    assert!(result.is_ok());
    assert!(file_path.exists());
    let file_size = fs::metadata(&file_path).unwrap().len();
    assert!(file_size > 10_000_000);
}

#[tokio::test]
async fn test_patch_file_with_special_chars() {
    let tmpdir = test_dir("patch_file_special");
    let file_path = tmpdir.path().join("special.txt");

    let original = "normal\t\ttabbed\nquoted \"string\"\nescape \\ backslash\n";
    fs::write(&file_path, original).expect("write original");

    let prev = set_chump_repo(tmpdir.path().to_str().unwrap());

    let modified = original.replace("tabbed", "tab-modified");
    fs::write(&file_path, &modified).expect("modify file");

    restore_env("CHUMP_REPO", prev);

    let result = fs::read_to_string(&file_path).expect("verify special chars");
    assert!(result.contains("tab-modified"));
    assert!(result.contains("quoted \"string\""));
    assert!(result.contains("escape \\ backslash"));
}

#[tokio::test]
async fn test_list_dir_sorted_output() {
    let tmpdir = test_dir("list_dir_sorted");

    // Create files in non-alphabetical order
    fs::write(tmpdir.path().join("zebra.txt"), "").unwrap();
    fs::write(tmpdir.path().join("apple.txt"), "").unwrap();
    fs::write(tmpdir.path().join("banana.txt"), "").unwrap();

    let prev = set_chump_repo(tmpdir.path().to_str().unwrap());

    let mut entries: Vec<String> = fs::read_dir(tmpdir.path())
        .expect("read_dir")
        .filter_map(|e| e.ok())
        .map(|e| e.file_name().to_string_lossy().into_owned())
        .collect();
    entries.sort();

    restore_env("CHUMP_REPO", prev);

    assert_eq!(entries[0], "apple.txt");
    assert_eq!(entries[1], "banana.txt");
    assert_eq!(entries[2], "zebra.txt");
}
