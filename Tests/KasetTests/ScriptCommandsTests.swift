import Foundation
import Testing
@testable import Kaset

/// Tests for AppleScript ScriptCommands.
@Suite(.serialized, .tags(.service))
@MainActor
struct ScriptCommandsTests {
    // MARK: - Setup/Teardown

    /// Clears PlayerService.shared before each test.
    init() {
        // Ensure clean state - no shared instance
        PlayerService.shared = nil
    }

    private func waitUntil(
        timeout: Duration = .seconds(1),
        pollInterval: Duration = .milliseconds(10),
        _ condition: () -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)

        while !condition() {
            guard clock.now < deadline else { return condition() }
            try? await Task.sleep(for: pollInterval)
        }

        return true
    }

    // MARK: - GetPlayerInfoCommand Tests

    @Test("GetPlayerInfo returns error JSON when PlayerService is nil")
    func getPlayerInfoReturnsErrorWhenNil() {
        PlayerService.shared = nil

        let command = GetPlayerInfoCommand()
        let result = command.performDefaultImplementation() as? String

        #expect(result?.contains("error") == true)
        #expect(result?.contains("Player not available") == true)
    }

    @Test("GetPlayerInfo returns valid JSON with player state")
    func getPlayerInfoReturnsValidJSON() {
        let playerService = PlayerService()
        PlayerService.shared = playerService

        let command = GetPlayerInfoCommand()
        let result = command.performDefaultImplementation() as? String

        #expect(result != nil)

        // Parse JSON to verify structure
        if let jsonData = result?.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any]
        {
            #expect(json["isPlaying"] != nil)
            #expect(json["isPaused"] != nil)
            #expect(json["volume"] != nil)
            #expect(json["shuffling"] != nil)
            #expect(json["repeating"] != nil)
            #expect(json["muted"] != nil)
            #expect(json["likeStatus"] != nil)
        } else {
            Issue.record("Failed to parse JSON response")
        }

        // Cleanup
        PlayerService.shared = nil
    }

    @Test("GetPlayerInfo includes track info when track is playing")
    func getPlayerInfoIncludesTrackInfo() {
        let playerService = PlayerService()
        playerService.currentTrack = Song(
            id: "test-id",
            title: "Test Song",
            artists: [Artist(id: "artist-1", name: "Test Artist")],
            album: Album(id: "album-1", title: "Test Album", artists: nil, thumbnailURL: nil, year: nil, trackCount: nil),
            duration: 180,
            thumbnailURL: URL(string: "https://example.com/thumb.jpg"),
            videoId: "test-video-id"
        )
        PlayerService.shared = playerService

        let command = GetPlayerInfoCommand()
        let result = command.performDefaultImplementation() as? String

        #expect(result != nil)

        if let jsonData = result?.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
           let trackInfo = json["currentTrack"] as? [String: Any]
        {
            #expect(trackInfo["name"] as? String == "Test Song")
            #expect(trackInfo["artist"] as? String == "Test Artist")
            #expect(trackInfo["album"] as? String == "Test Album")
            #expect(trackInfo["videoId"] as? String == "test-video-id")
            #expect(trackInfo["duration"] as? TimeInterval == 180)
        } else {
            Issue.record("Failed to parse track info from JSON response")
        }

        // Cleanup
        PlayerService.shared = nil
    }

    @Test("GetPlayerInfo returns correct repeat mode values")
    func getPlayerInfoReturnsCorrectRepeatMode() {
        let playerService = PlayerService()
        PlayerService.shared = playerService

        // Test each repeat mode
        let repeatModes: [(action: () -> Void, expected: String)] = [
            ({}, "off"), // Initial state
            ({ playerService.cycleRepeatMode() }, "all"),
            ({ playerService.cycleRepeatMode() }, "one"),
            ({ playerService.cycleRepeatMode() }, "off"),
        ]

        for (action, expected) in repeatModes {
            action()
            let command = GetPlayerInfoCommand()
            let result = command.performDefaultImplementation() as? String

            if let jsonData = result?.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any]
            {
                #expect(json["repeating"] as? String == expected, "Expected repeat mode '\(expected)'")
            }
        }

        // Cleanup
        PlayerService.shared = nil
    }

    // MARK: - ToggleShuffleCommand Tests

    @Test("ToggleShuffle toggles shuffle state when PlayerService exists")
    func toggleShuffleTogglesState() {
        let playerService = PlayerService()
        PlayerService.shared = playerService

        #expect(playerService.shuffleEnabled == false)

        let command = ToggleShuffleCommand()
        _ = command.performDefaultImplementation()

        #expect(playerService.shuffleEnabled == true)

        _ = command.performDefaultImplementation()

        #expect(playerService.shuffleEnabled == false)

        // Cleanup
        PlayerService.shared = nil
    }

    @Test("ToggleShuffle sets error when PlayerService is nil")
    func toggleShuffleSetsErrorWhenNil() {
        PlayerService.shared = nil

        let command = ToggleShuffleCommand()
        _ = command.performDefaultImplementation()

        #expect(command.scriptErrorNumber == -1728) // errAENoSuchObject
        #expect(command.scriptErrorString?.contains("Player service not initialized") == true)
    }

    // MARK: - CycleRepeatCommand Tests

    @Test("CycleRepeat cycles through repeat modes when PlayerService exists")
    func cycleRepeatCyclesThroughModes() {
        let playerService = PlayerService()
        PlayerService.shared = playerService

        #expect(playerService.repeatMode == .off)

        let command = CycleRepeatCommand()

        _ = command.performDefaultImplementation()
        #expect(playerService.repeatMode == .all)

        _ = command.performDefaultImplementation()
        #expect(playerService.repeatMode == .one)

        _ = command.performDefaultImplementation()
        #expect(playerService.repeatMode == .off)

        // Cleanup
        PlayerService.shared = nil
    }

    @Test("CycleRepeat sets error when PlayerService is nil")
    func cycleRepeatSetsErrorWhenNil() {
        PlayerService.shared = nil

        let command = CycleRepeatCommand()
        _ = command.performDefaultImplementation()

        #expect(command.scriptErrorNumber == -1728)
        #expect(command.scriptErrorString?.contains("Player service not initialized") == true)
    }

    // MARK: - SetVolumeCommand Tests

    @Test("SetVolume sets error when PlayerService is nil")
    func setVolumeSetsErrorWhenNil() {
        PlayerService.shared = nil

        let command = SetVolumeCommand()
        command.directParameter = 50 as NSNumber
        _ = command.performDefaultImplementation()

        #expect(command.scriptErrorNumber == -1728)
    }

    @Test("SetVolume sets error for invalid parameter type")
    func setVolumeSetsErrorForInvalidParameter() {
        let playerService = PlayerService()
        PlayerService.shared = playerService

        let command = SetVolumeCommand()
        command.directParameter = "not a number" as NSString
        _ = command.performDefaultImplementation()

        #expect(command.scriptErrorNumber == errAECoercionFail)
        #expect(command.scriptErrorString?.contains("Volume must be an integer") == true)

        // Cleanup
        PlayerService.shared = nil
    }

    // MARK: - PlayCommand Tests

    @Test("Play sets error when PlayerService is nil")
    func playSetsErrorWhenNil() {
        PlayerService.shared = nil

        let command = PlayCommand()
        _ = command.performDefaultImplementation()

        #expect(command.scriptErrorNumber == -1728)
        #expect(command.scriptErrorString?.contains("Player service not initialized") == true)
    }

    // MARK: - PlayVideoCommand Tests

    @Test("PlayVideo keeps the first-session gate closed until playback is confirmed")
    func playVideoKeepsFirstSessionGateClosedUntilPlaybackIsConfirmed() async {
        let playerService = PlayerService()
        let mockClient = MockYTMusicClient()
        playerService.setYTMusicClient(mockClient)
        PlayerService.shared = playerService

        let firstCommand = PlayVideoCommand()
        firstCommand.directParameter = "first-video-id" as NSString

        _ = firstCommand.performDefaultImplementation()
        let firstPlayLoaded = await self.waitUntil {
            playerService.pendingPlayVideoId == "first-video-id" &&
                playerService.currentTrack?.videoId == "first-video-id" &&
                playerService.queue.count == 1 &&
                playerService.queue.first?.videoId == "first-video-id" &&
                playerService.showMiniPlayer == true &&
                mockClient.getRadioQueueVideoIds == ["first-video-id"]
        }

        #expect(firstPlayLoaded)
        #expect(playerService.pendingPlayVideoId == "first-video-id")
        #expect(playerService.currentTrack?.videoId == "first-video-id")
        #expect(playerService.queue.count == 1)
        #expect(playerService.queue.first?.videoId == "first-video-id")
        #expect(playerService.showMiniPlayer == true)

        playerService.miniPlayerDismissed()
        #expect(playerService.showMiniPlayer == false)

        let secondCommand = PlayVideoCommand()
        secondCommand.directParameter = "second-video-id" as NSString

        _ = secondCommand.performDefaultImplementation()
        let secondPlayLoaded = await self.waitUntil {
            playerService.pendingPlayVideoId == "second-video-id" &&
                playerService.currentTrack?.videoId == "second-video-id" &&
                playerService.queue.count == 1 &&
                playerService.queue.first?.videoId == "second-video-id" &&
                playerService.showMiniPlayer == true &&
                mockClient.getRadioQueueVideoIds == ["first-video-id", "second-video-id"]
        }

        #expect(secondPlayLoaded)
        #expect(playerService.pendingPlayVideoId == "second-video-id")
        #expect(playerService.currentTrack?.videoId == "second-video-id")
        #expect(playerService.queue.count == 1)
        #expect(playerService.queue.first?.videoId == "second-video-id")
        #expect(playerService.showMiniPlayer == true)

        playerService.confirmPlaybackStarted()
        #expect(playerService.showMiniPlayer == false)

        let thirdCommand = PlayVideoCommand()
        thirdCommand.directParameter = "third-video-id" as NSString

        _ = thirdCommand.performDefaultImplementation()
        let thirdPlayLoaded = await self.waitUntil {
            playerService.pendingPlayVideoId == "third-video-id" &&
                playerService.currentTrack?.videoId == "third-video-id" &&
                playerService.queue.count == 1 &&
                playerService.queue.first?.videoId == "third-video-id" &&
                playerService.showMiniPlayer == false &&
                mockClient.getRadioQueueVideoIds == ["first-video-id", "second-video-id", "third-video-id"]
        }

        #expect(thirdPlayLoaded)
        #expect(playerService.pendingPlayVideoId == "third-video-id")
        #expect(playerService.currentTrack?.videoId == "third-video-id")
        #expect(playerService.queue.count == 1)
        #expect(playerService.queue.first?.videoId == "third-video-id")
        #expect(playerService.showMiniPlayer == false)
        #expect(mockClient.getRadioQueueCalled == true)
        #expect(mockClient.getRadioQueueVideoIds == ["first-video-id", "second-video-id", "third-video-id"])

        // Cleanup
        PlayerService.shared = nil
    }

    // MARK: - PauseCommand Tests

    @Test("Pause sets error when PlayerService is nil")
    func pauseSetsErrorWhenNil() {
        PlayerService.shared = nil

        let command = PauseCommand()
        _ = command.performDefaultImplementation()

        #expect(command.scriptErrorNumber == -1728)
    }

    // MARK: - PlayPauseCommand Tests

    @Test("PlayPause sets error when PlayerService is nil")
    func playPauseSetsErrorWhenNil() {
        PlayerService.shared = nil

        let command = PlayPauseCommand()
        _ = command.performDefaultImplementation()

        #expect(command.scriptErrorNumber == -1728)
    }

    // MARK: - NextTrackCommand Tests

    @Test("NextTrack sets error when PlayerService is nil")
    func nextTrackSetsErrorWhenNil() {
        PlayerService.shared = nil

        let command = NextTrackCommand()
        _ = command.performDefaultImplementation()

        #expect(command.scriptErrorNumber == -1728)
    }

    // MARK: - PreviousTrackCommand Tests

    @Test("PreviousTrack sets error when PlayerService is nil")
    func previousTrackSetsErrorWhenNil() {
        PlayerService.shared = nil

        let command = PreviousTrackCommand()
        _ = command.performDefaultImplementation()

        #expect(command.scriptErrorNumber == -1728)
    }

    // MARK: - ToggleMuteCommand Tests

    @Test("ToggleMute sets error when PlayerService is nil")
    func toggleMuteSetsErrorWhenNil() {
        PlayerService.shared = nil

        let command = ToggleMuteCommand()
        _ = command.performDefaultImplementation()

        #expect(command.scriptErrorNumber == -1728)
    }

    // MARK: - LikeTrackCommand Tests

    @Test("LikeTrack sets error when PlayerService is nil")
    func likeTrackSetsErrorWhenNil() {
        PlayerService.shared = nil

        let command = LikeTrackCommand()
        _ = command.performDefaultImplementation()

        #expect(command.scriptErrorNumber == -1728)
    }

    // MARK: - DislikeTrackCommand Tests

    @Test("DislikeTrack sets error when PlayerService is nil")
    func dislikeTrackSetsErrorWhenNil() {
        PlayerService.shared = nil

        let command = DislikeTrackCommand()
        _ = command.performDefaultImplementation()

        #expect(command.scriptErrorNumber == -1728)
    }
}
