import Foundation
import Testing
@testable import Kaset

/// Tests for `BiquadFilter`. These exercise the DSP path directly so we can
/// verify coefficient correctness, parameter slewing and stability without
/// involving Core Audio.
@Suite(.tags(.service))
struct BiquadFilterTests {
    // MARK: - Helpers

    private static let sampleRate: Float = 48000

    /// Drives a freshly configured filter with `frameCount` samples of the
    /// chosen test signal and returns the output, also reporting the peak
    /// absolute value. Long-enough runs let the slewing one-pole settle and
    /// give the steady-state response.
    private static func steadyStatePeak(
        configure: (BiquadFilter) -> Void,
        signal: (Int) -> Float,
        frameCount: Int = 8192
    ) -> Float {
        let filter = BiquadFilter()
        configure(filter)

        let buffer = UnsafeMutablePointer<Float>.allocate(capacity: frameCount)
        defer { buffer.deallocate() }
        for index in 0 ..< frameCount {
            buffer[index] = signal(index)
        }
        filter.processMono(samples: buffer, frameCount: frameCount)

        // Inspect only the last quarter — by then the smoothing one-pole has
        // settled and we're reading the genuine steady-state response.
        let analysisStart = frameCount * 3 / 4
        var peak: Float = 0
        for index in analysisStart ..< frameCount {
            peak = max(peak, abs(buffer[index]))
        }
        return peak
    }

    private static func sine(frequencyHz: Float, sampleRate: Float) -> (Int) -> Float {
        let omega = 2 * Float.pi * frequencyHz / sampleRate
        return { index in sinf(omega * Float(index)) }
    }

    // MARK: - Default state

    @Test("Default coefficients pass the signal through unchanged")
    func defaultIsUnityGain() {
        let peak = Self.steadyStatePeak(
            configure: { _ in },
            signal: Self.sine(frequencyHz: 1000, sampleRate: Self.sampleRate)
        )
        // Allow a tiny bit of headroom for floating-point round-off.
        #expect(abs(peak - 1) < 0.01)
    }

    // MARK: - Peaking EQ

    @Test("Peaking EQ at +6 dB roughly doubles the on-centre amplitude")
    func peakingEQBoostsCentreFrequency() {
        let peak = Self.steadyStatePeak(
            configure: {
                $0.setPeakingEQ(frequency: 1000, q: 1.0, gainDB: 6, sampleRate: Self.sampleRate)
            },
            signal: Self.sine(frequencyHz: 1000, sampleRate: Self.sampleRate)
        )
        // +6 dB is a 2x amplitude boost — within ±15% of expected after slew.
        #expect(peak > 1.7 && peak < 2.3)
    }

    @Test("Peaking EQ at −6 dB roughly halves the on-centre amplitude")
    func peakingEQCutsCentreFrequency() {
        let peak = Self.steadyStatePeak(
            configure: {
                $0.setPeakingEQ(frequency: 1000, q: 1.0, gainDB: -6, sampleRate: Self.sampleRate)
            },
            signal: Self.sine(frequencyHz: 1000, sampleRate: Self.sampleRate)
        )
        // −6 dB ≈ 0.5 amplitude.
        #expect(peak > 0.4 && peak < 0.6)
    }

    @Test("Peaking EQ leaves a far-away frequency untouched")
    func peakingEQNarrowEnoughToSpareDistantBands() {
        let peak = Self.steadyStatePeak(
            configure: {
                $0.setPeakingEQ(frequency: 60, q: 1.0, gainDB: 12, sampleRate: Self.sampleRate)
            },
            signal: Self.sine(frequencyHz: 8000, sampleRate: Self.sampleRate)
        )
        // 8 kHz is 7 octaves above a 60 Hz peaking band — the boost should
        // not noticeably reach it. Allow ~1 dB skirt residue.
        #expect(abs(peak - 1) < 0.15)
    }

    // MARK: - Shelving

    @Test("Low-shelf boost lifts a sub-centre frequency")
    func lowShelfBoostsBelowCentre() {
        let peak = Self.steadyStatePeak(
            configure: {
                $0.setLowShelf(frequency: 200, slope: 0.71, gainDB: 6, sampleRate: Self.sampleRate)
            },
            signal: Self.sine(frequencyHz: 60, sampleRate: Self.sampleRate)
        )
        // 60 Hz is well below the 200 Hz shelf knee — should be boosted
        // close to the full +6 dB (≈ 2.0×).
        #expect(peak > 1.6 && peak < 2.2)
    }

    @Test("Low-shelf leaves a high frequency unchanged")
    func lowShelfDoesNotAffectHighFrequencies() {
        let peak = Self.steadyStatePeak(
            configure: {
                $0.setLowShelf(frequency: 200, slope: 0.71, gainDB: 12, sampleRate: Self.sampleRate)
            },
            signal: Self.sine(frequencyHz: 8000, sampleRate: Self.sampleRate)
        )
        // The shelf transitions through its full +12 dB → 0 dB rolloff well
        // before 8 kHz, but allow a ~1 dB residual ripple from the slope.
        #expect(abs(peak - 1) < 0.15)
    }

    @Test("High-shelf boost lifts a super-centre frequency")
    func highShelfBoostsAboveCentre() {
        let peak = Self.steadyStatePeak(
            configure: {
                $0.setHighShelf(frequency: 5000, slope: 0.71, gainDB: 6, sampleRate: Self.sampleRate)
            },
            signal: Self.sine(frequencyHz: 12000, sampleRate: Self.sampleRate)
        )
        #expect(peak > 1.6 && peak < 2.2)
    }

    @Test("High-shelf leaves a low frequency unchanged")
    func highShelfDoesNotAffectLowFrequencies() {
        let peak = Self.steadyStatePeak(
            configure: {
                $0.setHighShelf(frequency: 5000, slope: 0.71, gainDB: 12, sampleRate: Self.sampleRate)
            },
            signal: Self.sine(frequencyHz: 100, sampleRate: Self.sampleRate)
        )
        #expect(abs(peak - 1) < 0.1)
    }

    // MARK: - Stability

    @Test("Extreme gains stay numerically stable over a long run")
    func extremeGainStaysStable() {
        let frameCount = 48000
        let buffer = UnsafeMutablePointer<Float>.allocate(capacity: frameCount)
        defer { buffer.deallocate() }
        let sineGen = Self.sine(frequencyHz: 1000, sampleRate: Self.sampleRate)
        for index in 0 ..< frameCount {
            buffer[index] = sineGen(index)
        }

        let filter = BiquadFilter()
        filter.setPeakingEQ(frequency: 1000, q: 1.0, gainDB: 12, sampleRate: Self.sampleRate)
        filter.processMono(samples: buffer, frameCount: frameCount)

        // No NaN, no infinite — pole/zero placement remained inside the unit
        // circle for the whole run.
        for index in 0 ..< frameCount {
            #expect(buffer[index].isFinite)
        }
    }

    // MARK: - Stereo independence

    @Test("Stereo channels use independent state (no L↔R bleed)")
    func stereoChannelsAreIndependent() {
        let frameCount = 4096
        let leftBuffer = UnsafeMutablePointer<Float>.allocate(capacity: frameCount)
        let rightBuffer = UnsafeMutablePointer<Float>.allocate(capacity: frameCount)
        defer {
            leftBuffer.deallocate()
            rightBuffer.deallocate()
        }
        let sineGen = Self.sine(frequencyHz: 1000, sampleRate: Self.sampleRate)
        for index in 0 ..< frameCount {
            leftBuffer[index] = sineGen(index)
            rightBuffer[index] = 0 // silent right channel
        }

        let filter = BiquadFilter()
        filter.setPeakingEQ(frequency: 1000, q: 1.0, gainDB: 6, sampleRate: Self.sampleRate)
        filter.processNonInterleavedStereo(
            left: leftBuffer,
            right: rightBuffer,
            frameCount: frameCount
        )

        // Right channel was silent in, must stay silent out.
        let rightPeak = (0 ..< frameCount).map { abs(rightBuffer[$0]) }.max() ?? 0
        #expect(rightPeak < 1e-6)

        // Left channel still produced output.
        let leftPeak = (frameCount * 3 / 4 ..< frameCount).map { abs(leftBuffer[$0]) }.max() ?? 0
        #expect(leftPeak > 1.5)
    }
}
