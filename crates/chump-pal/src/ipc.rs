//! Authenticated loopback TCP Local IPC (`127.0.0.1:0` + `0o600` runtime `.ipc`
//! file under `chump_home()/run/<name>.ipc`) replacing Unix-only `UnixListener`
//! across macOS, Linux, and Windows.
//!
//! Wire framing (newline-delimited over `127.0.0.1:<port>`):
//! 1. Client sends `<hex-token>\n<json-request-one-line>\n`.
//! 2. Server verifies peer is loopback (`127.0.0.1` / `::1`) and compares
//!    `<hex-token>` in constant time against its random 256-bit token.
//! 3. Server replies with `<json-response-one-line>\n`.

use rand::RngExt;
use serde::{de::DeserializeOwned, Deserialize, Serialize};
use std::fs::{self, OpenOptions};
use std::io::{self, BufRead, BufReader, Write};
use std::net::{
    IpAddr, Ipv4Addr, SocketAddr, TcpListener as StdTcpListener, TcpStream as StdTcpStream,
};
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader as TokioBufReader};
use tokio::net::{TcpListener as TokioTcpListener, TcpStream as TokioTcpStream};

use crate::paths::{chump_home, restrict_file_permissions};

/// Runtime metadata persisted at `<chump_home>/run/<name>.ipc`.
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct IpcEndpoint {
    pub host: String,
    pub port: u16,
    pub token: String,
    pub pid: u32,
}

/// Sanitize a logical daemon/session name into a safe single-segment filename.
pub fn sanitize_ipc_name(name: &str) -> String {
    name.chars()
        .map(|c| match c {
            '/' | '\\' | ':' | '\0' => '_',
            _ => c,
        })
        .collect()
}

/// Canonical `.ipc` runtime file path inside `chump_dir/run/<name>.ipc`.
pub fn ipc_file_path_in(chump_dir: &Path, name: &str) -> PathBuf {
    let safe = sanitize_ipc_name(name);
    chump_dir.join("run").join(format!("{safe}.ipc"))
}

/// Canonical `.ipc` runtime file path under `chump_home()/run/<name>.ipc`.
pub fn ipc_file_path(name: &str) -> PathBuf {
    ipc_file_path_in(&chump_home(), name)
}

fn generate_hex_token() -> String {
    let mut bytes = [0u8; 32];
    rand::rng().fill(&mut bytes);
    hex::encode(bytes)
}

fn constant_time_eq(a: &[u8], b: &[u8]) -> bool {
    if a.len() != b.len() {
        return false;
    }
    let mut diff = 0u8;
    for (&x, &y) in a.iter().zip(b.iter()) {
        diff |= x ^ y;
    }
    diff == 0
}

/// Read an [`IpcEndpoint`] JSON descriptor from disk.
pub fn read_endpoint(ipc_path: &Path) -> io::Result<IpcEndpoint> {
    let raw = fs::read_to_string(ipc_path)?;
    serde_json::from_str(raw.trim())
        .map_err(|e| io::Error::new(io::ErrorKind::InvalidData, format!("invalid ipc file: {e}")))
}

/// Probe whether an existing `.ipc` file points to a live process and an actively
/// listening loopback port.
pub fn endpoint_is_live(ep: &IpcEndpoint) -> bool {
    if !crate::process::is_pid_alive(ep.pid) {
        return false;
    }
    let addr = SocketAddr::new(IpAddr::V4(Ipv4Addr::LOCALHOST), ep.port);
    StdTcpStream::connect_timeout(&addr, Duration::from_millis(100)).is_ok()
}

/// Bound loopback TCP IPC server + RAII `.ipc` file owner.
pub struct IpcServer {
    listener: StdTcpListener,
    endpoint: IpcEndpoint,
    ipc_path: PathBuf,
}

impl IpcServer {
    /// Bind `127.0.0.1:0` and publish `<chump_home>/run/<name>.ipc` (replacing any
    /// stale file).
    pub fn bind(name: &str) -> io::Result<Self> {
        Self::bind_at(&ipc_file_path(name))
    }

    /// Bind `127.0.0.1:0` and publish the `.ipc` descriptor atomically at `ipc_path`.
    pub fn bind_at(ipc_path: &Path) -> io::Result<Self> {
        if let Some(parent) = ipc_path.parent() {
            fs::create_dir_all(parent)?;
        }
        let listener = StdTcpListener::bind((Ipv4Addr::LOCALHOST, 0))?;
        let port = listener.local_addr()?.port();
        let token = generate_hex_token();
        let endpoint = IpcEndpoint {
            host: "127.0.0.1".to_string(),
            port,
            token,
            pid: std::process::id(),
        };
        let payload =
            serde_json::to_string(&endpoint).map_err(|e| io::Error::other(e.to_string()))?;

        let tmp_path = ipc_path.with_extension(format!("ipc.tmp.{}", std::process::id()));
        fs::write(&tmp_path, payload.as_bytes())?;
        let _ = restrict_file_permissions(&tmp_path);
        fs::rename(&tmp_path, ipc_path)?;
        let _ = restrict_file_permissions(ipc_path);

        Ok(Self {
            listener,
            endpoint,
            ipc_path: ipc_path.to_path_buf(),
        })
    }

    /// Bind exclusively under `<chump_home>/run/<name>.ipc`: fails with
    /// [`io::ErrorKind::AddrInUse`] if another live instance already holds `name`,
    /// while reaping stale crash-leftover `.ipc` files automatically.
    pub fn bind_exclusive(name: &str) -> io::Result<Self> {
        Self::bind_exclusive_at(&ipc_file_path(name))
    }

    /// Bind exclusively at `ipc_path` using kernel-atomic `create_new(true)` +
    /// live-port verification so racing callers never both succeed.
    pub fn bind_exclusive_at(ipc_path: &Path) -> io::Result<Self> {
        if let Some(parent) = ipc_path.parent() {
            fs::create_dir_all(parent)?;
        }

        let listener = StdTcpListener::bind((Ipv4Addr::LOCALHOST, 0))?;
        let port = listener.local_addr()?.port();
        let token = generate_hex_token();
        let endpoint = IpcEndpoint {
            host: "127.0.0.1".to_string(),
            port,
            token,
            pid: std::process::id(),
        };
        let payload =
            serde_json::to_string(&endpoint).map_err(|e| io::Error::other(e.to_string()))?;

        for attempt in 0..3 {
            match OpenOptions::new()
                .write(true)
                .create_new(true)
                .open(ipc_path)
            {
                Ok(mut f) => {
                    f.write_all(payload.as_bytes())?;
                    f.sync_all()?;
                    drop(f);
                    let _ = restrict_file_permissions(ipc_path);
                    return Ok(Self {
                        listener,
                        endpoint,
                        ipc_path: ipc_path.to_path_buf(),
                    });
                }
                Err(e) if e.kind() == io::ErrorKind::AlreadyExists => {
                    // Give a racing winner up to 15ms to finish writing JSON bytes.
                    let mut existing = read_endpoint(ipc_path);
                    if existing.is_err() {
                        std::thread::sleep(Duration::from_millis(15));
                        existing = read_endpoint(ipc_path);
                    }
                    if let Ok(ep) = existing {
                        if endpoint_is_live(&ep) {
                            return Err(io::Error::new(
                                io::ErrorKind::AddrInUse,
                                format!(
                                    "ipc endpoint {} already bound by live process pid={} port={}",
                                    ipc_path.display(),
                                    ep.pid,
                                    ep.port
                                ),
                            ));
                        }
                    }
                    // Stale crash leftover: remove and retry atomic create_new.
                    let _ = fs::remove_file(ipc_path);
                    if attempt == 2 {
                        return Err(io::Error::new(
                            io::ErrorKind::AddrInUse,
                            format!(
                                "ipc endpoint {} contended across retries",
                                ipc_path.display()
                            ),
                        ));
                    }
                }
                Err(e) => return Err(e),
            }
        }

        Err(io::Error::new(
            io::ErrorKind::AddrInUse,
            format!("ipc endpoint {} already in use", ipc_path.display()),
        ))
    }

    pub fn endpoint(&self) -> &IpcEndpoint {
        &self.endpoint
    }

    pub fn ipc_path(&self) -> &Path {
        &self.ipc_path
    }

    pub fn token(&self) -> &str {
        &self.endpoint.token
    }

    /// Clone the underlying listener into a non-blocking [`tokio::net::TcpListener`]
    /// while keeping `self` alive so `Drop` cleans up the `.ipc` file on shutdown.
    pub fn tokio_listener(&self) -> io::Result<TokioTcpListener> {
        let cloned = self.listener.try_clone()?;
        cloned.set_nonblocking(true)?;
        TokioTcpListener::from_std(cloned)
    }

    /// Synchronously accept and serve up to one authenticated JSON request within
    /// `timeout` (useful in synchronous tests and lightweight single-shot servers).
    pub fn serve_one_sync<F>(&self, timeout: Duration, handler: F) -> io::Result<bool>
    where
        F: FnOnce(serde_json::Value) -> serde_json::Value,
    {
        self.listener.set_nonblocking(true)?;
        let deadline = Instant::now() + timeout;
        while Instant::now() < deadline {
            match self.listener.accept() {
                Ok((stream, peer)) => {
                    if !peer.ip().is_loopback() {
                        return Err(io::Error::new(
                            io::ErrorKind::PermissionDenied,
                            "non-loopback peer rejected",
                        ));
                    }
                    stream.set_nonblocking(false)?;
                    stream.set_read_timeout(Some(Duration::from_secs(2)))?;
                    stream.set_write_timeout(Some(Duration::from_secs(2)))?;
                    let mut reader = BufReader::new(stream.try_clone()?);
                    let mut tok_line = String::new();
                    if reader.read_line(&mut tok_line)? == 0 {
                        continue;
                    }
                    if !constant_time_eq(tok_line.trim().as_bytes(), self.endpoint.token.as_bytes())
                    {
                        return Err(io::Error::new(
                            io::ErrorKind::PermissionDenied,
                            "ipc token mismatch",
                        ));
                    }
                    let mut req_line = String::new();
                    if reader.read_line(&mut req_line)? == 0 {
                        continue;
                    }
                    let req: serde_json::Value = serde_json::from_str(req_line.trim())
                        .map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e.to_string()))?;
                    let resp = handler(req);
                    let mut writer = stream;
                    let mut out =
                        serde_json::to_vec(&resp).map_err(|e| io::Error::other(e.to_string()))?;
                    out.push(b'\n');
                    writer.write_all(&out)?;
                    writer.flush()?;
                    return Ok(true);
                }
                Err(e) if e.kind() == io::ErrorKind::WouldBlock => {
                    std::thread::sleep(Duration::from_millis(10));
                }
                Err(e) => return Err(e),
            }
        }
        Ok(false)
    }
}

impl Drop for IpcServer {
    fn drop(&mut self) {
        // Only unlink if the file on disk still belongs to our bound port + token.
        if let Ok(on_disk) = read_endpoint(&self.ipc_path) {
            if on_disk.port == self.endpoint.port && on_disk.token == self.endpoint.token {
                let _ = fs::remove_file(&self.ipc_path);
            }
        }
    }
}

/// Authenticate an accepted [`TokioTcpStream`] against `expected_token`, parse one
/// JSON request of type `Req`, and return `(Req, TokioTcpStream)` ready for
/// [`write_json_response`].
pub async fn accept_authenticated<Req: DeserializeOwned>(
    stream: TokioTcpStream,
    peer: SocketAddr,
    expected_token: &str,
) -> io::Result<(Req, TokioTcpStream)> {
    if !peer.ip().is_loopback() {
        return Err(io::Error::new(
            io::ErrorKind::PermissionDenied,
            "non-loopback peer rejected",
        ));
    }
    let mut reader = TokioBufReader::new(stream);
    let mut tok_line = String::new();
    let n_tok = reader.read_line(&mut tok_line).await?;
    if n_tok == 0 {
        return Err(io::Error::new(
            io::ErrorKind::UnexpectedEof,
            "empty ipc auth frame",
        ));
    }
    if !constant_time_eq(tok_line.trim().as_bytes(), expected_token.as_bytes()) {
        return Err(io::Error::new(
            io::ErrorKind::PermissionDenied,
            "ipc token mismatch",
        ));
    }
    let mut req_line = String::new();
    let n_req = reader.read_line(&mut req_line).await?;
    if n_req == 0 {
        return Err(io::Error::new(
            io::ErrorKind::UnexpectedEof,
            "empty ipc request frame",
        ));
    }
    let req: Req = serde_json::from_str(req_line.trim())
        .map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e.to_string()))?;
    Ok((req, reader.into_inner()))
}

/// Accept the next real authenticated JSON request from `listener`, automatically
/// skipping empty 0-byte liveness-probe connections (such as [`endpoint_is_live`]).
pub async fn accept_next_authenticated<Req: DeserializeOwned>(
    listener: &TokioTcpListener,
    expected_token: &str,
) -> io::Result<(Req, TokioTcpStream)> {
    loop {
        let (stream, peer) = listener.accept().await?;
        match accept_authenticated(stream, peer, expected_token).await {
            Ok(pair) => return Ok(pair),
            Err(e) if e.kind() == io::ErrorKind::UnexpectedEof => continue,
            Err(e) => return Err(e),
        }
    }
}

/// Write a single JSON line response onto an authenticated [`TokioTcpStream`].
pub async fn write_json_response<Resp: Serialize>(
    stream: &mut TokioTcpStream,
    resp: &Resp,
) -> io::Result<()> {
    let mut bytes = serde_json::to_vec(resp).map_err(|e| io::Error::other(e.to_string()))?;
    bytes.push(b'\n');
    stream.write_all(&bytes).await?;
    stream.flush().await
}

/// Send an authenticated synchronous JSON request to the daemon at `ipc_path`.
pub fn request_json_sync<Req: Serialize, Resp: DeserializeOwned>(
    ipc_path: &Path,
    req: &Req,
    timeout: Duration,
) -> io::Result<Resp> {
    let ep = read_endpoint(ipc_path)?;
    let addr = SocketAddr::new(IpAddr::V4(Ipv4Addr::LOCALHOST), ep.port);
    let mut stream = StdTcpStream::connect_timeout(&addr, timeout)?;
    stream.set_read_timeout(Some(timeout))?;
    stream.set_write_timeout(Some(timeout))?;

    let req_str = serde_json::to_string(req)
        .map_err(|e| io::Error::new(io::ErrorKind::InvalidInput, e.to_string()))?;
    let wire = format!("{}\n{}\n", ep.token, req_str);
    stream.write_all(wire.as_bytes())?;
    stream.flush()?;

    let mut reader = BufReader::new(stream);
    let mut resp_line = String::new();
    let n = reader.read_line(&mut resp_line)?;
    if n == 0 {
        return Err(io::Error::new(
            io::ErrorKind::UnexpectedEof,
            "empty ipc response",
        ));
    }
    serde_json::from_str(resp_line.trim())
        .map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e.to_string()))
}

/// Send an authenticated async JSON request to the daemon at `ipc_path`.
pub async fn request_json_async<Req: Serialize, Resp: DeserializeOwned>(
    ipc_path: &Path,
    req: &Req,
    timeout: Duration,
) -> io::Result<Resp> {
    let ep = read_endpoint(ipc_path)?;
    let addr = SocketAddr::new(IpAddr::V4(Ipv4Addr::LOCALHOST), ep.port);
    let stream = tokio::time::timeout(timeout, TokioTcpStream::connect(addr))
        .await
        .map_err(|_| io::Error::new(io::ErrorKind::TimedOut, "ipc connect timeout"))??;
    let mut reader = TokioBufReader::new(stream);
    let req_str = serde_json::to_string(req)
        .map_err(|e| io::Error::new(io::ErrorKind::InvalidInput, e.to_string()))?;
    let wire = format!("{}\n{}\n", ep.token, req_str);
    reader.get_mut().write_all(wire.as_bytes()).await?;
    reader.get_mut().flush().await?;

    let mut resp_line = String::new();
    let n = tokio::time::timeout(timeout, reader.read_line(&mut resp_line))
        .await
        .map_err(|_| io::Error::new(io::ErrorKind::TimedOut, "ipc read timeout"))??;
    if n == 0 {
        return Err(io::Error::new(
            io::ErrorKind::UnexpectedEof,
            "empty ipc response",
        ));
    }
    serde_json::from_str(resp_line.trim())
        .map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e.to_string()))
}
