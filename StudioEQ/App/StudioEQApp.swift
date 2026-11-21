// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright © 2026 Jean-Christophe Baptiste

import AppKit
import SwiftUI

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

    /// Another copy of Studio EQ (same bundle identifier) is already running. Two instances would
    /// each tap the other's processed output: the display would go silent or feed back.
    nonisolated static var otherInstanceRunning: Bool {
        guard let id = Bundle.main.bundleIdentifier else { return false }
        let me = ProcessInfo.processInfo.processIdentifier
        return NSRunningApplication.runningApplications(withBundleIdentifier: id)
            .contains { $0.processIdentifier != me && !$0.isTerminated }
    }

    static let model: AppModel? = {
        if isCommandLineMode || isTesting { return nil }
        if otherInstanceRunning {
            // Hand over to the running copy and leave without touching the audio.
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
