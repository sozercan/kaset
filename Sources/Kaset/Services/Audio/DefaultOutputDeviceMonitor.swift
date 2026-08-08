import CoreAudio
import Foundation

// MARK: - RouteChangeEvent

/// One observed change of the system output device.
struct RouteChangeEvent: Equatable {
    let at: ContinuousClock.Instant
    /// True when the device that had been the default went away, as opposed to the user
    /// switching outputs or a new device arriving.
    let isDisappearance: Bool
    /// Set once this disappearance has explained a pause, so it cannot explain another.
    var isConsumed = false
}

// MARK: - RouteChangeRecord

/// Thread-safe log of recent system output-device changes.
///
/// Core Audio delivers notifications on its own thread while these are read on the MainActor,
/// and consumers classify events by how closely they followed a route change — tens of
/// milliseconds. Storing this in actor-isolated state would date a change to whenever a hop
/// happened to be scheduled instead of to when the route actually changed.
///
/// A log rather than a latest-pair: classification runs after an unbounded hop, so further
/// route events can land before a queued command is judged, and keeping only the newest pair
/// would discard the very event that explains it.
private final class RouteChangeRecord: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [RouteChangeEvent] = []
    private var defaultDeviceID: AudioDeviceID?
    /// Far longer than any classification window, and still a hard bound on growth.
    private static let retention = Duration.seconds(30)
    private static let capacity = 32

    func prime(defaultDeviceID: AudioDeviceID?) {
        self.lock.withLock { self.defaultDeviceID = defaultDeviceID }
    }

    /// Appends a change, marking it a disappearance when the device that had been the default is
    /// gone — the difference between headphones being unplugged and the user picking a different
    /// output.
    ///
    /// Timestamping and the Core Audio queries all happen under this lock. A `nil` dispatch queue
    /// means the listener runs directly on the notifying thread with no serialization, so
    /// overlapping callbacks would otherwise interleave: one could pair its device ID with
    /// another's usability result, or commit out of order and drop the very disappearance a
    /// queued pause needs to be attributed. Serializing the whole sequence also makes the
    /// timestamps monotonic by construction.
    func recordChange(
        currentDefaultDeviceID: () -> AudioDeviceID?,
        isDeviceUsable: (AudioDeviceID) -> Bool
    ) {
        self.lock.withLock {
            let instant = ContinuousClock.now
            let isDisappearance = self.defaultDeviceID.map { !isDeviceUsable($0) } ?? false
            self.events.append(RouteChangeEvent(at: instant, isDisappearance: isDisappearance))
            self.events.removeAll { instant - $0.at > Self.retention }
            if self.events.count > Self.capacity {
                self.events.removeFirst(self.events.count - Self.capacity)
            }
            self.defaultDeviceID = currentDefaultDeviceID()
        }
    }

    func routeRestored(since instant: ContinuousClock.Instant) -> Bool {
        self.lock.withLock {
            DefaultOutputDeviceMonitor.routeRestored(in: self.events, since: instant)
        }
    }

    /// Claims the disappearance that explains a pause admitted at `instant`, if there is one.
    ///
    /// Claiming is what keeps a single disconnect from excusing every pause that follows it:
    /// a user pressing Pause moments after the system already did must keep its own meaning.
    func claimRouteLoss(admittedAt instant: ContinuousClock.Instant, within window: Duration) -> Bool {
        self.lock.withLock {
            guard let index = DefaultOutputDeviceMonitor.routeLossIndex(
                in: self.events,
                admittedAt: instant,
                within: window
            ) else { return false }
            self.events[index].isConsumed = true
            return true
        }
    }
}

// MARK: - DefaultOutputDeviceMonitor

/// Reports system default-output-device changes: Bluetooth connect/disconnect,
/// headphone plug/unplug, and manual output switches.
///
/// `EqualizerService` installs its own listener, but that one is gated behind the
/// equalizer being enabled. Playback-state correctness must not depend on a
/// user-facing audio feature being switched on, so this monitor stays independent.
///
/// Known limitation: this watches only which device is the default output. A route change
/// *within* one device — some Macs expose speakers and the headphone jack as data sources on
/// the same built-in device — leaves that selection untouched and goes unseen. Covering it
/// means also listening on the current device's output data source and retargeting those
/// listeners on every default-device change. Bluetooth, the case this was built for, always
/// swaps the device itself; consumers degrade to their pre-existing behavior when a change is
/// missed rather than misbehaving.
@MainActor
final class DefaultOutputDeviceMonitor {
    static let shared = DefaultOutputDeviceMonitor()

    private var handler: (() -> Void)?
    private var isListening = false
    private let logger = DiagnosticsLogger.player
    // swiftformat:disable:next modifierOrder
    nonisolated private static let record = RouteChangeRecord()

    private init() {}

    /// Claims the disappearance explaining a pause admitted at `instant`, if there is one.
    ///
    /// macOS stops playback when a route vanishes by sending the app a `pause` remote command,
    /// which is indistinguishable from the user pressing Pause. Pairing it with a device that
    /// just went away is what tells the two apart — and why a device merely being added, or the
    /// user switching outputs by hand, deliberately does not qualify.
    ///
    /// Each disappearance can explain at most one pause. Otherwise a user pressing Pause shortly
    /// after the system already paused for the same disconnect would also read as system-driven,
    /// losing their explicit intent and letting a later reconnect resume against it.
    ///
    /// `instant` must be when the command was admitted, not when it is being handled: commands
    /// are drained onto the MainActor asynchronously, so measuring against the handling time
    /// would let a delayed main actor age a genuine route pause out of the window, or backdate
    /// a user pause into one.
    nonisolated func claimRouteLossPause(admittedAt instant: ContinuousClock.Instant, within window: Duration) -> Bool {
        Self.record.claimRouteLoss(admittedAt: instant, within: window)
    }

    /// Pure decision behind ``claimRouteLossPause(admittedAt:within:)``: which logged
    /// disappearance, if any, explains a pause admitted at `instant`.
    ///
    /// Reconstructs the route timeline *as of* `instant` rather than as of now. Classification
    /// runs after an unbounded hop, so route events can land in between; judging by the latest
    /// state would let a reconnect arriving after the pause retroactively turn a genuine
    /// route-loss pause into a user pause and disable recovery.
    nonisolated static func routeLossIndex(
        in events: [RouteChangeEvent],
        admittedAt instant: ContinuousClock.Instant,
        within window: Duration
    ) -> Int? {
        guard let index = events.lastIndex(where: { event in
            event.isDisappearance
                && !event.isConsumed
                && event.at <= instant
                && instant - event.at <= window
        }) else { return nil }

        // Output coming back between that disappearance and the command means there was a route
        // to play to when the command was admitted, so the pause is the user's. A restoration
        // after the command cannot explain a pause that had already been admitted.
        let disappearance = events[index]
        let restoredBeforeCommand = events.contains { event in
            !event.isDisappearance && event.at > disappearance.at && event.at <= instant
        }
        return restoredBeforeCommand ? nil : index
    }

    /// Whether output came back after `instant` and is still available.
    ///
    /// Not merely "something changed": a disconnect fires this monitor too, and under flapping
    /// the newest event after a route-loss pause can be another disappearance. Resuming then
    /// would start playback with no usable output — and because playback is already paused, that
    /// second loss may produce no pause command to re-arm the marker.
    nonisolated func routeRestored(since instant: ContinuousClock.Instant) -> Bool {
        Self.record.routeRestored(since: instant)
    }

    /// Pure decision behind ``routeRestored(since:)``.
    nonisolated static func routeRestored(
        in events: [RouteChangeEvent],
        since instant: ContinuousClock.Instant
    ) -> Bool {
        guard let latest = events.last(where: { $0.at > instant }) else { return false }
        return !latest.isDisappearance
    }

    /// Installs `handler` and starts listening on first use. Later calls replace the handler.
    func start(onChange handler: @escaping () -> Void) {
        self.handler = handler
        guard !self.isListening else { return }

        Self.record.prime(defaultDeviceID: Self.currentDefaultOutputDeviceID())

        var address = Self.defaultOutputDeviceAddress
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            nil,
            Self.listener
        )
        guard status == noErr else {
            self.logger.warning("failed to listen for default-output changes: \(status)")
            return
        }
        self.isListening = true
    }

    private func notifyChange() {
        self.handler?()
    }

    // Core Audio invokes this on its own callback queue. It is a `nonisolated static`
    // constant so it does not inherit MainActor isolation from the enclosing class —
    // otherwise Swift 6's runtime isolation check trips with `dispatch_assert_queue_fail`
    // the first time the block fires off-main. The hop to MainActor happens in the Task.
    // swiftformat:disable:next modifierOrder
    nonisolated private static let listener:
        @Sendable (UInt32, UnsafePointer<AudioObjectPropertyAddress>) -> Void = { _, _ in
            DefaultOutputDeviceMonitor.record.recordChange(
                currentDefaultDeviceID: DefaultOutputDeviceMonitor.currentDefaultOutputDeviceID,
                isDeviceUsable: DefaultOutputDeviceMonitor.isDeviceUsable
            )
            Task { @MainActor in
                DefaultOutputDeviceMonitor.shared.notifyChange()
            }
        }

    // swiftformat:disable:next modifierOrder
    nonisolated private static var defaultOutputDeviceAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    // swiftformat:disable:next modifierOrder
    nonisolated private static func currentDefaultOutputDeviceID() -> AudioDeviceID? {
        var address = Self.defaultOutputDeviceAddress
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

    // Whether `deviceID` is still a device the system could play through.
    //
    // Core Audio can mark a device dead before dropping its ID from the device list, so being
    // listed is not enough: an unplugged Bluetooth output often lingers as an ID whose
    // `DeviceIsAlive` has already gone to zero, and treating that as present would classify
    // the pause it triggers as the user's.
    // swiftformat:disable:next modifierOrder
    nonisolated private static func isDeviceUsable(_ deviceID: AudioDeviceID) -> Bool {
        guard self.availableDeviceIDs().contains(deviceID) else { return false }

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsAlive,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var isAlive = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &isAlive)
        // A device that cannot even answer the query is not one we can play through.
        guard status == noErr else { return false }
        return isAlive != 0
    }

    // swiftformat:disable:next modifierOrder
    nonisolated private static func availableDeviceIDs() -> Set<AudioDeviceID> {
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
        ) == noErr, size > 0 else { return [] }

        var deviceIDs = [AudioDeviceID](
            repeating: 0,
            count: Int(size) / MemoryLayout<AudioDeviceID>.size
        )
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceIDs
        ) == noErr else { return [] }
        return Set(deviceIDs)
    }
}
