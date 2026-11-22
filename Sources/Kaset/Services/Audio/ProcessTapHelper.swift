import ApplicationServices
import CoreAudio
import CoreGraphics
import Darwin
import Foundation

final class ProcessTapHelper {
    struct AudioProcessCandidate: Equatable {
        let objectID: AudioObjectID
        let pid: pid_t
        let parentPID: pid_t
        let processName: String?
        let launcherName: String?
    }

    private static let tapName = "com.sertacozercan.Kaset.EQ.Tap"

    private static let aggregateName = "Kaset EQ Aggregate"

    private static let aggregateUIDPrefix = "com.sertacozercan.Kaset.EQ.Aggregate."

    private(set) var tapStreamDescription: AudioStreamBasicDescription?

    private(set) var aggregateDeviceID: AudioObjectID = .init(kAudioObjectUnknown)

    private var tapID: AudioObjectID = .init(kAudioObjectUnknown)

    private var aggregateUID: String?

    private static let logger = DiagnosticsLogger.equalizer

    private static let hostProcessNames: [String] = {
        let bundle = Bundle.main
        let candidates = [
            ProcessInfo.processInfo.processName,
            bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String,
            bundle.object(forInfoDictionaryKey: kCFBundleNameKey as String) as? String,
        ]
        return Array(Set(candidates.compactMap {
            $0?.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }))
    }()

    enum StartFailure: Error {
        case noAudioSource
        case tapCreation(OSStatus)
        case permissionDenied
        case aggregateDeviceCreation
        case unsupportedOS
    }

    func start() -> Result<Void, StartFailure> {
        guard #available(macOS 14.2, *) else {
            Self.logger.error("process tap requires macOS 14.2+")
            return .failure(.unsupportedOS)
        }

        guard self.tapID == kAudioObjectUnknown else {
            return .success(())
        }

        if !CGPreflightScreenCaptureAccess() {
            Self.logger.warning(
                "screen / system-audio recording permission missing — not creating tap"
            )
            return .failure(.permissionDenied)
        }

        Self.destroyOrphanedAggregates()

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
            if newTapID != kAudioObjectUnknown {
                AudioHardwareDestroyProcessTap(newTapID)
            }
            return .failure(.tapCreation(tapStatus))
        }
        self.tapID = newTapID

        self.tapStreamDescription = Self.streamFormat(forTap: newTapID)

        guard let aggregate = Self.makeAggregateDevice(wrapping: newTapID) else {
            self.stop()
            return .failure(.aggregateDeviceCreation)
        }
        self.aggregateDeviceID = aggregate.objectID
        self.aggregateUID = aggregate.uid
        return .success(())
    }

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

    private static let webKitAudioBundleIDs: Set<String> = [
        "com.apple.WebKit.WebContent",
        "com.apple.WebKit.GPU",
    ]

    private static func isWebKitAudioCandidate(bundleID: String) -> Bool {
        self.webKitAudioBundleIDs.contains(bundleID)
    }

    private static func audioObjectsToTap() -> [AudioObjectID] {
        let ourPID = ProcessInfo.processInfo.processIdentifier
        let candidates = Self.allAudioProcessObjects().compactMap { objectID -> AudioProcessCandidate? in
            guard let bundleID = Self.processBundleID(of: objectID),
                  Self.isWebKitAudioCandidate(bundleID: bundleID)
            else { return nil }
            let pid = Self.processPID(of: objectID)
            let parentPID = pid > 0 ? Self.parentPID(of: pid) : -1
            return AudioProcessCandidate(
                objectID: objectID,
                pid: pid,
                parentPID: parentPID,
                processName: pid > 0 ? Self.processName(of: pid) : nil,
                launcherName: pid > 0 ? Self.launcherProcessName(of: pid) : nil
            )
        }
        let ours = Self.selectOwnedAudioObjects(
            from: candidates,
            ourPID: ourPID,
            ownedChildPIDs: Self.childPIDs(of: ourPID),
            hostProcessNames: Self.hostProcessNames
        )
        if !ours.isEmpty {
            return ours
        }
        if !candidates.isEmpty {
            Self.logger.warning(
                "found \(candidates.count) WebKit audio process(es) but none were provably owned by Kaset; skipping tap to avoid hijacking unrelated audio"
            )
        }
        return []
    }

    static func selectOwnedAudioObjects(
        from candidates: [AudioProcessCandidate],
        ourPID: pid_t,
        ownedChildPIDs: Set<pid_t>,
        hostProcessNames: [String]? = nil
    ) -> [AudioObjectID] {
        let hostProcessNames = hostProcessNames ?? Self.hostProcessNames
        return candidates.compactMap { candidate -> AudioObjectID? in
            guard candidate.pid > 0 else { return nil }
            if candidate.parentPID == ourPID ||
                ownedChildPIDs.contains(candidate.pid) ||
                Self.isOwnedProcessName(candidate.processName, hostProcessNames: hostProcessNames) ||
                Self.isOwnedProcessName(candidate.launcherName, hostProcessNames: hostProcessNames)
            {
                return candidate.objectID
            }
            return nil
        }
    }

    private static func isOwnedProcessName(_ name: String?, hostProcessNames: [String]) -> Bool {
        guard let name else { return false }
        return hostProcessNames.contains { hostName in
            name.range(of: hostName, options: [.caseInsensitive, .anchored]) != nil
        }
    }

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

    private static func parentPID(of pid: pid_t) -> pid_t {
        var info = proc_bsdinfo()
        let infoSize = Int32(MemoryLayout<proc_bsdinfo>.size)
        let result = withUnsafeMutablePointer(to: &info) { ptr in
            proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, UnsafeMutableRawPointer(ptr), infoSize)
        }
        return result == infoSize ? pid_t(info.pbi_ppid) : -1
    }

    private static func processName(of pid: pid_t) -> String? {
        var psn = ProcessSerialNumber()
        guard Self.legacyGetProcessForPID(pid, &psn) == noErr else { return nil }
        return Self.copyProcessName(for: psn)
    }

    private static func launcherProcessName(of pid: pid_t) -> String? {
        var psn = ProcessSerialNumber()
        guard Self.legacyGetProcessForPID(pid, &psn) == noErr else { return nil }
        var info = ProcessInfoRec()
        info.processInfoLength = UInt32(MemoryLayout<ProcessInfoRec>.size)
        guard Self.legacyGetProcessInformation(&psn, &info) == noErr else { return nil }
        guard info.processLauncher.highLongOfPSN != 0 || info.processLauncher.lowLongOfPSN != 0 else {
            return nil
        }
        return Self.copyProcessName(for: info.processLauncher)
    }

    private static func copyProcessName(for psn: ProcessSerialNumber) -> String? {
        var mutablePSN = psn
        var cfName: Unmanaged<CFString>?
        guard Self.legacyCopyProcessName(&mutablePSN, &cfName) == noErr,
              let cfName
        else { return nil }
        return cfName.takeRetainedValue() as String
    }

    private static func childPIDs(of parentPID: pid_t) -> Set<pid_t> {
        var capacity = 8
        while true {
            var children = [pid_t](repeating: 0, count: capacity)
            let byteCount = children.withUnsafeMutableBufferPointer { buffer -> Int32 in
                guard let base = buffer.baseAddress else { return -1 }
                return proc_listchildpids(
                    parentPID,
                    UnsafeMutableRawPointer(base),
                    Int32(buffer.count * MemoryLayout<pid_t>.size)
                )
            }
            guard byteCount >= 0 else { return [] }
            let childCount = Int(byteCount) / MemoryLayout<pid_t>.size
            if childCount < capacity {
                return Set(children.prefix(childCount).filter { $0 > 0 })
            }
            capacity *= 2
        }
    }

    @_silgen_name("GetProcessForPID")
    private static func legacyGetProcessForPID(
        _ pid: pid_t,
        _ psn: UnsafeMutablePointer<ProcessSerialNumber>
    ) -> OSStatus

    @_silgen_name("GetProcessInformation")
    private static func legacyGetProcessInformation(
        _ psn: UnsafeMutablePointer<ProcessSerialNumber>,
        _ info: UnsafeMutablePointer<ProcessInfoRec>
    ) -> OSErr

    @_silgen_name("CopyProcessName")
    private static func legacyCopyProcessName(
        _ psn: UnsafeMutablePointer<ProcessSerialNumber>,
        _ name: UnsafeMutablePointer<Unmanaged<CFString>?>
    ) -> OSStatus

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
