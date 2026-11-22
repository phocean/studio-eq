// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright © 2026 Jean-Christophe Baptiste

import AppKit
import os
import SwiftUI

private let log = Logger(subsystem: "com.jcbaptiste.StudioEQ", category: "app")

@main
struct StudioEQApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    private var model: AppModel? { AppInstance.model }

    var body: some Scene {
        MenuBarExtra(isInserted: .constant(model != nil)) {
            if let model { MenuContent(model: model) }
        } label: {
            MenuBarIcon(status: model?.status ?? .disabled)
        }
        .menuBarExtraStyle(.window)
    }
}

/// Process-wide state, created exactly once (not in the `App` struct, whose initializer SwiftUI
/// may run more than once: two models would mean two taps on the display).
@MainActor
enum AppInstance {
    /// Validation builds only: `--selftest`, `--list-devices`, `--permission-probe`, `--ab-test`
    /// run headless and exit, without the menu bar item or the normal engine.
    static let isCommandLineMode: Bool = {
        #if VALIDATION
        let args = CommandLine.arguments
        return ["--selftest", "--list-devices", "--permission-probe", "--ab-test"].contains(where: args.contains)
        #else
        return false
        #endif
    }()

    /// Hosting unit tests: no engine, no menu bar item.
    static let isTesting = NSClassFromString("XCTestCase") != nil

    /// Takes the per-user instance lock: false if another copy of Studio EQ already holds it.
    /// Two instances would each tap the other's processed output: the display would go silent or
    /// feed back. An exclusive `flock` on a file of the app's container is atomic, unlike a look
    /// at the running applications (two copies launched at the same instant both saw none), and
    /// the kernel releases it when the process exits or crashes. The descriptor is never closed.
    /// Other users' copies are out of its reach: `AppModel` stops the engine while this login
    /// session is in the background.
    nonisolated static func acquireInstanceLock() -> Bool {
        let fm = FileManager.default
        guard let dir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return true }
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let fd = open(dir.appendingPathComponent("StudioEQ.lock").path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0 else {
            log.error("instance lock unavailable (errno \(errno, privacy: .public)): running without it")
            return true
        }
        if flock(fd, LOCK_EX | LOCK_NB) == 0 { return true }
        close(fd)
        return false
    }

    static let model: AppModel? = {
        if isCommandLineMode || isTesting { return nil }
        guard acquireInstanceLock() else {
            // Hand over to the running copy and leave without touching the audio.
            log.info("another instance is running: quitting")
            DispatchQueue.main.async { NSApp.terminate(nil) }
            return nil
        }
        return AppModel()
    }()
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        #if VALIDATION
        if AppInstance.isCommandLineMode {
            MainActor.assumeIsolated { _ = SelfTest.runIfRequested() }
        }
        #endif
    }
}

struct MenuBarIcon: View {
    let status: AppModel.Status

    var body: some View {
        switch status {
        case .active: Image(systemName: "dial.high.fill").accessibilityLabel("Studio EQ active")
        case .error, .permissionDenied: Image(systemName: "exclamationmark.triangle").accessibilityLabel("Studio EQ error")
        default: Image(systemName: "dial.low").accessibilityLabel("Studio EQ inactive")
        }
    }
}
