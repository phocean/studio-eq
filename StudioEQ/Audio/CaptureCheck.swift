// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Jean-Christophe Baptiste

import CoreAudio
import Foundation
import Synchronization
import os

private let log = Logger(subsystem: "com.jcbaptiste.StudioEQ", category: "permission")

/// Verifies, before anything is muted, that macOS really lets this process capture audio
/// ("Screen & System Audio Recording" privacy permission).
///
/// Why: measured on macOS 27.3, when the permission is refused a process tap still runs and
/// still mutes the tapped apps, but delivers only zeros, so the Studio Display goes silent.
/// There is no public API to read this permission, so it is tested directly:
///  • a private, *unmuted* tap captures only Studio EQ's own output;
///  • an IOProc opened directly on the target device plays an inaudible test pattern (±1e-6,
///    i.e. −120 dBFS, below the 24-bit noise floor of the display). It must be a separate
///    IOProc: a tap only runs while its source plays, so the listener cannot be the source;
///  • a private aggregate holding only that tap listens. If it hears the pattern, capture
///    works; if it runs ~0.5 s hearing only zeros, capture is refused. While the system
///    permission prompt is pending the tap does not deliver, so the check waits for the answer.
/// Nothing is muted at any point during the check.
enum CaptureCheck {
    enum Outcome: Equatable { case granted, denied }

    @MainActor
    static func run(device: OutputDevice, timeout: Duration = .seconds(120)) async throws -> Outcome {
        let own = try HAL.processObject(pid: getpid())
        guard own != kAudioObjectUnknown else { throw CoreAudioError(status: -1, operation: "own process object") }

        let desc = CATapDescription(stereoMixdownOfProcesses: [own])
        desc.uuid = UUID()
        desc.name = "Studio EQ permission check"
        desc.isPrivate = true
        desc.muteBehavior = .unmuted
        var tap = AudioObjectID(kAudioObjectUnknown)
        try check(AudioHardwareCreateProcessTap(desc, &tap), "create check tap")
        defer { AudioHardwareDestroyProcessTap(tap) }

        let aggDesc: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Studio EQ check",
            kAudioAggregateDeviceUIDKey: "com.jcbaptiste.StudioEQ.check.\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: device.uid,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: device.uid]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: desc.uuid.uuidString]],
        ]
        var agg = AudioObjectID(kAudioObjectUnknown)
        try check(AudioHardwareCreateAggregateDevice(aggDesc as CFDictionary, &agg), "create check aggregate")
        defer { AudioHardwareDestroyAggregateDevice(agg) }
        let inputs = (try? HAL.array(agg, kAudioDevicePropertyStreams, kAudioObjectPropertyScopeInput, of: AudioObjectID.self).count) ?? 1

        let probe = Probe()

        // Source: the test pattern, played straight to the device by this process.
        var sourceID: AudioDeviceIOProcID?
        try check(AudioDeviceCreateIOProcIDWithBlock(&sourceID, device.id, nil, Probe.sourceBlock(probe)), "create check source")
        guard let sourceID else { throw CoreAudioError(status: -1, operation: "create check source") }
        defer { AudioDeviceDestroyIOProcID(device.id, sourceID) }
        try check(AudioDeviceStart(device.id, sourceID), "start check source")
        defer { AudioDeviceStop(device.id, sourceID) }

        // Listener: the aggregate reading the self-tap.
        var procID: AudioDeviceIOProcID?
        try check(AudioDeviceCreateIOProcIDWithBlock(&procID, agg, nil, Probe.ioBlock(probe, tapIndex: max(inputs - 1, 0))),
                  "create check IOProc")
        guard let procID else { throw CoreAudioError(status: -1, operation: "create check IOProc") }
        defer { AudioDeviceDestroyIOProcID(agg, procID) }
        try check(AudioDeviceStart(agg, procID), "start check")
        defer { AudioDeviceStop(agg, procID) }

        let deadline = ContinuousClock.now + timeout
        var ticks = 0
        var lastSourceCycles = 0
        var lastSourceProgress = ContinuousClock.now
        while ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))  // throws on cancellation; defers clean up
            ticks += 1
            // The source runs whatever the permission says. If it stops, the device is gone
            // (unplugged, asleep): fail now rather than waiting for the timeout.
            let source = probe.sourceCycles.load(ordering: .relaxed)
            if source != lastSourceCycles {
                lastSourceCycles = source
                lastSourceProgress = .now
            } else if ContinuousClock.now - lastSourceProgress > .seconds(2) {
                throw CoreAudioError(status: -1, operation: "the output stopped during the permission check")
            }
            if ticks % 20 == 0 {
                log.info("check: listening cycles=\(probe.cycles.load(ordering: .relaxed)) heard=\(probe.heard.load(ordering: .relaxed)) source cycles=\(probe.sourceCycles.load(ordering: .relaxed))")
            }
            if probe.heard.load(ordering: .relaxed) > 0 { return .granted }
            if probe.cycles.load(ordering: .relaxed) > 100 { return .denied }
        }
        throw CoreAudioError(status: -1, operation: "audio capture permission check timed out")
    }

    private final class Probe: Sendable {
        let cycles = Atomic<Int>(0)
        let heard = Atomic<Int>(0)
        let sourceCycles = Atomic<Int>(0)

        /// Built outside any actor so the closure carries no main-actor isolation (Swift 6 would
        /// trap when Core Audio calls it on the IO thread).
        nonisolated static func ioBlock(_ probe: Probe, tapIndex: Int) -> AudioDeviceIOBlock {
            { _, input, _, output, _ in
                let ins = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
                if tapIndex < ins.count, let data = ins[tapIndex].mData {
                    let n = Int(ins[tapIndex].mDataByteSize) / MemoryLayout<Float>.size
                    let p = data.assumingMemoryBound(to: Float.self)
                    for i in 0..<n where p[i] != 0 { probe.heard.add(1, ordering: .relaxed); break }
                    probe.cycles.add(1, ordering: .relaxed)
                }
                for buf in UnsafeMutableAudioBufferListPointer(output) {
                    if let d = buf.mData { memset(d, 0, Int(buf.mDataByteSize)) }
                }
            }
        }

        nonisolated static func sourceBlock(_ probe: Probe) -> AudioDeviceIOBlock {
            { _, _, _, output, _ in
                probe.sourceCycles.add(1, ordering: .relaxed)
                for buf in UnsafeMutableAudioBufferListPointer(output) {
                    guard let data = buf.mData else { continue }
                    // Sign alternates per frame (a −120 dBFS tone at half the sample rate on every
                    // channel), not per interleaved sample, which would give each channel a constant.
                    let channels = max(Int(buf.mNumberChannels), 1)
                    let frames = Int(buf.mDataByteSize) / (channels * MemoryLayout<Float>.size)
                    let p = data.assumingMemoryBound(to: Float.self)
                    for f in 0..<frames {
                        let v: Float = (f & 1) == 0 ? 1e-6 : -1e-6
                        for c in 0..<channels { p[f * channels + c] = v }
                    }
                }
            }
        }
    }
}
