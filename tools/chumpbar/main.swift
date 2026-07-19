// ChumpBar — one-glance Chump fleet status in the macOS menu bar. (EFFECTIVE-308)
//
// Single-file, zero-dependency NSStatusItem app. Polls
// scripts/ops/chumpbar-status.sh every 60s and renders:
//   title:  <icon> <ships_24h>        e.g. "🟢 17"
//   menu:   mode / workers / last merge / P0s / open gaps
//   actions: Grind / Travel / Off (chump-mode), Refresh, Quit
//
// Build:  swiftc -O -o ~/.local/bin/chumpbar tools/chumpbar/main.swift
// Run:    chumpbar &        (menu-bar accessory; no Dock icon)

import AppKit
import Foundation

final class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var timer: Timer?

    let repo = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Projects/Chump").path
    var statusScript: String { repo + "/scripts/ops/chumpbar-status.sh" }
    var chumpMode: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/bin/chump-mode").path
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "⏳"
        rebuildMenu(detail: ["loading…"])
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    func run(_ launchPath: String, _ args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launchPath)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        do { try p.run() } catch { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }

    func refresh() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let out = self.run("/bin/bash", [self.statusScript])
            var icon = "❓", title = "❓"
            var detail = ["status script unavailable"]
            if let data = out.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                icon = obj["icon"] as? String ?? "❓"
                let ships = "\(obj["ships_24h"] ?? "?")"
                let mins = "\(obj["last_merge_min"] ?? "?")"
                let workers = "\(obj["workers"] ?? "?")"
                let mode = "\(obj["mode"] ?? "?")"
                let p0 = "\(obj["p0_open"] ?? "?")"
                let open = "\(obj["open_gaps"] ?? "?")"
                title = "\(icon) \(ships)"
                detail = [
                    "Mode: \(mode)   Workers: \(workers)",
                    "Shipped 24h: \(ships)   Last merge: \(mins)m ago",
                    "P0 open: \(p0)   Gaps open: \(open)",
                ]
            }
            DispatchQueue.main.async {
                self.statusItem.button?.title = title
                self.rebuildMenu(detail: detail)
            }
        }
    }

    func rebuildMenu(detail: [String]) {
        let menu = NSMenu()
        for line in detail {
            let item = NSMenuItem(title: line, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(makeItem("🏃 Grind (full fleet, stay awake)", #selector(modeGrind)))
        menu.addItem(makeItem("🧳 Travel (battery-friendly)", #selector(modeTravel)))
        menu.addItem(makeItem("⏹ Off (stop fleet)", #selector(modeOff)))
        menu.addItem(.separator())
        menu.addItem(makeItem("↻ Refresh now", #selector(refreshNow)))
        menu.addItem(makeItem("Quit ChumpBar", #selector(quit)))
        statusItem.menu = menu
    }

    func makeItem(_ title: String, _ sel: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: sel, keyEquivalent: "")
        item.target = self
        return item
    }

    func setMode(_ mode: String) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            _ = self.run("/bin/bash", [self.chumpMode, mode])
            self.refresh()
        }
    }

    @objc func modeGrind() { setMode("grind") }
    @objc func modeTravel() { setMode("travel") }
    @objc func modeOff() { setMode("off") }
    @objc func refreshNow() { refresh() }
    @objc func quit() { NSApp.terminate(nil) }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
