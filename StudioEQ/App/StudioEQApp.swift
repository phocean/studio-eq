// SPDX-License-Identifier: GPL-3.0-or-later
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
        // Read-only binding: the icon's presence follows the model, never a ⌘-drag out of the bar.
        MenuBarExtra(isInserted: Binding(get: { model?.isIconVisible ?? false }, set: { _ in })) {
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

    /// Posted by a copy that quits because another one runs: the running copy shows its icon.
    nonisolated static let revealIconNotification = Notification.Name("com.jcbaptiste.StudioEQ.revealIcon")

    static let model: AppModel? = {
        if isCommandLineMode || isTesting { return nil }
        guard acquireInstanceLock() else {
            // Hand over to the running copy and leave without touching the audio.
            log.info("another instance is running: quitting")
            DistributedNotificationCenter.default().postNotificationName(
                revealIconNotification, object: nil, userInfo: nil, deliverImmediately: true)
            DispatchQueue.main.async { NSApp.terminate(nil) }
            return nil
        }
        return AppModel()
    }()
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Opening the running app again (Finder, Spotlight, Launchpad) shows a hidden icon.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MainActor.assumeIsolated { AppInstance.model?.revealIcon() }
        return true
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if VALIDATION
        if AppInstance.isCommandLineMode {
            MainActor.assumeIsolated { _ = SelfTest.runIfRequested() }
        } else {
            MenuBarIconProbe.start()
        }
        #endif
    }
}

#if VALIDATION
/// Validation builds: logs the number of menu bar item windows of this app whenever it changes,
/// so a script can check that the icon appears and disappears (other processes cannot see them).
@MainActor
enum MenuBarIconProbe {
    private static var last = -1

    static func start() {
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            MainActor.assumeIsolated {
                // A removed item keeps a zero-height window; a shown one has one per menu bar.
                let n = NSApp.windows.filter {
                    String(describing: type(of: $0)).contains("StatusBarWindow") && $0.isVisible && $0.frame.height > 0
                }.count
                if n != last { last = n; log.info("menu bar icon windows: \(n, privacy: .public)") }
            }
        }
    }
}
#endif

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
