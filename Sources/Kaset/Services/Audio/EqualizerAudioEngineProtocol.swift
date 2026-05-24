import Foundation

// MARK: - EqualizerAudioEngineProtocol

/// Audio-side surface that ``EqualizerService`` depends on. Production code
/// uses ``EqualizerAudioEngine``; tests inject a no-op stub so they don't
/// touch Core Audio.
///
/// Intentionally not actor-isolated: the production engine performs its
/// own internal synchronisation between the main thread (lifecycle) and the
/// render thread (DSP). `EqualizerService` calls all of these methods from
/// the main actor, sequencing the conformer's state accesses for free.
protocol EqualizerAudioEngineProtocol: AnyObject {
    var isRunning: Bool { get }
    /// `true` once the render thread has observed at least one non-zero
    /// input sample since the last successful `start()`. Read by
    /// ``EqualizerService/scheduleTapVerification`` to detect the case
    /// where Core Audio happily creates a tap but TCC silently denies it.
    var hasObservedAudio: Bool { get }
    func start() -> Result<Void, EqualizerAudioEngine.StartFailure>
    func stop()
    func apply(settings: EQSettings)
}
