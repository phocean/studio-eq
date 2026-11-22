// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright © 2026 Jean-Christophe Baptiste

#if VALIDATION
// Validation tools: compiled only into validation builds (Debug, or Release built with
// SWIFT_ACTIVE_COMPILATION_CONDITIONS=VALIDATION), never into the distributed app, because
// they drive the real engine on an arbitrary output (and --ab-test silences it on purpose).

import AVFoundation
import CoreAudio
import Foundation
import Synchronization

/// End-to-end validation run from the command line (no UI):
///
///   open -W -a StudioEQ --args --selftest [--device <uid>]
///   open -W -a StudioEQ --args --list-devices
///
/// The report is written to `<app temporary directory>/StudioEQ-selftest.txt`.
///
/// The self-test proves, digitally, that the EQ really is applied to another process's sound
/// on the real output path:
///  1. plays a multi-tone test file with `afplay` (a separate process) on the target device;
///  2. measures afplay's own output with an unmuted measurement tap  → reference spectrum;
///  3. starts the real TapEngine, then measures what *Studio EQ* sends to the device
///     with a second tap on its own process                                → processed spectrum;
///  4. compares processed − reference with the theoretical filter response at each tone.
@MainActor
enum SelfTest {
    static func runIfRequested() -> Bool {
        let args = CommandLine.arguments
        if args.contains("--list-devices") {
            finish(report: deviceReport())
            return true
        }
        if args.contains("--ab-test") || args.contains("--permission-probe"), !AppInstance.acquireInstanceLock() {
            finish(report: "RESULT: FAIL — quit the running Studio EQ first")
            return true
        }
        if args.contains("--ab-test") {
            var uid: String?
            if let i = args.firstIndex(of: "--device"), i + 1 < args.count { uid = args[i + 1] }
            Task { @MainActor in finish(report: await abTest(deviceUID: uid)) }
            return true
        }
        if args.contains("--permission-probe") {
            var uid: String?
            if let i = args.firstIndex(of: "--device"), i + 1 < args.count { uid = args[i + 1] }
            Task { @MainActor in finish(report: await permissionProbe(deviceUID: uid)) }
            return true
        }
        guard args.contains("--selftest") else { return false }
        // Two engines on the same output would chain (each muting the other's output).
        if !AppInstance.acquireInstanceLock() {
            finish(report: "RESULT: FAIL — quit the running Studio EQ first")
            return true
        }
        var uid: String?
        if let i = args.firstIndex(of: "--device"), i + 1 < args.count { uid = args[i + 1] }
        Task { @MainActor in
            let report = await run(deviceUID: uid)
            finish(report: report)
        }
        return true
    }

    static let reportURL = FileManager.default.temporaryDirectory.appendingPathComponent("StudioEQ-selftest.txt")

    private static func finish(report: String) {
        for name in ["studioeq-tones.wav", "studioeq-ab.wav"] {
            try? FileManager.default.removeItem(at: FileManager.default.temporaryDirectory.appendingPathComponent(name))
        }
        try? report.write(to: reportURL, atomically: true, encoding: .utf8)
        print(report)
        print("report: \(reportURL.path)")
        exit(report.contains("RESULT: PASS") || !report.contains("RESULT:") ? 0 : 1)
    }

    static func deviceReport() -> String {
        var lines = ["Output devices:"]
        let defaultID = try? HAL.defaultOutputDevice()
        for d in ((try? HAL.allDevices()) ?? []).compactMap(OutputDevice.read) where d.outputChannels > 0 {
            let tags = [d.id == defaultID ? "DEFAULT" : nil,
                        StudioDisplayMatcher.isStudioDisplaySpeakers(d) ? "STUDIO-DISPLAY" : nil].compactMap { $0 }
            lines.append("  \(d.description) \(tags.joined(separator: " "))")
        }
        return lines.joined(separator: "\n")
    }

    static let tones: [Double] = [40, 80, 150, 300, 700, 1_500, 3_000, 6_000, 10_000, 16_000]

    static func run(deviceUID: String?) async -> String {
        var out = [deviceReport(), ""]
        func fail(_ msg: String) -> String { (out + ["RESULT: FAIL — \(msg)"]).joined(separator: "\n") }

        let devices = ((try? HAL.allDevices()) ?? []).compactMap(OutputDevice.read)
        guard let target = devices.first(where: { deviceUID != nil ? $0.uid == deviceUID : StudioDisplayMatcher.isStudioDisplaySpeakers($0) })
        else { return fail("target device not found") }
        guard target.id == (try? HAL.defaultOutputDevice()) else {
            return fail("select \(target.name) as the system output before running the self-test")
        }
        out.append("Target: \(target.description)")

        // Test signal: ten tones at -26 dBFS each, 8 s, at the device rate.
        let rate = target.nominalSampleRate > 0 ? target.nominalSampleRate : 48_000
        let wav = FileManager.default.temporaryDirectory.appendingPathComponent("studioeq-tones.wav")
        do { try writeTones(to: wav, sampleRate: rate, seconds: 8) } catch { return fail("cannot write test file: \(error)") }

        let player = Process()
        player.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
        player.arguments = [wav.path]
        do { try player.run() } catch { return fail("cannot launch afplay: \(error)") }
        defer { if player.isRunning { player.terminate() } }

        var playerObject = AudioObjectID(kAudioObjectUnknown)
        for _ in 0..<40 where playerObject == kAudioObjectUnknown {
            try? await Task.sleep(for: .milliseconds(50))
            playerObject = (try? HAL.processObject(pid: player.processIdentifier)) ?? 0
        }
        guard playerObject != kAudioObjectUnknown else { return fail("afplay process object not found") }

        // 1. Reference: what afplay sends, before Studio EQ is involved.
        let reference: [Float]
        do { reference = try await MeasurementTap.capture(processes: [playerObject], device: target, seconds: 1.0, settle: 0.6) }
        catch { return fail("reference capture: \(error) — is \"System Audio Recording\" allowed for Studio EQ?") }

        // 2. Processed: run the real engine with the default settings and capture its output.
        let settings = EQSettings.defaults
        let parameters = EQParameters(settings)
        let engine: TapEngine
        do { engine = try TapEngine(device: target, parameters: parameters) } catch { return fail("engine: \(error)") }
        out.append("Engine: \(Int(engine.sampleRate)) Hz, buffer \(engine.bufferFrames) frames, output latency ≈ \(engine.latencyDescription)")
        let own = (try? HAL.processObject(pid: getpid())) ?? 0
        let processed: [Float]
        do { processed = try await MeasurementTap.capture(processes: [own], device: target, seconds: 1.0, settle: 0.5) }
        catch { engine.stop(); return fail("processed capture: \(error)") }
        let added = await measureAddedLatency(player: playerObject, own: own, device: target, rate: rate)
        let cpu = processCPUSeconds()
        try? await Task.sleep(for: .seconds(2))
        let cpuPercent = (processCPUSeconds() - cpu) / 2 * 100
        engine.stop()

        // 3. Compare.
        let preamp = EQDesign.preampDB
        out.append(String(format: "Settings: bass %+.1f, mid %+.1f, treble %+.1f dB, preamp %+.2f dB", settings.bass, settings.mid, settings.treble, preamp))
        out.append("  freq Hz   ref dBFS   out dBFS   measured   expected   error")
        var errors: [Double] = []
        var silent = false
        for f in tones {
            let r = level(reference, frequency: f, sampleRate: rate)
            let p = level(processed, frequency: f, sampleRate: rate)
            let expected = EQDesign.responseDB(settings, at: f, sampleRate: rate) + preamp
            let measured = p - r
            let err = measured - expected
            if r < -80 { silent = true }
            errors.append(err)
            out.append(String(format: "  %7.0f   %8.2f   %8.2f   %+8.2f   %+8.2f   %+6.2f", f, r, p, measured, expected, err))
        }
        out.append(String(format: "Studio EQ process CPU while processing: %.2f %% of one core", cpuPercent))
        out.append(added.map { String(format: "Added latency (original stream → processed stream, cross-correlation): %.1f ms", $0) }
                   ?? "Added latency: not measured")
        if silent { return fail("reference is silent — audio capture permission missing or tones not played") }
        // Shape error: deviation once the mean offset is removed (the reference capture level can
        // vary by a few tenths of a dB between runs); gain offset: that mean, reported separately.
        let offset = errors.reduce(0, +) / Double(errors.count)
        let shape = errors.map { abs($0 - offset) }.max() ?? 0
        let verdict = shape < 0.5 && abs(offset) < 1.0 ? "PASS" : "FAIL"
        out.append(String(format: "RESULT: %@ (curve shape error max %.2f dB, overall gain offset %+.2f dB)", verdict, shape, offset))
        return out.joined(separator: "\n")
    }

    /// Diagnostic for the "audio capture not allowed" case: plays tones for 20 s, starts the real
    /// engine after 3 s and reports, every second, how many IO cycles ran and how many carried
    /// signal. A human listens to tell whether the sound kept playing.
    static func permissionProbe(deviceUID: String?) async -> String {
        var out = [deviceReport(), ""]
        let devices = ((try? HAL.allDevices()) ?? []).compactMap(OutputDevice.read)
        guard let target = devices.first(where: { deviceUID != nil ? $0.uid == deviceUID : StudioDisplayMatcher.isStudioDisplaySpeakers($0) })
        else { return "RESULT: FAIL — target device not found" }
        let rate = target.nominalSampleRate > 0 ? target.nominalSampleRate : 48_000
        let wav = FileManager.default.temporaryDirectory.appendingPathComponent("studioeq-tones.wav")
        try? writeTones(to: wav, sampleRate: rate, seconds: 20)
        let player = Process()
        player.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
        player.arguments = [wav.path]
        try? player.run()
        defer { if player.isRunning { player.terminate() } }
        try? await Task.sleep(for: .seconds(3))
        let engine: TapEngine
        do { engine = try TapEngine(device: target, parameters: EQParameters(.defaults)) }
        catch { return (out + ["engine failed to start: \(error)"]).joined(separator: "\n") }
        out.append("t=3s engine started")
        for t in 4...20 {
            try? await Task.sleep(for: .seconds(1))
            let p = engine.processor
            out.append("t=\(t)s cycles=\(p?.cycles.load(ordering: .relaxed) ?? 0) withSignal=\(p?.cyclesWithSignal.load(ordering: .relaxed) ?? 0)")
        }
        engine.stop()
        return out.joined(separator: "\n")
    }

    /// Listening test for double playback: a tone plays through the engine; every 2 s the
    /// engine's output is silenced. If the original stream is properly muted, the tone stops
    /// completely every other 2 s. If it were also reaching the speakers, it would never stop.
    static func abTest(deviceUID: String?) async -> String {
        let devices = ((try? HAL.allDevices()) ?? []).compactMap(OutputDevice.read)
        guard let target = devices.first(where: { deviceUID != nil ? $0.uid == deviceUID : StudioDisplayMatcher.isStudioDisplaySpeakers($0) }),
              target.id == (try? HAL.defaultOutputDevice())
        else { return "RESULT: FAIL — target must exist and be the selected output" }
        let rate = target.nominalSampleRate > 0 ? target.nominalSampleRate : 48_000
        let wav = FileManager.default.temporaryDirectory.appendingPathComponent("studioeq-ab.wav")
        do {
            let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
            let frames = AVAudioFrameCount(rate * 20)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
            buffer.frameLength = frames
            for ch in 0..<2 {
                let p = buffer.floatChannelData![ch]
                for i in 0..<Int(frames) { p[i] = 0.1 * Float(sin(2 * Double.pi * 440 * Double(i) / rate)) }
            }
            try AVAudioFile(forWriting: wav, settings: format.settings).write(from: buffer)
        } catch { return "RESULT: FAIL — \(error)" }
        let player = Process()
        player.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
        player.arguments = [wav.path]
        try? player.run()
        defer { if player.isRunning { player.terminate() } }
        try? await Task.sleep(for: .seconds(1))
        let engine: TapEngine
        do { engine = try TapEngine(device: target, parameters: EQParameters(.defaults)) } catch { return "RESULT: FAIL — \(error)" }
        var log = ["A/B on \(target.name): tone audible 2 s, then engine output silenced 2 s, ×4"]
        for i in 0..<8 {
            engine.processor?.silenceOutput.store(i % 2 == 1, ordering: .relaxed)
            log.append("t=\(1 + 2 * i)s \(i % 2 == 1 ? "SILENCED" : "audible")")
            try? await Task.sleep(for: .seconds(2))
        }
        engine.stop()
        return log.joined(separator: "\n")
    }

    /// Captures the original (afplay) and processed (Studio EQ) streams at the same time, aligns
    /// them on the host time of their first captured sample, then finds the residual delay by
    /// cross-correlation over 0–60 ms (the multi-tone signal repeats every 100 ms, so the peak is
    /// unique). The EQ's own group delay (< 1 ms above 100 Hz) is included in the result.
    static func measureAddedLatency(player: AudioObjectID, own: AudioObjectID, device: OutputDevice, rate: Double) async -> Double? {
        async let refCapture = MeasurementTap.captureTimed(processes: [player], device: device, seconds: 0.5, settle: 0.3)
        async let outCapture = MeasurementTap.captureTimed(processes: [own], device: device, seconds: 0.5, settle: 0.3)
        guard let ref = try? await refCapture, let out = try? await outCapture,
              ref.hostNanos > 0, out.hostNanos > 0 else { return nil }
        // Cross-correlate (left channel) over ±60 ms around the host-time alignment.
        let r = ref.samples.enumerated().filter { $0.offset % 2 == 0 }.map { Double($0.element) }
        let o = out.samples.enumerated().filter { $0.offset % 2 == 0 }.map { Double($0.element) }
        let offsetFrames = Int((Double(out.hostNanos) - Double(ref.hostNanos)) / 1e9 * rate)  // o[0] is at r[offsetFrames]
        var best = (lag: 0, score: -Double.infinity)
        let window = 4_096
        for lag in 0..<Int(0.060 * rate) {
            var sum = 0.0, n = 0
            for i in 0..<window {
                let ri = i + offsetFrames - lag   // original sample played `lag` frames before o[i]
                guard ri >= 0, ri < r.count, i < o.count else { continue }
                sum += r[ri] * o[i]; n += 1
            }
            if n > window / 2, sum > best.score { best = (lag, sum) }
        }
        return Double(best.lag) / rate * 1000
    }

    // MARK: - Signal helpers

    static func writeTones(to url: URL, sampleRate: Double, seconds: Double) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
        let frames = AVAudioFrameCount(sampleRate * seconds)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        let amp: Float = 0.05  // -26 dBFS per tone; peak of the sum stays below 0 dBFS
        for ch in 0..<2 {
            let p = buffer.floatChannelData![ch]
            for i in 0..<Int(frames) {
                var v: Float = 0
                for (k, f) in tones.enumerated() {
                    v += amp * Float(sin(2 * Double.pi * f * Double(i) / sampleRate + Double(k)))
                }
                p[i] = v
            }
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }

    /// Tone level in dBFS (Hann-windowed single-bin DFT on the left channel of interleaved stereo).
    static func level(_ interleaved: [Float], frequency: Double, sampleRate: Double) -> Double {
        let n = interleaved.count / 2
        guard n > 0 else { return -200 }
        var re = 0.0, im = 0.0, wsum = 0.0
        for i in 0..<n {
            let w = 0.5 - 0.5 * cos(2 * Double.pi * Double(i) / Double(n - 1))
            let x = Double(interleaved[2 * i]) * w
            let ph = 2 * Double.pi * frequency * Double(i) / sampleRate
            re += x * cos(ph); im -= x * sin(ph); wsum += w
        }
        let amplitude = 2 * sqrt(re * re + im * im) / wsum
        return 20 * log10(max(amplitude, 1e-10))
    }

    static func processCPUSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1e6
    }
}

/// Unmuted, private tap used only by the self-test to observe a process's output.
final class MeasurementTap: @unchecked Sendable {
    private let capacity: Int
    private let samples: UnsafeMutablePointer<Float>
    private let written = Atomic<Int>(0)
    private let recording = Atomic<Bool>(false)
    private let firstHostTime = Atomic<UInt64>(0)

    private init(capacity: Int) {
        self.capacity = capacity
        samples = .allocate(capacity: capacity)
        samples.initialize(repeating: 0, count: capacity)
    }
    deinit { samples.deallocate() }

    @MainActor
    static func capture(processes: [AudioObjectID], device: OutputDevice, seconds: Double, settle: Double) async throws -> [Float] {
        try await captureTimed(processes: processes, device: device, seconds: seconds, settle: settle).samples
    }

    /// Same as `capture`, plus the host time (ns) at which the first returned sample was captured.
    @MainActor
    static func captureTimed(processes: [AudioObjectID], device: OutputDevice, seconds: Double, settle: Double) async throws -> (samples: [Float], hostNanos: UInt64, rate: Double) {
        let desc = CATapDescription(stereoMixdownOfProcesses: processes)
        desc.uuid = UUID()
        desc.isPrivate = true
        desc.muteBehavior = .unmuted
        var tap = AudioObjectID(kAudioObjectUnknown)
        try check(AudioHardwareCreateProcessTap(desc, &tap), "create measurement tap")
        defer { AudioHardwareDestroyProcessTap(tap) }

        let aggDesc: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Studio EQ measurement",
            kAudioAggregateDeviceUIDKey: "com.jcbaptiste.StudioEQ.measure.\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: device.uid,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: device.uid]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: desc.uuid.uuidString, kAudioSubTapDriftCompensationKey: true]],
        ]
        var agg = AudioObjectID(kAudioObjectUnknown)
        try check(AudioHardwareCreateAggregateDevice(aggDesc as CFDictionary, &agg), "create measurement aggregate")
        defer { AudioHardwareDestroyAggregateDevice(agg) }
        let rate = (try? HAL.value(agg, kAudioDevicePropertyNominalSampleRate, initial: Float64(48_000))) ?? 48_000
        let inputs = (try? HAL.array(agg, kAudioDevicePropertyStreams, kAudioObjectPropertyScopeInput, of: AudioObjectID.self).count) ?? 1
        let tapIndex = max(inputs - 1, 0)

        let sink = MeasurementTap(capacity: Int(rate * seconds) * 2)
        var procID: AudioDeviceIOProcID?
        try check(AudioDeviceCreateIOProcIDWithBlock(&procID, agg, nil, ioBlock(sink: sink, tapIndex: tapIndex)),
                  "create measurement IOProc")
        guard let procID else { throw CoreAudioError(status: -1, operation: "measurement IOProc") }
        defer { AudioDeviceDestroyIOProcID(agg, procID) }
        try check(AudioDeviceStart(agg, procID), "start measurement")
        defer { AudioDeviceStop(agg, procID) }

        try await Task.sleep(for: .seconds(settle))
        sink.recording.store(true, ordering: .releasing)
        for _ in 0..<Int(seconds * 20 + 40) where sink.written.load(ordering: .acquiring) < sink.capacity {
            try await Task.sleep(for: .milliseconds(50))
        }
        let n = sink.written.load(ordering: .acquiring)
        guard n >= sink.capacity else { throw CoreAudioError(status: -1, operation: "measurement timed out (\(n)/\(sink.capacity) samples)") }
        return (Array(UnsafeBufferPointer(start: sink.samples, count: n)),
                AudioConvertHostTimeToNanos(sink.firstHostTime.load(ordering: .acquiring)), rate)
    }

    /// Built outside any actor: a closure formed in a @MainActor function inherits main-actor
    /// isolation, and Swift 6 traps when Core Audio calls it on its real-time IO thread.
    nonisolated private static func ioBlock(sink: MeasurementTap, tapIndex: Int) -> AudioDeviceIOBlock {
        { _, input, inputTime, output, _ in
            sink.receive(input, time: inputTime, tapIndex: tapIndex)
            for buf in UnsafeMutableAudioBufferListPointer(output) { if let d = buf.mData { memset(d, 0, Int(buf.mDataByteSize)) } }
        }
    }

    private func receive(_ input: UnsafePointer<AudioBufferList>, time: UnsafePointer<AudioTimeStamp>, tapIndex: Int) {
        guard recording.load(ordering: .acquiring) else { return }
        let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        guard tapIndex < list.count, let data = list[tapIndex].mData else { return }
        let ch = Int(list[tapIndex].mNumberChannels)
        guard ch >= 1 else { return }
        let src = data.assumingMemoryBound(to: Float.self)
        let frames = Int(list[tapIndex].mDataByteSize) / (4 * ch)
        var w = written.load(ordering: .relaxed)
        if w == 0, time.pointee.mFlags.contains(.hostTimeValid) {
            firstHostTime.store(time.pointee.mHostTime, ordering: .releasing)
        }
        for i in 0..<frames where w + 2 <= capacity {
            samples[w] = src[i * ch]
            samples[w + 1] = src[i * ch + min(1, ch - 1)]
            w += 2
        }
        written.store(w, ordering: .releasing)
    }
}

#endif
