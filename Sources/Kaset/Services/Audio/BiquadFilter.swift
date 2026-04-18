import Foundation

// MARK: - BiquadFilter

/// Real-time-safe biquad filter (RBJ cookbook) supporting peaking, low-shelf
/// and high-shelf modes with **per-sample coefficient smoothing**.
///
/// Designed for use inside a Core Audio render callback:
/// - No allocation during `process(...)`
/// - No locking; coefficient target writes from the main thread can tear
///   across the 5 `Double` stores, but the per-sample smoothing one-pole
///   absorbs the transient so a slider sweep reads as a slew, not a click.
/// - State is kept per channel so stereo processing doesn't leak between
///   left and right.
///
/// Implemented as **Transposed Direct Form II** for better numerical
/// stability at low frequencies than Direct Form I.
final class BiquadFilter {
    // MARK: - Coefficients (current, ramped toward target each sample)

    // Coefficients are `Double` so round-off doesn't leak into the cascade
    // quantization noise. Only the per-sample Float ↔ Double conversion at
    // the input/output of the biquad happens at Float precision.
    private var b0: Double = 1
    private var b1: Double = 0
    private var b2: Double = 0
    private var a1: Double = 0
    private var a2: Double = 0

    /// Coefficient targets written by the parameter-update path on the main
    /// actor. The render thread linearly slews the live coefficients toward
    /// these targets at ``smoothingAlpha`` per sample.
    private var targetB0: Double = 1
    private var targetB1: Double = 0
    private var targetB2: Double = 0
    private var targetA1: Double = 0
    private var targetA2: Double = 0

    /// One-pole smoothing coefficient.
    ///
    /// `α ≈ 1 - exp(-1 / (τ · sampleRate))`. With τ = 5 ms at 48 kHz that's
    /// roughly 0.0042. Hard-coded to keep the render loop allocation-free
    /// (we don't know the SR at construction); the constant is tuned for
    /// 44.1–96 kHz and stays inaudible across that range.
    private let smoothingAlpha: Double = 0.004

    // MARK: - State (z^-1, z^-2 per channel)

    // State variables are `Double` rather than `Float` so round-off
    // error doesn't accumulate audibly across a 6-biquad cascade. Input
    // and output samples stay `Float` — only the feedback state (where
    // accumulation happens) benefits from the extra precision, and the
    // widening happens inside the inner loop below.
    private var leftZ1: Double = 0
    private var leftZ2: Double = 0
    private var rightZ1: Double = 0
    private var rightZ2: Double = 0

    // MARK: - Coefficient setters (call from main thread)

    /// Updates coefficients for a peaking EQ section.
    func setPeakingEQ(frequency: Float, q: Float, gainDB: Float, sampleRate: Float) {
        guard let terms = Self.commonTerms(frequency: frequency, gainDB: gainDB, sampleRate: sampleRate),
              q > 0
        else { return }

        let alpha = terms.sinOmega / (2 * Double(q))
        let capitalA = terms.capitalA

        self.installTargets(Coefficients(
            b0: 1 + alpha * capitalA,
            b1: -2 * terms.cosOmega,
            b2: 1 - alpha * capitalA,
            a0: 1 + alpha / capitalA,
            a1: -2 * terms.cosOmega,
            a2: 1 - alpha / capitalA
        ))
    }

    /// Updates coefficients for a low-shelf section. `slope` is RBJ's `S`
    /// parameter; 1.0 yields a Butterworth-like 12 dB/oct shelf.
    func setLowShelf(frequency: Float, slope: Float, gainDB: Float, sampleRate: Float) {
        self.setShelf(kind: .low, frequency: frequency, slope: slope, gainDB: gainDB, sampleRate: sampleRate)
    }

    /// Updates coefficients for a high-shelf section.
    func setHighShelf(frequency: Float, slope: Float, gainDB: Float, sampleRate: Float) {
        self.setShelf(kind: .high, frequency: frequency, slope: slope, gainDB: gainDB, sampleRate: sampleRate)
    }

    /// Shelf type used by ``setShelf``: low- or high-shelf differ only by
    /// the sign of the `(A−1)·cos(ω)` term in the RBJ cookbook formulae.
    private enum ShelfKind {
        case low
        case high

        /// Sign that flips the cosine-coupled term: `+1` for low-shelf,
        /// `-1` for high-shelf.
        var sign: Double {
            switch self {
            case .low: 1
            case .high: -1
            }
        }
    }

    /// Shared shelf-coefficient solver. Low- and high-shelf differ only by
    /// the sign of the `(A−1)·cos(ω)` term in the RBJ Audio EQ Cookbook
    /// (Bristow-Johnson) — `sign = +1` reproduces the cookbook's low-shelf,
    /// `sign = −1` the high-shelf. Same swap applies to the matched terms
    /// in `b₁`, `a₀`, `a₁`, `a₂`.
    private func setShelf(
        kind: ShelfKind,
        frequency: Float,
        slope: Float,
        gainDB: Float,
        sampleRate: Float
    ) {
        guard let terms = Self.commonTerms(frequency: frequency, gainDB: gainDB, sampleRate: sampleRate),
              slope > 0
        else { return }

        // Clamp to (0, 1]: above 1 the cookbook's `(1/slope − 1)` term goes
        // negative, which can drive the radicand below zero and produce NaN
        // alphas at high gain. The default bands stay below this; the clamp
        // protects API callers that don't.
        let safeSlope = min(Double(slope), 1)
        let capitalA = terms.capitalA
        let sqrtA = sqrt(capitalA)
        let alpha = terms.sinOmega / 2 * sqrt((capitalA + 1 / capitalA) * (1 / safeSlope - 1) + 2)
        let cosOmega = terms.cosOmega
        let sign = kind.sign
        let aPlus1 = capitalA + 1
        let aMinus1 = capitalA - 1
        let twoSqrtAAlpha = 2 * sqrtA * alpha

        self.installTargets(Coefficients(
            b0: capitalA * (aPlus1 - sign * aMinus1 * cosOmega + twoSqrtAAlpha),
            b1: 2 * capitalA * (sign * aMinus1 - aPlus1 * cosOmega),
            b2: capitalA * (aPlus1 - sign * aMinus1 * cosOmega - twoSqrtAAlpha),
            a0: aPlus1 + sign * aMinus1 * cosOmega + twoSqrtAAlpha,
            a1: -2 * (sign * aMinus1 + aPlus1 * cosOmega),
            a2: aPlus1 + sign * aMinus1 * cosOmega - twoSqrtAAlpha
        ))
    }

    // MARK: - Render

    /// Processes `frameCount` frames of non-interleaved stereo audio in
    /// place, slewing coefficients toward their targets per sample.
    func processNonInterleavedStereo(
        left: UnsafeMutablePointer<Float>,
        right: UnsafeMutablePointer<Float>,
        frameCount: Int
    ) {
        var b0 = self.b0, b1 = self.b1, b2 = self.b2
        var a1 = self.a1, a2 = self.a2
        let tb0 = self.targetB0, tb1 = self.targetB1, tb2 = self.targetB2
        let ta1 = self.targetA1, ta2 = self.targetA2
        let alpha = self.smoothingAlpha

        var lz1 = self.leftZ1, lz2 = self.leftZ2
        var rz1 = self.rightZ1, rz2 = self.rightZ2

        for index in 0 ..< frameCount {
            // Slew coefficients toward target.
            b0 += (tb0 - b0) * alpha
            b1 += (tb1 - b1) * alpha
            b2 += (tb2 - b2) * alpha
            a1 += (ta1 - a1) * alpha
            a2 += (ta2 - a2) * alpha

            let xLeft = Double(left[index])
            let yLeft = b0 * xLeft + lz1
            lz1 = b1 * xLeft - a1 * yLeft + lz2
            lz2 = b2 * xLeft - a2 * yLeft
            left[index] = Float(yLeft)

            let xRight = Double(right[index])
            let yRight = b0 * xRight + rz1
            rz1 = b1 * xRight - a1 * yRight + rz2
            rz2 = b2 * xRight - a2 * yRight
            right[index] = Float(yRight)
        }

        self.b0 = b0
        self.b1 = b1
        self.b2 = b2
        self.a1 = a1
        self.a2 = a2
        self.leftZ1 = lz1
        self.leftZ2 = lz2
        self.rightZ1 = rz1
        self.rightZ2 = rz2
    }

    /// Mono variant.
    func processMono(
        samples: UnsafeMutablePointer<Float>,
        frameCount: Int
    ) {
        var b0 = self.b0, b1 = self.b1, b2 = self.b2
        var a1 = self.a1, a2 = self.a2
        let tb0 = self.targetB0, tb1 = self.targetB1, tb2 = self.targetB2
        let ta1 = self.targetA1, ta2 = self.targetA2
        let alpha = self.smoothingAlpha

        var z1 = self.leftZ1
        var z2 = self.leftZ2

        for index in 0 ..< frameCount {
            b0 += (tb0 - b0) * alpha
            b1 += (tb1 - b1) * alpha
            b2 += (tb2 - b2) * alpha
            a1 += (ta1 - a1) * alpha
            a2 += (ta2 - a2) * alpha

            let x = Double(samples[index])
            let y = b0 * x + z1
            z1 = b1 * x - a1 * y + z2
            z2 = b2 * x - a2 * y
            samples[index] = Float(y)
        }

        self.b0 = b0
        self.b1 = b1
        self.b2 = b2
        self.a1 = a1
        self.a2 = a2
        self.leftZ1 = z1
        self.leftZ2 = z2
    }

    // MARK: - Private

    /// Pre-normalised RBJ terms shared by every coefficient setter.
    private struct CommonTerms {
        let capitalA: Double
        let cosOmega: Double
        let sinOmega: Double
    }

    private static func commonTerms(frequency: Float, gainDB: Float, sampleRate: Float) -> CommonTerms? {
        guard sampleRate > 0, frequency > 0 else { return nil }
        let omega = 2 * Double.pi * Double(frequency) / Double(sampleRate)
        return CommonTerms(
            capitalA: pow(10, Double(gainDB) / 40),
            cosOmega: cos(omega),
            sinOmega: sin(omega)
        )
    }

    /// Raw RBJ-cookbook coefficient set, normalised by `installTargets`.
    private struct Coefficients {
        let b0: Double
        let b1: Double
        let b2: Double
        let a0: Double
        let a1: Double
        let a2: Double
    }

    private func installTargets(_ coeffs: Coefficients) {
        // Pathological inputs (e.g. frequency near Nyquist with extreme Q)
        // can drive a0 to zero, which would publish ±∞ targets to the render
        // thread and permanently poison the slewed coefficients. Bail before
        // dividing.
        guard coeffs.a0.isFinite, abs(coeffs.a0) > 1e-10 else { return }
        let inverseA0 = 1 / coeffs.a0
        self.targetB0 = coeffs.b0 * inverseA0
        self.targetB1 = coeffs.b1 * inverseA0
        self.targetB2 = coeffs.b2 * inverseA0
        self.targetA1 = coeffs.a1 * inverseA0
        self.targetA2 = coeffs.a2 * inverseA0
    }
}
