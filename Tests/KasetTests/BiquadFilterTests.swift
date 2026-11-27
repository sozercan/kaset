import CoreAudio
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

    @Test("Concurrent parameter updates and rendering stay finite and coherent")
    func concurrentParameterUpdatesAndRendering() async {
        struct UncheckedEngineBox: @unchecked Sendable {
            let engine: EqualizerAudioEngine
        }

        let box = UncheckedEngineBox(engine: EqualizerAudioEngine())
        let frames = 256

        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                for step in 0 ..< 120 {
                    let gain: Float = step.isMultiple(of: 2) ? 6 : -6
                    var settings = EQSettings.flat
                    settings.isEnabled = step % 3 != 0
                    settings.preampDB = step.isMultiple(of: 2) ? 2 : -2
                    settings.bandGainsDB = Array(repeating: gain, count: EQBand.defaultBands.count)
                    box.engine.apply(settings: settings)
                    await Task.yield()
                }
                return true
            }

            group.addTask {
                var inLeft = [Float](repeating: 0, count: frames)
                var inRight = [Float](repeating: 0, count: frames)
                var outLeft = [Float](repeating: 0, count: frames)
                var outRight = [Float](repeating: 0, count: frames)
                let sineGen = Self.sine(frequencyHz: 1000, sampleRate: Self.sampleRate)
                for i in 0 ..< frames {
                    inLeft[i] = sineGen(i) * 0.5
                    inRight[i] = sineGen(i) * 0.5
                }

                for _ in 0 ..< 120 {
                    inLeft.withUnsafeMutableBufferPointer { inL in
                        inRight.withUnsafeMutableBufferPointer { inR in
                            outLeft.withUnsafeMutableBufferPointer { outL in
                                outRight.withUnsafeMutableBufferPointer { outR in
                                    let byteCount = UInt32(frames * MemoryLayout<Float>.size)
                                    let inABL = AudioBufferList.allocate(maximumBuffers: 2)
                                    let outABL = AudioBufferList.allocate(maximumBuffers: 2)
                                    defer {
                                        free(inABL.unsafeMutablePointer)
                                        free(outABL.unsafeMutablePointer)
                                    }
                                    inABL[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: byteCount, mData: inL.baseAddress)
                                    inABL[1] = AudioBuffer(mNumberChannels: 1, mDataByteSize: byteCount, mData: inR.baseAddress)
                                    outABL[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: byteCount, mData: outL.baseAddress)
                                    outABL[1] = AudioBuffer(mNumberChannels: 1, mDataByteSize: byteCount, mData: outR.baseAddress)
                                    box.engine.performRender(
                                        inputBuffers: inABL.unsafePointer,
                                        frameCount: UInt32(frames),
                                        outputBuffers: outABL.unsafeMutablePointer
                                    )
                                }
                            }
                        }
                    }
                    guard outLeft.allSatisfy(\.isFinite), outRight.allSatisfy(\.isFinite) else {
                        return false
                    }
                }
                return true
            }

            var allFinite = true
            for await result in group {
                allFinite = allFinite && result
            }
            #expect(allFinite)
        }

        #expect(box.engine.hasObservedAudio == true)
    }

    @Test("Published filter coefficients and render parameters stay snapshot-coherent and converge")
    func publishedSnapshotsStayCoherentAndConverge() async {
        struct UncheckedFilterBox: @unchecked Sendable {
            let filter: BiquadFilter
        }
        struct UncheckedEngineBox: @unchecked Sendable {
            let engine: EqualizerAudioEngine
        }

        let referenceA = BiquadFilter()
        referenceA.setPeakingEQ(frequency: 1000, q: 1.4, gainDB: 6, sampleRate: Self.sampleRate)
        let expectedA = referenceA.readPublishedTargets()

        let referenceB = BiquadFilter()
        referenceB.setPeakingEQ(frequency: 1000, q: 1.4, gainDB: -6, sampleRate: Self.sampleRate)
        let expectedB = referenceB.readPublishedTargets()

        let filterBox = UncheckedFilterBox(filter: BiquadFilter())
        let validFilterSnapshots: Set<[Double]> = [
            [1, 0, 0, 0, 0],
            [expectedA.b0, expectedA.b1, expectedA.b2, expectedA.a1, expectedA.a2],
            [expectedB.b0, expectedB.b1, expectedB.b2, expectedB.a1, expectedB.a2],
        ]

        let engineBox = UncheckedEngineBox(engine: EqualizerAudioEngine())
        var mutableSettingsA = EQSettings.flat
        mutableSettingsA.isEnabled = true
        mutableSettingsA.preampDB = 3
        mutableSettingsA.bandGainsDB = Array(repeating: 6, count: EQBand.defaultBands.count)
        let settingsA = mutableSettingsA
        var mutableSettingsB = EQSettings.flat
        mutableSettingsB.isEnabled = false
        mutableSettingsB.preampDB = -4
        mutableSettingsB.bandGainsDB = Array(repeating: -6, count: EQBand.defaultBands.count)
        let settingsB = mutableSettingsB
        let expectedParamsA = EqualizerAudioEngine.RenderParameters(
            preampLinear: powf(10, (settingsA.preampDB + settingsA.autoTrimDB) / 20),
            wetMixTarget: 1
        )
        let expectedParamsB = EqualizerAudioEngine.RenderParameters(
            preampLinear: powf(10, (settingsB.preampDB + settingsB.autoTrimDB) / 20),
            wetMixTarget: 0
        )

        let coherent = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                for step in 0 ..< 200 {
                    let useA = step.isMultiple(of: 2)
                    filterBox.filter.setPeakingEQ(
                        frequency: 1000,
                        q: 1.4,
                        gainDB: useA ? 6 : -6,
                        sampleRate: Self.sampleRate
                    )
                    engineBox.engine.apply(settings: useA ? settingsA : settingsB)
                    if step.isMultiple(of: 10) {
                        await Task.yield()
                    }
                }
                filterBox.filter.setPeakingEQ(frequency: 1000, q: 1.4, gainDB: -6, sampleRate: Self.sampleRate)
                engineBox.engine.apply(settings: settingsB)
                return true
            }

            group.addTask {
                for step in 0 ..< 400 {
                    let coeffs = filterBox.filter.readPublishedTargets()
                    let tuple = [coeffs.b0, coeffs.b1, coeffs.b2, coeffs.a1, coeffs.a2]
                    guard validFilterSnapshots.contains(tuple) else { return false }

                    let params = engineBox.engine.readPublishedRenderParameters()
                    let matchesValid = params == .unity || params == expectedParamsA || params == expectedParamsB
                    guard matchesValid else { return false }
                    if step.isMultiple(of: 10) {
                        await Task.yield()
                    }
                }
                return true
            }

            var ok = true
            for await result in group {
                ok = ok && result
            }
            return ok
        }

        #expect(coherent)
        #expect(filterBox.filter.readPublishedTargets() == expectedB)
        #expect(engineBox.engine.readPublishedRenderParameters() == expectedParamsB)
    }

    @Test("Reserved reader slot survives writer wraparound without tearing")
    func reservedSlotSurvivesWriterWraparound() {
        let referenceA = BiquadFilter()
        referenceA.setPeakingEQ(frequency: 1000, q: 1.4, gainDB: 6, sampleRate: Self.sampleRate)
        let expectedA = referenceA.readPublishedTargets()

        let reservedFilter = BiquadFilter()
        reservedFilter.setPeakingEQ(frequency: 1000, q: 1.4, gainDB: 6, sampleRate: Self.sampleRate)
        let reservedFilterSnapshot = reservedFilter.readPublishedTargets {
            for step in 0 ..< 6 {
                reservedFilter.setPeakingEQ(
                    frequency: 1000,
                    q: 1.4,
                    gainDB: step.isMultiple(of: 2) ? -6 : -3,
                    sampleRate: Self.sampleRate
                )
            }
        }
        #expect(reservedFilterSnapshot == expectedA)

        var settingsA = EQSettings.flat
        settingsA.isEnabled = true
        settingsA.preampDB = 3
        settingsA.bandGainsDB = Array(repeating: 6, count: EQBand.defaultBands.count)
        var settingsB = EQSettings.flat
        settingsB.isEnabled = false
        settingsB.preampDB = -4
        settingsB.bandGainsDB = Array(repeating: -6, count: EQBand.defaultBands.count)
        let expectedParamsA = EqualizerAudioEngine.RenderParameters(
            preampLinear: powf(10, (settingsA.preampDB + settingsA.autoTrimDB) / 20),
            wetMixTarget: 1
        )
        let expectedParamsB = EqualizerAudioEngine.RenderParameters(
            preampLinear: powf(10, (settingsB.preampDB + settingsB.autoTrimDB) / 20),
            wetMixTarget: 0
        )

        let reservedEngine = EqualizerAudioEngine()
        reservedEngine.apply(settings: settingsA)
        let reservedEngineSnapshot = reservedEngine.readPublishedRenderParameters {
            for _ in 0 ..< 6 {
                reservedEngine.apply(settings: settingsB)
            }
        }
        #expect(reservedEngineSnapshot == expectedParamsA)
        #expect(reservedEngine.readPublishedRenderParameters() == expectedParamsB)
    }
}
