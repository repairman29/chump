// Chump menu bar app: start/stop Chump and show status. macOS 14+.
import AppKit
import Foundation
import SwiftUI

private let defaultRepoPath = FileManager.default.homeDirectoryForCurrentUser.path + "/Projects/Chump"
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
    case deploy = "Deploy"
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
            .accessibilityLabel("Status, Deploy, or Roles tab")

            if selectedTab == .roles {
                RolesTabView(state: state)
            } else if selectedTab == .deploy {
                DeployTabView(state: state)
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
                Button { state.openChumpPWA() } label: {
                    Label("Open Chump PWA", systemImage: "globe")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .accessibilityHint("Opens Chump chat UI at localhost:3000 in the default browser")
                Button { state.showActivityFeed.toggle() } label: {
                    Label(state.showActivityFeed ? "Hide activity feed" : "Show activity feed", systemImage: "text.alignleft")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                if state.showActivityFeed {
                    VStack(alignment: .leading, spacing: 2) {
                        if state.recentActivityLines.isEmpty {
                            Text("No recent activity in chump.log")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.tertiary)
                        } else {
                            ForEach(state.recentActivityLines, id: \.self) { line in
                                Text(line)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                                    .truncationMode(.tail)
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
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
                } header: {
                    Text("Local inference (Ollama)")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                }

                Section {
                    portRow(port: 8000, status: state.port8000Status, modelLabel: state.model8000Label, start: { state.startVLLM() }, stop: { state.stopVLLM8000() }, disabled: state.busyMessage != nil)
                    portRow(port: 8001, status: state.port8001Status, modelLabel: nil, start: { state.startVLLM8001() }, stop: { state.stopVLLM8001() }, disabled: state.busyMessage != nil)
                } header: {
                    Text("vLLM-MLX (model server)")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                } footer: {
                    Text("8000 = main model (14B default). 8001 = optional second model. Start uses serve-vllm-mlx.sh.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                Section {
                    embedRow(status: state.embedServerStatus, start: { state.startEmbedServer() }, stop: { state.stopEmbedServer() }, disabled: state.busyMessage != nil)
                } header: {
                    Text("Embed")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                }

                Section {
                    Button { state.runChumpMode() } label: {
                        Label("Enter Chump mode", systemImage: "bolt.circle.fill")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .tint(Color.orange)
                    .disabled(state.busyMessage != nil)
                    .opacity(state.busyMessage != nil ? 0.6 : 1)
                    .accessibilityHint("Kills blocklisted processes to free RAM/CPU for the model on 8000. Edit scripts/chump-mode.conf to choose which apps to close.")
                    Button { state.runListHeavyProcesses() } label: {
                        Label("Show heavy processes", systemImage: "list.bullet.rectangle")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .disabled(state.busyMessage != nil)
                    .opacity(state.busyMessage != nil ? 0.6 : 1)
                    .accessibilityHint("Lists top memory users and known GPU-heavy apps; opens log. Uncomment matches in chump-mode.conf then Enter Chump mode.")
                    if let chumpModeSummary = state.chumpModeLastRunSummary {
                        Text(chumpModeSummary)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 12)
                    }
                } header: {
                    Text("Chump mode")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                } footer: {
                    Text("Slim mode: stops Ollama + embed server and kills all apps in chump-mode.conf. Comment out any app to keep.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
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
                if state.cursorImproveLoopRunning {
                    Button { state.stopCursorImproveLoop() } label: {
                        Label("Stop cursor-improve loop", systemImage: "arrow.trianglehead.2.clockwise")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .disabled(state.busyMessage != nil)
                    .opacity(state.busyMessage != nil ? 0.6 : 1)
                    .accessibilityHint("Stops the loop that runs cursor_improve rounds one after another")
                } else {
                    Button { state.startCursorImproveLoop(quick: false) } label: {
                        Label("Start cursor-improve loop (8h)", systemImage: "arrow.trianglehead.2.clockwise")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .disabled(state.busyMessage != nil)
                    .opacity(state.busyMessage != nil ? 0.6 : 1)
                    Button { state.startCursorImproveLoop(quick: true) } label: {
                        Label("Cursor-improve loop (quick 2m)", systemImage: "arrow.trianglehead.2.clockwise")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .disabled(state.busyMessage != nil)
                    .opacity(state.busyMessage != nil ? 0.6 : 1)
                }
                if state.heartbeatPaused {
                    Button { state.resumeSelfImprove() } label: {
                        Label("Resume self-improve", systemImage: "play.circle")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .tint(Color(nsColor: .systemGreen))
                    .disabled(state.busyMessage != nil)
                    .opacity(state.busyMessage != nil ? 0.6 : 1)
                    .accessibilityHint("Removes logs/pause so heartbeat and cursor-improve loop run rounds again")
                } else {
                    Button { state.pauseSelfImprove() } label: {
                        Label("Pause self-improve", systemImage: "pause.circle")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .disabled(state.busyMessage != nil)
                    .opacity(state.busyMessage != nil ? 0.6 : 1)
                    .accessibilityHint("Creates logs/pause; heartbeat and cursor-improve loop skip rounds until you resume")
                }
                } header: {
                    Text("Chump & heartbeat")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                }

                Section {
                    if state.shipRunning {
                        Button { state.stopShip() } label: {
                            Label("Stop ship heartbeat", systemImage: "shippingbox")
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                        .disabled(state.busyMessage != nil)
                        .opacity(state.busyMessage != nil ? 0.6 : 1)
                    } else {
                        Button { state.startShip(quick: false) } label: {
                            Label("Start ship heartbeat (8h)", systemImage: "shippingbox")
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                        .disabled(state.busyMessage != nil)
                        .opacity(state.busyMessage != nil ? 0.6 : 1)
                        Button { state.startShip(quick: true) } label: {
                            Label("Ship heartbeat (quick 2m)", systemImage: "shippingbox.fill")
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                        .disabled(state.busyMessage != nil)
                        .opacity(state.busyMessage != nil ? 0.6 : 1)
                        Button { state.startShip(quick: false, dryRun: true) } label: {
                            Label("Ship heartbeat (8h, dry run)", systemImage: "shippingbox")
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .disabled(state.busyMessage != nil)
                        .opacity(state.busyMessage != nil ? 0.6 : 1)
                    }
                } header: {
                    Text("Ship (product)")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                }

                Section {
                    Button { state.startMabelHeartbeat() } label: {
                        Label("Start Mabel heartbeat", systemImage: "waveform.path.ecg")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .disabled(state.busyMessage != nil)
                    .opacity(state.busyMessage != nil ? 0.6 : 1)
                    Button { state.stopMabelHeartbeat() } label: {
                        Label("Stop Mabel heartbeat", systemImage: "stop.circle")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .disabled(state.busyMessage != nil)
                    .opacity(state.busyMessage != nil ? 0.6 : 1)
                } header: {
                    Text("Mabel (Pixel)")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                }

                Section {
                    Button { state.chooseRepoPath() } label: {
                        Label("Set Chump repo path…", systemImage: "folder")
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
                    Button { state.openOllamaLog() } label: {
                        Label("Open Ollama log", systemImage: "doc.text")
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
                    Button { state.openCursorImproveLoopLog() } label: {
                        Label("Open cursor-improve loop log", systemImage: "doc.text")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    Button { state.openShipLog() } label: {
                        Label("Open ship log", systemImage: "doc.text")
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
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text("These roles should be running in the background to keep the stack healthy, Chump online, and heartbeat/models tended. Run once = execute script now. For 24/7 help, schedule them (launchd or cron): Farmer Brown every ~2 min, Shepherd every 15–30 min, Sentinel / Memory Keeper / Oven Tender as needed. See docs/OPERATIONS.md.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text("Green dot = script running or log updated in last 30s. \"Not found\" → set Chump repo path to the folder that contains scripts/ (e.g. ~/Projects/Chump).")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .id(state.rolesRefreshTrigger) // Re-render when refresh() runs so role dots update (Roles tab doesn't read other refresh state)
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
    var cursorImproveLoopRunning = false
    var shipRunning = false
    /// True when logs/pause exists; heartbeat and cursor-improve loop skip rounds until resumed.
    var heartbeatPaused = false
    var autonomyTier: Int? = nil
    var model8000Label: String? = nil
    var lastErrorMessage: String? = nil
    var lastSuccessMessage: String? = nil
    /// Shown while a long-running action is in progress; buttons should be disabled.
    var busyMessage: String? = nil
    /// e.g. "Heartbeat 5m ago" or "Discord active 1m ago" for at-a-glance liveness.
    var lastActivitySummary: String? = nil
    var recentActivityLines: [String] = []
    var showActivityFeed: Bool = false
    /// Bumped on each refresh so the Roles tab re-renders and re-evaluates roleRunning() (Roles don't read other refresh state).
    var rolesRefreshTrigger: Date = .distantPast
    /// e.g. "Last run: 5m ago" from logs/chump-mode.log
    var chumpModeLastRunSummary: String? = nil

    var repoPath: String {
        get {
            UserDefaults.standard.string(forKey: ChumpRepoPathKey) ?? defaultRepoPath
        }
        set {
            UserDefaults.standard.set(newValue, forKey: ChumpRepoPathKey)
        }
    }

    /// Path safe for use inside single-quoted shell strings (e.g. cd '...').
    private func shellEscape(_ path: String) -> String {
        path.replacingOccurrences(of: "'", with: "'\\''")
    }

    func refresh() {
        chumpRunning = isChumpProcessRunning()
        ollamaStatus = checkOllama()
        port8000Status = checkPort(8000)
        port8001Status = checkPort(8001)
        embedServerStatus = checkEmbedServer()
        heartbeatRunning = isHeartbeatRunning()
        selfImproveRunning = isSelfImproveRunning()
        cursorImproveLoopRunning = isCursorImproveLoopRunning()
        shipRunning = isShipRunning()
        heartbeatPaused = FileManager.default.fileExists(atPath: "\(repoPath)/logs/pause")
        autonomyTier = loadAutonomyTier()
        if port8000Status == "200" {
            model8000Label = fetchModel8000Label()
        } else {
            model8000Label = nil
        }
        lastActivitySummary = computeLastActivitySummary()
        recentActivityLines = readRecentActivityLines()
        rolesRefreshTrigger = Date()
        chumpModeLastRunSummary = computeChumpModeLastRunSummary()
    }

    private func computeChumpModeLastRunSummary() -> String? {
        let logPath = "\(repoPath)/logs/chump-mode.log"
        guard let att = try? FileManager.default.attributesOfItem(atPath: logPath),
              let mtime = att[.modificationDate] as? Date else { return nil }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return "Last run: \(formatter.localizedString(for: mtime, relativeTo: Date()))"
    }

    func runChumpMode() {
        let scriptPath = "\(repoPath)/scripts/enter-chump-mode.sh"
        guard FileManager.default.fileExists(atPath: scriptPath) else {
            showToast("Not found: scripts/enter-chump-mode.sh. Use Set Chump repo path…")
            return
        }
        guard busyMessage == nil else { return }
        busyMessage = "Entering Chump mode…"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/bin/bash")
            task.arguments = ["-lc", "cd '\(shellEscape(self.repoPath))' && ./scripts/enter-chump-mode.sh"]
            task.currentDirectoryURL = URL(fileURLWithPath: self.repoPath)
            let pipe = Pipe()
            task.standardOutput = pipe
            task.standardError = pipe
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = (env["PATH"] ?? "") + ":/opt/homebrew/bin:\(NSHomeDirectory())/.local/bin"
            env["CHUMP_HOME"] = self.repoPath
            task.environment = env
            do {
                try task.run()
                task.waitUntilExit()
                _ = pipe.fileHandleForReading.readDataToEndOfFile()
                DispatchQueue.main.async {
                    self.busyMessage = nil
                    self.refresh()
                    if task.terminationStatus == 0 {
                        self.showSuccess("Chump mode: blocklisted processes closed. See logs/chump-mode.log")
                    } else {
                        self.showToast("Chump mode script exited \(task.terminationStatus). Check scripts/chump-mode.conf and logs/chump-mode.log")
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

    func runListHeavyProcesses() {
        let scriptPath = "\(repoPath)/scripts/list-heavy-processes.sh"
        guard FileManager.default.fileExists(atPath: scriptPath) else {
            showToast("Not found: scripts/list-heavy-processes.sh. Use Set Chump repo path…")
            return
        }
        guard busyMessage == nil else { return }
        busyMessage = "Listing heavy processes…"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/bin/bash")
            task.arguments = ["-lc", "cd '\(shellEscape(self.repoPath))' && ./scripts/list-heavy-processes.sh"]
            task.currentDirectoryURL = URL(fileURLWithPath: self.repoPath)
            task.standardOutput = FileHandle.nullDevice
            task.standardError = FileHandle.nullDevice
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = (env["PATH"] ?? "") + ":/opt/homebrew/bin"
            env["CHUMP_HOME"] = self.repoPath
            task.environment = env
            do {
                try task.run()
                task.waitUntilExit()
                let logPath = "\(self.repoPath)/logs/heavy-processes.log"
                DispatchQueue.main.async {
                    self.busyMessage = nil
                    self.refresh()
                    if FileManager.default.fileExists(atPath: logPath) {
                        NSWorkspace.shared.open(URL(fileURLWithPath: logPath))
                        self.showSuccess("Heavy processes log opened. Uncomment matches in chump-mode.conf then Enter Chump mode.")
                    } else {
                        self.showToast("Script ran but log not found at logs/heavy-processes.log")
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

    /// Green dot: script process is running now, or its log was updated in the last 30s (one-shot roles exit quickly).
    func roleRunning(script scriptName: String) -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        task.arguments = ["-f", scriptName]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            task.waitUntilExit()
            if task.terminationStatus == 0 { return true }
        } catch { }
        // One-shot scripts exit quickly; show green if log was touched recently
        let logName = roleRows.first { $0.scriptName == scriptName }?.logName ?? scriptName.replacingOccurrences(of: ".sh", with: ".log")
        let logPath = "\(repoPath)/logs/\(logName)"
        guard let att = try? FileManager.default.attributesOfItem(atPath: logPath),
              let mtime = att[.modificationDate] as? Date else { return false }
        return Date().timeIntervalSince(mtime) < 30
    }

    func runRole(script scriptName: String) {
        let scriptPath = "\(repoPath)/scripts/\(scriptName)"
        guard FileManager.default.fileExists(atPath: scriptPath) else {
            showToast("Not found: scripts/\(scriptName). Use Set Chump repo path… and choose the Chump folder (contains scripts/).")
            return
        }
        guard busyMessage == nil else { return }
        busyMessage = "Running \(scriptName)..."
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/bin/bash")
            task.arguments = ["-lc", "cd '\(shellEscape(self.repoPath))' && source .env 2>/dev/null; ./scripts/\(scriptName)"]
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
            runAlert("Log not found. Run the role once to create \(logName). Path: \(logPath)")
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
        let shipLog = "\(repoPath)/logs/heartbeat-ship.log"
        if let att = try? FileManager.default.attributesOfItem(atPath: shipLog),
           let mtime = att[.modificationDate] as? Date,
           now.timeIntervalSince(mtime) < 86400 {
            let label = "Ship \(formatter.localizedString(for: mtime, relativeTo: now))"
            if best == nil || mtime > best!.date { best = (mtime, label) }
        }
        let chumpLog = "\(repoPath)/logs/chump.log"
        if let att = try? FileManager.default.attributesOfItem(atPath: chumpLog),
           let mtime = att[.modificationDate] as? Date,
           now.timeIntervalSince(mtime) < 3600 {
            let label = "Active \(formatter.localizedString(for: mtime, relativeTo: now))"
            if best == nil || mtime > best!.date { best = (mtime, label) }
        }
        return best?.label
    }

    /// Returns the last 8 meaningful lines from chump.log for the live activity feed.
    private func readRecentActivityLines() -> [String] {
        let logPath = "\(repoPath)/logs/chump.log"
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: logPath)),
              let text = String(data: data, encoding: .utf8) else { return [] }
        let lines = text.components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        return Array(lines.suffix(8))
    }

    func openChumpPWA() {
        if let url = URL(string: "http://localhost:3000") {
            NSWorkspace.shared.open(url)
        }
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
            else if id.contains("14B") || id.contains("14b") { out = "14B" }
            else if id.contains("20B") || id.contains("20b") { out = "20B" }
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
            showToast("Not found: run-discord.sh. Use Set Chump repo path…")
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
            showToast("Chump binary not found. Run: cargo build --release")
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
        panel.message = "Select the Chump repo (e.g. ~/Projects/Chump). Must contain run-discord.sh and Cargo.toml."
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
            task.arguments = ["-lc", "cd '\(shellEscape(self.repoPath))' && ./scripts/run-autonomy-tests.sh 2>&1 | tee logs/autonomy-run.log"]
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

    private func isCursorImproveLoopRunning() -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        task.arguments = ["-f", "heartbeat-cursor-improve-loop"]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            task.waitUntilExit()
            return task.terminationStatus == 0
        } catch { return false }
    }

    private func isShipRunning() -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        task.arguments = ["-f", "heartbeat-ship"]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            task.waitUntilExit()
            return task.terminationStatus == 0
        } catch { return false }
    }

    func startShip(quick: Bool = false, dryRun: Bool = false) {
        let script = "\(repoPath)/scripts/heartbeat-ship.sh"
        guard FileManager.default.fileExists(atPath: script) else {
            showToast("Not found: \(script). Run: cp Downloads/heartbeat-ship.sh scripts/")
            return
        }
        let envExport = "export CHUMP_REPO='\(shellEscape(repoPath))'; "
        let quickEnv = quick ? "HEARTBEAT_QUICK_TEST=1 " : ""
        let dryEnv   = dryRun ? "HEARTBEAT_DRY_RUN=1 " : ""
        let dryNote  = dryRun ? " (dry run — no push/PR)" : ""
        let cmd = "cd '\(shellEscape(repoPath))' && \(envExport)\(quickEnv)\(dryEnv)nohup bash scripts/heartbeat-ship.sh >> logs/heartbeat-ship.log 2>&1 &"
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/bash")
        task.arguments = ["-lc", cmd]
        do {
            try task.run()
            shipRunning = true
            if quick {
                showToast("Ship heartbeat (quick 2m) started. Log: logs/heartbeat-ship.log")
            } else {
                runAlert("Ship heartbeat started (8h).\(dryNote) Log: \(repoPath)/logs/heartbeat-ship.log")
            }
        } catch {
            showToast("Failed to start ship heartbeat: \(error.localizedDescription)")
        }
    }

    func stopShip() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        task.arguments = ["-f", "heartbeat-ship"]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        try? task.run()
        task.waitUntilExit()
        shipRunning = false
        showToast("Ship heartbeat stopped.")
    }

    func openShipLog() {
        let logPath = "\(repoPath)/logs/heartbeat-ship.log"
        NSWorkspace.shared.open(URL(fileURLWithPath: logPath))
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
            showToast("Not found: \(script). Use Set Chump repo path…")
            return
        }
        let logPath = "\(repoPath)/logs/discord.log"
        let cmd = "cd '\(shellEscape(repoPath))' && nohup ./run-discord.sh >> '\(shellEscape(logPath))' 2>&1 &"
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
            showToast("Not found: \(script). Use Set Chump repo path…")
            return
        }
        let envExport = FileManager.default.fileExists(atPath: "\(repoPath)/.env")
            ? "source .env 2>/dev/null; " : ""
        let quickEnv = quick ? "HEARTBEAT_QUICK_TEST=1 " : ""
        let cmd = "cd '\(shellEscape(repoPath))' && \(envExport)\(quickEnv)nohup bash scripts/heartbeat-learn.sh >> logs/heartbeat-learn.log 2>&1 &"
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
                runAlert("Heartbeat started (8h). Log: \(repoPath)/logs/heartbeat-learn.log. Ensure Ollama is running (ollama serve) and TAVILY_API_KEY in .env.")
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
        let cmd = "cd '\(shellEscape(repoPath))' && \(envExport)\(quickEnv)\(dryEnv)nohup bash scripts/heartbeat-self-improve.sh >> logs/heartbeat-self-improve.log 2>&1 &"
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
                runAlert("Self-improve started (8h).\(dryNote) Log: \(repoPath)/logs/heartbeat-self-improve.log. Ensure Ollama is running (ollama serve) and CHUMP_REPO set.")
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

    /// Creates logs/pause so heartbeat and cursor-improve loop skip rounds until resumed.
    func pauseSelfImprove() {
        let logsDir = "\(repoPath)/logs"
        let pausePath = "\(logsDir)/pause"
        do {
            if !FileManager.default.fileExists(atPath: logsDir) {
                try FileManager.default.createDirectory(atPath: logsDir, withIntermediateDirectories: true)
            }
            try Data().write(to: URL(fileURLWithPath: pausePath))
            refresh()
            showSuccess("Self-improve paused (rounds will skip until resumed)")
        } catch {
            showToast("Could not create logs/pause: \(error.localizedDescription)")
        }
    }

    /// Removes logs/pause so heartbeat and cursor-improve loop run rounds again.
    func resumeSelfImprove() {
        let pausePath = "\(repoPath)/logs/pause"
        guard FileManager.default.fileExists(atPath: pausePath) else {
            refresh()
            return
        }
        do {
            try FileManager.default.removeItem(atPath: pausePath)
            refresh()
            showSuccess("Self-improve resumed")
        } catch {
            showToast("Could not remove logs/pause: \(error.localizedDescription)")
        }
    }

    func startCursorImproveLoop(quick: Bool) {
        let script = "\(repoPath)/scripts/heartbeat-cursor-improve-loop.sh"
        guard FileManager.default.fileExists(atPath: script) else {
            showToast("Not found: \(script). Use Set Chump repo path…")
            return
        }
        let envExport = FileManager.default.fileExists(atPath: "\(repoPath)/.env")
            ? "source .env 2>/dev/null; " : ""
        let quickEnv = quick ? "HEARTBEAT_QUICK_TEST=1 " : ""
        let cmd = "cd '\(shellEscape(repoPath))' && \(envExport)\(quickEnv)nohup bash scripts/heartbeat-cursor-improve-loop.sh >> logs/heartbeat-cursor-improve-loop.log 2>&1 &"
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/bash")
        task.arguments = ["-lc", cmd]
        task.standardInput = FileHandle.nullDevice
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        task.currentDirectoryURL = URL(fileURLWithPath: repoPath)
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = (env["PATH"] ?? "") + ":/opt/homebrew/bin:\(NSHomeDirectory())/.cargo/bin:\(NSHomeDirectory())/.local/bin"
        env["CHUMP_HOME"] = repoPath
        task.environment = env
        do {
            try task.run()
            task.waitUntilExit()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.refresh() }
            if quick {
                showToast("Cursor-improve loop (quick 2m) started. Log: logs/heartbeat-cursor-improve-loop.log")
            } else {
                showSuccess("Cursor-improve loop started (8h, one round after another). Pause from menu when needed.")
            }
        } catch {
            showToast("Failed to start: \(error.localizedDescription)")
        }
    }

    func stopCursorImproveLoop() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        task.arguments = ["-f", "heartbeat-cursor-improve-loop"]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        try? task.run()
        task.waitUntilExit()
        cursorImproveLoopRunning = false
        refresh()
    }

    /// Start Mabel heartbeat on Pixel via SSH (termux, port 8022). Requires ~/.ssh/config host "termux".
    func startMabelHeartbeat() {
        let cmd = "ssh -o ConnectTimeout=10 -p 8022 termux 'cd ~/chump && nohup bash scripts/heartbeat-mabel.sh >> logs/heartbeat-mabel.log 2>&1 &'"
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/bash")
        task.arguments = ["-lc", cmd]
        task.standardInput = FileHandle.nullDevice
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = (env["PATH"] ?? "") + ":/opt/homebrew/bin:\(NSHomeDirectory())/.local/bin"
        task.environment = env
        do {
            try task.run()
            task.waitUntilExit()
            if task.terminationStatus == 0 {
                showToast("Mabel heartbeat start sent to Pixel. Log: ~/chump/logs/heartbeat-mabel.log on device.")
            } else {
                showToast("SSH to Pixel failed (check termux in ~/.ssh/config, port 8022).")
            }
        } catch {
            showToast("Failed to start Mabel heartbeat: \(error.localizedDescription)")
        }
    }

    /// Stop Mabel heartbeat on Pixel via SSH.
    func stopMabelHeartbeat() {
        let cmd = "ssh -o ConnectTimeout=10 -p 8022 termux 'pkill -f heartbeat-mabel || true'"
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/bash")
        task.arguments = ["-lc", cmd]
        task.standardInput = FileHandle.nullDevice
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = (env["PATH"] ?? "") + ":/opt/homebrew/bin:\(NSHomeDirectory())/.local/bin"
        task.environment = env
        try? task.run()
        task.waitUntilExit()
        showToast("Stop Mabel heartbeat sent to Pixel.")
    }

    func openCursorImproveLoopLog() {
        let logPath = "\(repoPath)/logs/heartbeat-cursor-improve-loop.log"
        if !FileManager.default.fileExists(atPath: logPath) {
            runAlert("Cursor-improve loop log not found. Start cursor-improve loop first; log is created at \(logPath).")
            return
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: logPath))
    }

    func startVLLM() {
        let script = "\(repoPath)/serve-vllm-mlx.sh"
        guard FileManager.default.fileExists(atPath: script) else {
            runAlert("Not found: \(script). Set Chump repo path or run from repo root.")
            return
        }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/bash")
        task.arguments = ["-lc", "cd '\(shellEscape(repoPath))' && nohup ./serve-vllm-mlx.sh >> /tmp/chump-vllm.log 2>&1 &"]
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
            runAlert("Not found: \(script). Set Chump repo path or run from repo root.")
            return
        }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/bash")
        task.arguments = ["-lc", "cd '\(shellEscape(repoPath))' && nohup ./scripts/serve-vllm-mlx-8001.sh >> /tmp/chump-vllm-8001.log 2>&1 &"]
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
            runAlert("Not found: \(script). Set Chump repo path or run from repo root.")
            return
        }
        // Ensure Python is on PATH when launched from menu (Finder gives minimal env)
        let pathForEmbed = "/usr/bin:/bin:/opt/homebrew/bin:\(NSHomeDirectory())/.local/bin:\(NSHomeDirectory())/Library/pnpm:\(ProcessInfo.processInfo.environment["PATH"] ?? "")"
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/bash")
        task.arguments = ["-lc", "cd '\(shellEscape(repoPath))' && nohup sh ./scripts/start-embed-server.sh >> /tmp/chump-embed.log 2>&1 &"]
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
                self?.runAlert("Embed server failed to start. Common fix: run in Terminal from repo root: pip install -r scripts/requirements-embed.txt\n\nLast log lines:\n\(snippet)")
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

    func openOllamaLog() {
        let logPath = "/tmp/chump-ollama.log"
        if !FileManager.default.fileExists(atPath: logPath) {
            runAlert("Ollama log not found. Start Ollama from the menu first; log is created at \(logPath).")
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
