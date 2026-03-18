// DeployTabView.swift — Pixel deploy & manage tab for ChumpMenu.
// Drop into ChumpMenu/Sources/ChumpMenu/ alongside ChumpMenuApp.swift.

import AppKit
import Foundation
import SwiftUI

// MARK: - Deploy action model

private struct DeployAction: Identifiable {
    let id: String
    let name: String
    let subtitle: String
    let icon: String
    /// Shell command run via `bash -lc` from repoPath.
    let shellCommand: String
    let tint: NSColor?
}

private func makeActions(repoPath: String) -> [DeployAction] {
    let esc = repoPath.replacingOccurrences(of: "'", with: "'\\''")
    return [
        DeployAction(
            id: "deploy-all",
            name: "Deploy All to Pixel",
            subtitle: "Build + binary + scripts + env + restart",
            icon: "arrow.up.doc.on.clipboard",
            shellCommand: "cd '\(esc)' && source .env 2>/dev/null; ./scripts/deploy-all-to-pixel.sh",
            tint: .systemBlue
        ),
        DeployAction(
            id: "deploy-binary",
            name: "Binary Only to Pixel",
            subtitle: "Build + push binary + restart (no env refresh)",
            icon: "shippingbox",
            shellCommand: "cd '\(esc)' && source .env 2>/dev/null; ./scripts/deploy-mabel-to-pixel.sh",
            tint: .systemIndigo
        ),
        DeployAction(
            id: "restart-mabel",
            name: "Restart Mabel Bot",
            subtitle: "SSH restart — no rebuild (uses .env host/port, force network)",
            icon: "arrow.counterclockwise",
            shellCommand: "cd '\(esc)' && source .env 2>/dev/null; PIXEL_SSH_FORCE_NETWORK=1 ./scripts/restart-mabel-bot-on-pixel.sh",
            tint: .systemOrange
        ),
        DeployAction(
            id: "capture-timing",
            name: "Capture Timing (30s)",
            subtitle: "Perf capture — send a Discord msg during the window",
            icon: "timer",
            shellCommand: "cd '\(esc)' && source .env 2>/dev/null; ./scripts/capture-mabel-timing.sh --yes termux 30",
            tint: nil
        ),
        DeployAction(
            id: "check-network",
            name: "Check Network",
            subtitle: "Tailscale IP + SSH reachability + Pixel status",
            icon: "network",
            shellCommand: "cd '\(esc)' && ./scripts/check-network-after-swap.sh",
            tint: nil
        ),
        DeployAction(
            id: "tail-mabel-log",
            name: "Tail Mabel Log",
            subtitle: "Last 40 lines of companion.log on Pixel",
            icon: "doc.text.magnifyingglass",
            shellCommand: "ssh -o ConnectTimeout=10 -p 8022 termux 'tail -40 ~/chump/logs/companion.log'",
            tint: nil
        ),
    ]
}

// MARK: - DeployTabView

struct DeployTabView: View {
    @Bindable var state: ChumpState

    // Live output from deploy actions
    @State private var output: String = ""
    @State private var runningID: String? = nil
    @State private var lastResult: (id: String, exit: Int32, at: Date)? = nil

    // Pixel status from SSH probe
    @State private var pixelReachable: Bool? = nil
    @State private var mabelBotUp: Bool? = nil
    @State private var pixelLlamaUp: Bool? = nil
    @State private var probing = false

    // Local toast (self-contained — no access to ChumpState's private showToast needed)
    @State private var toastMessage: String? = nil

    private var busy: Bool { runningID != nil }

    var body: some View {
        VStack(spacing: 0) {
            listContent
            if !output.isEmpty || busy {
                Divider()
                outputPane
            }
            // Toast bar
            if let msg = toastMessage {
                Text(msg)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: toastMessage != nil)
        .onAppear { probePixelStatus() }
    }

    // MARK: - List content

    private var listContent: some View {
        List {
            // ── Pixel status ──
            Section {
                pixelStatusRow
            } header: {
                HStack {
                    Text("Pixel")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        probePixelStatus()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.caption2)
                    }
                    .buttonStyle(.borderless)
                    .disabled(probing || busy)
                    .help("Probe Pixel via SSH")
                }
            }

            // ── Deploy actions ──
            Section {
                ForEach(makeActions(repoPath: state.repoPath)) { action in
                    actionRow(action)
                }
            } header: {
                Text("Deploy & Diagnostics")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
            }

            // ── Mabel on Pixel ──
            Section {
                mabelHeartbeatRow
                mabelFarmerRow
            } header: {
                Text("Mabel on Pixel")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
            }
        }
        .listStyle(.sidebar)
    }

    // MARK: - Pixel status row

    private var pixelStatusRow: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(pixelDotColor)
                .frame(width: 8, height: 8)
                .animation(.easeInOut(duration: 0.3), value: pixelReachable)
            VStack(alignment: .leading, spacing: 2) {
                Text(pixelLabel)
                    .font(.subheadline.weight(.medium))
                HStack(spacing: 12) {
                    statusChip(label: "Bot", up: mabelBotUp)
                    statusChip(label: "llama", up: pixelLlamaUp)
                }
            }
            Spacer(minLength: 0)
            if let r = lastResult {
                VStack(alignment: .trailing, spacing: 1) {
                    HStack(spacing: 3) {
                        Image(systemName: r.exit == 0 ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .font(.caption2)
                            .foregroundStyle(r.exit == 0 ? Color(nsColor: .systemGreen) : Color(nsColor: .systemRed))
                        Text(r.exit == 0 ? "OK" : "exit \(r.exit)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Text(relative(r.at))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func statusChip(label: String, up: Bool?) -> some View {
        HStack(spacing: 3) {
            Circle()
                .fill(chipColor(up))
                .frame(width: 5, height: 5)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func chipColor(_ up: Bool?) -> Color {
        guard let up else { return Color(nsColor: .secondaryLabelColor).opacity(0.4) }
        return up ? Color(nsColor: .systemGreen) : Color(nsColor: .systemRed).opacity(0.7)
    }

    private var pixelDotColor: Color {
        guard let r = pixelReachable else { return Color(nsColor: .secondaryLabelColor).opacity(0.4) }
        if !r { return Color(nsColor: .systemRed) }
        if mabelBotUp == true && pixelLlamaUp == true { return Color(nsColor: .systemGreen) }
        return Color(nsColor: .systemYellow)
    }

    private var pixelLabel: String {
        if probing { return "Checking Pixel…" }
        guard let r = pixelReachable else { return "Pixel: tap ↻ to check" }
        return r ? "Pixel reachable" : "Pixel unreachable"
    }

    // MARK: - Action row

    private func actionRow(_ action: DeployAction) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: action.icon)
                .font(.body)
                .foregroundStyle(action.tint.map { Color(nsColor: $0) } ?? .secondary)
                .frame(width: 20)
                .padding(.top, 3)
            VStack(alignment: .leading, spacing: 2) {
                Text(action.name)
                    .font(.subheadline.weight(.medium))
                Text(action.subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
            if runningID == action.id {
                ProgressView()
                    .controlSize(.small)
                    .padding(.top, 4)
            } else {
                Button("Run") { runAction(action) }
                    .buttonStyle(.borderless)
                    .disabled(busy || state.busyMessage != nil)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(action.name): \(action.subtitle)")
    }

    // MARK: - Mabel heartbeat

    private var mabelHeartbeatRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "waveform.path.ecg")
                .font(.body)
                .foregroundStyle(.secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text("Heartbeat")
                    .font(.subheadline.weight(.medium))
                Text("Patrol, research, report on Pixel")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button("Start") { state.startMabelHeartbeat() }
                .buttonStyle(.borderless)
                .disabled(busy)
            Button("Stop") { state.stopMabelHeartbeat() }
                .buttonStyle(.borderless)
                .disabled(busy)
        }
        .padding(.vertical, 4)
    }

    // MARK: - Mabel farmer

    private var mabelFarmerRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "stethoscope")
                .font(.body)
                .foregroundStyle(.secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text("Farmer (diagnose)")
                    .font(.subheadline.weight(.medium))
                Text("Pixel → Mac health check")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button("Run") {
                sshFireAndForget(
                    "cd ~/chump && MABEL_FARMER_DIAGNOSE_ONLY=1 bash scripts/mabel-farmer.sh",
                    label: "Mabel farmer diagnose"
                )
            }
            .buttonStyle(.borderless)
            .disabled(busy)
        }
        .padding(.vertical, 4)
    }

    // MARK: - Output pane

    private var outputPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header bar
            HStack(spacing: 6) {
                if busy {
                    ProgressView()
                        .controlSize(.mini)
                    Text(runningID ?? "")
                        .font(.caption2.weight(.medium).monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else {
                    Text("Output")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if !output.isEmpty {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(output, forType: .string)
                        flash("Copied ✓")
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.caption2)
                    }
                    .buttonStyle(.borderless)
                    .help("Copy output to clipboard")
                }
                if !busy && !output.isEmpty {
                    Button {
                        withAnimation { output = "" }
                    } label: {
                        Image(systemName: "xmark.circle")
                            .font(.caption2)
                    }
                    .buttonStyle(.borderless)
                    .help("Clear output")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)

            // Scrolling log
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    Text(output.isEmpty ? " " : output)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 8)
                        .id("outputBottom")
                }
                .frame(height: 160)
                .onChange(of: output) { _, _ in
                    proxy.scrollTo("outputBottom", anchor: .bottom)
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor).opacity(0.5))
    }

    // MARK: - Run deploy action (foreground, streaming output)

    private func runAction(_ action: DeployAction) {
        guard !busy else { return }
        runningID = action.id
        output = "▶ \(action.name)\n"

        DispatchQueue.global(qos: .userInitiated).async {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/bin/bash")
            task.arguments = ["-lc", action.shellCommand]
            task.currentDirectoryURL = URL(fileURLWithPath: state.repoPath)

            let pipe = Pipe()
            task.standardOutput = pipe
            task.standardError = pipe

            var env = ProcessInfo.processInfo.environment
            env["PATH"] = (env["PATH"] ?? "")
                + ":/opt/homebrew/bin"
                + ":\(NSHomeDirectory())/.local/bin"
                + ":\(NSHomeDirectory())/.cargo/bin"
            env["CHUMP_HOME"] = state.repoPath
            task.environment = env

            // Stream output chunk by chunk
            let handle = pipe.fileHandleForReading
            handle.readabilityHandler = { fh in
                let data = fh.availableData
                guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else { return }
                DispatchQueue.main.async {
                    output += chunk
                    // Trim to last ~250 lines so menu doesn't bloat
                    let lines = output.components(separatedBy: "\n")
                    if lines.count > 250 {
                        output = "…(trimmed)\n" + lines.suffix(250).joined(separator: "\n")
                    }
                }
            }

            do {
                try task.run()
                task.waitUntilExit()
                handle.readabilityHandler = nil

                let code = task.terminationStatus
                DispatchQueue.main.async {
                    output += code == 0
                        ? "\n✅ Done."
                        : "\n❌ Failed (exit \(code))."
                    runningID = nil
                    lastResult = (id: action.id, exit: code, at: Date())

                    // Re-probe after deploy/restart
                    if action.id.hasPrefix("deploy") || action.id == "restart-mabel" {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                            probePixelStatus()
                        }
                    }
                    state.refresh()
                }
            } catch {
                DispatchQueue.main.async {
                    output += "\n❌ Launch failed: \(error.localizedDescription)"
                    runningID = nil
                    state.refresh()
                }
            }
        }
    }

    // MARK: - SSH fire-and-forget (Mabel farmer, etc.)

    private func sshFireAndForget(_ cmd: String, label: String) {
        flash("\(label)…")
        DispatchQueue.global(qos: .utility).async {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/bin/bash")
            task.arguments = ["-lc", "ssh -o ConnectTimeout=10 -p 8022 termux '\(cmd)'"]
            task.standardInput = FileHandle.nullDevice
            task.standardOutput = FileHandle.nullDevice
            task.standardError = FileHandle.nullDevice
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = (env["PATH"] ?? "") + ":/opt/homebrew/bin:\(NSHomeDirectory())/.local/bin"
            task.environment = env
            do {
                try task.run()
                task.waitUntilExit()
                DispatchQueue.main.async {
                    flash(task.terminationStatus == 0
                        ? "\(label): sent ✓"
                        : "\(label): SSH failed (exit \(task.terminationStatus))")
                }
            } catch {
                DispatchQueue.main.async {
                    flash("\(label): \(error.localizedDescription)")
                }
            }
        }
    }

    // MARK: - Probe Pixel status

    private func probePixelStatus() {
        guard !probing else { return }
        probing = true
        DispatchQueue.global(qos: .utility).async {
            // Single SSH call: check bot + llama-server in one shot
            let cmd = """
                ssh -o ConnectTimeout=5 -o BatchMode=yes -p 8022 termux \
                'BOT=0; LLAMA=0; \
                 pgrep -f "chump.*--discord" >/dev/null 2>&1 && BOT=1; \
                 curl -sf -o /dev/null http://127.0.0.1:8000/v1/models 2>/dev/null && LLAMA=1; \
                 echo "BOT=$BOT LLAMA=$LLAMA"'
                """
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/bin/bash")
            task.arguments = ["-lc", cmd]
            task.standardInput = FileHandle.nullDevice
            let pipe = Pipe()
            task.standardOutput = pipe
            task.standardError = FileHandle.nullDevice
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = (env["PATH"] ?? "") + ":/opt/homebrew/bin:\(NSHomeDirectory())/.local/bin"
            task.environment = env
            do {
                try task.run()
                task.waitUntilExit()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let out = String(data: data, encoding: .utf8) ?? ""
                DispatchQueue.main.async {
                    if task.terminationStatus == 0 {
                        pixelReachable = true
                        mabelBotUp = out.contains("BOT=1")
                        pixelLlamaUp = out.contains("LLAMA=1")
                    } else {
                        pixelReachable = false
                        mabelBotUp = nil
                        pixelLlamaUp = nil
                    }
                    probing = false
                }
            } catch {
                DispatchQueue.main.async {
                    pixelReachable = false
                    mabelBotUp = nil
                    pixelLlamaUp = nil
                    probing = false
                }
            }
        }
    }

    // MARK: - Helpers

    private func relative(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f.localizedString(for: date, relativeTo: Date())
    }

    private func flash(_ msg: String) {
        toastMessage = msg
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
            if toastMessage == msg { toastMessage = nil }
        }
    }
}
