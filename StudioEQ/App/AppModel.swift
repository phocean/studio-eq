// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright © 2026 Jean-Christophe Baptiste

import AppKit
import CoreAudio
import Observation
import os
import ServiceManagement

private let log = Logger(subsystem: "com.jcbaptiste.StudioEQ", category: "model")

/// Glue between hardware state, user preferences and the audio engine.
/// Every decision is taken in `reconcile()`, which is idempotent and runs on each hardware event.
@MainActor
@Observable
final class AppModel {
    enum Status: Equatable {
        case active
        case disabled          // user turned the correction off
        case noDisplay         // no Studio Display speakers connected
        case otherOutput       // display present, another output selected
        case checkingPermission // verifying audio capture is allowed (prompt may be on screen)
        case permissionDenied  // capture refused: engine not started, sound left untouched
        case error(String)
    }

    private(set) var status: Status = .noDisplay
    private var loggedStatus: Status?
    private(set) var currentOutput: OutputDevice?
    private(set) var displaySpeakers: OutputDevice?
    private(set) var launchAtLoginError: String?

    var settings: EQSettings {
        didSet {
            guard settings != oldValue else { return }
            parameters.set(settings)
            Preferences.settings = settings
        }
    }

    var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            Preferences.isEnabled = isEnabled
            reconcile()
        }
    }

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                launchAtLoginError = nil
            } catch {
                launchAtLoginError = error.localizedDescription
                log.error("login item: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private let parameters: EQParameters
    private let monitor = DeviceMonitor()
    private var engine: TapEngine?

    /// Result of the last `CaptureCheck`. A `.granted` result is consumed by the engine start it
    /// was run for: every new start (output switch, sample-rate change, wake, toggle) checks
    /// again, because a permission revoked meanwhile would otherwise mute the display (the tap
    /// mutes the originals but delivers only zeros).
    private enum Permission: Equatable { case unknown, checking, granted, denied }
    private var permission: Permission = .unknown
    /// The running check, and a generation number so a result that arrives after the context
    /// changed (output switched, sleep, toggle) is ignored.
    private var checkTask: Task<Void, Never>?
    private var checkGeneration = 0
    private var checkedOutputUID: String?
    /// Configuration whose engine start or capture check failed, and why: not retried while the
    /// hardware stays in that same configuration (no retry loop), except once automatically
    /// (`autoRetryUsed`); retried as soon as it changes, on wake, or on Retry.
    private var failedConfiguration: String?
    private var failureMessage = ""
    private var autoRetryUsed = false
    private var retryTask: Task<Void, Never>?
    private var isAsleep = false
    /// Fast user switching moved this login session to the background. Another user's copy of
    /// Studio EQ may run in the foreground session: two engines would tap each other's output.
    private var isSessionInactive = false
    private var isShutDown = false
    private var observers: [NSObjectProtocol] = []

    init() {
        let s = Preferences.settings
        settings = s
        isEnabled = Preferences.isEnabled
        parameters = EQParameters(s)
        monitor.onChange = { [weak self] in self?.reconcile() }
        monitor.start()

        let nc = NSWorkspace.shared.notificationCenter
        // Sleep: release the hardware cleanly and stay idle until wake, even if a hardware event
        // arrives in between. Wake: rebuild from scratch (the HAL may have re-enumerated the
        // display while asleep), with a fresh permission check.
        observers.append(nc.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.isAsleep = true
                self.reconcile()
            }
        })
        observers.append(nc.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.isAsleep = false
                self.rearm()
                self.reconcile()
            }
        })
        // Fast user switching: the engine runs only while this session is the active one, like
        // sleep. The instance lock (AppInstance) is per user and cannot see other users' copies.
        observers.append(nc.addObserver(forName: NSWorkspace.sessionDidResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.isSessionInactive = true
                self.reconcile()
            }
        })
        observers.append(nc.addObserver(forName: NSWorkspace.sessionDidBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.isSessionInactive = false
                self.rearm()
                self.reconcile()
            }
        })
        reconcile()
    }

    func resetToDefaults() { settings = .defaults }

    /// Retry after an error (also happens automatically on the next hardware event).
    func retry() {
        stopEngine()
        cancelCheck()
        rearm()
        reconcile()
    }

    /// Forgets past failures and the last permission result: the next engine start checks
    /// afresh and gets one automatic retry again.
    private func rearm() {
        permission = .unknown
        failedConfiguration = nil
        autoRetryUsed = false
        retryTask?.cancel()
        retryTask = nil
    }

    func openPrivacySettings() {
        let pane = "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AudioCapture"
        if let url = URL(string: pane) { NSWorkspace.shared.open(url) }
    }

    func shutdown() {
        isShutDown = true
        cancelCheck()
        retryTask?.cancel()
        stopEngine()
        monitor.stop()
    }

    /// Validation builds only: launching with `-TargetDeviceUID <uid>` makes the engine treat
    /// another output as if it were the Studio Display. Not exposed in the UI.
    private func isTarget(_ device: OutputDevice) -> Bool {
        if let override = Preferences.targetDeviceUIDOverride { return device.uid == override }
        return StudioDisplayMatcher.isStudioDisplaySpeakers(device)
    }

    func reconcile() {
        update()
        if status != loggedStatus {
            loggedStatus = status
            log.info("status: \(String(describing: self.status), privacy: .public) output=\(self.currentOutput?.uid ?? "-", privacy: .private(mask: .hash))")
        }
    }

    private func update() {
        guard !isShutDown else { return }
        let devices = ((try? HAL.allDevices()) ?? []).compactMap(OutputDevice.read).filter { $0.outputChannels > 0 }
        let defaultID = try? HAL.defaultOutputDevice()
        currentOutput = devices.first { $0.id == defaultID }
        displaySpeakers = devices.first(where: isTarget)
        monitor.watch(device: currentOutput?.id)

        guard !isAsleep, !isSessionInactive else { cancelCheck(); stopEngine(); return }
        guard isEnabled else { cancelCheck(); stopEngine(); status = .disabled; return }
        guard let output = currentOutput, isTarget(output) else {
            cancelCheck()
            stopEngine()
            status = displaySpeakers == nil ? .noDisplay : .otherOutput
            // Leaving the display re-arms everything: the permission is checked again (the user
            // may have changed it meanwhile) and a failed configuration may be retried.
            rearm()
            return
        }
        if let engine, engine.device.id == output.id, engine.device.uid == output.uid,
           engine.sampleRate == output.nominalSampleRate,
           engine.device.outputChannels == output.outputChannels, engine.isAlive {
            status = .active
            return
        }
        stopEngine()

        let configuration = "\(output.uid)@\(output.nominalSampleRate)/\(output.outputChannels)"
        if let failed = failedConfiguration {
            if failed == configuration { status = .error(failureMessage); return }  // no retry loop
            failedConfiguration = nil  // the hardware changed: try again
        }

        // Never mute anything before capture is known to work (see CaptureCheck).
        if permission == .checking, checkedOutputUID != output.uid { cancelCheck() }
        switch permission {
        case .granted: break
        case .denied: status = .permissionDenied; return
        case .checking: status = .checkingPermission; return
        case .unknown: startCheck(on: output, configuration: configuration); return
        }
        permission = .unknown  // consumed: the next engine start checks again

        do {
            #if VALIDATION
            if Preferences.simulateEngineFailure {
                throw CoreAudioError(status: -1, operation: "simulated engine start (validation)")
            }
            #endif
            let e = try TapEngine(device: output, parameters: parameters)
            engine = e
            status = .active
            autoRetryUsed = false
            log.info("active on \(output.description, privacy: .private(mask: .hash)) rate=\(output.nominalSampleRate) channels=\(output.outputChannels)")
        } catch {
            log.error("engine failed: \(String(describing: error), privacy: .public)")
            recordFailure(String(describing: error), configuration: configuration)
        }
    }

    /// Shows the failure and blocks this configuration (sound untouched: nothing is muted). One
    /// automatic retry 3 s later lets a display still waking up, or briefly busy, recover without
    /// a click; after that only a change of configuration, a wake or Retry tries again.
    private func recordFailure(_ message: String, configuration: String) {
        failedConfiguration = configuration
        failureMessage = message
        status = .error(message)
        guard !autoRetryUsed else { return }
        autoRetryUsed = true
        retryTask?.cancel()
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard let self, !Task.isCancelled, self.failedConfiguration == configuration else { return }
            log.info("automatic retry after a failure")
            self.retryTask = nil
            self.failedConfiguration = nil
            self.reconcile()
        }
    }

    private func startCheck(on output: OutputDevice, configuration: String) {
        permission = .checking
        status = .checkingPermission
        checkGeneration += 1
        let generation = checkGeneration
        checkedOutputUID = output.uid
        checkTask = Task { [weak self] in
            let result: Result<CaptureCheck.Outcome, any Error>
            do { result = .success(try await CaptureCheck.run(device: output)) }
            catch { result = .failure(error) }
            guard let self, generation == self.checkGeneration, !Task.isCancelled else { return }
            self.checkTask = nil
            switch result {
            case .success(let outcome):
                log.info("capture permission: \(String(describing: outcome), privacy: .public)")
                self.permission = outcome == .granted ? .granted : .denied
            case .failure(let error):
                // Not a refusal: the check could not conclude (output stopped, timeout). Handled
                // like an engine failure, so a configuration change or the automatic retry
                // checks again.
                log.error("capture check failed: \(String(describing: error), privacy: .public)")
                self.permission = .unknown
                self.recordFailure(String(describing: error), configuration: configuration)
            }
            self.reconcile()
        }
    }

    /// Abandons a running check (its result will be ignored) so a new context checks afresh.
    private func cancelCheck() {
        guard let task = checkTask else { return }
        task.cancel()
        checkTask = nil
        checkGeneration += 1
        checkedOutputUID = nil
        if permission == .checking { permission = .unknown }
    }

    private func stopEngine() {
        engine?.stop()
        engine = nil
    }
}

/// UserDefaults-backed preferences (sandbox container; no other storage).
enum Preferences {
    private static var store: UserDefaults { .standard }

    static var settings: EQSettings {
        get {
            guard let data = store.data(forKey: "EQSettings"),
                  let s = try? JSONDecoder().decode(EQSettings.self, from: data) else { return .defaults }
            return s.clamped
        }
        set { store.set(try? JSONEncoder().encode(newValue), forKey: "EQSettings") }
    }

    static var isEnabled: Bool {
        get { store.object(forKey: "Enabled") as? Bool ?? true }
        set { store.set(newValue, forKey: "Enabled") }
    }

    #if VALIDATION
    /// Validation overrides, honoured only in validation builds and only from the command line
    /// (`-SimulateEngineFailure YES`, `-TargetDeviceUID <uid>`): a value left in the persistent
    /// preferences is ignored, so it can never silently change which output gets equalized.
    private static var arguments: [String: Any] { store.volatileDomain(forName: UserDefaults.argumentDomain) }
    static var simulateEngineFailure: Bool { (arguments["SimulateEngineFailure"] as? String).map { $0 == "YES" || $0 == "1" } ?? false }
    static var targetDeviceUIDOverride: String? {
        (arguments["TargetDeviceUID"] as? String).flatMap { $0.isEmpty ? nil : $0 }
    }
    #else
    static var targetDeviceUIDOverride: String? { nil }
    #endif
}
