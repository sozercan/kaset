import CoreAudio
import Foundation

struct RouteChangeEvent: Equatable {
    let at: ContinuousClock.Instant
    let isDisappearance: Bool
    var lostDevice: String?
    var defaultDevice: String?
    var isConsumed = false

    func restores(_ device: String?) -> Bool {
        guard let device else { return false }
        return self.defaultDevice == device
    }
}

final class RouteChangeRecord: @unchecked Sendable {
    private struct ClaimedLoss {
        let admittedAt: ContinuousClock.Instant
        let lostDevice: String?
    }

    private let lock = NSLock()
    private var events: [RouteChangeEvent] = []
    private var claimedLosses: [ClaimedLoss] = []
    private var defaultDeviceID: AudioDeviceID?
    private var defaultDevice: String?
    private static let retention = Duration.seconds(30)
    private static let capacity = 32
    private static let claimCapacity = 8

    func prime(defaultDeviceID: AudioDeviceID?, deviceIdentity: (AudioDeviceID) -> String) {
        self.lock.withLock {
            self.defaultDeviceID = defaultDeviceID
            self.defaultDevice = defaultDeviceID.map(deviceIdentity)
        }
    }

    func recordChange(
        at instant: ContinuousClock.Instant,
        currentDefaultDeviceID: () -> AudioDeviceID?,
        isDeviceUsable: (AudioDeviceID) -> Bool,
        deviceIdentity: (AudioDeviceID) -> String
    ) {
        self.lock.withLock {
            let isDisappearance = self.defaultDeviceID.map { !isDeviceUsable($0) } ?? false
            let at = self.events.last.map { max(instant, $0.at) } ?? instant
            let newDefaultDeviceID = currentDefaultDeviceID()
            let newDefaultDevice = newDefaultDeviceID.map(deviceIdentity)
            self.events.append(RouteChangeEvent(
                at: at,
                isDisappearance: isDisappearance,
                lostDevice: isDisappearance ? self.defaultDevice : nil,
                defaultDevice: newDefaultDevice
            ))
            self.events.removeAll { at - $0.at > Self.retention }
            if self.events.count > Self.capacity {
                self.events.removeFirst(self.events.count - Self.capacity)
            }
            self.defaultDeviceID = newDefaultDeviceID
            self.defaultDevice = newDefaultDevice
        }
    }

    func routeRestored(since instant: ContinuousClock.Instant) -> Bool {
        self.lock.withLock {
            let lostDevice = self.claimedLosses.last { $0.admittedAt == instant }?.lostDevice
            return DefaultOutputDeviceMonitor.routeRestored(in: self.events, since: instant, lostDevice: lostDevice)
        }
    }

    func claimRouteLoss(admittedAt instant: ContinuousClock.Instant, within window: Duration) -> Bool {
        self.lock.withLock {
            guard let index = DefaultOutputDeviceMonitor.routeLossIndex(
                in: self.events,
                admittedAt: instant,
                within: window
            ) else { return false }
            self.events[index].isConsumed = true
            self.claimedLosses.append(ClaimedLoss(admittedAt: instant, lostDevice: self.events[index].lostDevice))
            if self.claimedLosses.count > Self.claimCapacity {
                self.claimedLosses.removeFirst(self.claimedLosses.count - Self.claimCapacity)
            }
            return true
        }
    }
}

@MainActor
final class DefaultOutputDeviceMonitor {
    static let shared = DefaultOutputDeviceMonitor()

    private var handler: (() -> Void)?
    private var isListening = false
    private let logger = DiagnosticsLogger.player
    private init() {}

    nonisolated func claimRouteLossPause(admittedAt instant: ContinuousClock.Instant, within window: Duration) -> Bool {
        CoreAudioOutput.record.claimRouteLoss(admittedAt: instant, within: window)
    }

    nonisolated static func routeLossIndex(
        in events: [RouteChangeEvent],
        admittedAt instant: ContinuousClock.Instant,
        within window: Duration
    ) -> Int? {
        guard let index = events.lastIndex(where: { $0.isDisappearance && $0.at <= instant }),
              !events[index].isConsumed,
              instant - events[index].at <= window
        else { return nil }

        let disappearance = events[index]
        let restoredBeforeCommand = events.contains { event in
            event.at > disappearance.at && event.at <= instant && event.restores(disappearance.lostDevice)
        }
        return restoredBeforeCommand ? nil : index
    }

    nonisolated func routeRestored(since instant: ContinuousClock.Instant) -> Bool {
        CoreAudioOutput.record.routeRestored(since: instant)
    }

    nonisolated static func routeRestored(
        in events: [RouteChangeEvent],
        since instant: ContinuousClock.Instant,
        lostDevice: String?
    ) -> Bool {
        guard let latest = events.last(where: { $0.at > instant }) else { return false }
        return latest.restores(lostDevice)
    }

    func start(onChange handler: @escaping () -> Void) {
        self.handler = handler
        guard !self.isListening else { return }

        CoreAudioOutput.record.prime(
            defaultDeviceID: CoreAudioOutput.currentDefaultOutputDeviceID(),
            deviceIdentity: CoreAudioOutput.deviceIdentity
        )

        var address = CoreAudioOutput.defaultOutputDeviceAddress
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            nil,
            CoreAudioOutput.listener
        )
        guard status == noErr else {
            self.logger.warning("failed to listen for default-output changes: \(status)")
            return
        }
        self.isListening = true
    }

    fileprivate func notifyChange() {
        self.handler?()
    }
}

private enum CoreAudioOutput {
    static let record = RouteChangeRecord()

    static let listener:
        @Sendable (UInt32, UnsafePointer<AudioObjectPropertyAddress>) -> Void = { _, _ in
            let changedAt = ContinuousClock.now
            CoreAudioOutput.record.recordChange(
                at: changedAt,
                currentDefaultDeviceID: CoreAudioOutput.currentDefaultOutputDeviceID,
                isDeviceUsable: CoreAudioOutput.isDeviceUsable,
                deviceIdentity: CoreAudioOutput.deviceIdentity
            )
            Task { @MainActor in
                DefaultOutputDeviceMonitor.shared.notifyChange()
            }
        }

    static var defaultOutputDeviceAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    static func currentDefaultOutputDeviceID() -> AudioDeviceID? {
        var address = CoreAudioOutput.defaultOutputDeviceAddress
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceID
        )
        guard status == noErr, deviceID != AudioDeviceID(kAudioObjectUnknown) else { return nil }
        return deviceID
    }

    static func deviceIdentity(_ deviceID: AudioDeviceID) -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var uid: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &uid)
        guard status == noErr, let uid else { return "id:\(deviceID)" }
        return "uid:\(uid.takeRetainedValue() as String)"
    }

    static func isDeviceUsable(_ deviceID: AudioDeviceID) -> Bool {
        if let availableDeviceIDs = self.availableDeviceIDs(), !availableDeviceIDs.contains(deviceID) {
            return false
        }

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsAlive,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var isAlive = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &isAlive)
        guard status == noErr else { return false }
        return isAlive != 0
    }

    static func availableDeviceIDs() -> Set<AudioDeviceID>? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(0)
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size
        ) == noErr, size > 0 else { return nil }

        let capacity = size
        var deviceIDs = [AudioDeviceID](
            repeating: 0,
            count: Int(capacity) / MemoryLayout<AudioDeviceID>.size
        )
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceIDs
        ) == noErr else { return nil }

        var currentSize = UInt32(0)
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &currentSize
        ) == noErr, currentSize <= capacity else { return nil }
        return Set(deviceIDs.prefix(Int(size) / MemoryLayout<AudioDeviceID>.size))
    }
}
