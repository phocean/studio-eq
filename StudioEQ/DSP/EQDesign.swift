// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright © 2026 Jean-Christophe Baptiste

import Foundation

/// The three tone controls exposed to the user, and how each one maps to a real
/// digital filter. See docs/DSP.md for the rationale behind every number here.
struct EQSettings: Equatable, Codable, Sendable {
    var bass: Double    // dB, low shelf
    var mid: Double     // dB, peaking
    var treble: Double  // dB, high shelf

    /// Starting point taken from r/mac "Studio Display equalizer" (subjective, not a calibration).
    static let defaults = EQSettings(bass: -6, mid: 3, treble: 2)
    static let gainRange: ClosedRange<Double> = -12...12

    var clamped: EQSettings {
        EQSettings(bass: bass.clamped(to: Self.gainRange),
                   mid: mid.clamped(to: Self.gainRange),
                   treble: treble.clamped(to: Self.gainRange))
    }

    var isFlat: Bool { bass == 0 && mid == 0 && treble == 0 }
}

enum FilterKind: Sendable { case lowShelf, peaking, highShelf }

/// Fixed band geometry. Only the gains are user-adjustable.
struct BandDesign: Sendable {
    let kind: FilterKind
    let frequency: Double  // Hz: shelf midpoint (gain/2) or peak centre
    let q: Double

    /// Low shelf, 150 Hz, Q 0.707 (Butterworth-like, no overshoot): tames the low-end
    /// bloom of the Studio Display's small enclosure while leaving voices' body above 300 Hz intact.
    static let bass = BandDesign(kind: .lowShelf, frequency: 150, q: 0.707)
    /// Peaking, 1.5 kHz, Q 0.7 (≈ 1.9 octave bandwidth): broad presence lift for voices and
    /// instruments; a wide Q keeps it a tonal tilt rather than an audible resonance.
    static let mid = BandDesign(kind: .peaking, frequency: 1_500, q: 0.7)
    /// High shelf, 6 kHz, Q 0.707: "air" and detail, above the sibilance region (5–8 kHz starts here
    /// at only half the gain).
    static let treble = BandDesign(kind: .highShelf, frequency: 6_000, q: 0.707)

    static let all: [BandDesign] = [.bass, .mid, .treble]
}

/// Normalised biquad coefficients (a0 == 1), transfer function
/// H(z) = (b0 + b1 z⁻¹ + b2 z⁻²) / (1 + a1 z⁻¹ + a2 z⁻²).
struct BiquadCoefficients: Equatable, Sendable {
    var b0, b1, b2, a1, a2: Double
    static let identity = BiquadCoefficients(b0: 1, b1: 0, b2: 0, a1: 0, a2: 0)

    /// Robert Bristow-Johnson, "Cookbook formulae for audio EQ biquad filter coefficients".
    /// Pure math, no allocation: safe to call from the real-time audio thread.
    @inline(__always)
    static func make(_ kind: FilterKind, frequency: Double, q: Double, gainDB: Double, sampleRate: Double) -> BiquadCoefficients {
        if gainDB == 0 { return .identity }
        let f = min(frequency, sampleRate * 0.45)
        let A = pow(10, gainDB / 40)
        let w0 = 2 * Double.pi * f / sampleRate
        let cosw = cos(w0)
        let alpha = sin(w0) / (2 * q)
        var b0, b1, b2, a0, a1, a2: Double
        switch kind {
        case .peaking:
            b0 = 1 + alpha * A; b1 = -2 * cosw; b2 = 1 - alpha * A
            a0 = 1 + alpha / A; a1 = -2 * cosw; a2 = 1 - alpha / A
        case .lowShelf:
            let s = 2 * sqrt(A) * alpha
            b0 = A * ((A + 1) - (A - 1) * cosw + s)
            b1 = 2 * A * ((A - 1) - (A + 1) * cosw)
            b2 = A * ((A + 1) - (A - 1) * cosw - s)
            a0 = (A + 1) + (A - 1) * cosw + s
            a1 = -2 * ((A - 1) + (A + 1) * cosw)
            a2 = (A + 1) + (A - 1) * cosw - s
        case .highShelf:
            let s = 2 * sqrt(A) * alpha
            b0 = A * ((A + 1) + (A - 1) * cosw + s)
            b1 = -2 * A * ((A - 1) + (A + 1) * cosw)
            b2 = A * ((A + 1) + (A - 1) * cosw - s)
            a0 = (A + 1) - (A - 1) * cosw + s
            a1 = 2 * ((A - 1) - (A + 1) * cosw)
            a2 = (A + 1) - (A - 1) * cosw - s
        }
        return BiquadCoefficients(b0: b0 / a0, b1: b1 / a0, b2: b2 / a0, a1: a1 / a0, a2: a2 / a0)
    }

    /// |H(e^jw)| in dB at `frequency`.
    func magnitudeDB(at frequency: Double, sampleRate: Double) -> Double {
        let w = 2 * Double.pi * frequency / sampleRate
        let c1 = cos(w), s1 = sin(w), c2 = cos(2 * w), s2 = sin(2 * w)
        let nr = b0 + b1 * c1 + b2 * c2, ni = -(b1 * s1 + b2 * s2)
        let dr = 1 + a1 * c1 + a2 * c2, di = -(a1 * s1 + a2 * s2)
        let mag2 = (nr * nr + ni * ni) / (dr * dr + di * di)
        return 10 * log10(mag2)
    }
}

enum EQDesign {
    static func coefficients(for settings: EQSettings, sampleRate: Double) -> [BiquadCoefficients] {
        let gains = [settings.bass, settings.mid, settings.treble]
        return zip(BandDesign.all, gains).map { band, gain in
            .make(band.kind, frequency: band.frequency, q: band.q, gainDB: gain, sampleRate: sampleRate)
        }
    }

    /// Combined response of the three bands (without preamp), in dB.
    static func responseDB(_ settings: EQSettings, at frequency: Double, sampleRate: Double) -> Double {
        coefficients(for: settings, sampleRate: sampleRate)
            .reduce(0) { $0 + $1.magnitudeDB(at: frequency, sampleRate: sampleRate) }
    }

    /// Largest boost of the combined curve over 20 Hz–20 kHz, in dB (0 when nothing is boosted).
    static func peakBoostDB(for settings: EQSettings, sampleRate: Double = 48_000) -> Double {
        let points = 480
        let lo = log10(20.0), hi = log10(min(20_000, sampleRate * 0.45))
        var peak = 0.0
        for i in 0...points {
            let f = pow(10, lo + (hi - lo) * Double(i) / Double(points))
            peak = max(peak, responseDB(settings, at: f, sampleRate: sampleRate))
        }
        return peak
    }

    /// Fixed preamp (headroom), applied whatever the settings.
    ///
    /// Why fixed: an automatic preamp that cancels the curve's boost makes every boost behave
    /// like a cut of everything else (treble +12 dB → the whole sound 12 dB quieter, so moving
    /// the treble slider down made the music louder — reported by the user). With a constant
    /// headroom each slider changes its own band and nothing else. 3 dB covers the default curve
    /// exactly (its peak is +3.0 dB); for larger boosts, and for transient peaks that a
    /// frequency-domain bound cannot catch, the output limiter in `EQProcessor` prevents clipping.
    static let headroomDB = 3.0
    static var preampDB: Double { -headroomDB }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self { min(max(self, range.lowerBound), range.upperBound) }
}
