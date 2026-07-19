// chumpwake — RESILIENT-169: system-wake listener that revives the Chump fleet.
//
// launchd has no native "run on wake" trigger, so this tiny always-on daemon
// (KeepAlive LaunchAgent, sibling of tools/chumpbar) subscribes to
// NSWorkspace.didWakeNotification and runs scripts/ops/wake-recovery.sh on
// every wake: bust the stale auth cache (CREDIBLE-147), re-probe auth, kick
// the farmer + merge chain, emit kind=wake_recovery to ambient.jsonl.
//
// Build:  swiftc -O -o ~/.local/bin/chumpwake tools/chumpwake/main.swift
// Install: scripts/setup/install-wake-recovery.sh

import AppKit
import Foundation

let repo = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Projects/Chump").path
let recoveryScript = ProcessInfo.processInfo.environment["CHUMP_WAKE_RECOVERY_SH"]
    ?? (repo + "/scripts/ops/wake-recovery.sh")

func log(_ msg: String) {
    let ts = ISO8601DateFormatter().string(from: Date())
    print("[chumpwake] \(ts) \(msg)")
}

func runRecovery(reason: String) {
    log("wake detected (\(reason)) — running recovery")
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/bash")
    p.arguments = [recoveryScript]
    do {
        try p.run()
        p.waitUntilExit()
        log("recovery exited rc=\(p.terminationStatus)")
    } catch {
        log("ERROR launching recovery: \(error)")
    }
}

let center = NSWorkspace.shared.notificationCenter
center.addObserver(
    forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
) { _ in
    // Small delay: right at wake, the network stack and keychain may not be
    // up yet; 10s makes the auth re-probe meaningful instead of a false RED.
    DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
        runRecovery(reason: "didWakeNotification")
    }
}

log("armed — listening for system wake (recovery: \(recoveryScript))")
RunLoop.main.run()
