//! Agent-to-agent inbox messaging substrate (INFRA-1998 Phase 1).
//!
//! Mirrors the semantics of the legacy bash callsite at
//! `scripts/coord/broadcast.sh` + `scripts/coord/chump-inbox.sh`:
//!
//! - Inbox files at `<lock_dir>/inbox/<TO>.jsonl`, one JSON event per line.
//! - Cursor files at `<lock_dir>/inbox/<TO>.cursor`, storing the last-read
//!   byte offset.
//! - Atomic cursor writes (tempfile + rename) so concurrent inbox-reads
//!   cannot race with cursor advance.
//! - Append+fsync on send so concurrent writers from multiple processes
//!   do not interleave bytes.
//!
//! ## What's different from the bash callsite
//!
//! - **Typed envelope**: [`OutboundMessage`] carries a structured
//!   [`serde_json::Value`] body instead of an escaped JSON-in-a-string
//!   the bash callsite produces with `python3 -c "json.dumps(...)"`.
//!   Eliminates the sed-escape bug class when message bodies contain
//!   JSON-shaped data or pipe/newline chars.
//! - **`Cow<'a, str>`** on `from` / `to` / `kind` / `corr_id` so callers
//!   can pass borrowed env-derived strings without an allocation.
//! - **Typed [`MessageLevel`]** instead of a free-form positional string.
//!
//! ## Phase 1 non-goals (deferred to follow-up sub-gaps)
//!
//! - `NatsBroker` impl — only [`FileBroker`] this PR.
//! - SQLite-backed cursor migration.
//! - Mirror-to-GitHub-comments path (INFRA-1932).
//! - Auto-ack on corresponding DONE event.

use std::borrow::Cow;
use std::path::PathBuf;

use async_trait::async_trait;
use chrono::Utc;
use serde::{Deserialize, Serialize};
use tokio::fs;
use tokio::io::{AsyncReadExt, AsyncWriteExt};

use crate::error::BrokerError;

/// Stable identifier returned by a successful
/// [`Broker::send`](Broker::send).
///
/// Phase 1 derives this from `(ts, to, kind)` — sufficient to look up
/// the event in the recipient inbox. A NATS broker in a follow-up
/// would return a NATS sequence id.
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct MessageId(pub String);

impl MessageId {
    /// Constructor from owned String.
    pub fn new(s: impl Into<String>) -> Self {
        MessageId(s.into())
    }

    /// Borrowed access to the inner string.
    pub fn as_str(&self) -> &str {
        &self.0
    }
}

/// Classification of an outbound message.
///
/// Mirrors the positional `EVENT` argument in `scripts/coord/broadcast.sh`
/// (INTENT / HANDOFF / STUCK / DONE / WARN / ALERT / FEEDBACK).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "UPPERCASE")]
pub enum MessageLevel {
    /// "I'm about to start working on gap X with files Y" — pre-claim
    /// announcement. Other agents check INTENT events from the last 5
    /// minutes before claiming the same gap.
    Intent,
    /// "Picking up where session Y left off" — explicit ownership pass.
    Handoff,
    /// "I can't proceed because X" — operator-visible diagnostic.
    Stuck,
    /// "Gap X shipped at commit Y" — terminal lifecycle event.
    Done,
    /// Free-form warning.
    Warn,
    /// Operator-page-class alert (`kind=` sub-type carried separately).
    Alert,
    /// Structured opinion / preference / retro feedback (INFRA-1271).
    Feedback,
}

impl MessageLevel {
    /// Parse from the uppercase positional bash argument
    /// (`INTENT` / `HANDOFF` / …). Case-insensitive.
    pub fn parse(s: &str) -> Result<Self, BrokerError> {
        match s.to_ascii_uppercase().as_str() {
            "INTENT" => Ok(MessageLevel::Intent),
            "HANDOFF" => Ok(MessageLevel::Handoff),
            "STUCK" => Ok(MessageLevel::Stuck),
            "DONE" => Ok(MessageLevel::Done),
            "WARN" => Ok(MessageLevel::Warn),
            "ALERT" => Ok(MessageLevel::Alert),
            "FEEDBACK" => Ok(MessageLevel::Feedback),
            other => Err(BrokerError::InvalidLevel(other.to_string())),
        }
    }

    /// Uppercase string form used as the `event` JSON field.
    pub fn as_str(self) -> &'static str {
        match self {
            MessageLevel::Intent => "INTENT",
            MessageLevel::Handoff => "HANDOFF",
            MessageLevel::Stuck => "STUCK",
            MessageLevel::Done => "DONE",
            MessageLevel::Warn => "WARN",
            MessageLevel::Alert => "ALERT",
            MessageLevel::Feedback => "FEEDBACK",
        }
    }
}

/// Optional urgency hint (mirrors the `--urgency` flag in
/// `scripts/coord/broadcast.sh`, INFRA-1299).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Urgency {
    /// Reach for the operator now (pages, notifications).
    Now,
    /// Surfaces in hourly digest.
    Hours,
    /// Surfaces in daily digest.
    Digest,
}

impl Urgency {
    /// Lowercase string for the JSON `urgency` field.
    pub fn as_str(self) -> &'static str {
        match self {
            Urgency::Now => "now",
            Urgency::Hours => "hours",
            Urgency::Digest => "digest",
        }
    }

    /// Parse from CLI flag string.
    pub fn parse(s: &str) -> Option<Self> {
        match s {
            "now" => Some(Urgency::Now),
            "hours" => Some(Urgency::Hours),
            "digest" => Some(Urgency::Digest),
            _ => None,
        }
    }
}

/// A message about to be sent to a peer agent's inbox.
///
/// Uses `Cow<'a, str>` on the small string fields so callers in hot
/// paths can pass borrowed env-derived values without allocating.
/// The `body` is a structured [`serde_json::Value`] — NOT a string
/// containing escaped JSON.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct OutboundMessage<'a> {
    /// Sender session id (from `CHUMP_SESSION_ID` env in the bash callsite).
    pub from: Cow<'a, str>,
    /// Recipient session id. Empty = broadcast-only (not supported by
    /// [`FileBroker::send`] — see [`BrokerError::MissingRecipient`]).
    pub to: Cow<'a, str>,
    /// Message classification (INTENT / STUCK / DONE / ...).
    pub level: MessageLevel,
    /// Sub-kind for ALERT (`kind=fleet_wedge`, etc.). Empty for non-ALERT.
    pub kind: Cow<'a, str>,
    /// Optional urgency hint.
    pub urgency: Option<Urgency>,
    /// Optional correlation id to tie request/response pairs (INFRA-1255).
    pub corr_id: Option<Cow<'a, str>>,
    /// Optional gap id (when applicable to this level).
    pub gap: Option<Cow<'a, str>>,
    /// Structured body. For STUCK / WARN / FEEDBACK this is typically a
    /// `{"reason": "..."}`; for DONE a `{"commit": "..."}`. Adapters MUST
    /// NOT pre-escape JSON into a string — pass real `serde_json::Value`.
    pub body: serde_json::Value,
}

impl<'a> OutboundMessage<'a> {
    /// Convenience: build a WARN message with a string reason.
    pub fn warn(from: impl Into<Cow<'a, str>>, to: impl Into<Cow<'a, str>>, reason: &str) -> Self {
        OutboundMessage {
            from: from.into(),
            to: to.into(),
            level: MessageLevel::Warn,
            kind: Cow::Borrowed(""),
            urgency: None,
            corr_id: None,
            gap: None,
            body: serde_json::json!({ "reason": reason }),
        }
    }

    /// Convenience: build an INTENT message with gap + comma-separated files.
    pub fn intent(
        from: impl Into<Cow<'a, str>>,
        to: impl Into<Cow<'a, str>>,
        gap: &str,
        files: &str,
    ) -> Self {
        OutboundMessage {
            from: from.into(),
            to: to.into(),
            level: MessageLevel::Intent,
            kind: Cow::Borrowed(""),
            urgency: None,
            corr_id: Some(Cow::Owned(gap.to_string())),
            gap: Some(Cow::Owned(gap.to_string())),
            body: serde_json::json!({ "files": files }),
        }
    }
}

/// One row read back from an inbox file.
///
/// Phase 1 returns the raw JSON value plus a synthesized [`MessageId`]
/// — callers that need typed fields can deserialize the body themselves.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct InboundMessage {
    /// Synthesized id used by [`Broker::ack`]. Phase 1 derives it from
    /// `(ts, kind/event, to)`.
    pub id: MessageId,
    /// The raw event row as written by either the bash or the Rust path.
    pub event: serde_json::Value,
}

/// Async trait implemented by file-backed and (future) NATS-backed brokers.
///
/// All methods are async to keep the surface forward-compatible with a
/// NATS broker that needs to await its client. The Phase 1 `FileBroker`
/// uses `tokio::fs` to honor the signature without blocking.
#[async_trait]
pub trait Broker: Send + Sync {
    /// Append `msg` to the recipient's inbox + return its [`MessageId`].
    async fn send(&self, msg: OutboundMessage<'_>) -> Result<MessageId, BrokerError>;

    /// Read all unread messages for `session_id` (since the persisted
    /// cursor) and advance the cursor atomically. Returns an empty vec
    /// if the inbox file does not exist.
    async fn read(&self, session_id: &str) -> Result<Vec<InboundMessage>, BrokerError>;

    /// Mark a single message as acknowledged. Phase 1 [`FileBroker`]
    /// treats this as a no-op (the per-session cursor IS the ack mechanism);
    /// the API exists so a NATS broker can implement explicit per-message
    /// acks in a follow-up.
    async fn ack(&self, _id: MessageId) -> Result<(), BrokerError> {
        Ok(())
    }
}

/// File-backed [`Broker`] mirroring the legacy
/// `scripts/coord/broadcast.sh` + `scripts/coord/chump-inbox.sh`
/// semantics.
///
/// Layout under `dir`:
///   - `<TO>.jsonl`        — append-only event stream per recipient.
///   - `<TO>.cursor`       — last-read byte offset for that recipient.
///   - `.<TO>.cursor.tmp.<pid>` — staging file for atomic cursor write.
#[derive(Debug, Clone)]
pub struct FileBroker {
    /// Inbox directory (typically `.chump-locks/inbox/`).
    pub dir: PathBuf,
}

impl FileBroker {
    /// Construct against an explicit inbox directory. The directory
    /// will be created on first send.
    pub fn new(dir: impl Into<PathBuf>) -> Self {
        FileBroker { dir: dir.into() }
    }

    /// Resolve the inbox file path for `recipient`.
    pub fn inbox_path(&self, recipient: &str) -> PathBuf {
        self.dir.join(format!("{}.jsonl", recipient))
    }

    /// Resolve the cursor file path for `session_id`.
    pub fn cursor_path(&self, session_id: &str) -> PathBuf {
        self.dir.join(format!("{}.cursor", session_id))
    }

    /// Build the JSON event row written to the inbox file.
    ///
    /// Field order + names match the bash callsite at
    /// `scripts/coord/broadcast.sh` for byte-level parity with legacy
    /// readers. The keys are emitted in insertion order via
    /// `serde_json::Map`.
    fn build_event_row(msg: &OutboundMessage<'_>, ts: &str) -> serde_json::Value {
        let mut row = serde_json::Map::new();
        row.insert(
            "event".to_string(),
            serde_json::Value::String(msg.level.as_str().to_string()),
        );
        row.insert(
            "session".to_string(),
            serde_json::Value::String(msg.from.clone().into_owned()),
        );
        row.insert("ts".to_string(), serde_json::Value::String(ts.to_string()));
        if let Some(corr) = &msg.corr_id {
            row.insert(
                "corr_id".to_string(),
                serde_json::Value::String(corr.clone().into_owned()),
            );
        }
        if let Some(u) = msg.urgency {
            row.insert(
                "urgency".to_string(),
                serde_json::Value::String(u.as_str().to_string()),
            );
        }
        if let Some(gap) = &msg.gap {
            row.insert(
                "gap".to_string(),
                serde_json::Value::String(gap.clone().into_owned()),
            );
        }
        if !msg.kind.is_empty() {
            row.insert(
                "kind".to_string(),
                serde_json::Value::String(msg.kind.clone().into_owned()),
            );
        }
        // Splat the structured body into the row so readers see flat
        // top-level keys like `reason` / `commit` / `files` exactly as
        // the bash python-json builder emits them today.
        if let serde_json::Value::Object(body_map) = &msg.body {
            for (k, v) in body_map {
                row.insert(k.clone(), v.clone());
            }
        } else if !msg.body.is_null() {
            // Non-object body — stash under "body" so we don't lose it.
            row.insert("body".to_string(), msg.body.clone());
        }
        if !msg.to.is_empty() {
            row.insert(
                "to".to_string(),
                serde_json::Value::String(msg.to.clone().into_owned()),
            );
        }
        serde_json::Value::Object(row)
    }

    /// Synthesize a stable id from `(ts, level, to)`.
    fn synth_id(msg: &OutboundMessage<'_>, ts: &str) -> MessageId {
        MessageId::new(format!("{}|{}|{}", ts, msg.level.as_str(), msg.to))
    }

    /// Synthesize an id from a read-back row (best-effort: matches the
    /// `synth_id` shape when the row was written by us).
    fn synth_id_from_row(row: &serde_json::Value) -> MessageId {
        let ts = row.get("ts").and_then(|v| v.as_str()).unwrap_or("");
        let event = row.get("event").and_then(|v| v.as_str()).unwrap_or("");
        let to = row.get("to").and_then(|v| v.as_str()).unwrap_or("");
        MessageId::new(format!("{}|{}|{}", ts, event, to))
    }

    /// Atomically replace the cursor file via tempfile + rename.
    async fn write_cursor_atomically(
        &self,
        session_id: &str,
        offset: u64,
    ) -> Result<(), BrokerError> {
        let final_path = self.cursor_path(session_id);
        let tmp_path = self
            .dir
            .join(format!(".{}.cursor.tmp.{}", session_id, std::process::id()));
        // Write tempfile.
        {
            let mut f = fs::File::create(&tmp_path).await?;
            f.write_all(offset.to_string().as_bytes()).await?;
            f.sync_all().await?;
        }
        // Atomic rename. On POSIX this is atomic when src + dst are on
        // the same filesystem (always true here — same `dir`).
        fs::rename(&tmp_path, &final_path).await?;
        Ok(())
    }
}

#[async_trait]
impl Broker for FileBroker {
    async fn send(&self, msg: OutboundMessage<'_>) -> Result<MessageId, BrokerError> {
        if msg.to.is_empty() {
            return Err(BrokerError::MissingRecipient);
        }

        // Ensure inbox dir exists.
        fs::create_dir_all(&self.dir).await?;

        let ts = Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string();
        let row = Self::build_event_row(&msg, &ts);
        let id = Self::synth_id(&msg, &ts);

        let mut line = serde_json::to_string(&row)?;
        line.push('\n');

        let inbox_file = self.inbox_path(&msg.to);
        // OpenOptions append + fsync after write so concurrent multi-process
        // writers don't interleave bytes — matches the flock'd append in
        // the bash callsite. POSIX guarantees O_APPEND-flagged writes are
        // atomic for sizes <= PIPE_BUF (4096 bytes on Linux/macOS); the
        // bash callsite uses flock for the same reason.
        let mut f = fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(&inbox_file)
            .await?;
        f.write_all(line.as_bytes()).await?;
        f.sync_all().await?;

        Ok(id)
    }

    async fn read(&self, session_id: &str) -> Result<Vec<InboundMessage>, BrokerError> {
        let inbox_file = self.inbox_path(session_id);
        // Inbox does not exist yet — empty result, no cursor update.
        if !fs::try_exists(&inbox_file).await? {
            return Ok(Vec::new());
        }

        // Resolve cursor offset.
        let cursor_path = self.cursor_path(session_id);
        let mut offset: u64 = 0;
        if fs::try_exists(&cursor_path).await? {
            let raw = fs::read_to_string(&cursor_path).await?;
            offset = raw.trim().parse::<u64>().unwrap_or(0);
        }

        // Open + seek to offset.
        let mut f = fs::File::open(&inbox_file).await?;
        let file_size = f.metadata().await?.len();
        // If cursor advanced past file end (truncation), reset to 0.
        if offset > file_size {
            offset = 0;
        }
        // Read the tail slice.
        if offset > 0 {
            use tokio::io::AsyncSeekExt;
            f.seek(std::io::SeekFrom::Start(offset)).await?;
        }
        let mut buf = String::new();
        f.read_to_string(&mut buf).await?;

        let mut out: Vec<InboundMessage> = Vec::new();
        for line in buf.lines() {
            let line = line.trim();
            if line.is_empty() {
                continue;
            }
            match serde_json::from_str::<serde_json::Value>(line) {
                Ok(v) => {
                    let id = Self::synth_id_from_row(&v);
                    out.push(InboundMessage { id, event: v });
                }
                Err(_) => {
                    // Skip malformed lines (the bash callsite's python
                    // filter does the same — be tolerant of partial
                    // writes during a crash).
                    continue;
                }
            }
        }

        // Advance cursor atomically.
        self.write_cursor_atomically(session_id, file_size).await?;

        Ok(out)
    }
}

// ---- Tests --------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::Path;
    use tempfile::TempDir;

    #[test]
    fn level_round_trip() {
        for l in [
            MessageLevel::Intent,
            MessageLevel::Handoff,
            MessageLevel::Stuck,
            MessageLevel::Done,
            MessageLevel::Warn,
            MessageLevel::Alert,
            MessageLevel::Feedback,
        ] {
            let parsed = MessageLevel::parse(l.as_str()).expect("parse");
            assert_eq!(parsed, l);
        }
    }

    #[test]
    fn level_parse_case_insensitive() {
        assert_eq!(MessageLevel::parse("intent").unwrap(), MessageLevel::Intent);
        assert_eq!(MessageLevel::parse("Done").unwrap(), MessageLevel::Done);
    }

    #[test]
    fn level_parse_rejects_garbage() {
        let err = MessageLevel::parse("DOEN").unwrap_err();
        assert!(matches!(err, BrokerError::InvalidLevel(_)));
    }

    #[test]
    fn urgency_round_trip() {
        for u in [Urgency::Now, Urgency::Hours, Urgency::Digest] {
            assert_eq!(Urgency::parse(u.as_str()).unwrap(), u);
        }
        assert!(Urgency::parse("yesterday").is_none());
    }

    #[test]
    fn warn_helper_shape() {
        let m = OutboundMessage::warn("from-a", "to-b", "boom");
        assert_eq!(m.level, MessageLevel::Warn);
        assert_eq!(m.from, "from-a");
        assert_eq!(m.to, "to-b");
        assert_eq!(m.body["reason"], "boom");
    }

    #[test]
    fn build_event_row_flattens_body() {
        let m = OutboundMessage::warn("sess-a", "sess-b", "hi");
        let row = FileBroker::build_event_row(&m, "2026-05-25T19:00:00Z");
        assert_eq!(row["event"], "WARN");
        assert_eq!(row["session"], "sess-a");
        assert_eq!(row["to"], "sess-b");
        assert_eq!(row["reason"], "hi");
        assert_eq!(row["ts"], "2026-05-25T19:00:00Z");
    }

    #[test]
    fn build_event_row_omits_empty_kind() {
        let m = OutboundMessage::warn("a", "b", "x");
        let row = FileBroker::build_event_row(&m, "ts");
        assert!(row.get("kind").is_none());
    }

    #[test]
    fn build_event_row_includes_corr_and_gap_when_set() {
        let m = OutboundMessage::intent("a", "b", "INFRA-9999", "src/foo.rs,src/bar.rs");
        let row = FileBroker::build_event_row(&m, "ts");
        assert_eq!(row["event"], "INTENT");
        assert_eq!(row["gap"], "INFRA-9999");
        assert_eq!(row["corr_id"], "INFRA-9999");
        assert_eq!(row["files"], "src/foo.rs,src/bar.rs");
    }

    #[tokio::test]
    async fn send_writes_jsonl_line_to_recipient_inbox() {
        let tmp = TempDir::new().expect("tmp");
        let broker = FileBroker::new(tmp.path());
        let id = broker
            .send(OutboundMessage::warn("from-a", "to-b", "first"))
            .await
            .expect("send");
        assert!(id.as_str().contains("WARN"));
        let body = fs::read_to_string(tmp.path().join("to-b.jsonl"))
            .await
            .unwrap();
        assert_eq!(body.lines().count(), 1);
        let v: serde_json::Value = serde_json::from_str(body.lines().next().unwrap()).unwrap();
        assert_eq!(v["event"], "WARN");
        assert_eq!(v["session"], "from-a");
        assert_eq!(v["to"], "to-b");
        assert_eq!(v["reason"], "first");
    }

    #[tokio::test]
    async fn send_with_empty_recipient_returns_missing_recipient() {
        let tmp = TempDir::new().expect("tmp");
        let broker = FileBroker::new(tmp.path());
        let mut msg = OutboundMessage::warn("a", "", "boom");
        msg.to = Cow::Borrowed("");
        let err = broker.send(msg).await.unwrap_err();
        assert!(matches!(err, BrokerError::MissingRecipient));
    }

    #[tokio::test]
    async fn send_preserves_special_chars_in_body() {
        let tmp = TempDir::new().expect("tmp");
        let broker = FileBroker::new(tmp.path());
        let tricky = "pipe | newline\\n quote \" and { \"nested\": \"json\" }";
        broker
            .send(OutboundMessage::warn("from-a", "to-b", tricky))
            .await
            .unwrap();
        let body = fs::read_to_string(tmp.path().join("to-b.jsonl"))
            .await
            .unwrap();
        let v: serde_json::Value = serde_json::from_str(body.lines().next().unwrap()).unwrap();
        // The reason field must round-trip the raw bytes of the input.
        assert_eq!(v["reason"], tricky);
    }

    #[tokio::test]
    async fn read_returns_empty_when_inbox_absent() {
        let tmp = TempDir::new().expect("tmp");
        let broker = FileBroker::new(tmp.path());
        let r = broker.read("nobody").await.unwrap();
        assert!(r.is_empty());
    }

    #[tokio::test]
    async fn read_returns_appended_messages_and_advances_cursor() {
        let tmp = TempDir::new().expect("tmp");
        let broker = FileBroker::new(tmp.path());
        broker
            .send(OutboundMessage::warn("from-a", "to-b", "one"))
            .await
            .unwrap();
        broker
            .send(OutboundMessage::warn("from-a", "to-b", "two"))
            .await
            .unwrap();
        let first = broker.read("to-b").await.unwrap();
        assert_eq!(first.len(), 2);
        assert_eq!(first[0].event["reason"], "one");
        assert_eq!(first[1].event["reason"], "two");
        // Second read returns nothing — cursor advanced.
        let second = broker.read("to-b").await.unwrap();
        assert!(second.is_empty());
    }

    #[tokio::test]
    async fn read_resets_cursor_on_truncation() {
        let tmp = TempDir::new().expect("tmp");
        let broker = FileBroker::new(tmp.path());
        // Send several long messages so the cursor advances well past
        // any plausible single-message file size.
        for i in 0..5 {
            broker
                .send(OutboundMessage::warn(
                    "from-a",
                    "to-b",
                    &format!("long-message-padding-padding-padding-{i}"),
                ))
                .await
                .unwrap();
        }
        // Read to advance cursor past file size.
        let _ = broker.read("to-b").await.unwrap();
        // Simulate inbox archive: replace with a much shorter file
        // (smaller than the advanced cursor).
        let short_replacement =
            r#"{"event":"WARN","session":"x","to":"to-b","reason":"short"}"#.to_string() + "\n";
        fs::write(tmp.path().join("to-b.jsonl"), short_replacement.as_bytes())
            .await
            .unwrap();
        // Now read — offset > new file_size → reset to 0 → see the short replacement.
        let v = broker.read("to-b").await.unwrap();
        assert_eq!(v.len(), 1);
        assert_eq!(v[0].event["reason"], "short");
    }

    #[tokio::test]
    async fn read_skips_malformed_lines() {
        let tmp = TempDir::new().expect("tmp");
        let broker = FileBroker::new(tmp.path());
        // Write a junk line + a real line.
        let path = tmp.path().join("to-b.jsonl");
        fs::write(
            &path,
            "{not valid json\n{\"event\":\"WARN\",\"to\":\"to-b\",\"reason\":\"ok\"}\n",
        )
        .await
        .unwrap();
        let v = broker.read("to-b").await.unwrap();
        assert_eq!(v.len(), 1);
        assert_eq!(v[0].event["reason"], "ok");
    }

    #[tokio::test]
    async fn ack_is_a_noop_for_filebroker() {
        let tmp = TempDir::new().expect("tmp");
        let broker = FileBroker::new(tmp.path());
        broker.ack(MessageId::new("doesnt-matter")).await.unwrap();
    }

    #[tokio::test]
    async fn cursor_write_is_atomic_no_stale_tmp_left_behind() {
        let tmp = TempDir::new().expect("tmp");
        let broker = FileBroker::new(tmp.path());
        broker
            .send(OutboundMessage::warn("from-a", "to-b", "one"))
            .await
            .unwrap();
        let _ = broker.read("to-b").await.unwrap();
        // No leftover *.cursor.tmp.* files.
        let mut entries = fs::read_dir(tmp.path()).await.unwrap();
        let mut left_overs: Vec<String> = Vec::new();
        while let Some(entry) = entries.next_entry().await.unwrap() {
            let name = entry.file_name().into_string().unwrap();
            if name.contains(".cursor.tmp.") {
                left_overs.push(name);
            }
        }
        assert!(
            left_overs.is_empty(),
            "leftover tmp files: {:?}",
            left_overs
        );
    }

    #[test]
    fn synth_id_from_row_handles_missing_fields() {
        let row = serde_json::json!({});
        let id = FileBroker::synth_id_from_row(&row);
        // No panic; produces a degenerate-but-stable id.
        assert_eq!(id.as_str(), "||");
    }

    #[test]
    fn inbox_path_and_cursor_path_use_recipient_id() {
        let broker = FileBroker::new(Path::new("/some/dir"));
        assert_eq!(
            broker.inbox_path("alice"),
            PathBuf::from("/some/dir/alice.jsonl")
        );
        assert_eq!(
            broker.cursor_path("alice"),
            PathBuf::from("/some/dir/alice.cursor")
        );
    }
}
