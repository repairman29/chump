// Chump menu bar app: start/stop Chump and show status. macOS 14+.
import AppKit
import Foundation
import SwiftUI

private let defaultRepoPath = FileManager.default.homeDirectoryForCurrentUser.path + "/Projects/Maclawd/rust-agent"
private let ChumpRepoPathKey = "ChumpRepoPath"

@main
struct ChumpMenuApp: App {
    var body: some Scene {
        MenuBarExtra("Chump", systemImage: "brain.head.profile") {
            ChumpMenuContent()
        }
        .menuBarExtraStyle(.window)
    }
}

// MARK: - Tabs

enum ChumpMenuTab: String, CaseIterable {
    case status = "Status"
    case roles = "Roles"
}

// MARK: - Content view with sections, icons, status colors, refresh, toast

struct ChumpMenuContent: View {
    @State private var state = ChumpState()
    @State private var selectedTab: ChumpMenuTab = .status
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Picker("", selection: $selectedTab) {
                ForEach(ChumpMenuTab.allCases, id: \.self) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .accessibilityLabel("Status or Roles tab")

            if selectedTab == .roles {
                RolesTabView(state: state)
            } else {
            List {
                Section {
                    HStack(spacing: 8) {
                    Circle()
                        .fill(state.chumpRunning ? Color(nsColor: .systemGreen) : Color(nsColor: .secondaryLabelColor))
                        .frame(width: 8, height: 8)
                    Text(state.chumpRunning ? "Chump online" : "Chump offline")
                        .font(.headline)
                    Spacer(minLength: 0)
                }
                .animation(.easeInOut(duration: 0.2), value: state.chumpRunning)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(state.chumpRunning ? "Chump online" : "Chump offline")
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                if let tier = state.autonomyTier, tier >= 0 {
                    Text("Autonomy: Tier \(tier)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                }
                if let activity = state.lastActivitySummary {
                    Text(activity)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 12)
                }
                if let busy = state.busyMessage {
                    HStack(spacing: 6) {
                        ProgressView()
                            .scaleEffect(0.85)
                        Text(busy)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 12)
                }
                Button { state.getChumpOnline() } label: {
                    Label("Get Chump online", systemImage: "play.circle.fill")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .tint(Color(nsColor: .systemGreen))
                .disabled(state.busyMessage != nil)
                .opacity(state.busyMessage != nil ? 0.6 : 1)
                .accessibilityHint("Brings Chump and required servers online")
                Button { state.sendTestMessage() } label: {
                    Label("Send test message", systemImage: "paperplane")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .disabled(state.busyMessage != nil)
                .opacity(state.busyMessage != nil ? 0.6 : 1)
                Button { state.refresh() } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                } header: {
                    Text("Status")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                }

                Section {
                    ollamaRow(status: state.ollamaStatus, start: { state.startOllama() }, stop: { state.stopOllama() }, disabled: state.busyMessage != nil)
                    portRow(port: 8000, status: state.port8000Status, modelLabel: state.model8000Label, start: { state.startVLLM() }, stop: { state.stopVLLM8000() }, disabled: state.busyMessage != nil)
                    portRow(port: 8001, status: state.port8001Status, modelLabel: nil, start: { state.startVLLM8001() }, stop: { state.stopVLLM8001() }, disabled: state.busyMessage != nil)
                } header: {
                    Text("Local inference")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                }

                Section {
                    embedRow(status: state.embedServerStatus, start: { state.startEmbedServer() }, stop: { state.stopEmbedServer() }, disabled: state.busyMessage != nil)
                } header: {
                    Text("Embed")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                }

                Section {
                    if state.chumpRunning {
                    Button { state.stopChump() } label: {
                        Label("Stop Chump", systemImage: "stop.circle")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .tint(Color(nsColor: .systemRed))
                    .disabled(state.busyMessage != nil)
                    .opacity(state.busyMessage != nil ? 0.6 : 1)
                    .accessibilityHint("Stops the Chump agent")
                } else {
                    Button { state.startChump() } label: {
                        Label("Start Chump", systemImage: "play.circle")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .tint(Color(nsColor: .systemGreen))
                    .disabled(state.busyMessage != nil)
                    .opacity(state.busyMessage != nil ? 0.6 : 1)
                    .accessibilityHint("Starts the Chump agent")
                }
                if state.heartbeatRunning {
                    Button { state.stopHeartbeat() } label: {
                        Label("Stop heartbeat", systemImage: "waveform.path.ecg")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .disabled(state.busyMessage != nil)
                    .opacity(state.busyMessage != nil ? 0.6 : 1)
                } else {
                    Button { state.startHeartbeat(quick: false) } label: {
                        Label("Start heartbeat (8h)", systemImage: "waveform.path.ecg")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .disabled(state.busyMessage != nil)
                    .opacity(state.busyMessage != nil ? 0.6 : 1)
                    Button { state.startHeartbeat(quick: true) } label: {
                        Label("Start heartbeat (quick 2m)", systemImage: "waveform.path")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .disabled(state.busyMessage != nil)
                    .opacity(state.busyMessage != nil ? 0.6 : 1)
                }
                Divider()
                if state.selfImproveRunning {
                    Button { state.stopSelfImprove() } label: {
                        Label("Stop self-improve", systemImage: "hammer.circle")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .disabled(state.busyMessage != nil)
                    .opacity(state.busyMessage != nil ? 0.6 : 1)
                } else {
                    Button { state.startSelfImprove(quick: false) } label: {
                        Label("Start self-improve (8h)", systemImage: "hammer.circle")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .disabled(state.busyMessage != nil)
                    .opacity(state.busyMessage != nil ? 0.6 : 1)
                    Button { state.startSelfImprove(quick: true) } label: {
                        Label("Self-improve (quick 2m)", systemImage: "hammer")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .disabled(state.busyMessage != nil)
                    .opacity(state.busyMessage != nil ? 0.6 : 1)
                    Button { state.startSelfImprove(quick: false, dryRun: true) } label: {
                        Label("Self-improve (8h, dry run)", systemImage: "hammer.circle.fill")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .disabled(state.busyMessage != nil)
                    .opacity(state.busyMessage != nil ? 0.6 : 1)
                }
                } header: {
                    Text("Chump & heartbeat")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                }

                Section {
                    Button { state.chooseRepoPath() } label: {
                        Label("Set rust-agent path…", systemImage: "folder")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    Button { state.runAutonomyTests() } label: {
                        Label("Run autonomy tests", systemImage: "checkmark.seal")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .disabled(state.busyMessage != nil)
                    .opacity(state.busyMessage != nil ? 0.6 : 1)
                    Button { state.openLogs() } label: {
                        Label("Open logs", systemImage: "doc.text")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    Button { state.openVLLMLog() } label: {
                        Label("Open vLLM log (8000)", systemImage: "doc.text")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    Button { state.openVLLM8001Log() } label: {
                        Label("Open vLLM log (8001)", systemImage: "doc.text")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    Button { state.openEmbedLog() } label: {
                        Label("Open embed log", systemImage: "doc.text")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    Button { state.openHeartbeatLog() } label: {
                        Label("Open heartbeat log", systemImage: "doc.text")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    Button { state.openSelfImproveLog() } label: {
                        Label("Open self-improve log", systemImage: "doc.text")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                } header: {
                    Text("Logs & config")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                }

                Section {
                    Button { NSApplication.shared.terminate(nil) } label: {
                        Text("Quit Chump Menu")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut("q", modifiers: .command)
                }
            }
            .listStyle(.sidebar)
            }

            if let msg = state.lastSuccessMessage {
                Text(msg)
                    .font(.caption2)
                    .foregroundStyle(Color(nsColor: .systemGreen))
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 6).fill(.regularMaterial))
            }
            if let msg = state.lastErrorMessage {
                Text(msg)
                    .font(.caption2)
                    .foregroundStyle(Color(nsColor: .systemRed))
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 6).fill(.regularMaterial))
            }

            Divider()
        }
        .padding(.vertical, 8)
        .frame(minWidth: 300)
        .onAppear { state.refresh() }
        .onReceive(Timer.publish(every: 10, on: .main, in: .common).autoconnect()) { _ in state.refresh() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Chump menu")
        .accessibilityHint("Start and stop Chump and model servers")
    }
}

// MARK: - Roles tab (Farmer Brown, Heartbeat Shepherd, Memory Keeper, Sentinel, Oven Tender)

struct RoleRow: Identifiable {
    let id: String
    let name: String
    let subtitle: String
    let scriptName: String
    let logName: String
}

private let roleRows: [RoleRow] = [
    RoleRow(id: "farmer-brown", name: "Farmer Brown", subtitle: "Diagnose and repair stack; keep Chump online", scriptName: "farmer-brown.sh", logName: "farmer-brown.log"),
    RoleRow(id: "heartbeat-shepherd", name: "Heartbeat Shepherd", subtitle: "Ensure heartbeat ran and succeeded; optional retry", scriptName: "heartbeat-shepherd.sh", logName: "heartbeat-shepherd.log"),
    RoleRow(id: "memory-keeper", name: "Memory Keeper", subtitle: "Check memory DB and embed; herd health", scriptName: "memory-keeper.sh", logName: "memory-keeper.log"),
    RoleRow(id: "sentinel", name: "Sentinel", subtitle: "Alert when stack or heartbeat keeps failing", scriptName: "sentinel.sh", logName: "sentinel.log"),
    RoleRow(id: "oven-tender", name: "Oven Tender", subtitle: "Pre-warm model so Chump is ready on schedule", scriptName: "oven-tender.sh", logName: "oven-tender.log"),
]

struct RolesTabView: View {
    @Bindable var state: ChumpState
    var body: some View {
        List {
            Section {
                ForEach(roleRows) { role in
                    HStack(alignment: .top, spacing: 8) {
                        Circle()
                            .fill(state.roleRunning(script: role.scriptName) ? Color(nsColor: .systemGreen) : Color(nsColor: .secondaryLabelColor).opacity(0.8))
                            .frame(width: 8, height: 8)
                            .padding(.top, 5)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(role.name)
                                .font(.subheadline.weight(.medium))
                            Text(role.subtitle)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                            HStack(spacing: 8) {
                                Button("Run once") {
                                    state.runRole(script: role.scriptName)
                                }
                                .buttonStyle(.borderless)
                                .disabled(state.busyMessage != nil)
                                Button("Open log") {
                                    state.openRoleLog(logName: role.logName)
                                }
                                .buttonStyle(.borderless)
                            }
                            .padding(.top, 4)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 6)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(role.name): \(role.subtitle)")
                }
            } header: {
                Text("Roles")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
            }
        }
        .listStyle(.sidebar)
        .onAppear { state.refresh() }
    }
}

private func ollamaRow(status: String?, start: @escaping () -> Void, stop: @escaping () -> Void, disabled: Bool = false) -> some View {
    let warm = status == "200"
    return HStack(spacing: 6) {
        Circle()
            .fill(warm ? Color(nsColor: .systemGreen) : Color(nsColor: .secondaryLabelColor))
            .frame(width: 8, height: 8)
        Text("11434 (Ollama)")
            .font(.system(.body, design: .monospaced))
        Spacer(minLength: 4)
        if warm {
            Text("warm")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        if warm {
            Button("Stop", action: stop)
                .buttonStyle(.borderless)
                .disabled(disabled)
                .accessibilityHint("Stops Ollama on port 11434")
        } else {
            Button("Start", action: start)
                .buttonStyle(.borderless)
                .disabled(disabled)
                .accessibilityHint("Starts Ollama (ollama serve). Pull model: ollama pull qwen2.5:14b")
        }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 4)
}

private func portRow(port: Int, status: String?, modelLabel: String?, start: @escaping () -> Void, stop: @escaping () -> Void, disabled: Bool = false) -> some View {
    let warm = status == "200"
    return HStack(spacing: 6) {
        Image(systemName: "server.rack")
            .font(.caption)
            .foregroundStyle(.secondary)
        Circle()
            .fill(warm ? Color(nsColor: .systemGreen) : Color(nsColor: .secondaryLabelColor).opacity(0.8))
            .frame(width: 6, height: 6)
            .accessibilityLabel(warm ? "Port \(port) warm" : "Port \(port) cold")
        Text(port == 8000 && modelLabel != nil ? "8000 (\(modelLabel!))" : "\(port)")
            .font(.caption)
            .foregroundStyle(.secondary)
        if warm {
            Button("Stop", action: stop)
                .buttonStyle(.plain)
                .disabled(disabled)
                .opacity(disabled ? 0.6 : 1)
                .accessibilityHint("Stops the model server on port \(port)")
        } else {
            Button("Start", action: start)
                .buttonStyle(.plain)
                .disabled(disabled)
                .opacity(disabled ? 0.6 : 1)
                .accessibilityHint("Starts the model server on port \(port)")
        }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 6)
}

private func embedRow(status: String?, start: @escaping () -> Void, stop: @escaping () -> Void, disabled: Bool = false) -> some View {
    let warm = status == "200"
    return HStack(spacing: 6) {
        Image(systemName: "waveform")
            .font(.caption)
            .foregroundStyle(.secondary)
        Circle()
            .fill(warm ? Color(nsColor: .systemGreen) : Color(nsColor: .secondaryLabelColor).opacity(0.8))
            .frame(width: 6, height: 6)
            .accessibilityLabel(warm ? "Port 18765 warm" : "Port 18765 cold")
        Text("18765")
            .font(.caption)
            .foregroundStyle(.secondary)
        if warm {
            Button("Stop embed", action: stop)
                .buttonStyle(.plain)
                .disabled(disabled)
                .opacity(disabled ? 0.6 : 1)
                .accessibilityHint("Stops the embed server on port 18765")
        } else {
            Button("Start embed", action: start)
                .buttonStyle(.plain)
                .disabled(disabled)
                .opacity(disabled ? 0.6 : 1)
                .accessibilityHint("Starts the embed server on port 18765")
        }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 6)
}

// MARK: - State (Observation)

@Observable
final class ChumpState {
    var chumpRunning = false
    var ollamaStatus: String? = nil
    var port8000Status: String? = nil
    var port8001Status: String? = nil
    var embedServerStatus: String? = nil
    var heartbeatRunning = false
    var selfImproveRunning = false
    var autonomyTier: Int? = nil
    var model8000Label: String? = nil
    var lastErrorMessage: String? = nil
    var lastSuccessMessage: String? = nil
    /// Shown while a long-running action is in progress; buttons should be disabled.
    var busyMessage: String? = nil
    /// e.g. "Heartbeat 5m ago" or "Discord active 1m ago" for at-a-glance liveness.
    var lastActivitySummary: String? = nil

    var repoPath: String {
        get {
            UserDefaults.standard.string(forKey: ChumpRepoPathKey) ?? defaultRepoPath
        }
        set {
            UserDefaults.standard.set(newValue, forKey: ChumpRepoPathKey)
        }
    }

    func refresh() {
        chumpRunning = isChumpProcessRunning()
        ollamaStatus = checkOllama()
        port8000Status = checkPort(8000)
        port8001Status = checkPort(8001)
        embedServerStatus = checkEmbedServer()
        heartbeatRunning = isHeartbeatRunning()
        selfImproveRunning = isSelfImproveRunning()
        autonomyTier = loadAutonomyTier()
        if port8000Status == "200" {
            model8000Label = fetchModel8000Label()
        } else {
            model8000Label = nil
        }
        lastActivitySummary = computeLastActivitySummary()
    }

    func roleRunning(script scriptName: String) -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        task.arguments = ["-f", scriptName]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            task.waitUntilExit()
            return task.terminationStatus == 0
        } catch { return false }
    }

    func runRole(script scriptName: String) {
        let scriptPath = "\(repoPath)/scripts/\(scriptName)"
        guard FileManager.default.fileExists(atPath: scriptPath) else {
            showToast("Not found: scripts/\(scriptName)")
            return
        }
        guard busyMessage == nil else { return }
        busyMessage = "Running \(scriptName)..."
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/bin/bash")
            task.arguments = ["-lc", "cd '\(self.repoPath)' && source .env 2>/dev/null; ./scripts/\(scriptName)"]
            task.currentDirectoryURL = URL(fileURLWithPath: self.repoPath)
            let pipe = Pipe()
            task.standardOutput = pipe
            task.standardError = pipe
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = (env["PATH"] ?? "") + ":/opt/homebrew/bin:\(NSHomeDirectory())/.local/bin:\(NSHomeDirectory())/.cargo/bin"
            env["CHUMP_HOME"] = self.repoPath
            task.environment = env
            do {
                try task.run()
                task.waitUntilExit()
                DispatchQueue.main.async {
                    self.busyMessage = nil
                    self.refresh()
                    self.showSuccess("\(scriptName) finished (exit \(task.terminationStatus))")
                }
            } catch {
                DispatchQueue.main.async {
                    self.busyMessage = nil
                    self.showToast("Failed: \(error.localizedDescription)")
                }
            }
        }
    }

    func openRoleLog(logName: String) {
        let logPath = "\(repoPath)/logs/\(logName)"
        if !FileManager.default.fileExists(atPath: logPath) {
            showToast("Log not found. Run the role once to create \(logName).")
            return
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: logPath))
    }

    private func computeLastActivitySummary() -> String? {
        let now = Date()
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        var best: (date: Date, label: String)?
        let heartbeatLog = "\(repoPath)/logs/heartbeat-learn.log"
        let discordLog = "\(repoPath)/logs/discord.log"
        if let att = try? FileManager.default.attributesOfItem(atPath: heartbeatLog),
           let mtime = att[.modificationDate] as? Date {
            let age = now.timeIntervalSince(mtime)
            if age < 86400 { // last 24h
                best = (mtime, "Heartbeat \(formatter.localizedString(for: mtime, relativeTo: now))")
            }
        }
        if let att = try? FileManager.default.attributesOfItem(atPath: discordLog),
           let mtime = att[.modificationDate] as? Date {
            let age = now.timeIntervalSince(mtime)
            if age < 3600, best == nil || mtime > best!.date {
                best = (mtime, "Discord \(formatter.localizedString(for: mtime, relativeTo: now))")
            }
        }
        let selfImproveLog = "\(repoPath)/logs/heartbeat-self-improve.log"
        if let att = try? FileManager.default.attributesOfItem(atPath: selfImproveLog),
           let mtime = att[.modificationDate] as? Date,
           now.timeIntervalSince(mtime) < 86400 {
            let label = "Self-improve \(formatter.localizedString(for: mtime, relativeTo: now))"
            if best == nil || mtime > best!.date { best = (mtime, label) }
        }
        return best?.label
    }

    private func loadAutonomyTier() -> Int? {
        let path = "\(repoPath)/logs/autonomy-tier.env"
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let text = String(data: data, encoding: .utf8) else { return nil }
        let line = text.split(separator: "\n").first { $0.hasPrefix("CHUMP_AUTONOMY_TIER=") }
        guard let line = line else { return nil }
        let value = line.dropFirst("CHUMP_AUTONOMY_TIER=".count).trimmingCharacters(in: .whitespaces)
        return Int(value)
    }

    private func fetchModel8000Label() -> String? {
        guard let url = URL(string: "http://127.0.0.1:8000/v1/models") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 2
        var out: String?
        let sem = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { data, _, _ in
            defer { sem.signal() }
            guard let data = data,
                  let raw = try? JSONSerialization.jsonObject(with: data),
                  let json = raw as? [String: Any],
                  let list = json["data"] as? [[String: Any]],
                  let first = list.first,
                  let id = first["id"] as? String else { return }
            if id.contains("7B") || id.contains("7b") { out = "7B" }
            else if id.contains("30B") || id.contains("30b") { out = "30B" }
            else { out = String(id.prefix(12)) }
        }.resume()
        _ = sem.wait(timeout: .now() + 2)
        return out
    }

    /// One-click: ensure Ollama is up (default local inference), then start Chump. No Python.
    func getChumpOnline() {
        guard busyMessage == nil else { return }
        let chumpScript = "\(repoPath)/run-discord.sh"
        guard FileManager.default.fileExists(atPath: chumpScript) else {
            showToast("Not found: run-discord.sh. Use Set rust-agent path…")
            return
        }
        busyMessage = "Checking…"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let needOllama = self.checkOllama() != "200"
            if needOllama {
                DispatchQueue.main.async { self.busyMessage = "Starting Ollama…" }
                self.startOllamaBlocking()
                for _ in 0..<15 {
                    Thread.sleep(forTimeInterval: 2)
                    if self.checkOllama() == "200" { break }
                }
            }
            DispatchQueue.main.async { self.refresh() }
            if self.checkOllama() != "200" {
                DispatchQueue.main.async {
                    self.busyMessage = nil
                    self.showToast("Ollama did not become ready. Run: ollama serve && ollama pull qwen2.5:14b")
                }
                return
            }
            if !self.isChumpProcessRunning() {
                DispatchQueue.main.async { self.busyMessage = "Starting Chump…" }
                self.startChump()
                Thread.sleep(forTimeInterval: 2)
                for _ in 0..<10 {
                    Thread.sleep(forTimeInterval: 1)
                    if self.isChumpProcessRunning() { break }
                }
            }
            DispatchQueue.main.async {
                self.refresh()
                self.busyMessage = nil
                if self.chumpRunning {
                    self.showSuccess("Chump is online (Ollama)")
                } else {
                    self.showToast("Chump may still be starting. Check logs/discord.log")
                }
            }
        }
    }

    private func startOllamaBlocking() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/bash")
        task.arguments = ["-lc", "nohup ollama serve >> /tmp/chump-ollama.log 2>&1 &"]
        task.standardInput = FileHandle.nullDevice
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = (env["PATH"] ?? "") + ":/opt/homebrew/bin:/usr/local/bin"
        task.environment = env
        try? task.run()
        task.waitUntilExit()
    }

    /// Run a quick Chump query and show result in toast. Uses Ollama (default).
    func sendTestMessage() {
        guard busyMessage == nil else { return }
        guard checkOllama() == "200" else {
            showToast("Ollama is not ready. Start Ollama first (or run: ollama pull qwen2.5:14b).")
            return
        }
        let binary = "\(repoPath)/target/release/rust-agent"
        let fallback = "\(repoPath)/target/debug/rust-agent"
        let exe = FileManager.default.fileExists(atPath: binary) ? binary : (FileManager.default.fileExists(atPath: fallback) ? fallback : nil)
        guard let exe else {
            showToast("rust-agent binary not found. Run: cargo build --release")
            return
        }
        busyMessage = "Sending test…"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let task = Process()
            task.executableURL = URL(fileURLWithPath: exe)
            task.arguments = ["--chump", "Reply with exactly: OK"]
            task.currentDirectoryURL = URL(fileURLWithPath: self.repoPath)
            let pipe = Pipe()
            task.standardOutput = pipe
            task.standardError = pipe
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = (env["PATH"] ?? "") + ":/opt/homebrew/bin:\(NSHomeDirectory())/.cargo/bin:\(NSHomeDirectory())/.local/bin"
            env["OPENAI_API_BASE"] = "http://localhost:11434/v1"
            env["OPENAI_API_KEY"] = "ollama"
            env["OPENAI_MODEL"] = "qwen2.5:14b"
            task.environment = env
            do {
                try task.run()
                task.waitUntilExit()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: data, encoding: .utf8) ?? ""
                let ok = task.terminationStatus == 0 && (output.contains("OK") || output.contains("ok"))
                DispatchQueue.main.async {
                    self.busyMessage = nil
                    self.refresh()
                    if ok {
                        self.showSuccess("Chump replied OK")
                    } else {
                        self.showToast("Test failed (exit \(task.terminationStatus)). Check model and logs.")
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    self.busyMessage = nil
                    self.showToast("Test failed: \(error.localizedDescription)")
                }
            }
        }
    }

    func chooseRepoPath() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: repoPath)
        panel.message = "Select the rust-agent directory (contains run-discord.sh)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        repoPath = url.path
        showToast("Path set to \(url.lastPathComponent)")
        refresh()
    }

    func runAutonomyTests() {
        guard busyMessage == nil else { return }
        let script = "\(repoPath)/scripts/run-autonomy-tests.sh"
        guard FileManager.default.fileExists(atPath: script) else {
            showToast("Not found: run-autonomy-tests.sh")
            return
        }
        busyMessage = "Running autonomy tests…"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/bin/bash")
            task.arguments = ["-lc", "cd '\(self.repoPath)' && ./scripts/run-autonomy-tests.sh 2>&1 | tee logs/autonomy-run.log"]
            task.standardInput = FileHandle.nullDevice
            let pipe = Pipe()
            task.standardOutput = pipe
            task.standardError = pipe
            task.currentDirectoryURL = URL(fileURLWithPath: self.repoPath)
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = (env["PATH"] ?? "") + ":/opt/homebrew/bin:\(NSHomeDirectory())/.local/bin:\(NSHomeDirectory())/.cargo/bin"
            task.environment = env
            do {
                try task.run()
                task.waitUntilExit()
                let status = task.terminationStatus
                let logURL = URL(fileURLWithPath: "\(self.repoPath)/logs/autonomy-run.log")
                DispatchQueue.main.async {
                    self.busyMessage = nil
                    self.refresh()
                    if status == 0 {
                        self.showSuccess("Autonomy tests passed")
                    } else {
                        self.lastErrorMessage = "Tests exited \(status). Check logs/autonomy-run.log"
                        self.clearLastErrorAfterDelay()
                    }
                    if FileManager.default.fileExists(atPath: logURL.path) {
                        NSWorkspace.shared.open(logURL)
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    self.busyMessage = nil
                    self.showToast("Failed: \(error.localizedDescription)")
                }
            }
        }
    }

    private func showToast(_ message: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.lastErrorMessage = message
            self.lastSuccessMessage = nil
            self.clearLastErrorAfterDelay()
        }
    }

    private func showSuccess(_ message: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.lastSuccessMessage = message
            self.lastErrorMessage = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak s = self] in
                s?.lastSuccessMessage = nil
            }
        }
    }

    private func clearLastErrorAfterDelay() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            self?.lastErrorMessage = nil
        }
    }

    private func isChumpProcessRunning() -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        task.arguments = ["-f", "rust-agent.*--discord"]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            task.waitUntilExit()
            return task.terminationStatus == 0
        } catch { return false }
    }

    private func isHeartbeatRunning() -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        task.arguments = ["-f", "heartbeat-learn"]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            task.waitUntilExit()
            return task.terminationStatus == 0
        } catch { return false }
    }

    private func isSelfImproveRunning() -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        task.arguments = ["-f", "heartbeat-self-improve"]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            task.waitUntilExit()
            return task.terminationStatus == 0
        } catch { return false }
    }

    private func checkOllama() -> String {
        guard let url = URL(string: "http://127.0.0.1:11434/api/tags") else { return "—" }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 2
        var out: String?
        let sem = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { _, response, _ in
            if let r = response as? HTTPURLResponse { out = "\(r.statusCode)" }
            else { out = "unreachable" }
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + 3)
        return out ?? "—"
    }

    private func checkPort(_ port: Int) -> String {
        guard let url = URL(string: "http://127.0.0.1:\(port)/v1/models") else { return "—" }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 2
        var out: String?
        let sem = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { _, response, _ in
            if let r = response as? HTTPURLResponse { out = "\(r.statusCode)" }
            else { out = "unreachable" }
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + 3)
        return out ?? "—"
    }

    private func checkEmbedServer() -> String {
        guard let url = URL(string: "http://127.0.0.1:18765/health") else { return "—" }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 2
        var out: String?
        let sem = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { _, response, _ in
            if let r = response as? HTTPURLResponse { out = "\(r.statusCode)" }
            else { out = "unreachable" }
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + 3)
        return out ?? "—"
    }
    
    func startChump() {
        let script = "\(repoPath)/run-discord.sh"
        guard FileManager.default.fileExists(atPath: script) else {
            showToast("Not found: \(script). Use Set rust-agent path…")
            return
        }
        let logPath = "\(repoPath)/logs/discord.log"
        let cmd = "cd '\(repoPath)' && nohup ./run-discord.sh >> '\(logPath)' 2>&1 &"
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/bash")
        task.arguments = ["-lc", cmd]
        task.standardInput = FileHandle.nullDevice
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        task.currentDirectoryURL = URL(fileURLWithPath: repoPath)
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = (env["PATH"] ?? "") + ":/opt/homebrew/bin:\(NSHomeDirectory())/.cargo/bin:\(NSHomeDirectory())/.local/bin"
        task.environment = env
        do {
            try task.run()
            task.waitUntilExit()
            showToast("Chump starting in background. Log: \(logPath)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.refresh() }
        } catch {
            showToast("Failed to start: \(error.localizedDescription)")
        }
    }
    
    func stopChump() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        task.arguments = ["-f", "rust-agent.*--discord"]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        try? task.run()
        task.waitUntilExit()
        refresh()
    }

    func startHeartbeat(quick: Bool) {
        let script = "\(repoPath)/scripts/heartbeat-learn.sh"
        guard FileManager.default.fileExists(atPath: script) else {
            showToast("Not found: \(script). Use Set rust-agent path…")
            return
        }
        let envExport = FileManager.default.fileExists(atPath: "\(repoPath)/.env")
            ? "source .env 2>/dev/null; " : ""
        let quickEnv = quick ? "HEARTBEAT_QUICK_TEST=1 " : ""
        let cmd = "cd '\(repoPath)' && \(envExport)\(quickEnv)nohup bash scripts/heartbeat-learn.sh >> logs/heartbeat-learn.log 2>&1 &"
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/bash")
        task.arguments = ["-lc", cmd]
        task.standardInput = FileHandle.nullDevice
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        task.currentDirectoryURL = URL(fileURLWithPath: repoPath)
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = (env["PATH"] ?? "") + ":/opt/homebrew/bin:\(NSHomeDirectory())/.cargo/bin:\(NSHomeDirectory())/.local/bin"
        task.environment = env
        do {
            try task.run()
            task.waitUntilExit()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.refresh() }
            if quick {
                showToast("Heartbeat (quick 2m) started. Log: logs/heartbeat-learn.log")
            } else {
                runAlert("Heartbeat started (8h). Log: \(repoPath)/logs/heartbeat-learn.log. Ensure model on 8000 and TAVILY_API_KEY in .env.")
            }
        } catch {
            showToast("Failed to start heartbeat: \(error.localizedDescription)")
        }
    }

    func stopHeartbeat() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        task.arguments = ["-f", "heartbeat-learn"]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        try? task.run()
        task.waitUntilExit()
        heartbeatRunning = false
        refresh()
    }

    func startSelfImprove(quick: Bool, dryRun: Bool = false) {
        let script = "\(repoPath)/scripts/heartbeat-self-improve.sh"
        guard FileManager.default.fileExists(atPath: script) else {
            showToast("Not found: \(script). Copy heartbeat-self-improve.sh to scripts/")
            return
        }
        let envExport = FileManager.default.fileExists(atPath: "\(repoPath)/.env")
            ? "source .env 2>/dev/null; " : ""
        let quickEnv = quick ? "HEARTBEAT_QUICK_TEST=1 " : ""
        let dryEnv = dryRun ? "HEARTBEAT_DRY_RUN=1 " : ""
        let cmd = "cd '\(repoPath)' && \(envExport)\(quickEnv)\(dryEnv)nohup bash scripts/heartbeat-self-improve.sh >> logs/heartbeat-self-improve.log 2>&1 &"
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/bash")
        task.arguments = ["-lc", cmd]
        task.standardInput = FileHandle.nullDevice
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        task.currentDirectoryURL = URL(fileURLWithPath: repoPath)
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = (env["PATH"] ?? "") + ":/opt/homebrew/bin:\(NSHomeDirectory())/.cargo/bin:\(NSHomeDirectory())/.local/bin"
        task.environment = env
        do {
            try task.run()
            task.waitUntilExit()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.refresh() }
            if quick {
                showToast("Self-improve (quick 2m) started. Log: logs/heartbeat-self-improve.log")
            } else {
                let dryNote = dryRun ? " [DRY RUN — no push/PR]" : ""
                runAlert("Self-improve started (8h).\(dryNote) Log: \(repoPath)/logs/heartbeat-self-improve.log. Ensure model on 8000 and CHUMP_REPO set.")
            }
        } catch {
            showToast("Failed to start self-improve: \(error.localizedDescription)")
        }
    }

    func stopSelfImprove() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        task.arguments = ["-f", "heartbeat-self-improve"]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        try? task.run()
        task.waitUntilExit()
        selfImproveRunning = false
        refresh()
    }

    func startVLLM() {
        let script = "\(repoPath)/serve-vllm-mlx.sh"
        guard FileManager.default.fileExists(atPath: script) else {
            runAlert("Not found: \(script). Set ChumpRepoPath or run from rust-agent.")
            return
        }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/bash")
        task.arguments = ["-lc", "cd '\(repoPath)' && nohup ./serve-vllm-mlx.sh >> /tmp/chump-vllm.log 2>&1 &"]
        task.standardInput = FileHandle.nullDevice
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        task.currentDirectoryURL = URL(fileURLWithPath: repoPath)
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = (env["PATH"] ?? "") + ":/opt/homebrew/bin:\(NSHomeDirectory())/.local/bin:\(NSHomeDirectory())/Library/pnpm"
        env["VLLM_WORKER_MULTIPROC_METHOD"] = "spawn"
        task.environment = env
        do {
            try task.run()
            task.waitUntilExit()
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.refresh() }
            runAlert("vLLM-MLX is starting on 8000. First run may download the model. Log: /tmp/chump-vllm.log")
        } catch {
            runAlert("Failed to start vLLM-MLX: \(error.localizedDescription)")
        }
    }

    func startVLLM8001() {
        let script = "\(repoPath)/scripts/serve-vllm-mlx-8001.sh"
        guard FileManager.default.fileExists(atPath: script) else {
            runAlert("Not found: \(script). Set ChumpRepoPath or run from rust-agent.")
            return
        }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/bash")
        task.arguments = ["-lc", "cd '\(repoPath)' && nohup ./scripts/serve-vllm-mlx-8001.sh >> /tmp/chump-vllm-8001.log 2>&1 &"]
        task.standardInput = FileHandle.nullDevice
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        task.currentDirectoryURL = URL(fileURLWithPath: repoPath)
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = (env["PATH"] ?? "") + ":/opt/homebrew/bin:\(NSHomeDirectory())/.local/bin:\(NSHomeDirectory())/Library/pnpm"
        env["VLLM_WORKER_MULTIPROC_METHOD"] = "spawn"
        task.environment = env
        do {
            try task.run()
            task.waitUntilExit()
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.refresh() }
            runAlert("vLLM-MLX is starting on 8001. Log: /tmp/chump-vllm-8001.log")
        } catch {
            runAlert("Failed to start vLLM-MLX (8001): \(error.localizedDescription)")
        }
    }

    func stopVLLM8000() {
        killProcessOnPort(8000)
        port8000Status = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.refresh() }
    }

    func stopVLLM8001() {
        killProcessOnPort(8001)
        port8001Status = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.refresh() }
    }

    func startOllama() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/bash")
        task.arguments = ["-lc", "nohup ollama serve >> /tmp/chump-ollama.log 2>&1 &"]
        task.standardInput = FileHandle.nullDevice
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = (env["PATH"] ?? "") + ":/opt/homebrew/bin:/usr/local/bin"
        task.environment = env
        try? task.run()
        task.waitUntilExit()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.refresh() }
    }

    func stopOllama() {
        killProcessOnPort(11434)
        ollamaStatus = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.refresh() }
    }

    private func killProcessOnPort(_ port: Int) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/lsof")
        task.arguments = ["-ti", ":\(port)"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            task.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let pids = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !pids.isEmpty {
                for pid in pids.split(separator: "\n") {
                    kill(pid: String(pid))
                }
            }
        } catch {}
    }

    private func kill(pid: String) {
        guard let pidNum = Int32(pid.trimmingCharacters(in: .whitespaces)) else { return }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/kill")
        task.arguments = ["-9", String(pidNum)]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        try? task.run()
        task.waitUntilExit()
    }

    func startEmbedServer() {
        let script = "\(repoPath)/scripts/start-embed-server.sh"
        guard FileManager.default.fileExists(atPath: script) else {
            runAlert("Not found: \(script). Set ChumpRepoPath or run from rust-agent.")
            return
        }
        // Ensure Python is on PATH when launched from menu (Finder gives minimal env)
        let pathForEmbed = "/usr/bin:/bin:/opt/homebrew/bin:\(NSHomeDirectory())/.local/bin:\(NSHomeDirectory())/Library/pnpm:\(ProcessInfo.processInfo.environment["PATH"] ?? "")"
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/bash")
        task.arguments = ["-lc", "cd '\(repoPath)' && nohup sh ./scripts/start-embed-server.sh >> /tmp/chump-embed.log 2>&1 &"]
        task.standardInput = FileHandle.nullDevice
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        task.currentDirectoryURL = URL(fileURLWithPath: repoPath)
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = pathForEmbed
        task.environment = env
        do {
            try task.run()
            task.waitUntilExit()
            // Embed server loads the model before binding; refresh at 3s, 12s, 28s so we show warm when ready
            for delay in [3.0, 12.0, 28.0] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.refresh() }
            }
            runAlert("Embed server is starting on 18765 (model may take 20–60s to load). Log: /tmp/chump-embed.log")
            // After 2s, check log for immediate failures (python3 not found, missing deps)
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) { [weak self] in
                self?.checkEmbedLogAndAlertIfFailed()
            }
        } catch {
            runAlert("Failed to start embed server: \(error.localizedDescription)")
        }
    }

    private func checkEmbedLogAndAlertIfFailed() {
        let logPath = "/tmp/chump-embed.log"
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: logPath)),
              let text = String(data: data, encoding: .utf8) else { return }
        let lower = text.lowercased()
        if lower.contains("command not found") || lower.contains("no such file") || lower.contains("modulenotfounderror") || lower.contains("importerror") || lower.contains("no module named") {
            let snippet = String(text.suffix(600)).trimmingCharacters(in: .whitespacesAndNewlines)
            DispatchQueue.main.async { [weak self] in
                self?.runAlert("Embed server failed to start. Common fix: run in Terminal from rust-agent: pip install -r scripts/requirements-embed.txt\n\nLast log lines:\n\(snippet)")
            }
        }
    }

    func stopEmbedServer() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        task.arguments = ["-f", "embed_server.py"]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        try? task.run()
        task.waitUntilExit()
        embedServerStatus = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.refresh() }
    }

    func openLogs() {
        let logDir = "\(repoPath)/logs"
        let url = URL(fileURLWithPath: logDir)
        if !FileManager.default.fileExists(atPath: logDir) {
            do {
                try FileManager.default.createDirectory(atPath: logDir, withIntermediateDirectories: true)
            } catch {
                runAlert("Could not create logs dir: \(logDir). \(error.localizedDescription)")
                return
            }
        }
        NSWorkspace.shared.open(url)
    }

    func openEmbedLog() {
        let logPath = "/tmp/chump-embed.log"
        if !FileManager.default.fileExists(atPath: logPath) {
            runAlert("Embed log not found. Start the embed server first; log is created at \(logPath).")
            return
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: logPath))
    }

    func openVLLMLog() {
        let logPath = "/tmp/chump-vllm.log"
        if !FileManager.default.fileExists(atPath: logPath) {
            runAlert("vLLM log not found. Start vLLM-MLX (8000) first; log is created at \(logPath).")
            return
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: logPath))
    }

    func openVLLM8001Log() {
        let logPath = "/tmp/chump-vllm-8001.log"
        if !FileManager.default.fileExists(atPath: logPath) {
            runAlert("vLLM 8001 log not found. Start vLLM-MLX (8001) first; log is created at \(logPath).")
            return
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: logPath))
    }

    func openHeartbeatLog() {
        let logPath = "\(repoPath)/logs/heartbeat-learn.log"
        if !FileManager.default.fileExists(atPath: logPath) {
            runAlert("Heartbeat log not found. Start heartbeat first; log is created at \(logPath).")
            return
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: logPath))
    }

    func openSelfImproveLog() {
        let logPath = "\(repoPath)/logs/heartbeat-self-improve.log"
        if !FileManager.default.fileExists(atPath: logPath) {
            runAlert("Self-improve log not found. Start self-improve first; log is created at \(logPath).")
            return
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: logPath))
    }

    private func runAlert(_ message: String) {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = message
            alert.alertStyle = .warning
            alert.runModal()
        }
    }
}
