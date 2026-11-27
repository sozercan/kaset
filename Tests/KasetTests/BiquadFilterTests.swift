import Foundation
import Testing
@testable import Kaset

@Suite(.tags(.service))
struct BiquadFilterTests {
    private static let sampleRate: Float = 48000

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

    @Test("Default coefficients pass the signal through unchanged")
    func defaultIsUnityGain() {
        let peak = Self.steadyStatePeak(
            configure: { _ in },
            signal: Self.sine(frequencyHz: 1000, sampleRate: Self.sampleRate)
        )
        #expect(abs(peak - 1) < 0.01)
    }

    @Test("Peaking EQ at +6 dB roughly doubles the on-centre amplitude")
    func peakingEQBoostsCentreFrequency() {
        let peak = Self.steadyStatePeak(
            configure: {
                $0.setPeakingEQ(frequency: 1000, q: 1.0, gainDB: 6, sampleRate: Self.sampleRate)
            },
            signal: Self.sine(frequencyHz: 1000, sampleRate: Self.sampleRate)
        )
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
        #expect(abs(peak - 1) < 0.15)
    }

    @Test("Low-shelf boost lifts a sub-centre frequency")
    func lowShelfBoostsBelowCentre() {
        let peak = Self.steadyStatePeak(
            configure: {
                $0.setLowShelf(frequency: 200, slope: 0.71, gainDB: 6, sampleRate: Self.sampleRate)
            },
            signal: Self.sine(frequencyHz: 60, sampleRate: Self.sampleRate)
        )
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

        for index in 0 ..< frameCount {
            #expect(buffer[index].isFinite)
        }
    }

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
            rightBuffer[index] = 0
        }

        let filter = BiquadFilter()
        filter.setPeakingEQ(frequency: 1000, q: 1.0, gainDB: 6, sampleRate: Self.sampleRate)
        filter.processNonInterleavedStereo(
            left: leftBuffer,
            right: rightBuffer,
            frameCount: frameCount
        )

        let rightPeak = (0 ..< frameCount).map { abs(rightBuffer[$0]) }.max() ?? 0
        #expect(rightPeak < 1e-6)

        let leftPeak = (frameCount * 3 / 4 ..< frameCount).map { abs(leftBuffer[$0]) }.max() ?? 0
        #expect(leftPeak > 1.5)
    }
}
