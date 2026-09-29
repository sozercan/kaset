import Foundation
import Testing
@testable import Kaset

/// Tests for the queue-by-ID AppleScript commands (`play videos`, `add to queue`,
/// `remove from queue`). Kept in the serialized `ScriptCommandsTests` suite because every
/// test swaps `PlayerService.shared`.
extension ScriptCommandsTests {
    // MARK: - PlayVideosCommand Tests

    @Test("PlayVideos sets error when PlayerService is nil")
    func playVideosSetsErrorWhenNil() {
        PlayerService.shared = nil

        let command = PlayVideosCommand()
        command.directParameter = ["v1"] as NSArray
        _ = command.performDefaultImplementation()

        #expect(command.scriptErrorNumber == -1728)
        #expect(command.scriptErrorString?.contains("Player service not initialized") == true)
    }

    @Test("PlayVideos rejects missing, empty, or non-string video IDs", arguments: InvalidScriptParameter.allCases)
    func playVideosRejectsInvalidVideoIds(parameter: InvalidScriptParameter) {
        let playerService = PlayerService()
        PlayerService.shared = playerService
        defer { PlayerService.shared = nil }

        let command = PlayVideosCommand()
        command.directParameter = parameter.value
        _ = command.performDefaultImplementation()

        #expect(command.scriptErrorNumber == errAECoercionFail)
        #expect(command.scriptErrorString?.contains("non-empty list") == true)
        #expect(playerService.queue.isEmpty)
    }

    @Test("PlayVideos sets error for non-integer starting index")
    func playVideosSetsErrorForInvalidStartingIndex() {
        let playerService = PlayerService()
        PlayerService.shared = playerService
        defer { PlayerService.shared = nil }

        let command = PlayVideosCommand()
        command.directParameter = ["v1", "v2"] as NSArray
        command.arguments = ["startingAt": "second" as NSString]
        _ = command.performDefaultImplementation()

        #expect(command.scriptErrorNumber == errAECoercionFail)
        #expect(command.scriptErrorString?.contains("Starting index must be an integer") == true)
    }

    @Test("PlayVideos sets error for out of bounds starting index", arguments: [0, -1, 3, 10])
    func playVideosSetsErrorForOutOfBounds(index: Int) {
        let playerService = PlayerService()
        PlayerService.shared = playerService
        defer { PlayerService.shared = nil }

        let command = PlayVideosCommand()
        command.directParameter = ["v1", "v2"] as NSArray
        command.arguments = ["startingAt": index as NSNumber]
        _ = command.performDefaultImplementation()

        #expect(command.scriptErrorNumber == -1728)
        #expect(command.scriptErrorString?.contains("Index out of bounds") == true)
        #expect(playerService.queue.isEmpty)
    }

    @Test("PlayVideos replaces the queue with placeholder songs and starts at the given index")
    func playVideosReplacesQueueAtStartingIndex() async {
        let playerService = PlayerService()
        await playerService.playQueue([TestFixtures.makeSong(id: "old")], startingAt: 0)
        PlayerService.shared = playerService
        defer { PlayerService.shared = nil }

        let command = PlayVideosCommand()
        command.directParameter = ["v1", "v2", "v3"] as NSArray
        command.arguments = ["startingAt": 2 as NSNumber]
        _ = command.performDefaultImplementation()

        #expect(command.scriptErrorNumber == 0)
        let loaded = await self.waitUntil {
            playerService.queue.map(\.videoId) == ["v1", "v2", "v3"] &&
                playerService.currentTrack?.videoId == "v2"
        }
        #expect(loaded)
        #expect(playerService.currentIndex == 1)
        #expect(playerService.queue.allSatisfy { $0.id == $0.videoId && $0.title == "Loading..." })
    }

    @Test("PlayVideos defaults to the first video and accepts a single string")
    func playVideosDefaultsToFirstVideo() async {
        let playerService = PlayerService()
        PlayerService.shared = playerService
        defer { PlayerService.shared = nil }

        let command = PlayVideosCommand()
        command.directParameter = "solo" as NSString
        _ = command.performDefaultImplementation()

        #expect(command.scriptErrorNumber == 0)
        let loaded = await self.waitUntil {
            playerService.queue.map(\.videoId) == ["solo"] &&
                playerService.currentTrack?.videoId == "solo"
        }
        #expect(loaded)
        #expect(playerService.currentIndex == 0)
    }

    @Test("PlayVideos yields to playback that starts before its reservation is claimed")
    func playVideosYieldsToNewerPlaybackIntent() async {
        let playerService = PlayerService()
        await playerService.playQueue([TestFixtures.makeSong(id: "existing")], startingAt: 0)
        PlayerService.shared = playerService
        defer { PlayerService.shared = nil }

        let command = PlayVideosCommand()
        command.directParameter = ["v1", "v2"] as NSArray
        _ = command.performDefaultImplementation()
        // Newer playback begins before the scripting task runs on the main actor.
        _ = playerService.beginMusicPlaybackIntent()

        let replaced = await self.waitUntil(timeout: .milliseconds(200)) {
            playerService.queue.map(\.videoId) != ["existing"]
        }
        #expect(!replaced)
        #expect(playerService.queue.map(\.videoId) == ["existing"])
    }

    // MARK: - AddToQueueCommand Tests

    @Test("AddToQueue sets error when PlayerService is nil")
    func addToQueueSetsErrorWhenNil() {
        PlayerService.shared = nil

        let command = AddToQueueCommand()
        command.directParameter = ["v1"] as NSArray
        _ = command.performDefaultImplementation()

        #expect(command.scriptErrorNumber == -1728)
        #expect(command.scriptErrorString?.contains("Player service not initialized") == true)
    }

    @Test("AddToQueue rejects missing, empty, or non-string video IDs", arguments: InvalidScriptParameter.allCases)
    func addToQueueRejectsInvalidVideoIds(parameter: InvalidScriptParameter) {
        let playerService = PlayerService()
        PlayerService.shared = playerService
        defer { PlayerService.shared = nil }

        let command = AddToQueueCommand()
        command.directParameter = parameter.value
        _ = command.performDefaultImplementation()

        #expect(command.scriptErrorNumber == errAECoercionFail)
        #expect(playerService.queue.isEmpty)
    }

    @Test("AddToQueue sets error for non-boolean next parameter")
    func addToQueueSetsErrorForInvalidNext() {
        let playerService = PlayerService()
        PlayerService.shared = playerService
        defer { PlayerService.shared = nil }

        let command = AddToQueueCommand()
        command.directParameter = ["v1"] as NSArray
        command.arguments = ["next": "yes" as NSString]
        _ = command.performDefaultImplementation()

        #expect(command.scriptErrorNumber == errAECoercionFail)
        #expect(command.scriptErrorString?.contains("boolean") == true)
        #expect(playerService.queue.isEmpty)
    }

    @Test("AddToQueue appends placeholder songs to the end of the queue")
    func addToQueueAppendsToEnd() async {
        let playerService = PlayerService()
        await playerService.playQueue([
            TestFixtures.makeSong(id: "a"),
            TestFixtures.makeSong(id: "b"),
            TestFixtures.makeSong(id: "c"),
        ], startingAt: 0)
        PlayerService.shared = playerService
        defer { PlayerService.shared = nil }

        let command = AddToQueueCommand()
        command.directParameter = ["v1", "v2"] as NSArray
        _ = command.performDefaultImplementation()

        #expect(command.scriptErrorNumber == 0)
        #expect(playerService.queue.map(\.videoId) == ["a", "b", "c", "v1", "v2"])
        #expect(playerService.queue.suffix(2).allSatisfy { $0.title == "Loading..." })
        #expect(playerService.currentIndex == 0)
        #expect(playerService.currentTrack?.videoId == "a")
    }

    @Test("AddToQueue with next inserts after the current track")
    func addToQueueNextInsertsAfterCurrent() async {
        let playerService = PlayerService()
        await playerService.playQueue([
            TestFixtures.makeSong(id: "a"),
            TestFixtures.makeSong(id: "b"),
            TestFixtures.makeSong(id: "c"),
        ], startingAt: 1)
        PlayerService.shared = playerService
        defer { PlayerService.shared = nil }

        let command = AddToQueueCommand()
        command.directParameter = ["v1", "v2"] as NSArray
        command.arguments = ["next": true as NSNumber]
        _ = command.performDefaultImplementation()

        #expect(command.scriptErrorNumber == 0)
        #expect(playerService.queue.map(\.videoId) == ["a", "b", "v1", "v2", "c"])
        #expect(playerService.currentIndex == 1)
        #expect(playerService.currentTrack?.videoId == "b")
    }

    @Test("AddToQueue on an empty idle queue appends without starting playback", arguments: [false, true])
    func addToQueueOnEmptyQueueDoesNotStartPlayback(playNext: Bool) {
        let playerService = PlayerService()
        PlayerService.shared = playerService
        defer { PlayerService.shared = nil }

        let command = AddToQueueCommand()
        command.directParameter = ["v1", "v2"] as NSArray
        command.arguments = ["next": playNext as NSNumber]
        _ = command.performDefaultImplementation()

        #expect(command.scriptErrorNumber == 0)
        #expect(playerService.queue.map(\.videoId) == ["v1", "v2"])
        #expect(playerService.currentTrack == nil)
        #expect(playerService.isPlaying == false)
    }

    // MARK: - RemoveFromQueueCommand Tests

    @Test("RemoveFromQueue sets error when PlayerService is nil")
    func removeFromQueueSetsErrorWhenNil() {
        PlayerService.shared = nil

        let command = RemoveFromQueueCommand()
        command.directParameter = "v1" as NSString
        _ = command.performDefaultImplementation()

        #expect(command.scriptErrorNumber == -1728)
        #expect(command.scriptErrorString?.contains("Player service not initialized") == true)
    }

    @Test(
        "RemoveFromQueue rejects missing, empty, or non-string video ID",
        arguments: [InvalidScriptParameter.missing, .emptyString, .number]
    )
    func removeFromQueueRejectsInvalidVideoId(parameter: InvalidScriptParameter) {
        let playerService = PlayerService()
        PlayerService.shared = playerService
        defer { PlayerService.shared = nil }

        let command = RemoveFromQueueCommand()
        command.directParameter = parameter.value
        _ = command.performDefaultImplementation()

        #expect(command.scriptErrorNumber == errAECoercionFail)
        #expect(command.scriptErrorString?.contains("non-empty string") == true)
    }

    @Test("RemoveFromQueue removes every occurrence of the video")
    func removeFromQueueRemovesEveryOccurrence() async {
        let playerService = PlayerService()
        await playerService.playQueue([
            TestFixtures.makeSong(id: "a"),
            TestFixtures.makeSong(id: "dup"),
            TestFixtures.makeSong(id: "b"),
            TestFixtures.makeSong(id: "dup"),
        ], startingAt: 0)
        PlayerService.shared = playerService
        defer { PlayerService.shared = nil }

        let command = RemoveFromQueueCommand()
        command.directParameter = "dup" as NSString
        _ = command.performDefaultImplementation()

        #expect(command.scriptErrorNumber == 0)
        #expect(playerService.queue.map(\.videoId) == ["a", "b"])
        #expect(playerService.currentTrack?.videoId == "a")
    }

    @Test("RemoveFromQueue sets error when the video is not in the queue")
    func removeFromQueueSetsErrorWhenMissing() async {
        let playerService = PlayerService()
        await playerService.playQueue([TestFixtures.makeSong(id: "a")], startingAt: 0)
        PlayerService.shared = playerService
        defer { PlayerService.shared = nil }

        let command = RemoveFromQueueCommand()
        command.directParameter = "missing" as NSString
        _ = command.performDefaultImplementation()

        #expect(command.scriptErrorNumber == -1728)
        #expect(command.scriptErrorString?.contains("does not contain") == true)
        #expect(playerService.queue.map(\.videoId) == ["a"])
    }
}

// MARK: - InvalidScriptParameter

/// Invalid direct parameters for the queue-by-ID scripting commands.
enum InvalidScriptParameter: CaseIterable {
    case missing
    case emptyList
    case emptyString
    case listWithEmptyString
    case listWithNonString
    case number

    var value: Any? {
        switch self {
        case .missing: nil
        case .emptyList: [] as NSArray
        case .emptyString: "" as NSString
        case .listWithEmptyString: ["v1", ""] as NSArray
        case .listWithNonString: ["v1", 2] as NSArray
        case .number: 5 as NSNumber
        }
    }
}
