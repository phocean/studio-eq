// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Jean-Christophe Baptiste

import CoreAudio
import Synchronization

/// Target gains written by the UI thread and read by the audio thread, lock-free.
/// Each field is published independently: a reader may briefly see a mix of old and new
/// fields, which is harmless because the processor glides towards whatever it reads and the
/// output limiter bounds any transient overshoot.
final class EQParameters: Sendable {
    private let bass = Atomic<UInt64>(0)
    private let mid = Atomic<UInt64>(0)
    private let treble = Atomic<UInt64>(0)

    init(_ settings: EQSettings = .defaults) { set(settings) }

    func set(_ settings: EQSettings) {
        let s = settings.clamped
        bass.store(s.bass.bitPattern, ordering: .relaxed)
        mid.store(s.mid.bitPattern, ordering: .relaxed)
        treble.store(s.treble.bitPattern, ordering: .relaxed)
    }

    /// (bass, mid, treble) in dB. Real-time safe.
    @inline(__always)
    func load() -> (Double, Double, Double) {
        (Double(bitPattern: bass.load(ordering: .relaxed)),
         Double(bitPattern: mid.load(ordering: .relaxed)),
         Double(bitPattern: treble.load(ordering: .relaxed)))
    }
}

/// Multichannel three-band EQ running on the Core Audio IO thread (same curve on every channel).
///
/// Real-time rules: every buffer and all mutable state are allocated in `init` (raw pointers,
/// so no exclusivity checks on class properties); `process` performs no allocation, no
/// locking, no I/O and no logging. Gain changes glide with a 30 ms
/// time constant (coefficients are recomputed per buffer only while gliding) so slider
/// moves never click.
///
/// Signal chain per IO cycle: fixed preamp (−3 dB headroom) → low shelf → peak → high shelf
/// (per channel), then one
/// peak limiter linked across all channels, so the output never exceeds `limiterCeiling`.
final class EQProcessor: @unchecked Sendable {
    let sampleRate: Double
    let parameters: EQParameters

    private static let bandCount = 3
    /// The Studio Display speaker stream has 8 channels (5.1.2: L R C LFE Ls Rs Ltm Rtm).
    static let maxChannels = 16
    private static let smoothingTime = 0.030  // s

    /// Output ceiling: −0.2 dBFS. A curve whose response stays below 0 dB can still raise
    /// transient peaks (minimum-phase filters shift harmonics): measured +3 dBFS on a full-scale
    /// 100 Hz square wave with the default settings. The limiter has instant attack (the gain is
    /// set so the current frame lands exactly on the ceiling), holds its envelope for 25 ms, then
    /// releases over 100 ms; it is idle unless a peak actually crosses the ceiling.
    ///
    /// The hold is what makes it a limiter rather than a clipper: without it the envelope sagged
    /// between two crests of a bass note, every crest was flattened onto the ceiling and the
    /// limited signal carried ≈ 3 % harmonic distortion at 40 Hz (final review, 2026-11-22).
    /// 25 ms covers half a period down to 20 Hz, so the gain stays constant across a steady tone.
    static let limiterCeiling: Float = 0.977
    private static let limiterRelease = 0.100  // s
    private static let limiterHold = 0.025     // s

    /// Hard bound on a filtered sample before the limiter: ±16 (+24 dBFS). A finite but absurd
    /// input (a misbehaving app writing 1e38) would otherwise overflow `Float` to infinity, drive
    /// the limiter envelope to infinity and silence every channel for good. Bounded, the worst
    /// case is the envelope's normal recovery: hold plus ≈ 0.3 s of release.
    static let sampleBound = 16.0

    // Owned exclusively by the IO thread after init.
    private let gains = UnsafeMutablePointer<Double>.allocate(capacity: 3)       // bass, mid, treble (dB)
    private let coeffs = UnsafeMutablePointer<BiquadCoefficients>.allocate(capacity: bandCount)
    private let z = UnsafeMutablePointer<Double>.allocate(capacity: bandCount * maxChannels * 2) // TDF-II state
    private let channelData = UnsafeMutablePointer<UnsafeMutablePointer<Float>>.allocate(capacity: maxChannels)
    private let channelStride = UnsafeMutablePointer<Int>.allocate(capacity: maxChannels)
    private let limiterReleaseCoefficient: Float
    private let limiterHoldFrames: Int
    private let limiterEnvelope = UnsafeMutablePointer<Float>.allocate(capacity: 1)
    private let limiterHoldLeft = UnsafeMutablePointer<Int>.allocate(capacity: 1)
    private let preampLinear = pow(10, EQDesign.preampDB / 20)

    /// Number of times a channel's filter state became non-finite (NaN/Inf input) and was reset.
    /// Written by the IO thread (relaxed atomic, only on that rare path), logged when the engine
    /// stops.
    let filterResets = Atomic<UInt64>(0)

    #if VALIDATION
    /// Health counters read by the validation tools: number of IO cycles, and of cycles whose
    /// tap input carried any non-zero sample. Not compiled into the distributed app.
    let cycles = Atomic<UInt64>(0)
    let cyclesWithSignal = Atomic<UInt64>(0)

    /// `--ab-test`: silences the processed output while the originals stay muted by the tap, to
    /// prove by ear that the unprocessed stream is not also playing.
    let silenceOutput = Atomic<Bool>(false)
    #endif

    init(sampleRate: Double, parameters: EQParameters) {
        self.sampleRate = sampleRate
        self.parameters = parameters
        limiterReleaseCoefficient = Float(exp(-1 / (sampleRate * Self.limiterRelease)))
        limiterHoldFrames = Int(sampleRate * Self.limiterHold)
        limiterEnvelope.initialize(to: 0)
        limiterHoldLeft.initialize(to: 0)
        let t = parameters.load()
        gains[0] = t.0; gains[1] = t.1; gains[2] = t.2
        z.initialize(repeating: 0, count: Self.bandCount * Self.maxChannels * 2)
        coeffs.initialize(repeating: .identity, count: Self.bandCount)
        updateCoefficients()
    }

    deinit {
        gains.deallocate(); coeffs.deallocate(); z.deallocate()
        channelData.deallocate(); channelStride.deallocate()
        limiterEnvelope.deallocate(); limiterHoldLeft.deallocate()
    }

    private func updateCoefficients() {
        coeffs[0] = .make(.lowShelf, frequency: BandDesign.bass.frequency, q: BandDesign.bass.q, gainDB: gains[0], sampleRate: sampleRate)
        coeffs[1] = .make(.peaking, frequency: BandDesign.mid.frequency, q: BandDesign.mid.q, gainDB: gains[1], sampleRate: sampleRate)
        coeffs[2] = .make(.highShelf, frequency: BandDesign.treble.frequency, q: BandDesign.treble.q, gainDB: gains[2], sampleRate: sampleRate)
    }

    /// Moves current gains towards the published targets, recomputing coefficients if needed.
    @inline(__always)
    private func glide(frames: Int) {
        let t = parameters.load()
        let alpha = 1 - exp(-Double(frames) / (sampleRate * Self.smoothingTime))
        var changed = false
        func step(_ i: Int, _ target: Double) {
            let d = target - gains[i]
            if d == 0 { return }
            gains[i] = abs(d) < 0.01 ? target : gains[i] + d * alpha
            changed = true
        }
        step(0, t.0); step(1, t.1); step(2, t.2)
        if changed { updateCoefficients() }
    }

    /// Filters one channel (strided Float32) with its own filter state. Call `glide` once per
    /// IO cycle before filtering the cycle's channels.
    @inline(__always)
    private func filter(channel ch: Int, src: UnsafePointer<Float>, srcStride: Int,
                        dst: UnsafeMutablePointer<Float>, dstStride: Int, frames: Int) {
        let c0 = coeffs[0], c1 = coeffs[1], c2 = coeffs[2]
        let g = preampLinear, bound = Self.sampleBound
        let s = z + ch * Self.bandCount * 2
        var z0 = s[0], z1 = s[1], z2 = s[2], z3 = s[3], z4 = s[4], z5 = s[5]
        var i = 0, o = 0
        for _ in 0..<frames {
            var x = Double(src[i]) * g
            // Transposed direct form II, three sections in cascade.
            var y = c0.b0 * x + z0; z0 = c0.b1 * x - c0.a1 * y + z1; z1 = c0.b2 * x - c0.a2 * y; x = y
            y = c1.b0 * x + z2; z2 = c1.b1 * x - c1.a1 * y + z3; z3 = c1.b2 * x - c1.a2 * y; x = y
            y = c2.b0 * x + z4; z4 = c2.b1 * x - c2.a1 * y + z5; z5 = c2.b2 * x - c2.a2 * y
            dst[o] = Float(min(max(y, -bound), bound))  // NaN passes through: caught below
            i += srcStride; o += dstStride
        }
        // A NaN or Inf sample from a misbehaving app would otherwise stay in the recursive state
        // forever and silence (or fill with garbage) this channel until the engine is rebuilt.
        // NaN propagates through every later state, so checking the final state once per cycle
        // catches any bad sample of the cycle: reset the state and silence this cycle's output.
        if !(z0 + z1 + z2 + z3 + z4 + z5).isFinite {
            for k in 0..<6 { s[k] = 0 }
            o = 0
            for _ in 0..<frames { dst[o] = 0; o += dstStride }
            filterResets.add(1, ordering: .relaxed)
            return
        }
        // Flush denormal-range state so long silences cost nothing.
        func flush(_ v: Double) -> Double { abs(v) < 1e-20 ? 0 : v }
        s[0] = flush(z0); s[1] = flush(z1); s[2] = flush(z2); s[3] = flush(z3); s[4] = flush(z4); s[5] = flush(z5)
    }

    /// Peak limiter linked across the `count` channels registered in `channelData`. The envelope
    /// never falls below the current frame's peak, so the output never exceeds the ceiling.
    @inline(__always)
    private func limit(channels count: Int, frames: Int) {
        let ceiling = Self.limiterCeiling, release = limiterReleaseCoefficient, hold = limiterHoldFrames
        var env = limiterEnvelope.pointee, holdLeft = limiterHoldLeft.pointee
        for f in 0..<frames {
            var peak: Float = 0
            for c in 0..<count { peak = max(peak, abs(channelData[c][f * channelStride[c]])) }
            if peak >= env {
                env = peak; holdLeft = hold
            } else if holdLeft > 0 {
                holdLeft -= 1
            } else {
                env = max(peak, env * release)
            }
            if env > ceiling {
                let g = ceiling / env
                for c in 0..<count { channelData[c][f * channelStride[c]] *= g }
            }
        }
        limiterEnvelope.pointee = env < 1e-12 ? 0 : env
        limiterHoldLeft.pointee = holdLeft
    }

    /// Stereo convenience used by the unit tests: one IO cycle on two strided channels.
    func processStereo(inL: UnsafePointer<Float>, inR: UnsafePointer<Float>, inStride: Int,
                       outL: UnsafeMutablePointer<Float>, outStrideL: Int,
                       outR: UnsafeMutablePointer<Float>, outStrideR: Int,
                       frames: Int) {
        glide(frames: frames)
        filter(channel: 0, src: inL, srcStride: inStride, dst: outL, dstStride: outStrideL, frames: frames)
        filter(channel: 1, src: inR, srcStride: inStride, dst: outR, dstStride: outStrideR, frames: frames)
        channelData[0] = outL; channelStride[0] = outStrideL
        channelData[1] = outR; channelStride[1] = outStrideR
        limit(channels: 2, frames: frames)
    }

    /// IOProc entry point. `tapBufferIndex` selects the tap's stream among the aggregate's inputs.
    /// The tap is a device-stream tap, so it has the device stream's own channel layout: input
    /// channel n is filtered into output channel n. Output channels without a matching input
    /// channel are left silent.
    func process(input: UnsafePointer<AudioBufferList>, tapBufferIndex: Int,
                 output: UnsafeMutablePointer<AudioBufferList>) {
        let outList = UnsafeMutableAudioBufferListPointer(output)
        let inList = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))

        // Silence every output first: never leave stale memory in the device buffer.
        var outFrames = Int.max
        for buf in outList {
            guard let data = buf.mData else { continue }
            memset(data, 0, Int(buf.mDataByteSize))
            let n = max(Int(buf.mNumberChannels), 1)
            outFrames = min(outFrames, Int(buf.mDataByteSize) / (n * MemoryLayout<Float>.size))
        }
        guard outFrames != Int.max, outFrames > 0, tapBufferIndex < inList.count else { return }
        let tap = inList[tapBufferIndex]
        guard let inData = tap.mData else { return }
        let inChannels = max(Int(tap.mNumberChannels), 1)
        let frames = min(outFrames, Int(tap.mDataByteSize) / (inChannels * MemoryLayout<Float>.size))
        guard frames > 0 else { return }

        let inBase = inData.assumingMemoryBound(to: Float.self)
        #if VALIDATION
        cycles.add(1, ordering: .relaxed)
        var anySignal = false
        for i in 0..<(frames * inChannels) where inBase[i] != 0 { anySignal = true; break }
        if anySignal { cyclesWithSignal.add(1, ordering: .relaxed) }
        #endif

        glide(frames: frames)
        #if VALIDATION
        if silenceOutput.load(ordering: .relaxed) { return }
        #endif
        var count = 0
        for ch in 0..<min(inChannels, Self.maxChannels) {
            guard let (dst, dstStride) = Self.channel(ch, in: outList) else { break }
            filter(channel: ch, src: inBase + ch, srcStride: inChannels, dst: dst, dstStride: dstStride, frames: frames)
            channelData[count] = dst; channelStride[count] = dstStride; count += 1
        }
        limit(channels: count, frames: frames)
    }

    /// Pointer and stride of logical channel `c` across the buffers of an AudioBufferList.
    @inline(__always)
    static func channel(_ c: Int, in list: UnsafeMutableAudioBufferListPointer) -> (UnsafeMutablePointer<Float>, Int)? {
        var c = c
        for buf in list {
            let n = Int(buf.mNumberChannels)
            if c < n {
                guard let data = buf.mData else { return nil }
                return (data.assumingMemoryBound(to: Float.self) + c, n)
            }
            c -= n
        }
        return nil
    }
}
