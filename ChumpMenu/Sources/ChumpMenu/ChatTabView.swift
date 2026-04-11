// Native chat against local Chump web (`POST /api/chat`, SSE). No Discord required.
import AppKit
import SwiftUI

struct ChatBubble: Identifiable {
    let id: UUID
    let role: ChatRole
    let text: String
    /// Extracted `<thinking>` monologue from `turn_complete` (optional).
    var thinking: String?

    enum ChatRole {
        case user
        case assistant
        case system
    }

    init(role: ChatRole, text: String, thinking: String? = nil) {
        self.id = UUID()
        self.role = role
        self.text = text
        self.thinking = thinking
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

    /// Optional joined model reasoning from the last `turn_complete` event.
    static func thinkingMonologue(from events: [(String, [String: Any])]) -> String? {
        guard let tc = events.last(where: { $0.0 == "turn_complete" })?.1,
              let s = tc["thinking_monologue"] as? String else { return nil }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : s
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

// MARK: - Chat UI

private struct ChatHeroHeader: View {
    @Bindable var state: ChumpState

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Chat")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundStyle(.primary)
                Text("Same brain as the PWA — streaming `/api/chat`, tool approvals here.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 8) {
                Button {
                    state.openChumpPWA()
                } label: {
                    Label("Open in browser", systemImage: "safari")
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(!state.chumpWebRunning)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }
}

private struct ChatConnectionStrip: View {
    @Bindable var state: ChumpState

    var body: some View {
        let base = state.loadWebApiBaseURL()
        HStack(spacing: 10) {
            Circle()
                .fill(state.chumpWebRunning ? Color(nsColor: .systemGreen) : Color(nsColor: .systemOrange))
                .frame(width: 10, height: 10)
            Text(state.chumpWebRunning ? "Chump web ready" : "Start web from Status (or Get Chump online)")
                .font(.subheadline.weight(.medium))
            Spacer(minLength: 0)
            Text(base.replacingOccurrences(of: "http://", with: ""))
                .font(.caption.monospaced())
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor).opacity(0.85)))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
        )
        .padding(.horizontal, 20)
        .padding(.bottom, 8)
    }
}

private struct ChatMessageBlock: View {
    let bubble: ChatBubble
    private let bubbleMax: CGFloat = 560

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            if bubble.role == .user { Spacer(minLength: 56) }
            VStack(alignment: bubble.role == .user ? .trailing : .leading, spacing: 6) {
                HStack(spacing: 6) {
                    if bubble.role != .user {
                        Image(systemName: bubble.role == .system ? "exclamationmark.triangle.fill" : "brain.head.profile")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(bubble.role == .system ? Color.orange : Color.accentColor)
                    }
                    Text(senderLabel)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    if bubble.role == .user {
                        Image(systemName: "person.crop.circle.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.accentColor)
                    }
                }
                .frame(maxWidth: bubbleMax + 40, alignment: bubble.role == .user ? .trailing : .leading)

                if bubble.role == .assistant, let reasoning = bubble.thinking, !reasoning.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    DisclosureGroup("Model reasoning") {
                        ScrollView {
                            Text(reasoning)
                                .font(.system(size: 11, weight: .regular, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 200)
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: bubbleMax + 40, alignment: .leading)
                }

                Text(bubble.text)
                    .font(.system(size: 15, weight: .regular))
                    .lineSpacing(5)
                    .multilineTextAlignment(bubble.role == .user ? .trailing : .leading)
                    .textSelection(.enabled)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                    .frame(maxWidth: bubbleMax, alignment: bubble.role == .user ? .trailing : .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(bubbleFill)
                            .shadow(color: Color.black.opacity(bubble.role == .system ? 0 : 0.08), radius: 8, y: 3)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(bubbleStroke, lineWidth: 0.5)
                    )
            }
            if bubble.role != .user { Spacer(minLength: 56) }
        }
    }

    private var senderLabel: String {
        switch bubble.role {
        case .user: return "You"
        case .assistant: return "Chump"
        case .system: return "System"
        }
    }

    private var bubbleFill: Color {
        switch bubble.role {
        case .user:
            return Color.accentColor.opacity(0.22)
        case .system:
            return Color.orange.opacity(0.14)
        case .assistant:
            return Color(nsColor: .controlBackgroundColor)
        }
    }

    private var bubbleStroke: Color {
        switch bubble.role {
        case .user: return Color.accentColor.opacity(0.35)
        case .system: return Color.orange.opacity(0.4)
        case .assistant: return Color.primary.opacity(0.08)
        }
    }
}

private struct ChatEmptyState: View {
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "bubble.left.and.bubble.right.fill")
                .font(.system(size: 56))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
            VStack(spacing: 8) {
                Text("No messages yet")
                    .font(.title3.weight(.semibold))
                Text("Ask for a status check, a plan, or paste logs — replies stream in when Chump web is running.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
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
            ChatHeroHeader(state: state)
            ChatConnectionStrip(state: state)

            Divider()
                .padding(.horizontal, 8)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        if bubbles.isEmpty && !sending {
                            ChatEmptyState()
                        }
                        ForEach(bubbles) { b in
                            ChatMessageBlock(bubble: b)
                                .id(b.id)
                        }
                        if sending {
                            HStack(spacing: 12) {
                                ProgressView()
                                    .scaleEffect(1.1)
                                Text("Chump is replying…")
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(.secondary)
                                Spacer()
                            }
                            .padding(.horizontal, 24)
                            .padding(.vertical, 12)
                            .id("typing-indicator")
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 16)
                }
                .defaultScrollAnchor(.bottom)
                .onChange(of: bubbles.count) { _, _ in
                    scrollToBottom(proxy: proxy)
                }
                .onChange(of: sending) { _, isSending in
                    if isSending { scrollToBottom(proxy: proxy) }
                }
            }
            .frame(minHeight: 360)

            if let p = state.pendingToolApproval {
                toolApprovalCard(p)
            }

            composerSection
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            LinearGradient(
                colors: [
                    Color(nsColor: .windowBackgroundColor),
                    Color(nsColor: .windowBackgroundColor).opacity(0.92),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    private func scrollToBottom(proxy: ScrollViewProxy) {
        if sending {
            withAnimation(.easeOut(duration: 0.25)) {
                proxy.scrollTo("typing-indicator", anchor: .bottom)
            }
        } else if let last = bubbles.last?.id {
            withAnimation(.easeOut(duration: 0.25)) {
                proxy.scrollTo(last, anchor: .bottom)
            }
        }
    }

    @ViewBuilder
    private func toolApprovalCard(_ p: PendingToolApproval) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "hand.raised.fill")
                    .font(.title2)
                    .foregroundStyle(.orange)
                Text("Tool approval")
                    .font(.title3.weight(.bold))
            }
            Text(p.toolName)
                .font(.headline)
            Text("Risk: \(p.riskLevel)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if !p.reason.isEmpty {
                Text(p.reason)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(6)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 14) {
                Button("Deny") {
                    state.resolveToolApproval(allowed: false)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                Button("Allow once") {
                    state.resolveToolApproval(allowed: true)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.orange.opacity(0.12))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(Color.orange.opacity(0.35), lineWidth: 1)
                )
        )
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var composerSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()
            HStack(alignment: .bottom, spacing: 14) {
                TextField("Message Chump…", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.body)
                    .lineSpacing(4)
                    .padding(14)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color(nsColor: .textBackgroundColor))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
                    )
                    .lineLimit(5, reservesSpace: true)
                    .disabled(sending || !state.chumpWebRunning || state.pendingToolApproval != nil)
                VStack(spacing: 10) {
                    Button {
                        send()
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 36))
                            .symbolRenderingMode(.hierarchical)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(canSend ? Color.accentColor : Color.secondary)
                    .disabled(!canSend)
                    .keyboardShortcut(.return, modifiers: [.command])
                    .help("Send (⌘↩)")
                    Button("Clear") {
                        bubbles = []
                        sessionId = nil
                    }
                    .font(.subheadline.weight(.medium))
                    .disabled(sending || bubbles.isEmpty)
                    .buttonStyle(.borderless)
                }
            }
            HStack {
                Text("\(draft.count) characters")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Spacer()
                if state.chumpWebRunning {
                    Text("Return in field adds a line · ⌘↩ Send")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 4)
        }
        .padding(20)
        .background(.thickMaterial)
    }

    private var canSend: Bool {
        !sending
            && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && state.chumpWebRunning
            && state.pendingToolApproval == nil
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
                let thinking = ChumpSSEParser.thinkingMonologue(from: events)
                await MainActor.run {
                    if let newSid { sessionId = newSid }
                    bubbles.append(
                        ChatBubble(
                            role: .assistant,
                            text: reply.isEmpty
                                ? "(Empty reply — check CHUMP_WEB_TOKEN, tool approvals, or logs/chump-web.log.)"
                                : reply,
                            thinking: thinking
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
