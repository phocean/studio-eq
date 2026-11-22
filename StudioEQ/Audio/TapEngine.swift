// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Jean-Christophe Baptiste

import CoreAudio
import Foundation
import os

private let log = Logger(subsystem: "com.jcbaptiste.StudioEQ", category: "engine")

/// The audio path, without any virtual driver:
///
///   apps ──► [Studio Display stream 0] ──► process tap (muted while read, excludes Studio EQ)
///                                                    │
///                     private aggregate device = { tap input ; Studio Display output }
///                                                    │ IOProc: EQProcessor
///                                                    ▼
///                                       Studio Display speakers
///
/// • The tap only captures audio *destined to the Studio Display* (device + stream tap), so
///   audio sent to any other device is never touched.
/// • `mutedWhenTapped`: the originals are silenced only while the tap is being read. If this
///   process stops or crashes, macOS un-mutes them immediately — failure is "plain sound",
///   never silence.
/// • Studio EQ's own process is excluded from the tap, so its output cannot loop back.
/// • Tap and aggregate are private to this process and vanish with it.
final class TapEngine {
    let device: OutputDevice
    private(set) var processor: EQProcessor?
    private(set) var sampleRate: Double = 0
    private(set) var bufferFrames: UInt32 = 0

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?

    /// IO buffer size requested on the aggregate: 256 frames ≈ 5.3 ms at 48 kHz.
    static let preferredBufferFrames: UInt32 = 256
    /// Sample rates the engine accepts (NaN and infinities fall outside the range).
    static let supportedSampleRates: ClosedRange<Double> = 8_000...384_000

    init(device: OutputDevice, parameters: EQParameters) throws {
        self.device = device
        Self.allowIdleSleep()
        do {
            let (proc, tapIndex, inputCount) = try build(parameters: parameters)
            try start(processor: proc, tapBufferIndex: tapIndex, inputStreamCount: inputCount)
        } catch {
            teardown()
            throw error
        }
    }

    /// Core Audio normally takes a `PreventUserIdleSystemSleep` power assertion for any running
    /// IO. Ours only follows other apps' playback — they hold their own assertion while they
    /// actually play — so the always-running EQ path must not keep the Mac awake on its own.
    private static func allowIdleSleep() {
        try? HAL.set(.system, kAudioHardwarePropertySleepingIsAllowed, UInt32(1))
    }

    private func build(parameters: EQParameters) throws -> (EQProcessor, Int, Int) {
        // 1. Tap: everything sent to stream 0 of the Studio Display, except our own output.
        // Without our own process object the tap could not exclude us, and our output would
        // loop back into it: refuse to start rather than risk a feedback loop.
        let own = try HAL.processObject(pid: getpid())
        guard own != kAudioObjectUnknown else { throw CoreAudioError(status: -1, operation: "own process object") }
        let desc = CATapDescription(excludingProcesses: [own], deviceUID: device.uid, stream: 0)
        desc.name = "Studio EQ"
        desc.uuid = UUID()
        desc.isPrivate = true
        desc.muteBehavior = .mutedWhenTapped
        try check(AudioHardwareCreateProcessTap(desc, &tapID), "create process tap")

        var tapFormat = try HAL.value(tapID, kAudioTapPropertyFormat, initial: AudioStreamBasicDescription())
        // The processor expects one interleaved Float32 buffer for the tap (the last input
        // stream), with a channel count it can handle. Anything else: refuse to start, so the
        // originals are never muted for a stream that would come out silent.
        guard tapFormat.mFormatID == kAudioFormatLinearPCM,
              tapFormat.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              tapFormat.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0,
              tapFormat.mBitsPerChannel == 32,
              (1...UInt32(EQProcessor.maxChannels)).contains(tapFormat.mChannelsPerFrame) else {
            throw CoreAudioError(status: -1, operation: "unsupported tap format \(tapFormat)")
        }

        // 2. Private aggregate: the display as clock master and output, the tap as input.
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Studio EQ",
            kAudioAggregateDeviceUIDKey: "com.jcbaptiste.StudioEQ.aggregate.\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: device.uid,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: device.uid]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: desc.uuid.uuidString,
                kAudioSubTapDriftCompensationKey: true,
            ]],
        ]
        try check(AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggregateID), "create aggregate device")

        // 3. Low-latency buffer, within the device's allowed range.
        if let range = try? HAL.value(aggregateID, kAudioDevicePropertyBufferFrameSizeRange, initial: AudioValueRange()) {
            let frames = UInt32(Double(Self.preferredBufferFrames).clamped(to: range.mMinimum...range.mMaximum))
            try? HAL.set(aggregateID, kAudioDevicePropertyBufferFrameSize, frames)
        }
        bufferFrames = (try? HAL.value(aggregateID, kAudioDevicePropertyBufferFrameSize, initial: UInt32(0))) ?? 0
        sampleRate = try HAL.value(aggregateID, kAudioDevicePropertyNominalSampleRate, initial: Float64(0))
        // A zero or garbage rate would build filters that output only silence while the tap
        // mutes the originals: refuse to start instead (sound stays untouched).
        guard Self.supportedSampleRates.contains(sampleRate) else {
            throw CoreAudioError(status: -1, operation: "unsupported sample rate \(sampleRate)")
        }
        tapFormat = (try? HAL.value(tapID, kAudioTapPropertyFormat, initial: AudioStreamBasicDescription())) ?? tapFormat

        // 4. Find the tap among the aggregate's input streams (taps come after sub-device inputs)
        //    and disable every other input stream, so no microphone is ever opened.
        let inputStreams = (try? HAL.array(aggregateID, kAudioDevicePropertyStreams, kAudioObjectPropertyScopeInput,
                                            of: AudioObjectID.self)) ?? []
        guard !inputStreams.isEmpty else { throw CoreAudioError(status: -1, operation: "aggregate has no tap input") }
        let tapIndex = inputStreams.count - 1

        let proc = EQProcessor(sampleRate: sampleRate, parameters: parameters)
        processor = proc
        log.info("engine built: device=\(self.device.description, privacy: .private(mask: .hash)) rate=\(self.sampleRate) buffer=\(self.bufferFrames) tapFormat=\(tapFormat.mChannelsPerFrame)ch@\(tapFormat.mSampleRate) inputs=\(inputStreams.count)")
        return (proc, tapIndex, inputStreams.count)
    }

    private func start(processor proc: EQProcessor, tapBufferIndex: Int, inputStreamCount: Int) throws {
        try check(AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, nil) { _, inInput, _, outOutput, _ in
            proc.process(input: inInput, tapBufferIndex: tapBufferIndex, output: outOutput)
        }, "create IOProc")
        if inputStreamCount > 1 { try enableOnlyInputStream(tapBufferIndex, of: inputStreamCount) }
        try check(AudioDeviceStart(aggregateID, ioProcID), "start aggregate device")
    }

    /// kAudioDevicePropertyIOProcStreamUsage takes a variable-length C struct:
    /// { void *mIOProc; UInt32 mNumberStreams; UInt32 mStreamIsOn[mNumberStreams]; }.
    private func enableOnlyInputStream(_ keep: Int, of count: Int) throws {
        guard let ioProcID else { return }
        let size = MemoryLayout<UnsafeMutableRawPointer>.size + 4 + 4 * count
        let raw = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 8)
        defer { raw.deallocate() }
        raw.storeBytes(of: unsafeBitCast(ioProcID, to: UnsafeMutableRawPointer.self), as: UnsafeMutableRawPointer.self)
        raw.storeBytes(of: UInt32(count), toByteOffset: 8, as: UInt32.self)
        for i in 0..<count { raw.storeBytes(of: UInt32(i == keep ? 1 : 0), toByteOffset: 12 + 4 * i, as: UInt32.self) }
        var addr = HAL.address(kAudioDevicePropertyIOProcStreamUsage, kAudioObjectPropertyScopeInput)
        try check(AudioObjectSetPropertyData(aggregateID, &addr, 0, nil, UInt32(size), raw), "set input stream usage")
    }

    var isAlive: Bool {
        guard aggregateID != kAudioObjectUnknown else { return false }
        let alive = (try? HAL.value(aggregateID, kAudioDevicePropertyDeviceIsAlive, initial: UInt32(0))) ?? 0
        return alive != 0
    }

    var latencyDescription: String {
        guard sampleRate > 0 else { return "—" }
        let safety = (try? HAL.value(aggregateID, kAudioDevicePropertySafetyOffset, kAudioObjectPropertyScopeOutput, initial: UInt32(0))) ?? 0
        let lat = (try? HAL.value(aggregateID, kAudioDevicePropertyLatency, kAudioObjectPropertyScopeOutput, initial: UInt32(0))) ?? 0
        let ms = Double(bufferFrames + safety + lat) / sampleRate * 1000
        return String(format: "%.1f ms", ms)
    }

    func stop() { teardown() }

    deinit { teardown() }

    private func teardown() {
        if aggregateID != kAudioObjectUnknown {
            if let ioProcID {
                AudioDeviceStop(aggregateID, ioProcID)
                AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
            // IO stopped: the count is final. Each reset silenced one channel for one IO cycle.
            if let resets = processor?.filterResets.load(ordering: .relaxed), resets > 0 {
                log.error("\(resets) filter resets: an app sent NaN or infinite samples")
            }
        }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        ioProcID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
    }
}
