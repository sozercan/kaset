import CoreAudio
import CoreGraphics
import Darwin
import Foundation

// MARK: - ProcessTapHelper

/// Wraps the Core Audio "process tap" (macOS 14.2+) plumbing used by the
/// equalizer.
///
/// **Critical detail**: Kaset doesn't decode music itself — `WKWebView` does,
/// inside its `WebContent` XPC subprocess. Tapping our own PID therefore
/// captures silence. The helper enumerates Core Audio's process-object list,
/// filters to `WebContent` processes whose parent is this app, and taps
/// those instead. The original output is silenced via
/// ``CATapMuteBehavior/mutedWhenTapped`` so the user only hears our
/// post-EQ render.
///
/// Design notes:
///
/// * The aggregate device contains the system default output as its main
///   sub-device, so a single AUHAL bound to it can read the tap and write
///   to the speakers in one render cycle — no ring buffer, no cross-clock
///   drift.
/// * Drift compensation is enabled on the tap so its sample rate tracks the
///   output device.
/// * The helper exposes the negotiated stream format so callers can match
///   bit-for-bit instead of forcing an internal resample.
///
/// Not MainActor-isolated: it owns only OS audio-object IDs and calls C
/// APIs, safe to tear down from any context.
final class ProcessTapHelper {
    /// User-visible name of the private tap object (shown in diagnostic
    /// audio tools like Audio MIDI Setup).
    private static let tapName = "com.sertacozercan.Kaset.EQ.Tap"

    /// User-visible name of the aggregate device that wraps the tap.
    private static let aggregateName = "Kaset EQ Aggregate"

    /// Prefix for the aggregate device's unique ID. A UUID suffix is appended
    /// per instance so repeated start/stop cycles don't collide.
    private static let aggregateUIDPrefix = "com.sertacozercan.Kaset.EQ.Aggregate."

    /// Negotiated audio stream format of the tap output.
    private(set) var tapStreamDescription: AudioStreamBasicDescription?

    /// ID of the private aggregate device that fronts the tap. Bind this to
    /// an AUHAL via `kAudioOutputUnitProperty_CurrentDevice`.
    private(set) var aggregateDeviceID: AudioObjectID = .init(kAudioObjectUnknown)

    /// ID of the underlying tap object.
    private var tapID: AudioObjectID = .init(kAudioObjectUnknown)

    /// UID of the aggregate device (kept for teardown).
    private var aggregateUID: String?

    private static let logger = DiagnosticsLogger.equalizer

    // MARK: - StartFailure

    /// High-level reason a `start()` call didn't succeed. Lets the caller
    /// distinguish "user hasn't started playback yet" from "we hit a real
    /// Core Audio error" so the UI can phrase the message accordingly.
    enum StartFailure: Error {
        /// No WebKit audio process is currently registered with Core Audio,
        /// so there is nothing to tap. Almost always means the user simply
        /// hasn't started playback in this session yet.
        case noAudioSource
        /// `AudioHardwareCreateProcessTap` returned a non-zero status —
        /// usually permission denial or a transient HAL error.
        case tapCreation(OSStatus)
        /// TCC explicitly reports the audio-capture permission as denied
        /// or restricted. We bail before creating the tap so we never mute
        /// WebKit's output without being able to play it back ourselves.
        case permissionDenied
        /// Aggregate device construction failed. Rare.
        case aggregateDeviceCreation
        /// Pre-flight check failed (running on an unsupported macOS).
        case unsupportedOS
    }

    // MARK: - Lifecycle

    /// Starts the tap and installs the aggregate device.
    ///
    /// Discovers the WebKit XPC subprocess(es) that this app owns, taps them
    /// with mute-when-tapped behaviour, and wraps the tap in an aggregate
    /// device that fronts the system default output for clock alignment.
    ///
    /// - Returns: `.success` once `aggregateDeviceID` is usable by AUHAL.
    func start() -> Result<Void, StartFailure> {
        guard #available(macOS 14.2, *) else {
            Self.logger.error("process tap requires macOS 14.2+")
            return .failure(.unsupportedOS)
        }

        guard self.tapID == kAudioObjectUnknown else {
            return .success(()) // already running
        }

        // Gate everything on the *Screen Recording / System Audio Recording*
        // TCC permission — this is what Core Audio process taps actually
        // require, despite the dialog text mentioning audio capture.
        // `AVCaptureDevice.authorizationStatus(for: .audio)` checks the
        // **microphone** TCC service which is unrelated, so it can report
        // .authorized while taps are still silently denied.
        //
        // When permission is missing the tap APIs return `noErr` but feed
        // us only zeros while still installing the mute on WebKit, which
        // would silence the player without us noticing. Bailing here keeps
        // WebKit untouched.
        if !CGPreflightScreenCaptureAccess() {
            Self.logger.warning(
                "screen / system-audio recording permission missing — not creating tap"
            )
            return .failure(.permissionDenied)
        }

        // Clean up any aggregate devices left behind by a prior crash —
        // Core Audio keeps them until the system reboots otherwise, and
        // they show up in Audio MIDI Setup as lingering "Kaset EQ Aggregate"
        // entries. Identified by our UID prefix.
        Self.destroyOrphanedAggregates()

        // Find the process objects whose audio we actually want to tap.
        let processObjects = Self.audioObjectsToTap()
        guard !processObjects.isEmpty else {
            Self.logger.info(
                "no WebKit audio process registered yet — waiting for playback"
            )
            return .failure(.noAudioSource)
        }
        Self.logger.info(
            "tapping \(processObjects.count) WebKit process object(s)"
        )

        let description = CATapDescription(
            stereoMixdownOfProcesses: processObjects
        )
        description.muteBehavior = CATapMuteBehavior.mutedWhenTapped
        description.isPrivate = true
        description.isExclusive = false
        description.name = Self.tapName

        var newTapID = AudioObjectID(kAudioObjectUnknown)
        let tapStatus = AudioHardwareCreateProcessTap(description, &newTapID)
        guard tapStatus == noErr else {
            Self.logger.error("AudioHardwareCreateProcessTap failed: \(tapStatus)")
            // Defensive: some Core Audio paths populate `newTapID` even
            // when returning an error. A leaked tap with `mutedWhenTapped`
            // would silently mute WebKit's audio with no engine to render
            // it, so destroy it eagerly.
            if newTapID != kAudioObjectUnknown {
                AudioHardwareDestroyProcessTap(newTapID)
            }
            return .failure(.tapCreation(tapStatus))
        }
        self.tapID = newTapID

        // Query negotiated stream format.
        self.tapStreamDescription = Self.streamFormat(forTap: newTapID)

        // Build aggregate device wrapping the tap with drift compensation.
        guard let aggregate = Self.makeAggregateDevice(wrapping: newTapID) else {
            self.stop()
            return .failure(.aggregateDeviceCreation)
        }
        self.aggregateDeviceID = aggregate.objectID
        self.aggregateUID = aggregate.uid
        return .success(())
    }

    /// Tears down the aggregate device and the tap.
    func stop() {
        if self.aggregateDeviceID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(self.aggregateDeviceID)
            self.aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
        }
        if self.tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(self.tapID)
            self.tapID = AudioObjectID(kAudioObjectUnknown)
        }
        self.aggregateUID = nil
        self.tapStreamDescription = nil
    }

    deinit {
        if self.aggregateDeviceID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(self.aggregateDeviceID)
        }
        if self.tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(self.tapID)
        }
    }

    // MARK: - Process discovery

    /// Bundle IDs of WebKit XPC subprocesses that host audio playback.
    /// On macOS Sonoma+ WebKit moved media decode into the "GPU" process,
    /// so the name is misleading — both must be considered. The list is
    /// intentionally explicit: a `com.apple.WebKit.*` prefix would also
    /// match `Networking`/`Plugin` subprocesses that host no audio, and
    /// muting them would be a no-op at best and unexpected at worst.
    private static let webKitAudioBundleIDs: Set<String> = [
        "com.apple.WebKit.WebContent",
        "com.apple.WebKit.GPU",
    ]

    /// Returns `true` only for the WebKit XPC subprocesses known to host
    /// media playback today. Future renames will need a code change — that's
    /// preferable to muting unrelated WebKit helpers system-wide.
    private static func isWebKitAudioCandidate(bundleID: String) -> Bool {
        self.webKitAudioBundleIDs.contains(bundleID)
    }

    /// Returns the audio process objects we want to tap.
    ///
    /// Kaset's audio is decoded by `WKWebView`'s WebKit subprocesses, not by
    /// the app's main process — tapping `selfPID` therefore captures
    /// silence. We enumerate Core Audio's process list, filter to WebKit
    /// audio hosts, and return only those whose parent PID matches this
    /// app. We deliberately don't fall back to "any WebKit process" — doing
    /// so could mute Safari, Mail, or other unrelated apps.
    private static func audioObjectsToTap() -> [AudioObjectID] {
        let allObjects = Self.allAudioProcessObjects()

        // Tap WebKit audio subprocesses only. Deliberately excluding
        // Kaset's own process object: Core Audio returns all-zero samples
        // for a tap-on-self (even when the host process *is* the one
        // emitting audio via WKWebView), which yields silent EQ output.
        return allObjects.filter { objectID in
            guard let bundleID = Self.processBundleID(of: objectID) else { return false }
            return Self.isWebKitAudioCandidate(bundleID: bundleID)
        }
    }

    /// Enumerates all process objects currently registered with Core Audio.
    private static func allAudioProcessObjects() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        let sizeStatus = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size
        )
        guard sizeStatus == noErr, size > 0 else {
            return []
        }
        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        guard count > 0 else { return [] }
        var objects = [AudioObjectID](repeating: 0, count: count)
        let status = objects.withUnsafeMutableBufferPointer { buffer -> OSStatus in
            guard let base = buffer.baseAddress else { return -1 }
            return AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                0,
                nil,
                &size,
                base
            )
        }
        return status == noErr ? objects : []
    }

    /// Reads the bundle identifier of an audio process object.
    private static func processBundleID(of objectID: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyBundleID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<CFString?>.size)
        var cfString: Unmanaged<CFString>?
        let status = withUnsafeMutablePointer(to: &cfString) { ptr in
            AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, ptr)
        }
        guard status == noErr, let value = cfString?.takeRetainedValue() else {
            return nil
        }
        return value as String
    }

    /// Reads the PID of an audio process object.
    private static func processPID(of objectID: AudioObjectID) -> pid_t {
        var pid: pid_t = -1
        var size = UInt32(MemoryLayout<pid_t>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyPID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &pid)
        return status == noErr ? pid : -1
    }

    /// Reads the parent PID of a Unix process via libproc.
    private static func parentPID(of pid: pid_t) -> pid_t {
        var info = proc_bsdinfo()
        let infoSize = Int32(MemoryLayout<proc_bsdinfo>.size)
        let result = withUnsafeMutablePointer(to: &info) { ptr in
            proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, UnsafeMutableRawPointer(ptr), infoSize)
        }
        return result == infoSize ? pid_t(info.pbi_ppid) : -1
    }

    // MARK: - Audio-object lookup

    /// Reads the tap's negotiated stream format.
    private static func streamFormat(forTap tapID: AudioObjectID) -> AudioStreamBasicDescription? {
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &format)
        return status == noErr ? format : nil
    }

    /// Destroys every aggregate device whose UID starts with
    /// ``aggregateUIDPrefix``. Called at startup so a prior crash's leaked
    /// devices don't accumulate in Audio MIDI Setup across launches.
    private static func destroyOrphanedAggregates() {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size
        ) == noErr, size > 0 else { return }
        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        var devices = [AudioObjectID](repeating: 0, count: count)
        let status = devices.withUnsafeMutableBufferPointer { buffer -> OSStatus in
            guard let base = buffer.baseAddress else { return -1 }
            return AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, base
            )
        }
        guard status == noErr else { return }
        for deviceID in devices {
            guard let uid = Self.stringProperty(deviceID, selector: kAudioDevicePropertyDeviceUID),
                  uid.hasPrefix(Self.aggregateUIDPrefix)
            else { continue }
            let destroyStatus = AudioHardwareDestroyAggregateDevice(deviceID)
            if destroyStatus == noErr {
                Self.logger.info("destroyed orphaned aggregate \(uid)")
            } else {
                Self.logger.warning("failed to destroy orphaned aggregate \(uid): \(destroyStatus)")
            }
        }
    }

    /// Creates a duplex aggregate device: the default output device is the
    /// clock master sub-device, and the process tap is attached as a
    /// drift-compensated input. A single `AUHAL` bound to this aggregate can
    /// therefore render the tapped audio straight into the output device in
    /// the same render cycle — no ring buffer, no cross-clock drift.
    private static func makeAggregateDevice(
        wrapping tapID: AudioObjectID
    ) -> (objectID: AudioObjectID, uid: String)? {
        let uid = Self.aggregateUIDPrefix + UUID().uuidString
        let tapUID = Self.stringProperty(tapID, selector: kAudioTapPropertyUID) ?? ""

        guard let outputDeviceUID = Self.defaultOutputDeviceUID() else {
            Self.logger.error("could not resolve default output device UID")
            return nil
        }

        let description: [String: Any] = [
            kAudioAggregateDeviceUIDKey as String: uid,
            kAudioAggregateDeviceNameKey as String: Self.aggregateName,
            kAudioAggregateDeviceIsPrivateKey as String: true,
            kAudioAggregateDeviceIsStackedKey as String: false,
            kAudioAggregateDeviceMainSubDeviceKey as String: outputDeviceUID,
            kAudioAggregateDeviceTapAutoStartKey as String: true,
            kAudioAggregateDeviceSubDeviceListKey as String: [
                [
                    kAudioSubDeviceUIDKey as String: outputDeviceUID,
                ],
            ],
            kAudioAggregateDeviceTapListKey as String: [
                [
                    kAudioSubTapUIDKey as String: tapUID,
                    kAudioSubTapDriftCompensationKey as String: true,
                ],
            ],
        ]

        var aggregateID = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggregateID)
        guard status == noErr else {
            Self.logger.error("AudioHardwareCreateAggregateDevice failed: \(status)")
            return nil
        }
        return (aggregateID, uid)
    }

    /// Resolves the UID of the system's default output device so we can
    /// attach it as the aggregate's main sub-device.
    private static func defaultOutputDeviceUID() -> String? {
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceID
        )
        guard status == noErr, deviceID != kAudioObjectUnknown else {
            return nil
        }
        return Self.stringProperty(deviceID, selector: kAudioDevicePropertyDeviceUID)
    }

    /// Convenience to read a CFString property from an audio object.
    private static func stringProperty(_ id: AudioObjectID, selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<CFString?>.size)
        var cfString: Unmanaged<CFString>?
        let status = withUnsafeMutablePointer(to: &cfString) { ptr in
            AudioObjectGetPropertyData(id, &address, 0, nil, &size, ptr)
        }
        guard status == noErr, let value = cfString?.takeRetainedValue() else {
            return nil
        }
        return value as String
    }
}
