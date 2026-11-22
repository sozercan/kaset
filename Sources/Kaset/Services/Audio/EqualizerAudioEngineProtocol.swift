import Foundation

protocol EqualizerAudioEngineProtocol: AnyObject {
    var isRunning: Bool { get }
    var hasObservedAudio: Bool { get }
    func start() -> Result<Void, EqualizerAudioEngine.StartFailure>
    func stop()
    func apply(settings: EQSettings)
}
