// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright © 2026 Jean-Christophe Baptiste

import CoreAudio
import Foundation

/// Event-driven watch of the audio hardware (no polling).
///
/// Fires `onChange` on the main queue, coalesced over 150 ms, whenever:
///  • the system default output device changes,
///  • a device appears or disappears (display plugged / unplugged, AirPods connect…),
///  • the watched device changes sample rate, stream layout, or dies.
@MainActor
final class DeviceMonitor {
    var onChange: (() -> Void)?

    private let queue = DispatchQueue.main
    private var systemListeners: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private var deviceListeners: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private var pending: DispatchWorkItem?

    func start() {
        guard systemListeners.isEmpty else { return }
        for selector in [kAudioHardwarePropertyDefaultOutputDevice, kAudioHardwarePropertyDevices] {
            var addr = HAL.address(selector)
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                MainActor.assumeIsolated { self?.schedule() }
            }
            if AudioObjectAddPropertyListenerBlock(.system, &addr, queue, block) == noErr {
                systemListeners.append((addr, block))
            }
        }
    }

    /// Watches format/liveness of the device the engine is (or would be) running on.
    func watch(device: AudioObjectID?) {
        for (id, addr, block) in deviceListeners {
            var a = addr
            AudioObjectRemovePropertyListenerBlock(id, &a, queue, block)
        }
        deviceListeners.removeAll()
        guard let device, device != kAudioObjectUnknown else { return }
        let watched: [(AudioObjectPropertySelector, AudioObjectPropertyScope)] = [
            (kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal),
            (kAudioDevicePropertyDeviceIsAlive, kAudioObjectPropertyScopeGlobal),
            (kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeOutput),
        ]
        for (selector, scope) in watched {
            var addr = HAL.address(selector, scope)
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                MainActor.assumeIsolated { self?.schedule() }
            }
            if AudioObjectAddPropertyListenerBlock(device, &addr, queue, block) == noErr {
                deviceListeners.append((device, addr, block))
            }
        }
    }

    func stop() {
        // A change already coalesced must not call back after the stop (it could rebuild the
        // engine while the app quits).
        pending?.cancel()
        pending = nil
        onChange = nil
        watch(device: nil)
        for (addr, block) in systemListeners {
            var a = addr
            AudioObjectRemovePropertyListenerBlock(.system, &a, queue, block)
        }
        systemListeners.removeAll()
    }

    private func schedule() {
        pending?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.onChange?() }
        pending = item
        queue.asyncAfter(deadline: .now() + .milliseconds(150), execute: item)
    }
}
