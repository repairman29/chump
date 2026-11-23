//! `chump-pal` — Cross-Platform Abstraction Layer for Universal Chump v1.0.
//!
//! Provides zero-shell-out native OS primitives across macOS, Linux, and Windows:
//! - [`host`]: `free_disk_gb`, `total_ram_gb`, `available_cpus`, `derive_cargo_build_jobs`, `load_average_1m`
//! - [`process`]: `is_pid_alive`, `parent_pid`, `terminate_process`, `terminate_process_group`, `configure_isolated_child`
//! - [`signal`]: `install_shutdown_signal`, `wait_for_shutdown_signal`, `exit_code_for_signal`
//! - [`paths`]: `user_home`, `state_base_dir`, `chump_home`, `temp_dir`, `temp_file_path`, `restrict_file_permissions`, `with_file_lock`
//! - [`shell`]: `shell_command`, `pwsh_or_cmd`
//! - [`ipc`]: authenticated loopback TCP (`127.0.0.1:0` + `0o600` `.ipc` runtime file)

pub mod host;
pub mod ipc;
pub mod paths;
pub mod process;
pub mod shell;
pub mod signal;
#[cfg(windows)]
mod win32;

pub use host::{
    available_cpus, derive_cargo_build_jobs, derive_cargo_build_jobs_from, free_disk_gb,
    load_average_1m, total_ram_gb,
};
pub use paths::{
    chump_home, restrict_file_permissions, state_base_dir, symlink_or_copy_file, temp_dir,
    temp_file_path, user_home, with_file_lock,
};
pub use process::{
    configure_isolated_child, is_pid_alive, parent_pid, success_exit_status, terminate_process,
    terminate_process_group,
};
pub use shell::{pwsh_or_cmd, shell_command};
pub use signal::{
    exit_code_for_signal, install_shutdown_signal, wait_for_shutdown_signal, SIGINT_NUM,
    SIGTERM_NUM,
};

#[cfg(test)]
mod tests {
    use super::*;
    use serial_test::serial;
    use std::io::Write;
    use std::time::Duration;
    use tempfile::TempDir;

    #[test]
    fn host_resources_return_sane_values() {
        let tmp = TempDir::new().expect("tempdir");
        let free = free_disk_gb(tmp.path()).expect("free_disk_gb on existing dir");
        assert!(
            free > 0.01 && free < 1_000_000.0,
            "unexpected free_gb={free}"
        );

        // Non-existent child path resolves via nearest existing ancestor.
        let nested = tmp.path().join("does").join("not").join("exist");
        let free_nested = free_disk_gb(&nested).expect("free_disk_gb on non-existent child");
        assert!(free_nested > 0.01);

        let ram = total_ram_gb().expect("total_ram_gb");
        assert!(ram > 0.25 && ram < 65_536.0, "unexpected ram_gb={ram}");

        let cpus = available_cpus();
        assert!(cpus >= 1);

        let jobs = derive_cargo_build_jobs();
        assert!((1..=cpus).contains(&jobs));
        assert_eq!(derive_cargo_build_jobs_from(Some(16.0), 10), 6);
        assert_eq!(derive_cargo_build_jobs_from(Some(2.0), 8), 1);
        assert_eq!(derive_cargo_build_jobs_from(None, 2), 2);
    }

    #[test]
    fn process_liveness_and_isolated_group_termination() {
        assert!(!is_pid_alive(0));
        assert!(is_pid_alive(std::process::id()));

        #[cfg(unix)]
        let mut cmd = shell_command("sleep 30");
        #[cfg(windows)]
        let mut cmd = shell_command("ping -n 30 127.0.0.1 >NUL");

        configure_isolated_child(&mut cmd);
        let mut child = cmd.spawn().expect("spawn sleep child");
        let pid = child.id();
        assert!(is_pid_alive(pid));

        terminate_process_group(pid, true).expect("terminate_process_group");
        let _ = child.wait();
        assert!(!is_pid_alive(pid));
    }

    #[test]
    #[serial(pal_env)]
    fn portable_paths_and_permissions() {
        let tmp = TempDir::new().expect("tempdir");
        let saved_ch = std::env::var("CHUMP_HOME").ok();
        let saved_home = std::env::var("HOME").ok();
        let saved_up = std::env::var("USERPROFILE").ok();

        std::env::set_var("CHUMP_HOME", tmp.path());
        assert_eq!(chump_home(), tmp.path().join(".chump"));
        assert_eq!(state_base_dir(), tmp.path());

        let dot_chump = tmp.path().join(".chump");
        std::env::set_var("CHUMP_HOME", &dot_chump);
        assert_eq!(chump_home(), dot_chump);
        assert_eq!(state_base_dir(), tmp.path());

        // Windows USERPROFILE fallback when CHUMP_HOME and HOME are unset.
        std::env::remove_var("CHUMP_HOME");
        std::env::remove_var("HOME");
        std::env::set_var("USERPROFILE", tmp.path());
        assert_eq!(user_home(), tmp.path());
        assert_eq!(chump_home(), tmp.path().join(".chump"));

        match saved_ch {
            Some(v) => std::env::set_var("CHUMP_HOME", v),
            None => std::env::remove_var("CHUMP_HOME"),
        }
        match saved_home {
            Some(v) => std::env::set_var("HOME", v),
            None => std::env::remove_var("HOME"),
        }
        match saved_up {
            Some(v) => std::env::set_var("USERPROFILE", v),
            None => std::env::remove_var("USERPROFILE"),
        }

        let secret = tmp.path().join("secret.tok");
        std::fs::write(&secret, b"top-secret").expect("write secret");
        restrict_file_permissions(&secret).expect("restrict permissions");
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let mode = std::fs::metadata(&secret).unwrap().permissions().mode() & 0o777;
            assert_eq!(mode, 0o600);
        }

        let tp = temp_file_path("sub/dir\\file.tmp");
        assert!(tp.starts_with(temp_dir()));
        assert_eq!(tp.file_name().unwrap().to_str(), Some("sub_dir_file.tmp"));

        let lock_path = tmp.path().join("coord.lock");
        let val = with_file_lock(&lock_path, || 42);
        assert_eq!(val, 42);
    }

    #[test]
    fn shell_command_runs_echo() {
        let out = shell_command("echo pal-ok")
            .output()
            .expect("shell_command");
        assert!(out.status.success());
        assert!(String::from_utf8_lossy(&out.stdout).contains("pal-ok"));
    }

    #[tokio::test]
    async fn ipc_authenticated_roundtrip_and_exclusive_lock() {
        let tmp = TempDir::new().expect("tempdir");
        let ipc_path = ipc::ipc_file_path_in(tmp.path(), "test-daemon");

        let server = ipc::IpcServer::bind_exclusive_at(&ipc_path).expect("bind first");
        assert!(ipc_path.exists());

        // Second exclusive bind to same path must fail with AddrInUse.
        let second = ipc::IpcServer::bind_exclusive_at(&ipc_path);
        assert_eq!(
            second.err().map(|e| e.kind()),
            Some(std::io::ErrorKind::AddrInUse)
        );

        let listener = server.tokio_listener().expect("tokio listener");
        let expected_tok = server.token().to_string();
        let handle = tokio::spawn(async move {
            let (req, mut stream): (serde_json::Value, _) =
                ipc::accept_next_authenticated(&listener, &expected_tok)
                    .await
                    .expect("auth");
            assert_eq!(req["method"], "ping");
            ipc::write_json_response(&mut stream, &serde_json::json!({ "status": "pong" }))
                .await
                .expect("write resp");
        });

        let resp: serde_json::Value = ipc::request_json_async(
            &ipc_path,
            &serde_json::json!({ "method": "ping" }),
            Duration::from_secs(2),
        )
        .await
        .expect("rpc call");
        assert_eq!(resp["status"], "pong");
        handle.await.expect("server task");

        // Wrong token must be rejected.
        let ep = ipc::read_endpoint(&ipc_path).expect("read ep");
        let listener2 = server.tokio_listener().expect("tokio listener 2");
        let expected_tok2 = server.token().to_string();
        let reject_task = tokio::spawn(async move {
            let (stream, peer) = listener2.accept().await.expect("accept");
            let res: std::io::Result<(serde_json::Value, _)> =
                ipc::accept_authenticated(stream, peer, &expected_tok2).await;
            assert_eq!(
                res.err().map(|e| e.kind()),
                Some(std::io::ErrorKind::PermissionDenied)
            );
        });
        {
            let mut bad =
                std::net::TcpStream::connect(("127.0.0.1", ep.port)).expect("connect bad");
            bad.write_all(b"wrong-token\n{\"method\":\"ping\"}\n")
                .expect("write bad");
        }
        reject_task.await.expect("reject task");

        drop(server);
        assert!(!ipc_path.exists(), "Drop must remove .ipc file");
    }
}
