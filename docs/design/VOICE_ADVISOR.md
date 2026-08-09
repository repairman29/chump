# DESIGN — Voice Advisor (talk to ChumpOS by voice)

Status: draft, 2026-08-08. Goal: a full-time voice agent you chat with that sits in
your repos and advises mainly on ChumpOS, with almanac as the proxy for the whole
fleet. Built by cloning Olive's *proven* Siri-Shortcut voice-ask pattern and pointing
it at Chump's existing `/api/chat` agent loop (which already has `almanac_search` as a
tool). No new brain, no new transport, no new RAG tier — the layers all exist.

---

## 0. What already exists (do not rebuild)

- **Chump is already an HTTP agent server.** `src/web_server.rs:3927` (`handle_chat`)
  accepts `ChatRequest { message, session_id, bot, ... }`, enforces
  `CHUMP_WEB_TOKEN` bearer auth (`check_auth`, :295), persists per-session history via
  `web_sessions_db::session_ensure` (:3945) + `message_append_user/assistant`, and
  streams `AgentEvent`s over SSE. `chump_system_prompt(context, is_mabel)` (:148 in
  `system_prompt.rs`) builds the soul.
- **`almanac_search` is already a registered tool.** `src/almanac_tool.rs:24` shells
  out to the `almanac-mcp` binary against the live registry index. Its own header says
  the OS "gaining the ability to search itself." Voice just adds another door into it.
- **Olive already proved the Siri-Shortcut shape end to end.** `olive/src/app/api/voice/ask/route.ts`
  takes a dictated phrase, auths via a shared key, loads per-user history, calls
  `runAgent(..., spoken:true)`, persists history, detects EXIT/CLEAR terminal phrases,
  returns `{ spoken, end, items }` JSON the Shortcut loops on. It has e2e
  (`olive/e2e/voice-quality.mjs`) and a design doc (`olive/docs/DESIGN-voice.md`) that
  argues turn-based > realtime for advisory chat — which holds for ChumpOS advising too.
- **iPad is the right client after all.** Apple is the wake word: `Hey Siri, <phrase>`
  does wake + STT for free, POSTs the text to your endpoint, and speaks the reply. The
  iPad stays plugged in, screen-off, never touched — the degraded touch is irrelevant.
  No background-mic fight, no $99 dev fee, no Porcupine. (This is the correction to the
  earlier "iOS can't do always-on" verdict: Siri *is* the always-on layer.)

---

## 1. Addendum — voice-mode system prompt

Generalizes Olive's honesty rail from "prices never invented" to "repo/PR/gate claims
never invented." Appended to `chump_system_prompt` output when the request is `voice`.
The existing Chump soul/persona is kept; this only adds spoken-output discipline + the
almanac-first rule for advisory answers.

```
VOICE ADDENDUM — this reply will be READ ALOUD. Hard rules:

SOURCE OF TRUTH (the honesty rail, for code):
- You are advising on ChumpOS and the fleet around it. Every concrete claim — a PR's
  status, a CI gate's name, a bypass env, a file's path, a function's signature, a
  repo's structure, whether something exists — MUST come from a tool result you got
  THIS turn or a prior turn of this session. NEVER invent, estimate, or guess a
  repo/PR/gate/file fact. If you don't have it, say you don't know, or call a tool.
- Call almanac_search FIRST for any question about code, a repo, or "where does X
  live." It spans the whole fleet (Chump, olive, jarvis, upshift, almanac itself…),
  not just ChumpOS — so a question about any repo routes through the same tool.
- If a tool is unavailable (almanac_search not registered, run_cli gated off), say so
  plainly — "I can't search the codebase right now" — do not paper over it with a
  plausible-sounding answer. Silence about a failed tool is the one thing that breaks
  trust fastest.
- Destructive-by-voice stays advisory. You can describe a gap, a gate, a fix; you do
  NOT ship, merge, or mutate repos from a voice turn. The irreversible action stays a
  tap in the app/web UI — same rail as Olive's checkout.

VOICE OUTPUT FORMAT:
- 1 to 3 short sentences. NEVER bullet points, NEVER markdown (no **, no lists, no
  headers, no code spans). Plain speech, contractions, no symbols.
- Name the one thing that matters (the gate that's blocking, the file the symbol lives
  in, the PR number). The screen — if one's attached — shows the rest.
- If you ran tools, say what you found, not "let me check" — by the time you speak,
  the tool already ran.
- End with one short question at most, and only when a decision genuinely branches.

When the shopper says "done", "stop", "that's all", "goodbye", or similar — end the
turn cleanly; the route handles session close.
```

> Why "shopper" stays in the last line: it's a find/replace artifact risk to lift
> Olive's addendum verbatim. On review, swap "shopper" → "user". The rule is what
> matters, not the word.

---

## 2. The route — `/api/voice/ask` (co-located in Chump's web server)

**Recommendation: add it as a Rust route in `web_server.rs`, sibling to `/api/chat`.**
Reuses `check_auth`, `web_sessions_db`, and the agent loop directly — no SSE-over-HTTP
proxy hop, no second service. The logic cloned from Olive is the Siri *shape*
(detect terminal phrases, persist session, return `{spoken, end}` loop-control JSON),
not the TypeScript.

### 2.1 ChatRequest extension (one line + handler)

```rust
// src/web_server.rs, in struct ChatRequest (line 62)
struct ChatRequest {
    message: String,
    #[serde(default)]
    session_id: Option<String>,
    #[serde(default)]
    attachments: Option<Vec<AttachmentRef>>,
    #[serde(default)]
    bot: Option<String>,
    #[serde(default)]
    policy_override: Option<PolicyOverrideInline>,
    /// NEW — when true, the voice addendum is appended to the system prompt and the
    /// session is marked spoken so replies stay TTS-friendly. Mirrors Olive's
    /// `ctx.spoken` flag (olive/src/lib/agent/orchestrator.ts:133).
    #[serde(default)]
    voice: Option<bool>,
}
```

Where the system prompt is assembled (`system_prompt.rs`, after `chump_system_prompt`
returns), append the §1 addendum when the session is voice. The cleanest seam: thread
`voice` through the agent loop the same way `is_mabel` already threads, and in the
prompt builder:

```rust
if voice {
    prompt.push_str(VOICE_ADDENDUM);  // the §1 block, as a const &str
}
```

### 2.2 The voice-ask route

Mirrors `olive/src/app/api/voice/ask/route.ts` line for line in intent. Key differences
from Olive: no Kroger, no cart, no per-user Supabase voice keys (single-operator MVP —
reuse `CHUMP_WEB_TOKEN`). Chump's `web_sessions_db` already persists history per
`session_id`, so we do NOT clone Olive's `olive_voice_cart` table — we just keep one
stable `session_id` for the voice conversation and let Chump remember.

```rust
// src/web_server.rs

/// POST /api/voice/ask — Siri Shortcut entry point. Takes { text }, returns { spoken, end }.
/// Reuses check_auth + handle_chat's agent loop. Session continuity via a stable
/// voice session id (CHUMP_VOICE_SESSION_ID env, else "voice").
async fn handle_voice_ask(
    headers: HeaderMap,
    Json(body): Json<VoiceAskBody>,
) -> Response {
    if !check_auth(&headers) {
        return (StatusCode::UNAUTHORIZED, "unauthorized").into_response();
    }
    let text = body.text.trim();
    let session = std::env::var("CHUMP_VOICE_SESSION_ID")
        .unwrap_or_else(|_| "voice".to_string());

    // Terminal phrases close the conversation cleanly (mirrors Olive's EXIT regex).
    const EXIT: &str = r"(?i)^\s*(that'?\s*(?:it|all)|i'?\s*m done|all done|we'?\s*re done|done|nothing else|no,?\s*that'?\s*(?:it|all)|stop|goodbye|bye|thanks?)\s*[.!]?\s*$";
    if regex::Regex::new(EXIT).unwrap().is_match(text) {
        return Json(serde_json::json!({
            "spoken": "Closing out. Say hey Siri, ask Chump, when you need me.",
            "end": "yes",
        })).into_response();
    }
    if text.is_empty() {
        return Json(serde_json::json!({
            "spoken": "Didn't catch that. Say hey Siri, ask Chump, and your question.",
            "end": "yes",
        })).into_response();
    }

    // Forward into the SAME agent loop /api/chat uses, but voice:true and non-streaming
    // (we collect the SSE into a single spoken string for the Shortcut).
    let chat_body = ChatRequest {
        message: text.to_string(),
        session_id: Some(session.clone()),
        attachments: None,
        bot: None,
        policy_override: None,
        voice: Some(true),
    };

    // Consume the SSE stream handle_chat returns; collect until turn_complete.
    // (In practice: call the agent loop fn directly rather than HTTP-to-self, or
    //  drain the Sse stream. The cleanest is to factor the loop body out of
    //  handle_chat into a helper both /api/chat and /api/voice/ask call.)
    let spoken = drain_agent_to_final_text(/* chat_body, session */).await;

    Json(serde_json::json!({
        "spoken": spoken,
        "end": "no",
    })).into_response();
}

#[derive(serde::Deserialize)]
struct VoiceAskBody {
    #[serde(default)]
    text: String,
}
```

### 2.3 SSE → single spoken string

`/api/chat` returns `Sse<...>` of `AgentEvent`s. The voice route drains the stream and
takes the `full_text` from `turn_complete` (or the last `text_complete`), matching the
real event type names from `stream_events.rs:82-97`.

The events that matter (`src/stream_events.rs`):
- `turn_complete` → `{ full_text, ... }` — **the spoken reply**
- `text_complete` → `{ text }` — fallback if turn_complete never fires
- `turn_error` → `{ error }` — surface plainly
- `tool_call_start` / `tool_call_result` — optionally narrate ("checking the codebase…")
  but for MVP, ignore; the §1 addendum says "say what you found, not let me check"

```rust
async fn drain_agent_to_final_text(/* body */) -> String {
    // Call the factored agent-loop helper (same one handle_chat uses), get the
    // EventReceiver, drain until turn_complete or turn_error.
    // Collect the last text_complete; on turn_complete use full_text.
    let mut last_text = String::new();
    while let Some(ev) = rx.recv().await {
        match ev {
            AgentEvent::TextComplete { text } => last_text = text,
            AgentEvent::TurnComplete { full_text, .. } => return full_text,
            AgentEvent::TurnError { error, .. } => return format!("Chump hit an error: {error}"),
            _ => {}
        }
    }
    last_text
}
```

> Refactor note: `handle_chat` currently owns session-ensure + message-append + the
> agent spawn. Factor the "run one turn and emit events" body into a helper both
> `/api/chat` (streaming) and `/api/voice/ask` (drain-to-text) call. That's the one
> real refactor; it's mechanical, not behavioral.

---

## 3. Siri Shortcut (the client — zero app code)

Build in the Shortcuts app on the iPad (or Mac, synced to iPad):

1. **Trigger:** any phrase collision-free with Apple's reserved intents. Olive uses
   "Let's shop with Olive." Chump equivalent: **"Ask Chump."** So: *Hey Siri, ask Chump
   what's blocking PR two seven eight zero.* (Spell digits to avoid transcription noise.)
2. **Dictate Text** → captures the question.
3. **Get Contents of URL** → `POST https://<your-chump-public-url>/api/voice/ask`
   - Headers: `Authorization: Bearer <CHUMP_WEB_TOKEN>`, `Content-Type: application/json`
   - Body: `{ "text": "<dictated input>" }`
4. **Dictionary from Contents → get `spoken`** → **Speak Text**.
5. **If `end` equals "no"** → loop back to Dictate Text (multi-turn). Else Stop.

The iPad stays plugged in, screen off, volume up. Touch is never used. This is the
correct answer to "what do I do with a half-dead-touch iPad": it's a Siri voice
terminal to your own agent.

### Exposing Chump to Siri

Siri needs public HTTPS (Shortcuts runs in the cloud, not your LAN). Options, best
first:
- **Tailscale Funnel** — gives your already-running Chump web server a public HTTPS URL
  without opening a router port. One `tailscale funnel` command. Stays self-hosted.
- **Cloudflare Tunnel** — same idea, if you prefer CF.
- Do NOT expose without `CHUMP_WEB_TOKEN` set — `check_auth` (:295) enforces it; the
  auth middleware (:339) covers all `/api/*` except the bypass list (:320).

Set a dedicated `CHUMP_VOICE_SESSION_ID=voice-jeff` so the voice conversation has its
own persistent thread, separate from your web/Discord sessions — Chump's
`web_sessions_db` keeps the context across calls.

---

## 4. What this does NOT build (and why)

| Draft tier | Why we skip it |
|---|---|
| LiveKit / WebRTC / Pipecat | Siri is the transport + wake word. WebRTC is for full-duplex phone-call latency; advisory chat is turn-based. Olive's `DESIGN-voice.md` §1.4 argues this and holds. |
| Moshi / PersonaPlex (speech-to-speech) | Only earns its cost if back-and-forth feels sluggish. For "what's blocking gap INFRA-2218?" a tool round + a spoken sentence is instant. Drop unless proven slow. |
| vLLM / separate reasoning tier | Chump's `provider_cascade` already serves models. Adding vLLM is extra surface. |
| Redis shared state | `web_sessions_db` persists per-session history. No externa state store needed. |
| Native iOS app + Porcupine + $99/yr | Siri gives you wake + STT for free. Don't ship a native app to replicate what Siri already does. |
| New RAG tier over the fleet | `almanac_search` IS the fleet RAG, already wired into Chump's tool inventory. The voice agent just asks it. |

---

## 5. Build path

**Phase 1 (weekend) — wire it, ship the chat**
1. Add `voice: Option<bool>` to `ChatRequest` + the `VOICE_ADDENDUM` const + the append
   in the prompt builder. (~20 LOC in `web_server.rs` + `system_prompt.rs`.)
2. Factor the "run one turn → emit events" body out of `handle_chat` into a helper.
3. Add `/api/voice/ask` route + `drain_agent_to_final_text` + terminal-phrase guard.
   Register the route in the axum router.
4. `tailscale funnel` on the box running Chump's web server; set `CHUMP_WEB_TOKEN` +
   `CHUMP_VOICE_SESSION_ID`.
5. Build the Siri Shortcut ("Ask Chump"). Test: *"Hey Siri, ask Chump what the almanac
   search tool does."* → spoken answer grounded in `almanac_search` results.

**Phase 2 (1 weekend) — fluidity + display**
- Optionally narrate tool calls during the wait: emit a "spoken" interim while tools
  run (a second SSE event the route forwards). For MVP the §1 rule "say what you found"
  makes waits feel instant because the first thing you hear is the answer.
- Point the iPad's browser (Chump PWA) at the same `CHUMP_VOICE_SESSION_ID` so the
  screen mirrors the tool calls + reasoning as they stream, while Siri speaks the
  headline. Pure display, no mic — the iPad's third life.

**Phase 3 (only if Phase 1 feels too robotic) — richer voice**
- Cloud TTS (cloning Olive's `/api/voice/speak` → OpenAI `tts-1`) instead of Siri's
  built-in voice. ~$0.002/reply. Only if Siri's voice grates.
- Deepgram Aura-2 (<90ms TTS) only if `tts-1` latency lags.

---

## 6. Honesty rail for code (the one thing to get right)

Olive's whole doctrine is "numbers never fall back" — every price a shopper hears came
from a tool. The code-advisor equivalent is **"repo/PR/gate facts never fall back"**:
every concrete claim a voice turn makes about ChumpOS (or any fleet repo) traces to an
`almanac_search` / `read_file` / `run_cli` result. The §1 addendum encodes this as a
system-prompt rule AND it's structally enforced the same way Olive's is — the agent
can only narrate what tools returned, and the screen (PWA) renders tool truth, not
prose. A voice that confidents a wrong PR status is the code equivalent of Olive
rounding the total quietly — the exact failure the rail exists to prevent.