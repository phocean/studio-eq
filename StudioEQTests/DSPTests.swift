// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Jean-Christophe Baptiste

import CoreAudio
import XCTest
@testable import StudioEQ

final class EQDesignTests: XCTestCase {
    let rate = 48_000.0

    func testFlatSettingsAreIdentity() {
        let s = EQSettings(bass: 0, mid: 0, treble: 0)
        XCTAssertEqual(EQDesign.coefficients(for: s, sampleRate: rate), [.identity, .identity, .identity])
    }

    func testBandGainsReachTheirTargets() {
        for g in [-12.0, -6, 3, 12] {
            let low = BiquadCoefficients.make(.lowShelf, frequency: 150, q: 0.707, gainDB: g, sampleRate: rate)
            XCTAssertEqual(low.magnitudeDB(at: 10, sampleRate: rate), g, accuracy: 0.05, "low shelf plateau")
            XCTAssertEqual(low.magnitudeDB(at: 150, sampleRate: rate), g / 2, accuracy: 0.05, "low shelf midpoint")
            XCTAssertEqual(low.magnitudeDB(at: 5_000, sampleRate: rate), 0, accuracy: 0.05)

            let peak = BiquadCoefficients.make(.peaking, frequency: 1_500, q: 0.7, gainDB: g, sampleRate: rate)
            XCTAssertEqual(peak.magnitudeDB(at: 1_500, sampleRate: rate), g, accuracy: 0.01, "peak centre")
            XCTAssertEqual(peak.magnitudeDB(at: 20, sampleRate: rate), 0, accuracy: 0.1)

            let high = BiquadCoefficients.make(.highShelf, frequency: 6_000, q: 0.707, gainDB: g, sampleRate: rate)
            XCTAssertEqual(high.magnitudeDB(at: 20_000, sampleRate: rate), g, accuracy: 0.6, "high shelf plateau")
            XCTAssertEqual(high.magnitudeDB(at: 6_000, sampleRate: rate), g / 2, accuracy: 0.05, "high shelf midpoint")
            XCTAssertEqual(high.magnitudeDB(at: 100, sampleRate: rate), 0, accuracy: 0.05)
        }
    }

    func testFiltersAreStableAcrossRangeAndRates() {
        for rate in [44_100.0, 48_000, 88_200, 96_000, 192_000] {
            for g in stride(from: -12.0, through: 12, by: 0.5) {
                for band in BandDesign.all {
                    let c = BiquadCoefficients.make(band.kind, frequency: band.frequency, q: band.q, gainDB: g, sampleRate: rate)
                    // Poles of 1 + a1 z^-1 + a2 z^-2 inside the unit circle ⇔ |a2| < 1 and |a1| < 1 + a2.
                    XCTAssertLessThan(abs(c.a2), 1, "rate \(rate) gain \(g)")
                    XCTAssertLessThan(abs(c.a1), 1 + c.a2, "rate \(rate) gain \(g)")
                }
            }
        }
    }

    /// The fixed headroom covers the default curve: with the defaults, no frequency ends up
    /// louder than the original.
    func testHeadroomCoversTheDefaultCurve() {
        XCTAssertEqual(EQDesign.preampDB, -3)
        XCTAssertEqual(EQDesign.peakBoostDB(for: .defaults), 3.0, accuracy: 0.05)
        for f in stride(from: 20.0, through: 20_000, by: 37) {
            XCTAssertLessThanOrEqual(EQDesign.responseDB(.defaults, at: f, sampleRate: rate) + EQDesign.preampDB, 0.05, "\(f) Hz")
        }
    }

    /// Every slider moves its own band in the direction it shows, preamp included, and leaves
    /// the rest of the spectrum alone (a boost must not turn into a cut of everything else).
    func testEachSliderRaisesItsOwnBandAndBarelyMovesTheRest() {
        typealias Band = (name: String, at: Double, elsewhere: Double, set: (inout EQSettings, Double) -> Void)
        let bands: [Band] = [
            ("bass", 40, 3_000, { $0.bass = $1 }),
            ("mid", 1_500, 16_000, { $0.mid = $1 }),
            ("treble", 16_000, 300, { $0.treble = $1 }),
        ]
        for base in [EQSettings.defaults, EQSettings(bass: 0, mid: 0, treble: 0)] {
            for band in bands {
                var previousAt = -Double.infinity
                var levelsElsewhere: [Double] = []
                for g in stride(from: -12.0, through: 12, by: 3) {
                    var s = base
                    band.set(&s, g)
                    let preamp = EQDesign.preampDB
                    let at = EQDesign.responseDB(s, at: band.at, sampleRate: rate) + preamp
                    XCTAssertGreaterThan(at, previousAt, "\(band.name) \(g) dB must be louder at \(band.at) Hz than one step lower")
                    previousAt = at
                    levelsElsewhere.append(EQDesign.responseDB(s, at: band.elsewhere, sampleRate: rate) + preamp)
                }
                let swing = levelsElsewhere.max()! - levelsElsewhere.min()!
                XCTAssertLessThanOrEqual(swing, 0.6, "\(band.name) slider moves \(band.elsewhere) Hz by \(swing) dB")
            }
        }
    }

    func testSettingsClampingAndCoding() throws {
        let s = EQSettings(bass: -40, mid: 3, treble: 99).clamped
        XCTAssertEqual(s, EQSettings(bass: -12, mid: 3, treble: 12))
        let decoded = try JSONDecoder().decode(EQSettings.self, from: JSONEncoder().encode(EQSettings.defaults))
        XCTAssertEqual(decoded, .defaults)
    }
}

final class EQProcessorTests: XCTestCase {
    let rate = 48_000.0

    /// Runs `seconds` of a stereo sine through the processor in 256-frame IO buffers.
    private func run(_ p: EQProcessor, frequency: Double, seconds: Double, amplitude: Float = 0.5) -> [Float] {
        let frames = 256
        let total = Int(rate * seconds) / frames * frames
        var input = [Float](repeating: 0, count: total * 2)
        for i in 0..<total {
            let v = amplitude * Float(sin(2 * Double.pi * frequency * Double(i) / rate))
            input[2 * i] = v; input[2 * i + 1] = v
        }
        var output = [Float](repeating: 0, count: total * 2)
        input.withUnsafeBufferPointer { inp in
            output.withUnsafeMutableBufferPointer { out in
                for start in stride(from: 0, to: total, by: frames) {
                    let i = inp.baseAddress! + 2 * start, o = out.baseAddress! + 2 * start
                    p.processStereo(inL: i, inR: i + 1, inStride: 2, outL: o, outStrideL: 2, outR: o + 1, outStrideR: 2, frames: frames)
                }
            }
        }
        return output
    }

    private func rmsDB(_ x: ArraySlice<Float>) -> Double {
        let ms = x.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(x.count)
        return 10 * log10(ms)
    }

    func testProcessedSineMatchesTheoreticalResponse() {
        let params = EQParameters(.defaults)
        for f in [50.0, 150, 1_500, 6_000, 15_000] {
            let p = EQProcessor(sampleRate: rate, parameters: params)
            let out = run(p, frequency: f, seconds: 1)
            let measured = rmsDB(out[(out.count / 2)...]) - 20 * log10(0.5 / 2.0.squareRoot())
            let expected = EQDesign.responseDB(.defaults, at: f, sampleRate: rate) + EQDesign.preampDB
            XCTAssertEqual(measured, expected, accuracy: 0.05, "\(f) Hz")
        }
    }

    func testParameterChangeGlidesWithoutClicks() {
        let params = EQParameters(EQSettings(bass: 0, mid: 0, treble: 0))
        let p = EQProcessor(sampleRate: rate, parameters: params)
        _ = run(p, frequency: 100, seconds: 0.2)
        params.set(EQSettings(bass: -12, mid: 0, treble: 0))  // abrupt 12 dB jump requested
        let out = run(p, frequency: 100, seconds: 0.3)
        // Largest sample-to-sample step of a 0.5-amplitude 100 Hz sine is ≈ 0.0065; a hard
        // coefficient/gain switch would produce a discontinuity far above that.
        var maxStep: Float = 0
        for i in stride(from: 2, to: out.count, by: 2) { maxStep = max(maxStep, abs(out[i] - out[i - 2])) }
        XCTAssertLessThan(maxStep, 0.01)
        // And the target is eventually reached.
        let expected = EQDesign.responseDB(EQSettings(bass: -12, mid: 0, treble: 0), at: 100, sampleRate: rate) + EQDesign.preampDB
        let settled = rmsDB(out[(out.count * 2 / 3)...]) - 20 * log10(0.5 / 2.0.squareRoot())
        XCTAssertEqual(settled, expected, accuracy: 0.1)
    }

    /// Runs interleaved `channels`-channel input through the real IOProc entry point, 256 frames
    /// per cycle, into one interleaved output buffer of the same layout.
    private func runIOProc(_ p: EQProcessor, input: [Float], channels: Int) -> [Float] {
        let frames = 256
        var inp = input, out = [Float](repeating: 0, count: input.count)
        inp.withUnsafeMutableBufferPointer { i in
            out.withUnsafeMutableBufferPointer { o in
                for start in stride(from: 0, to: input.count / channels - frames + 1, by: frames) {
                    let bytes = UInt32(frames * channels * MemoryLayout<Float>.size)
                    var inList = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
                        mNumberChannels: UInt32(channels), mDataByteSize: bytes, mData: i.baseAddress! + start * channels))
                    var outList = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
                        mNumberChannels: UInt32(channels), mDataByteSize: bytes, mData: o.baseAddress! + start * channels))
                    p.process(input: &inList, tapBufferIndex: 0, output: &outList)
                }
            }
        }
        return out
    }

    /// The frequency-domain preamp does not bound time-domain peaks (measured +3 dBFS on a
    /// full-scale square wave); the output limiter must.
    func testOutputNeverExceedsCeilingOnFullScaleSquareWaves() {
        for s in [EQSettings.defaults, EQSettings(bass: -12, mid: 0, treble: 0), EQSettings(bass: 12, mid: 12, treble: 12),
                  EQSettings(bass: 0, mid: 0, treble: 12)] {
            for f in [50.0, 100, 1_000] {
                let p = EQProcessor(sampleRate: rate, parameters: EQParameters(s))
                let period = rate / f, total = 48_000
                var input = [Float](repeating: 0, count: total * 2)
                for i in 0..<total { let v: Float = Double(i).truncatingRemainder(dividingBy: period) < period / 2 ? 1 : -1
                    input[2 * i] = v; input[2 * i + 1] = v }
                let out = runIOProc(p, input: input, channels: 2)
                let peak = out.map { abs($0) }.max()!
                XCTAssertLessThanOrEqual(peak, EQProcessor.limiterCeiling + 1e-6, "\(s) square \(f) Hz")
                XCTAssertTrue(out.allSatisfy { $0.isFinite })
            }
        }
    }

    /// Normal levels never reach the limiter: the processed sine matches the theory exactly.
    func testLimiterIsTransparentBelowCeiling() {
        let p = EQProcessor(sampleRate: rate, parameters: EQParameters(.defaults))
        let out = run(p, frequency: 1_500, seconds: 1, amplitude: 0.9)
        let measured = rmsDB(out[(out.count / 2)...]) - 20 * log10(0.9 / 2.0.squareRoot())
        XCTAssertEqual(measured, EQDesign.responseDB(.defaults, at: 1_500, sampleRate: rate) + EQDesign.preampDB, accuracy: 0.05)
    }

    /// Amplitude of the `frequency` component of `x` (integer number of periods expected).
    private func amplitude(_ x: [Float], frequency: Double) -> Double {
        var c = 0.0, s = 0.0
        for (i, v) in x.enumerated() {
            let w = 2 * Double.pi * frequency * Double(i) / rate
            c += Double(v) * cos(w); s += Double(v) * sin(w)
        }
        return 2 * (c * c + s * s).squareRoot() / Double(x.count)
    }

    /// A steady bass note above the ceiling must be turned down, not clipped: the 25 ms hold keeps
    /// the gain constant between crests. Without it: ≈ 3 % THD at 40 Hz, 1.4 % at 100 Hz.
    func testLimiterTurnsSteadyBassDownWithoutDistortion() {
        for f in [40.0, 50, 100] {
            let p = EQProcessor(sampleRate: rate, parameters: EQParameters(EQSettings(bass: 0, mid: 0, treble: 0)))
            // Flat curve, input at 2.0: 1.41 after the preamp, 3.2 dB above the ceiling.
            let out = run(p, frequency: f, seconds: 2, amplitude: 2)
            let left = stride(from: 0, to: out.count, by: 2).map { out[$0] }
            XCTAssertLessThanOrEqual(left.map { abs($0) }.max()!, EQProcessor.limiterCeiling + 1e-6, "\(f) Hz peak")
            let steady = Array(left.suffix(24_000))  // last 0.5 s: whole periods of 40/50/100 Hz
            let fundamental = amplitude(steady, frequency: f)
            XCTAssertEqual(fundamental, Double(EQProcessor.limiterCeiling), accuracy: 0.01, "\(f) Hz level")
            let harmonics = (2...10).map { amplitude(steady, frequency: f * Double($0)) }
            let thd = harmonics.reduce(0) { $0 + $1 * $1 }.squareRoot() / fundamental
            XCTAssertLessThan(thd, 0.001, "\(f) Hz THD \(thd * 100) %")
        }
    }

    /// A finite but absurd sample (1e38) used to overflow Float to infinity, drive the limiter
    /// envelope to infinity and silence every channel until the engine was rebuilt.
    func testHugeFiniteSamplesDoNotSilenceTheOutput() {
        let s = EQSettings(bass: 0, mid: 0, treble: 12)  // +12 dB near Nyquist: the burst overflows
        let p = EQProcessor(sampleRate: rate, parameters: EQParameters(s))
        let total = 282 * 256  // ≈ 1.5 s, whole IO cycles
        var input = [Float](repeating: 0, count: total * 2)
        for i in 0..<total { let v = 0.5 * Float(sin(2 * Double.pi * 1_500 * Double(i) / rate)); input[2 * i] = v; input[2 * i + 1] = v }
        for i in 9_600..<9_664 { let v: Float = i % 2 == 0 ? .greatestFiniteMagnitude : -.greatestFiniteMagnitude
            input[2 * i] = v; input[2 * i + 1] = v }
        let out = runIOProc(p, input: input, channels: 2)
        XCTAssertTrue(out.allSatisfy { $0.isFinite })
        XCTAssertLessThanOrEqual(out.map { abs($0) }.max()!, EQProcessor.limiterCeiling + 1e-6)
        let left = stride(from: 2 * (total - 24_000), to: 2 * total, by: 2).map { out[$0] }  // last 0.5 s
        let expected = EQDesign.responseDB(s, at: 1_500, sampleRate: rate) + EQDesign.preampDB
        XCTAssertEqual(rmsDB(left[...]) - 20 * log10(0.5 / 2.0.squareRoot()), expected, accuracy: 0.05, "output recovered")
    }

    /// One NaN sample from a misbehaving app must not poison the channel's filter state forever.
    func testNaNInputIsContainedAndTheChannelRecovers() {
        let p = EQProcessor(sampleRate: rate, parameters: EQParameters(.defaults))
        let total = 48_000
        var input = [Float](repeating: 0, count: total * 2)
        for i in 0..<total { let v = 0.5 * Float(sin(2 * Double.pi * 1_500 * Double(i) / rate)); input[2 * i] = v; input[2 * i + 1] = v }
        input[2 * 1_000] = .nan; input[2 * 1_001 + 1] = .infinity
        let out = runIOProc(p, input: input, channels: 2)
        XCTAssertTrue(out.allSatisfy { $0.isFinite })
        XCTAssertEqual(p.filterResets.load(ordering: .relaxed), 2)
        let left = stride(from: total, to: 2 * total, by: 2).map { out[$0] }
        let expected = EQDesign.responseDB(.defaults, at: 1_500, sampleRate: rate) + EQDesign.preampDB
        XCTAssertEqual(rmsDB(left[...]) - 20 * log10(0.5 / 2.0.squareRoot()), expected, accuracy: 0.05, "left channel recovered")
    }

    /// The Studio Display stream has 8 interleaved channels: each one is filtered into the same
    /// output channel, none is dropped or swapped.
    func testEightChannelStreamKeepsChannelMapping() {
        let p = EQProcessor(sampleRate: rate, parameters: EQParameters(EQSettings(bass: 0, mid: 0, treble: 0)))
        let channels = 8, frames = 512
        var input = [Float](repeating: 0, count: frames * channels)
        for f in 0..<frames { for c in 0..<channels { input[f * channels + c] = Float(c + 1) / 20 } }
        let out = runIOProc(p, input: input, channels: channels)
        let g = Float(pow(10, EQDesign.preampDB / 20))  // flat curve: only the fixed preamp remains
        for c in 0..<channels { XCTAssertEqual(out[(frames - 1) * channels + c], g * Float(c + 1) / 20, accuracy: 1e-6, "channel \(c)") }
    }

    func testSilenceStaysExactlySilentAndFinite() {
        let p = EQProcessor(sampleRate: rate, parameters: EQParameters(.defaults))
        _ = run(p, frequency: 1_000, seconds: 0.1)
        let out = run(p, frequency: 0, seconds: 5, amplitude: 0)
        XCTAssertTrue(out.allSatisfy { $0.isFinite })
        XCTAssertEqual(out.suffix(512).map { abs($0) }.max(), 0)
    }

    func testIOProcEntryHandlesInterleavedAndNonInterleavedOutput() {
        let p = EQProcessor(sampleRate: rate, parameters: EQParameters(EQSettings(bass: 0, mid: 0, treble: 0)))
        let frames = 64
        var tap = [Float](repeating: 0, count: frames * 2)
        for i in 0..<frames { tap[2 * i] = 0.25; tap[2 * i + 1] = -0.25 }
        var left = [Float](repeating: 9, count: frames), right = [Float](repeating: 9, count: frames)

        tap.withUnsafeMutableBytes { tapBytes in
            left.withUnsafeMutableBytes { l in
                right.withUnsafeMutableBytes { r in
                    var inList = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
                        mNumberChannels: 2, mDataByteSize: UInt32(tapBytes.count), mData: tapBytes.baseAddress))
                    let out = AudioBufferList.allocate(maximumBuffers: 2)
                    out[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(l.count), mData: l.baseAddress)
                    out[1] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(r.count), mData: r.baseAddress)
                    p.process(input: &inList, tapBufferIndex: 0, output: out.unsafeMutablePointer)
                    free(out.unsafeMutablePointer)
                }
            }
        }
        let g = Float(pow(10, EQDesign.preampDB / 20))  // flat curve: only the fixed preamp remains
        XCTAssertEqual(left.last!, 0.25 * g, accuracy: 1e-6)
        XCTAssertEqual(right.last!, -0.25 * g, accuracy: 1e-6)
    }
}
