import AudioToolbox
import AVFoundation
import CoreAudio
import Foundation

// MARK: - EqualizerAudioEngine

/// Full-duplex AUHAL implementation of the Kaset equalizer.
///
/// A single `AUHAL` unit (`kAudioUnitSubType_HALOutput`) is bound to the
/// aggregate device created by ``ProcessTapHelper``:
/// - the aggregate's **tap** is exposed as the unit's input bus (1);
/// - the aggregate's **main sub-device** (the system default output) is the
///   unit's output bus (0);
/// - a single render callback pulls tap samples, runs six cascaded
///   ``BiquadFilter`` sections, blends wet/dry, soft-limits, and writes
///   straight to the output buffer.
///
/// Input and output share the aggregate clock domain, so there is no ring
/// buffer and no cross-device drift.
///
/// **Not** `@MainActor`-isolated: the render callback runs on Core Audio's
/// real-time thread and must be able to call back into the engine without
/// hopping actors. Lifecycle calls (`start`, `stop`, `apply`) are invoked
/// from the main-actor-isolated ``EqualizerService``.
final class EqualizerAudioEngine: EqualizerAudioEngineProtocol {
    /// Maximum frames per render cycle we pre-allocate input buffers for.
    /// AUHAL typically requests 512–1024 frames; 8192 is a comfortable cap.
    private static let maxFramesPerCycle: UInt32 = 8192

    /// Sample rate used when the tap hasn't reported one yet — only matters
    /// for biquad coefficient pre-seeding before the first audio cycle.
    private static let fallbackSampleRate: Float64 = 48000

    /// Channel count of the tap stream we negotiate with AUHAL. Stereo is
    /// the only mixdown CATap exposes today, and biquads operate per channel.
    private static let tapChannelCount: Int = 2

    // MARK: - Public state

    private(set) var isRunning: Bool = false

    // swiftformat:disable modifierOrder
    /// Render-thread storage for the protocol-declared
    /// ``EqualizerAudioEngineProtocol/hasObservedAudio`` flag.
    nonisolated(unsafe) private(set) var hasObservedAudio: Bool = false
    // swiftformat:enable modifierOrder

    // MARK: - Private — audio unit / graph

    private let tapHelper = ProcessTapHelper()
    private var audioUnit: AudioUnit?

    /// Format negotiated with the audio unit (stereo Float32 non-interleaved).
    /// Kept so we can configure biquads at the same sample rate we render at.
    private var renderFormat: AudioStreamBasicDescription?

    /// Heap-allocated input buffer list handed to `AudioUnitRender`.
    private var inputBufferList: UnsafeMutablePointer<AudioBufferList>?

    /// Backing storage for the two channels of the input buffer list.
    private var leftStorage: UnsafeMutablePointer<Float>?
    private var rightStorage: UnsafeMutablePointer<Float>?

    // MARK: - Private — DSP

    /// One biquad per EQ band, all cascaded on every frame.
    private let filters: [BiquadFilter]

    /// Preamp applied as a simple gain multiplier after the biquad chain.
    /// Stored as Float so audio-thread reads are effectively atomic.
    private var preampLinear: Float = 1

    /// Wet/dry crossfade target. Driven by ``apply(settings:)`` — `1` when
    /// the user enables the EQ, `0` when they disable it. Each render cycle
    /// the live ``wetMix`` slews toward this target so toggling never clicks.
    private var wetMixTarget: Float = 1

    /// Live wet/dry blend used inside the render callback.
    /// `0 = dry`, `1 = fully filtered`.
    private var wetMix: Float = 1

    /// Previous post-gain sample per channel, used by ``softLimitOversampled``
    /// to interpolate the half-rate point. Render-thread state.
    private var prevLeftSample: Float = 0
    private var prevRightSample: Float = 0
    private var prevMonoSample: Float = 0

    /// Snapshot of the band layout so we can reconfigure coefficients when
    /// settings change.
    private let bands: [EQBand]

    private let logger = DiagnosticsLogger.equalizer

    // MARK: - Init

    init(bands: [EQBand] = EQBand.defaultBands) {
        self.bands = bands
        self.filters = bands.map { _ in BiquadFilter() }
    }

    // MARK: - Lifecycle

    /// Brings the tap, aggregate device, AUHAL, and render graph up.
    ///
    /// Rolls back partial state in reverse order on any failure, so the app
    /// is always in either "fully running" or "fully torn down" state on
    /// return. Never throws into the caller.
    func start() -> Result<Void, StartFailure> {
        guard !self.isRunning else { return .success(()) }

        // Reset the silence-detection flag so the verifier in
        // ``EqualizerService`` measures only this run.
        self.hasObservedAudio = false

        // Reset oversample interpolation history so the first frame after
        // a restart doesn't pull a stale previous sample into the limiter.
        self.prevLeftSample = 0
        self.prevRightSample = 0
        self.prevMonoSample = 0

        // 1. Tap + aggregate device.
        switch self.tapHelper.start() {
        case .success:
            break
        case let .failure(reason):
            return .failure(.tap(reason))
        }

        // 2. Create AUHAL.
        guard let unit = Self.createHALAudioUnit() else {
            self.tapHelper.stop()
            return .failure(.unitCreation)
        }

        // 3. Enable input + output buses.
        if let status = Self.enableIO(unit: unit) {
            self.tearDown(partialUnit: unit)
            return .failure(.unitConfiguration(status))
        }

        // 4. Bind to the aggregate device.
        var aggregateID = self.tapHelper.aggregateDeviceID
        let bindStatus = AudioUnitSetProperty(
            unit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &aggregateID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        guard bindStatus == noErr else {
            self.logger.error("CurrentDevice bind failed: \(bindStatus)")
            self.tearDown(partialUnit: unit)
            return .failure(.deviceBind)
        }

        // 5. Negotiate format: stereo non-interleaved Float32 at the tap's
        // sample rate, so biquads work on a simple predictable layout.
        let sampleRate = self.tapHelper.tapStreamDescription?.mSampleRate ?? Self.fallbackSampleRate
        guard sampleRate > 0 else {
            self.tearDown(partialUnit: unit)
            return .failure(.invalidTapFormat)
        }

        var format = Self.stereoFloat32NonInterleaved(sampleRate: sampleRate)
        let formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)

        // Format the unit hands to us on the INPUT bus (1, output scope = to client).
        let inputFormatStatus = AudioUnitSetProperty(
            unit,
            kAudioUnitProperty_StreamFormat,
            kAudioUnitScope_Output,
            1,
            &format,
            formatSize
        )
        // Format we hand to the unit on the OUTPUT bus (0, input scope = from client).
        let outputFormatStatus = AudioUnitSetProperty(
            unit,
            kAudioUnitProperty_StreamFormat,
            kAudioUnitScope_Input,
            0,
            &format,
            formatSize
        )
        guard inputFormatStatus == noErr, outputFormatStatus == noErr else {
            self.logger.error(
                "format set failed (input=\(inputFormatStatus) output=\(outputFormatStatus))"
            )
            self.tearDown(partialUnit: unit)
            return .failure(.formatNegotiation)
        }

        // 6. Pre-allocate input buffers and install render callback.
        self.allocateInputBuffers(frameCapacity: Self.maxFramesPerCycle)

        var callback = AURenderCallbackStruct(
            inputProc: kasetEQRenderCallback,
            inputProcRefCon: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        )
        let cbStatus = AudioUnitSetProperty(
            unit,
            kAudioUnitProperty_SetRenderCallback,
            kAudioUnitScope_Input,
            0,
            &callback,
            UInt32(MemoryLayout<AURenderCallbackStruct>.size)
        )
        guard cbStatus == noErr else {
            self.logger.error("render callback install failed: \(cbStatus)")
            self.tearDown(partialUnit: unit)
            return .failure(.renderCallback(cbStatus))
        }

        // 7. Initialize + start.
        let initStatus = AudioUnitInitialize(unit)
        guard initStatus == noErr else {
            self.logger.error("AudioUnitInitialize failed: \(initStatus)")
            self.tearDown(partialUnit: unit)
            return .failure(.engineStart("AudioUnitInitialize: \(initStatus)"))
        }

        let startStatus = AudioOutputUnitStart(unit)
        guard startStatus == noErr else {
            self.logger.error("AudioOutputUnitStart failed: \(startStatus)")
            AudioUnitUninitialize(unit)
            self.tearDown(partialUnit: unit)
            return .failure(.engineStart("AudioOutputUnitStart: \(startStatus)"))
        }

        self.audioUnit = unit
        self.renderFormat = format
        self.isRunning = true
        self.logger.info("AUHAL started at \(format.mSampleRate) Hz")
        return .success(())
    }

    /// Stops rendering and destroys the tap. Safe to call repeatedly.
    func stop() {
        if let unit = self.audioUnit {
            AudioOutputUnitStop(unit)
            AudioUnitUninitialize(unit)
            AudioComponentInstanceDispose(unit)
            self.audioUnit = nil
        }
        self.freeInputBuffers()
        self.tapHelper.stop()
        self.renderFormat = nil
        self.isRunning = false
    }

    /// Applies the latest user-facing settings to the DSP chain.
    /// Safe to call from the main actor while rendering is active.
    func apply(settings: EQSettings) {
        let sampleRate = Float(self.renderFormat?.mSampleRate ?? Self.fallbackSampleRate)
        // User preamp + automatic headroom trim derived from peak band gain.
        // The soft limiter at the end of the render chain catches whatever
        // still pokes above 0 dBFS after this attenuation.
        let totalGainDB = settings.preampDB + settings.autoTrimDB
        self.preampLinear = powf(10, totalGainDB / 20)
        // Crossfade between dry and wet over ~50 ms instead of an abrupt
        // bypass switch — prevents the click users hear when filter state
        // changes from "live coefficients" to "straight passthrough".
        self.wetMixTarget = settings.isEnabled ? 1 : 0
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

    // MARK: - Render (called on audio I/O thread)

    /// Render callback body. Pulls input samples from the tap, runs the EQ
    /// chain in place, and writes the result to `outputBuffers`.
    func performRender(
        flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
        timestamp: UnsafePointer<AudioTimeStamp>,
        frameCount: UInt32,
        outputBuffers: UnsafeMutablePointer<AudioBufferList>?
    ) -> OSStatus {
        guard let unit = self.audioUnit,
              let inputList = self.inputBufferList,
              let outputList = outputBuffers
        else {
            return kAudioUnitErr_NoConnection
        }

        // Reset the sizes of the pre-allocated input buffers for this cycle.
        let mutableInput = UnsafeMutableAudioBufferListPointer(inputList)
        let bytesPerBuffer = frameCount * UInt32(MemoryLayout<Float>.size)
        for index in 0 ..< mutableInput.count {
            mutableInput[index].mDataByteSize = bytesPerBuffer
        }

        // Pull input samples from the tap side of the unit.
        let pullStatus = AudioUnitRender(unit, flags, timestamp, 1, frameCount, inputList)
        if pullStatus != noErr {
            // Emit silence on the output so the render thread doesn't go
            // critical; the render engine will recover on the next cycle.
            Self.silence(bufferList: outputList)
            return noErr
        }

        // Copy input → output and run biquads in place on the output buffers.
        let mutableOutput = UnsafeMutableAudioBufferListPointer(outputList)
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
            // Cheap silence detector — once we've ever seen audio we stop
            // scanning. The pre-check should usually catch denied
            // permission, but this catches the rest (TCC service split,
            // post-launch revoke, etc.).
            if !self.hasObservedAudio,
               UnsafeBufferPointer(start: src, count: frames).contains(where: { $0 != 0 })
            {
                self.hasObservedAudio = true
            }
        }

        // Run filters unconditionally; the wet/dry mix below handles bypass.
        // Iteration uses an explicit index so the render thread doesn't
        // create an array iterator (RT-safety).
        let gain = self.preampLinear
        var mix = self.wetMix
        let target = self.wetMixTarget
        let filterCount = self.filters.count

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
                return noErr
            }
            for filterIndex in 0 ..< filterCount {
                self.filters[filterIndex].processNonInterleavedStereo(
                    left: leftPtr,
                    right: rightPtr,
                    frameCount: frames
                )
            }
            var prevLeft = self.prevLeftSample
            var prevRight = self.prevRightSample
            for index in 0 ..< frames {
                mix += (target - mix) * Self.crossfadeAlpha
                let wetL = Self.softLimitOversampled(
                    leftPtr[index] * gain,
                    prevSample: &prevLeft
                )
                let wetR = Self.softLimitOversampled(
                    rightPtr[index] * gain,
                    prevSample: &prevRight
                )
                leftPtr[index] = dryLeft[index] * (1 - mix) + wetL * mix
                rightPtr[index] = dryRight[index] * (1 - mix) + wetR * mix
            }
            self.prevLeftSample = prevLeft
            self.prevRightSample = prevRight
        } else if channelCount == 1 {
            guard let ptr = mutableOutput[0].mData?
                .bindMemory(to: Float.self, capacity: frames),
                let dry = mutableInput[0].mData?
                .bindMemory(to: Float.self, capacity: frames)
            else {
                return noErr
            }
            for filterIndex in 0 ..< filterCount {
                self.filters[filterIndex].processMono(samples: ptr, frameCount: frames)
            }
            var prev = self.prevMonoSample
            for index in 0 ..< frames {
                mix += (target - mix) * Self.crossfadeAlpha
                let wet = Self.softLimitOversampled(
                    ptr[index] * gain,
                    prevSample: &prev
                )
                ptr[index] = dry[index] * (1 - mix) + wet * mix
            }
            self.prevMonoSample = prev
        }

        self.wetMix = mix
        return noErr
    }

    /// One-pole smoothing constant for the wet/dry crossfade.
    /// `~ 1 / (τ · sampleRate)` with τ ≈ 10 ms at 48 kHz → 99 % settle in
    /// ~40 ms, fast enough to feel responsive but slow enough to avoid clicks.
    private static let crossfadeAlpha: Float = 0.002

    /// Soft-knee limiter with a fixed −1 dBFS ceiling.
    ///
    /// Below ±0.9 (≈ −0.92 dBFS) the signal is passed through unchanged so
    /// quiet music isn't coloured. Above the threshold the excess is folded
    /// into the remaining 0.1 of headroom via `tanh`, so the output is hard
    /// capped at ±1.0 without the snap-clip artefacts of digital truncation.
    @inline(__always)
    private static func softLimit(_ sample: Float) -> Float {
        let threshold: Float = 0.9
        let absValue = abs(sample)
        if absValue <= threshold { return sample }
        let sign: Float = sample >= 0 ? 1 : -1
        let knee: Float = 1 - threshold
        let excess = absValue - threshold
        return sign * (threshold + knee * tanhf(excess / knee))
    }

    /// 2× oversampled wrapper around ``softLimit``.
    ///
    /// `tanh` saturation generates harmonics that, at our 48 kHz render
    /// rate, can fold above 24 kHz back into the audible band as a
    /// crackly fizz when every band is pushed to +12 dB. Linearly
    /// interpolating the half-rate point, applying the limiter at twice
    /// the rate, then box-filter decimating gives ~30 dB of alias
    /// suppression — enough to remove the audible artifact without the
    /// cost of a polyphase FIR.
    ///
    /// `prevSample` is in/out: callers pass a per-channel state slot that
    /// the function reads (for interpolation) and updates (for next call).
    @inline(__always)
    private static func softLimitOversampled(
        _ sample: Float,
        prevSample: inout Float
    ) -> Float {
        let interpolated = (prevSample + sample) * 0.5
        let limitedInterpolated = Self.softLimit(interpolated)
        let limitedSample = Self.softLimit(sample)
        prevSample = sample
        return (limitedInterpolated + limitedSample) * 0.5
    }

    // MARK: - Buffer management

    private func allocateInputBuffers(frameCapacity: UInt32) {
        self.freeInputBuffers()

        let channelCount = Self.tapChannelCount
        let bytesPerChannel = Int(frameCapacity) * MemoryLayout<Float>.size

        let leftPtr = UnsafeMutablePointer<Float>.allocate(capacity: Int(frameCapacity))
        let rightPtr = UnsafeMutablePointer<Float>.allocate(capacity: Int(frameCapacity))
        leftPtr.initialize(repeating: 0, count: Int(frameCapacity))
        rightPtr.initialize(repeating: 0, count: Int(frameCapacity))
        self.leftStorage = leftPtr
        self.rightStorage = rightPtr

        // `AudioBufferList` is declared with one inline `AudioBuffer`, so for
        // N channels we allocate sizeof(list) + (N-1) trailing buffers.
        let listSize = MemoryLayout<AudioBufferList>.size
            + MemoryLayout<AudioBuffer>.size * (channelCount - 1)
        let rawList = UnsafeMutableRawPointer.allocate(
            byteCount: listSize,
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        let list = rawList.assumingMemoryBound(to: AudioBufferList.self)
        list.pointee.mNumberBuffers = UInt32(channelCount)

        // `mDataByteSize` is overwritten per render cycle from the actual
        // `frameCount` AUHAL hands us; the value here is a defensive
        // prefill so the buffers never report zero-sized regions before
        // the first cycle runs.
        let mutable = UnsafeMutableAudioBufferListPointer(list)
        mutable[0] = AudioBuffer(
            mNumberChannels: 1,
            mDataByteSize: UInt32(bytesPerChannel),
            mData: UnsafeMutableRawPointer(leftPtr)
        )
        mutable[1] = AudioBuffer(
            mNumberChannels: 1,
            mDataByteSize: UInt32(bytesPerChannel),
            mData: UnsafeMutableRawPointer(rightPtr)
        )
        self.inputBufferList = list
    }

    private func freeInputBuffers() {
        if let list = self.inputBufferList {
            UnsafeMutableRawPointer(list).deallocate()
            self.inputBufferList = nil
        }
        if let leftPtr = self.leftStorage {
            leftPtr.deinitialize(count: Int(Self.maxFramesPerCycle))
            leftPtr.deallocate()
            self.leftStorage = nil
        }
        if let rightPtr = self.rightStorage {
            rightPtr.deinitialize(count: Int(Self.maxFramesPerCycle))
            rightPtr.deallocate()
            self.rightStorage = nil
        }
    }

    // MARK: - Teardown helpers

    private func tearDown(partialUnit: AudioUnit) {
        AudioComponentInstanceDispose(partialUnit)
        self.freeInputBuffers()
        self.tapHelper.stop()
    }

    // MARK: - AUHAL plumbing

    private static func createHALAudioUnit() -> AudioUnit? {
        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        guard let component = AudioComponentFindNext(nil, &description) else {
            DiagnosticsLogger.equalizer.error("HAL AudioComponent not found")
            return nil
        }
        var unit: AudioUnit?
        let status = AudioComponentInstanceNew(component, &unit)
        guard status == noErr, let unit else {
            DiagnosticsLogger.equalizer.error("AudioComponentInstanceNew failed: \(status)")
            return nil
        }
        return unit
    }

    private static func enableIO(unit: AudioUnit) -> OSStatus? {
        // Output bus 0 = render to device, input bus 1 = capture from tap.
        var enabled: UInt32 = 1
        let size = UInt32(MemoryLayout<UInt32>.size)
        let outputStatus = AudioUnitSetProperty(
            unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &enabled, size
        )
        if outputStatus != noErr {
            DiagnosticsLogger.equalizer.error("EnableIO output failed: \(outputStatus)")
            return outputStatus
        }
        let inputStatus = AudioUnitSetProperty(
            unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &enabled, size
        )
        if inputStatus != noErr {
            DiagnosticsLogger.equalizer.error("EnableIO input failed: \(inputStatus)")
            return inputStatus
        }
        return nil
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

    private static func silence(bufferList: UnsafeMutablePointer<AudioBufferList>) {
        let mutable = UnsafeMutableAudioBufferListPointer(bufferList)
        for index in 0 ..< mutable.count {
            if let data = mutable[index].mData {
                memset(data, 0, Int(mutable[index].mDataByteSize))
            }
        }
    }

    // MARK: - Errors

    enum StartFailure: Error {
        case tap(ProcessTapHelper.StartFailure)
        case invalidTapFormat
        case unitCreation
        case unitConfiguration(OSStatus)
        case deviceBind
        case formatNegotiation
        case renderCallback(OSStatus)
        case engineStart(String)

        /// Whether the failure is recoverable just by playing audio — we
        /// shouldn't show a permission warning in this case.
        var isWaitingForPlayback: Bool {
            if case .tap(.noAudioSource) = self { return true }
            return false
        }

        /// Whether the failure points to the audio-capture TCC permission.
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
            case .unitCreation:
                String(localized: "Couldn't create the audio unit.")
            case let .unitConfiguration(status):
                String(localized: "Couldn't configure the audio unit (\(status)).")
            case .deviceBind:
                String(localized: "Couldn't route Kaset's audio into the equalizer engine.")
            case .formatNegotiation:
                String(localized: "Couldn't negotiate a compatible audio format with the output device.")
            case let .renderCallback(status):
                String(localized: "Couldn't install the audio render callback (\(status)).")
            case let .engineStart(detail):
                String(localized: "Audio engine failed to start: \(detail)")
            }
        }
    }
}

// MARK: - C render callback

// Top-level C render callback. Trampolines into the engine instance carried
// in `refCon`. Must be `@convention(c)` so Core Audio can invoke it without
// Swift closure context. The six-parameter signature is dictated by
// `AURenderCallback` and cannot be reduced.
// swiftlint:disable:next function_parameter_count
private func kasetEQRenderCallback(
    refCon: UnsafeMutableRawPointer,
    ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
    inTimeStamp: UnsafePointer<AudioTimeStamp>,
    inBusNumber _: UInt32,
    inNumberFrames: UInt32,
    ioData: UnsafeMutablePointer<AudioBufferList>?
) -> OSStatus {
    let engine = Unmanaged<EqualizerAudioEngine>
        .fromOpaque(refCon)
        .takeUnretainedValue()
    return engine.performRender(
        flags: ioActionFlags,
        timestamp: inTimeStamp,
        frameCount: inNumberFrames,
        outputBuffers: ioData
    )
}
