import AudioToolbox
import CoreAudio
import Foundation
import Synchronization

final class EqualizerAudioEngine: EqualizerAudioEngineProtocol {
    private static let fallbackSampleRate: Float64 = 48000

    private static let tapChannelCount: Int = 2

    struct RenderParameters: Equatable {
        let preampLinear: Float
        let wetMixTarget: Float

        static let unity = Self(preampLinear: 1, wetMixTarget: 1)
    }

    private(set) var isRunning: Bool = false

    private let hasObservedAudioStorage = Atomic<Bool>(false)

    var hasObservedAudio: Bool {
        self.hasObservedAudioStorage.load(ordering: .acquiring)
    }

    private let tapHelper = ProcessTapHelper()

    private var ioProcID: AudioDeviceIOProcID?

    private var renderFormat: AudioStreamBasicDescription?

    private let filters: [BiquadFilter]

    private let parameterSlots: UnsafeMutablePointer<RenderParameters>
    private let publishedParameterSlot = Atomic<Int>(0)
    private let readerReservedParameterSlot = Atomic<Int>(-1)
    private let parameterWriterLock = NSLock()
    private var writerParameterSlot = 0
    private var cachedRenderParameters = RenderParameters.unity

    private var wetMix: Float = 1

    private var envStereo: Float = 0
    private var envMono: Float = 0
    private var limiterGainStereo: Float = 1
    private var limiterGainMono: Float = 1

    private let bands: [EQBand]

    private let logger = DiagnosticsLogger.equalizer

    init(bands: [EQBand] = EQBand.defaultBands) {
        self.bands = bands
        self.filters = bands.map { _ in BiquadFilter() }
        self.parameterSlots = UnsafeMutablePointer<RenderParameters>.allocate(capacity: 3)
        self.parameterSlots.initialize(repeating: .unity, count: 3)
    }

    deinit {
        if let procID = self.ioProcID {
            let aggregateID = self.tapHelper.aggregateDeviceID
            if aggregateID != kAudioObjectUnknown {
                AudioDeviceStop(aggregateID, procID)
                AudioDeviceDestroyIOProcID(aggregateID, procID)
            }
        }
        self.parameterSlots.deinitialize(count: 3)
        self.parameterSlots.deallocate()
    }

    func start() -> Result<Void, StartFailure> {
        guard !self.isRunning else { return .success(()) }

        self.hasObservedAudioStorage.store(false, ordering: .releasing)

        self.envStereo = 0
        self.envMono = 0
        self.limiterGainStereo = 1
        self.limiterGainMono = 1

        switch self.tapHelper.start() {
        case .success:
            break
        case let .failure(reason):
            return .failure(.tap(reason))
        }

        let aggregateID = self.tapHelper.aggregateDeviceID

        var sampleRate: Float64 = 0
        var srateSize = UInt32(MemoryLayout<Float64>.size)
        var srateAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let srateStatus = AudioObjectGetPropertyData(
            aggregateID, &srateAddr, 0, nil, &srateSize, &sampleRate
        )
        guard srateStatus == noErr, sampleRate > 0 else {
            self.logger.error("aggregate sample rate read failed: \(srateStatus)")
            self.tapHelper.stop()
            return .failure(.invalidTapFormat)
        }
        let format = Self.stereoFloat32NonInterleaved(sampleRate: sampleRate)
        self.renderFormat = format

        let selfRef = Unmanaged.passUnretained(self).toOpaque()
        var procID: AudioDeviceIOProcID?
        let createStatus = AudioDeviceCreateIOProcID(
            aggregateID, kasetEQIOProc, selfRef, &procID
        )
        guard createStatus == noErr, let procID else {
            self.logger.error("AudioDeviceCreateIOProcID failed: \(createStatus)")
            self.tapHelper.stop()
            return .failure(.ioProcInstall(createStatus))
        }
        self.ioProcID = procID

        let startStatus = AudioDeviceStart(aggregateID, procID)
        guard startStatus == noErr else {
            self.logger.error("AudioDeviceStart failed: \(startStatus)")
            AudioDeviceDestroyIOProcID(aggregateID, procID)
            self.ioProcID = nil
            self.tapHelper.stop()
            return .failure(.engineStart("AudioDeviceStart: \(startStatus)"))
        }

        self.isRunning = true
        self.logger.info("HAL I/O proc started at \(sampleRate) Hz")
        return .success(())
    }

    func stop() {
        if let procID = self.ioProcID {
            let aggregateID = self.tapHelper.aggregateDeviceID
            if aggregateID != kAudioObjectUnknown {
                AudioDeviceStop(aggregateID, procID)
                AudioDeviceDestroyIOProcID(aggregateID, procID)
            }
            self.ioProcID = nil
        }
        self.tapHelper.stop()
        self.renderFormat = nil
        self.isRunning = false
        self.hasObservedAudioStorage.store(false, ordering: .releasing)
    }

    func apply(settings: EQSettings) {
        let sampleRate = Float(self.renderFormat?.mSampleRate ?? Self.fallbackSampleRate)
        let totalGainDB = settings.preampDB + settings.autoTrimDB
        let params = RenderParameters(
            preampLinear: powf(10, totalGainDB / 20),
            wetMixTarget: settings.isEnabled ? 1 : 0
        )
        self.parameterWriterLock.lock()
        let published = self.writerParameterSlot
        let reserved = self.readerReservedParameterSlot.load(ordering: .sequentiallyConsistent)
        var nextSlot = (published + 1) % 3
        if nextSlot == reserved {
            nextSlot = (nextSlot + 1) % 3
        }
        self.parameterSlots[nextSlot] = params
        self.publishedParameterSlot.store(nextSlot, ordering: .sequentiallyConsistent)
        self.writerParameterSlot = nextSlot
        self.parameterWriterLock.unlock()
        for (index, band) in self.bands.enumerated() {
            guard index < settings.bandGainsDB.count else { break }
            let gainDB = settings.bandGainsDB[index]
            switch band.type {
            case .peaking:
                self.filters[index].setPeakingEQ(
                    frequency: band.frequencyHz,
                    q: band.q,
                    gainDB: gainDB,
                    sampleRate: sampleRate
                )
            case .lowShelf:
                self.filters[index].setLowShelf(
                    frequency: band.frequencyHz,
                    slope: band.q,
                    gainDB: gainDB,
                    sampleRate: sampleRate
                )
            case .highShelf:
                self.filters[index].setHighShelf(
                    frequency: band.frequencyHz,
                    slope: band.q,
                    gainDB: gainDB,
                    sampleRate: sampleRate
                )
            }
        }
    }

    func performRender(
        inputBuffers: UnsafePointer<AudioBufferList>,
        frameCount: UInt32,
        outputBuffers: UnsafeMutablePointer<AudioBufferList>
    ) {
        let mutableInput = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: inputBuffers)
        )
        let mutableOutput = UnsafeMutableAudioBufferListPointer(outputBuffers)
        let frames = Int(frameCount)

        let channelCount = min(mutableInput.count, mutableOutput.count)
        for channelIndex in 0 ..< channelCount {
            guard let src = mutableInput[channelIndex].mData?
                .bindMemory(to: Float.self, capacity: frames),
                let dst = mutableOutput[channelIndex].mData?
                .bindMemory(to: Float.self, capacity: frames)
            else {
                continue
            }
            dst.update(from: src, count: frames)
            if !self.hasObservedAudioStorage.load(ordering: .relaxed),
               UnsafeBufferPointer(start: src, count: frames).contains(where: { $0 != 0 })
            {
                self.hasObservedAudioStorage.store(true, ordering: .releasing)
            }
        }

        let publishedParams = self.readPublishedRenderParameters()
        let gain = publishedParams.preampLinear
        var mix = self.wetMix
        let target = publishedParams.wetMixTarget
        let filters = self.filters
        let filterCount = filters.count

        if channelCount >= 2 {
            guard let leftPtr = mutableOutput[0].mData?
                .bindMemory(to: Float.self, capacity: frames),
                let rightPtr = mutableOutput[1].mData?
                .bindMemory(to: Float.self, capacity: frames),
                let dryLeft = mutableInput[0].mData?
                .bindMemory(to: Float.self, capacity: frames),
                let dryRight = mutableInput[1].mData?
                .bindMemory(to: Float.self, capacity: frames)
            else {
                return
            }
            for filterIndex in 0 ..< filterCount {
                filters[filterIndex].processNonInterleavedStereo(
                    left: leftPtr,
                    right: rightPtr,
                    frameCount: frames
                )
            }
            var env = self.envStereo
            var gR = self.limiterGainStereo
            for index in 0 ..< frames {
                mix += (target - mix) * Self.crossfadeAlpha
                let lSample = leftPtr[index] * gain
                let rSample = rightPtr[index] * gain
                let (wetL, wetR) = Self.limiterProcessStereo(
                    left: lSample, right: rSample, envelope: &env, gain: &gR
                )
                leftPtr[index] = dryLeft[index] * (1 - mix) + wetL * mix
                rightPtr[index] = dryRight[index] * (1 - mix) + wetR * mix
            }
            self.envStereo = env
            self.limiterGainStereo = gR
        } else if channelCount == 1 {
            guard let ptr = mutableOutput[0].mData?
                .bindMemory(to: Float.self, capacity: frames),
                let dry = mutableInput[0].mData?
                .bindMemory(to: Float.self, capacity: frames)
            else {
                return
            }
            for filterIndex in 0 ..< filterCount {
                filters[filterIndex].processMono(samples: ptr, frameCount: frames)
            }
            var env = self.envMono
            var gm = self.limiterGainMono
            for index in 0 ..< frames {
                mix += (target - mix) * Self.crossfadeAlpha
                let wet = Self.limiterProcess(
                    sample: ptr[index] * gain, envelope: &env, gain: &gm
                )
                ptr[index] = dry[index] * (1 - mix) + wet * mix
            }
            self.envMono = env
            self.limiterGainMono = gm
        }

        self.wetMix = mix
    }

    func readPublishedRenderParameters(
        onSlotReserved: (() -> Void)? = nil
    ) -> RenderParameters {
        var index = self.publishedParameterSlot.load(ordering: .acquiring)
        for _ in 0 ..< 4 {
            self.readerReservedParameterSlot.store(index, ordering: .sequentiallyConsistent)
            let confirmed = self.publishedParameterSlot.load(ordering: .sequentiallyConsistent)
            if confirmed == index {
                onSlotReserved?()
                let snapshot = self.parameterSlots[index]
                self.readerReservedParameterSlot.store(-1, ordering: .releasing)
                self.cachedRenderParameters = snapshot
                return snapshot
            }
            index = confirmed
        }
        self.readerReservedParameterSlot.store(-1, ordering: .releasing)
        return self.cachedRenderParameters
    }

    private static let crossfadeAlpha: Float = 0.002

    private static let limiterThreshold: Float = 0.99
    private static let limiterAttackCoeff: Float = 0.959
    private static let limiterReleaseCoeff: Float = 0.9999
    private static let limiterGainSlew: Float = 0.04

    @inline(__always)
    private static func limiterGainStep(
        level: Float,
        envelope: inout Float,
        gain: inout Float
    ) -> Float {
        if level > envelope {
            envelope = self.limiterAttackCoeff * envelope
                + (1 - self.limiterAttackCoeff) * level
        } else {
            envelope = self.limiterReleaseCoeff * envelope
                + (1 - self.limiterReleaseCoeff) * level
        }
        let target: Float = envelope > Self.limiterThreshold
            ? Self.limiterThreshold / envelope
            : 1
        gain += (target - gain) * Self.limiterGainSlew
        return gain
    }

    @inline(__always)
    private static func limiterProcess(
        sample: Float,
        envelope: inout Float,
        gain: inout Float
    ) -> Float {
        let g = Self.limiterGainStep(level: abs(sample), envelope: &envelope, gain: &gain)
        return sample * g
    }

    @inline(__always)
    private static func limiterProcessStereo(
        left: Float,
        right: Float,
        envelope: inout Float,
        gain: inout Float
    ) -> (Float, Float) {
        let g = Self.limiterGainStep(
            level: max(abs(left), abs(right)), envelope: &envelope, gain: &gain
        )
        return (left * g, right * g)
    }

    private static func stereoFloat32NonInterleaved(sampleRate: Float64) -> AudioStreamBasicDescription {
        let bytesPerSample = UInt32(MemoryLayout<Float>.size)
        return AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat
                | kAudioFormatFlagIsPacked
                | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: bytesPerSample,
            mFramesPerPacket: 1,
            mBytesPerFrame: bytesPerSample,
            mChannelsPerFrame: UInt32(Self.tapChannelCount),
            mBitsPerChannel: 32,
            mReserved: 0
        )
    }

    enum StartFailure: Error {
        case tap(ProcessTapHelper.StartFailure)
        case invalidTapFormat
        case ioProcInstall(OSStatus)
        case engineStart(String)

        var isWaitingForPlayback: Bool {
            if case .tap(.noAudioSource) = self {
                return true
            }
            return false
        }

        var isPermissionLikely: Bool {
            switch self {
            case .tap(.tapCreation), .tap(.permissionDenied):
                true
            default:
                false
            }
        }

        var userFacingMessage: String {
            switch self {
            case .tap(.noAudioSource):
                String(localized: "The equalizer activates as soon as you start playback.")
            case let .tap(.tapCreation(status)):
                String(localized: "Couldn't capture Kaset's audio (status \(status)). Check Screen & System Audio Recording permission in System Settings.")
            case .tap(.permissionDenied):
                String(localized: "Open System Settings → Privacy & Security → Screen & System Audio Recording and enable Kaset, then toggle the equalizer on again.")
            case .tap(.aggregateDeviceCreation):
                String(localized: "Couldn't create the equalizer audio device. Restarting Kaset usually fixes this.")
            case .tap(.unsupportedOS):
                String(localized: "The equalizer requires macOS 14.2 or later.")
            case .invalidTapFormat:
                String(localized: "The system didn't report a valid audio format for Kaset's output. Try disabling the equalizer, starting playback, then enabling it again.")
            case let .ioProcInstall(status):
                String(localized: "Couldn't install the audio I/O proc (\(status)).")
            case let .engineStart(detail):
                String(localized: "Audio engine failed to start: \(detail)")
            }
        }
    }
}

// swiftlint:disable:next function_parameter_count
private func kasetEQIOProc(
    inDevice _: AudioObjectID,
    inNow _: UnsafePointer<AudioTimeStamp>,
    inInputData: UnsafePointer<AudioBufferList>,
    inInputTime _: UnsafePointer<AudioTimeStamp>,
    outOutputData: UnsafeMutablePointer<AudioBufferList>,
    inOutputTime _: UnsafePointer<AudioTimeStamp>,
    inClientData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let inClientData else { return kAudioUnitErr_NoConnection }
    let engine = Unmanaged<EqualizerAudioEngine>
        .fromOpaque(inClientData)
        .takeUnretainedValue()
    let outList = UnsafeMutableAudioBufferListPointer(outOutputData)
    let frames = outList.isEmpty
        ? 0
        : outList[0].mDataByteSize / UInt32(MemoryLayout<Float>.size)
    engine.performRender(
        inputBuffers: inInputData,
        frameCount: frames,
        outputBuffers: outOutputData
    )
    return noErr
}
