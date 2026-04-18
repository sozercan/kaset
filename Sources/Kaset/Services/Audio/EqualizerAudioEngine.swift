import AudioToolbox
import CoreAudio
import Foundation

// MARK: - EqualizerAudioEngine

/// HAL-level duplex implementation of the Kaset equalizer.
///
/// An `AudioDeviceIOProcID` is registered directly on the aggregate
/// device created by ``ProcessTapHelper`` (WebKit process tap + system
/// default output). The HAL delivers input (tap samples) and output
/// (speaker) buffer lists to the same I/O block, where we run six
/// cascaded ``BiquadFilter`` sections, apply an envelope-follower
/// limiter with stereo linking, and blend wet/dry.
///
/// **Not** `@MainActor`-isolated: the I/O block runs on Core Audio's
/// real-time thread. Lifecycle calls (`start`, `stop`, `apply`) are
/// invoked from the main-actor-isolated ``EqualizerService``.
final class EqualizerAudioEngine: EqualizerAudioEngineProtocol {
    /// Sample rate used when the tap hasn't reported one yet — only matters
    /// for biquad coefficient pre-seeding before the first audio cycle.
    private static let fallbackSampleRate: Float64 = 48000

    /// Channel count of the tap stream. Stereo is the only mixdown CATap
    /// exposes today, and biquads operate per channel.
    private static let tapChannelCount: Int = 2

    // MARK: - Public state

    private(set) var isRunning: Bool = false

    // swiftformat:disable modifierOrder
    /// Render-thread storage for the protocol-declared
    /// ``EqualizerAudioEngineProtocol/hasObservedAudio`` flag.
    nonisolated(unsafe) private(set) var hasObservedAudio: Bool = false
    // swiftformat:enable modifierOrder

    // MARK: - Private — HAL I/O

    private let tapHelper = ProcessTapHelper()

    /// HAL I/O proc registered on the aggregate device.
    private var ioProcID: AudioDeviceIOProcID?

    /// Format derived from the aggregate device's nominal sample rate.
    private var renderFormat: AudioStreamBasicDescription?

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

    /// Envelope-follower state. For stereo we use a single shared
    /// envelope and gain — "stereo linked" — so a transient on one
    /// channel pulls both channels down equally and the centre image
    /// stays stable (behaviour matches Logic / Ableton / Spotify's
    /// mastering limiters). Mono keeps its own pair.
    private var envStereo: Float = 0
    private var envMono: Float = 0
    private var limiterGainStereo: Float = 1
    private var limiterGainMono: Float = 1

    /// Snapshot of the band layout so we can reconfigure coefficients when
    /// settings change.
    private let bands: [EQBand]

    private let logger = DiagnosticsLogger.equalizer

    // MARK: - Init

    init(bands: [EQBand] = EQBand.defaultBands) {
        self.bands = bands
        self.filters = bands.map { _ in BiquadFilter() }
    }

    /// Defensive: if the service drops the engine without calling
    /// ``stop()``, the HAL thread could still trampoline into freed
    /// memory via the `AudioDeviceIOProcID` we registered. `stop()` is
    /// idempotent and safe to call here.
    deinit {
        if let procID = self.ioProcID {
            let aggregateID = self.tapHelper.aggregateDeviceID
            if aggregateID != kAudioObjectUnknown {
                AudioDeviceStop(aggregateID, procID)
                AudioDeviceDestroyIOProcID(aggregateID, procID)
            }
        }
    }

    // MARK: - Lifecycle

    /// Brings the tap, aggregate device, and HAL I/O proc up.
    ///
    /// Rolls back partial state in reverse order on any failure, so the app
    /// is always in either "fully running" or "fully torn down" state on
    /// return. Never throws into the caller.
    func start() -> Result<Void, StartFailure> {
        guard !self.isRunning else { return .success(()) }

        // Reset the silence-detection flag so the verifier in
        // ``EqualizerService`` measures only this run.
        self.hasObservedAudio = false

        // Reset envelope-follower and gain-smoothing state so a
        // stop/start cycle starts the limiter with a clean slate.
        self.envStereo = 0
        self.envMono = 0
        self.limiterGainStereo = 1
        self.limiterGainMono = 1

        // 1. Tap + aggregate device.
        switch self.tapHelper.start() {
        case .success:
            break
        case let .failure(reason):
            return .failure(.tap(reason))
        }

        let aggregateID = self.tapHelper.aggregateDeviceID

        // 2. Read the aggregate's nominal sample rate. The HAL I/O proc
        // will present input and output at this rate so the biquad chain
        // has a single known rate.
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

        // 3. Install HAL I/O proc on the aggregate.
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

        // 4. Start the aggregate — the HAL now drives our I/O proc on its
        // own thread.
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

    /// Stops rendering and destroys the tap. Safe to call repeatedly.
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
        // Reset so a stop/start cycle (e.g., after permission revoke) starts
        // the silence verifier with a clean slate.
        self.hasObservedAudio = false
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

    // MARK: - Render (called on HAL I/O thread)

    /// HAL I/O proc body. RT-thread: no allocations, no blocking.
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
        // create an array iterator (RT-safety). Hoist the filter array
        // out of `self.` so each loop iteration skips a class-pointer
        // load + bounds check.
        let gain = self.preampLinear
        var mix = self.wetMix
        let target = self.wetMixTarget
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

    /// One-pole smoothing constant for the wet/dry crossfade.
    /// `~ 1 / (τ · sampleRate)` with τ ≈ 10 ms at 48 kHz → 99 % settle in
    /// ~40 ms, fast enough to feel responsive but slow enough to avoid clicks.
    private static let crossfadeAlpha: Float = 0.002

    // Envelope-follower peak limiter. An internal peak follower with
    // fast attack and slower release tracks the signal envelope and
    // slews a gain-reduction multiplier toward `threshold / envelope`
    // whenever the envelope exceeds the ceiling. Unlike a memoryless
    // `tanh` saturator this produces **no harmonic distortion on
    // sustained content** — the signal is simply ducked while the
    // envelope is above threshold, so boosted presets keep their tonal
    // shape without the "tearing" artefacts a waveshaper introduces at
    // ±12 dB slider extremes.

    /// Threshold (linear amplitude) — ≈ −0.09 dBFS ceiling. Close to
    /// 0 dBFS so the limiter only intervenes on true clipping peaks;
    /// sustained content sits below threshold and the gain multiplier
    /// stays flat at 1.0, eliminating the subtle noise-floor modulation
    /// a tighter ceiling (e.g. 0.97) introduced. Trade-off: with a
    /// ~0.5 ms attack envelope, a step to ±1.0+ may briefly overshoot
    /// before `gain` catches up — safe for our Float32 HAL output path
    /// but worth keeping in mind if the device format ever narrows.
    private static let limiterThreshold: Float = 0.99
    /// Envelope-follower attack (~0.5 ms @ 48 kHz).
    private static let limiterAttackCoeff: Float = 0.959
    /// Envelope-follower release (~150 ms @ 48 kHz) — slow enough to
    /// prevent audible pumping on content that hovers near threshold.
    private static let limiterReleaseCoeff: Float = 0.9999
    /// Gain slew coefficient (~1 ms settling) — blocks zipper noise.
    private static let limiterGainSlew: Float = 0.04

    /// Shared envelope-follower update. Advances `envelope` toward
    /// `level` and slews `gain` toward `threshold / envelope` (or `1`).
    /// Returns the current gain multiplier.
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

    /// Mono variant of the envelope-follower limiter.
    @inline(__always)
    private static func limiterProcess(
        sample: Float,
        envelope: inout Float,
        gain: inout Float
    ) -> Float {
        let g = Self.limiterGainStep(level: abs(sample), envelope: &envelope, gain: &gain)
        return sample * g
    }

    /// Stereo-linked variant: one envelope/gain pair driven by
    /// `max(|L|, |R|)`. A peak on either channel ducks both equally, so
    /// the centre image stays anchored (no imbalance pumping).
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

    // MARK: - Format helper

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

    // MARK: - Errors

    enum StartFailure: Error {
        case tap(ProcessTapHelper.StartFailure)
        case invalidTapFormat
        case ioProcInstall(OSStatus)
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
            case let .ioProcInstall(status):
                String(localized: "Couldn't install the audio I/O proc (\(status)).")
            case let .engineStart(detail):
                String(localized: "Audio engine failed to start: \(detail)")
            }
        }
    }
}

// MARK: - C render callback

// C-convention trampoline that lets Core Audio's `AudioDeviceIOProc`
// invoke the Swift engine. The seven-parameter signature is dictated by
// `AudioDeviceIOProc` and cannot be reduced.
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
    // Derive frameCount from output buffer0's mDataByteSize (4 bytes/Float).
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
