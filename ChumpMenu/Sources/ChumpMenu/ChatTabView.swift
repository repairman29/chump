// Native chat against local Chump web (`POST /api/chat`, SSE). No Discord required.
import SwiftUI

struct ChatBubble: Identifiable {
    let id: UUID
    let role: ChatRole
    let text: String

    enum ChatRole {
        case user
        case assistant
        case system
    }

    init(role: ChatRole, text: String) {
        self.id = UUID()
        self.role = role
        self.text = text
    }
}

enum ChumpSSEParser {
    static func parseEvents(_ raw: String) -> [(String, [String: Any])] {
        let normalized = raw.replacingOccurrences(of: "\r\n", with: "\n")
        var out: [(String, [String: Any])] = []
        for block in normalized.components(separatedBy: "\n\n") {
            if block.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
            var eventName = "message"
            var dataLines: [String] = []
            for line in block.split(separator: "\n", omittingEmptySubsequences: false) {
                let s = String(line)
                if s.hasPrefix("event:") {
                    eventName = s.dropFirst(6).trimmingCharacters(in: .whitespaces)
                } else if s.hasPrefix("data:") {
                    dataLines.append(s.dropFirst(5).trimmingCharacters(in: .whitespaces))
                }
            }
            let dataStr = dataLines.joined(separator: "\n")
            guard let d = dataStr.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { continue }
            out.append((eventName, obj))
        }
        return out
    }

    static func sessionId(from events: [(String, [String: Any])]) -> String? {
        for (_, dict) in events {
            if let t = dict["type"] as? String, t == "web_session_ready",
               let sid = dict["session_id"] as? String, !sid.isEmpty {
                return sid
            }
        }
        return nil
    }

    /// Parse one SSE block (lines without trailing empty separator).
    static func parseSSEBlock(_ lines: [String]) -> (event: String, payload: [String: Any])? {
        var eventName = "message"
        var dataLines: [String] = []
        for line in lines {
            if line.hasPrefix("event:") {
                eventName = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("data:") {
                dataLines.append(String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces))
            }
        }
        let dataStr = dataLines.joined(separator: "\n")
        guard let d = dataStr.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
        return (eventName, obj)
    }

    static func assistantReply(from events: [(String, [String: Any])]) -> String {
        if let tc = events.last(where: { $0.0 == "turn_complete" })?.1,
           let full = tc["full_text"] as? String, !full.isEmpty {
            return full
        }
        var buf = ""
        for (ev, json) in events {
            if ev == "text_delta", let d = json["delta"] as? String {
                buf += d
            }
            if ev == "text_complete", let t = json["text"] as? String {
                buf = t
            }
        }
        if buf.isEmpty {
            for (ev, json) in events where ev == "turn_error" {
                if let err = json["error"] as? String { return "Error: \(err)" }
            }
        }
        return buf
    }
}

struct ChatTabView: View {
    @Bindable var state: ChumpState
    @State private var draft: String = ""
    @State private var bubbles: [ChatBubble] = []
    @State private var sending = false
    @State private var sessionId: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !state.chumpWebRunning {
                Text(
                    "Start Chump web from the Status tab (Start Chump or Get Chump online). This tab uses POST /api/chat on \(state.loadWebApiBaseURL()) — no Discord."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(bubbles) { b in
                            chatBubbleRow(b)
                                .id(b.id)
                        }
                    }
                    .padding(12)
                }
                .onChange(of: bubbles.count) { _, _ in
                    if let last = bubbles.last?.id {
                        withAnimation { proxy.scrollTo(last, anchor: .bottom) }
                    }
                }
            }
            if let p = state.pendingToolApproval {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Tool approval required")
                        .font(.headline)
                    Text(p.toolName)
                        .font(.subheadline.weight(.semibold))
                    Text("Risk: \(p.riskLevel)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if !p.reason.isEmpty {
                        Text(p.reason)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(4)
                    }
                    HStack(spacing: 12) {
                        Button("Deny") { state.resolveToolApproval(allowed: false) }
                        Button("Allow once") { state.resolveToolApproval(allowed: true) }
                            .keyboardShortcut(.defaultAction)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.12))
            }
            Divider()
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Message", text: $draft, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...6)
                    .disabled(sending || !state.chumpWebRunning || state.pendingToolApproval != nil)
                Button("Send") { send() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(sending || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !state.chumpWebRunning || state.pendingToolApproval != nil)
            }
            .padding(12)
        }
        .frame(minWidth: 320, minHeight: 280)
    }

    private func chatBubbleRow(_ b: ChatBubble) -> some View {
        HStack(alignment: .top) {
            if b.role == .user { Spacer(minLength: 48) }
            Text(b.text)
                .textSelection(.enabled)
                .font(.body)
                .padding(10)
                .background(
                    b.role == .user
                        ? Color.accentColor.opacity(0.18)
                        : (b.role == .system ? Color.orange.opacity(0.12) : Color(nsColor: .controlBackgroundColor))
                )
                .cornerRadius(10)
            if b.role != .user { Spacer(minLength: 48) }
        }
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !sending else { return }
        draft = ""
        bubbles.append(ChatBubble(role: .user, text: text))
        sending = true
        let sid = sessionId
        Task {
            do {
                let raw = try await state.fetchChatSSE(message: text, sessionId: sid)
                let events = ChumpSSEParser.parseEvents(raw)
                let newSid = ChumpSSEParser.sessionId(from: events)
                let reply = ChumpSSEParser.assistantReply(from: events)
                await MainActor.run {
                    if let newSid { sessionId = newSid }
                    bubbles.append(
                        ChatBubble(
                            role: .assistant,
                            text: reply.isEmpty
                                ? "(Empty reply — check CHUMP_WEB_TOKEN, tool approvals, or logs/chump-web.log.)"
                                : reply
                        )
                    )
                    sending = false
                    state.refresh()
                }
            } catch {
                await MainActor.run {
                    bubbles.append(ChatBubble(role: .system, text: error.localizedDescription))
                    sending = false
                }
            }
        }
    }
}
