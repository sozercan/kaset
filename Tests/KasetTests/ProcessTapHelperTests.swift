import CoreAudio
import Testing
@testable import Kaset

@Suite(.tags(.service))
struct ProcessTapHelperTests {
    @Test("Ownership selection accepts direct parent PID matches")
    func selectOwnedAudioObjectsMatchesParentPID() {
        let objects = ProcessTapHelper.selectOwnedAudioObjects(
            from: [
                .init(objectID: 11, pid: 201, parentPID: 42, processName: nil, launcherName: nil),
                .init(objectID: 12, pid: 202, parentPID: 999, processName: nil, launcherName: nil),
            ],
            ourPID: 42,
            ownedChildPIDs: [],
            hostProcessNames: ["Kaset"]
        )

        #expect(objects == [11])
    }

    @Test("Ownership selection accepts child-PID matches when parent lookup fails")
    func selectOwnedAudioObjectsMatchesChildPIDFallback() {
        let objects = ProcessTapHelper.selectOwnedAudioObjects(
            from: [
                .init(objectID: 21, pid: 301, parentPID: -1, processName: nil, launcherName: nil),
                .init(objectID: 22, pid: 302, parentPID: -1, processName: nil, launcherName: nil),
            ],
            ourPID: 42,
            ownedChildPIDs: [301],
            hostProcessNames: ["Kaset"]
        )

        #expect(objects == [21])
    }

    @Test("Ownership selection rejects unproven WebKit processes")
    func selectOwnedAudioObjectsRejectsUnownedCandidates() {
        let objects = ProcessTapHelper.selectOwnedAudioObjects(
            from: [
                .init(objectID: 31, pid: 401, parentPID: -1, processName: nil, launcherName: nil),
                .init(objectID: 32, pid: 402, parentPID: 999, processName: nil, launcherName: nil),
            ],
            ourPID: 42,
            ownedChildPIDs: [],
            hostProcessNames: ["Kaset"]
        )

        #expect(objects.isEmpty)
    }

    @Test("Ownership selection accepts helper names that carry the host app name")
    func selectOwnedAudioObjectsMatchesLegacyProcessName() {
        let objects = ProcessTapHelper.selectOwnedAudioObjects(
            from: [
                .init(objectID: 41, pid: 501, parentPID: -1, processName: "Kaset Web Content", launcherName: nil),
                .init(objectID: 42, pid: 502, parentPID: -1, processName: "Safari Web Content", launcherName: nil),
            ],
            ourPID: 42,
            ownedChildPIDs: [],
            hostProcessNames: ["Kaset"]
        )

        #expect(objects == [41])
    }

    @Test("Ownership selection accepts launcher names that carry the host app name")
    func selectOwnedAudioObjectsMatchesLauncherName() {
        let objects = ProcessTapHelper.selectOwnedAudioObjects(
            from: [
                .init(objectID: 51, pid: 601, parentPID: -1, processName: nil, launcherName: "Kaset Networking"),
                .init(objectID: 52, pid: 602, parentPID: -1, processName: nil, launcherName: "Safari Networking"),
            ],
            ourPID: 42,
            ownedChildPIDs: [],
            hostProcessNames: ["Kaset"]
        )

        #expect(objects == [51])
    }
}
