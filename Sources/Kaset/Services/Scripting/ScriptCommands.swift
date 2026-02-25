import AppKit
import Foundation
import os

// MARK: - Constants

/// AppleScript error code for when PlayerService is not available.
private let errPlayerNotAvailable: Int = -1728 // errAENoSuchObject

/// Error message when PlayerService is not available.
private let playerNotAvailableMessage = "Player service not initialized. Please wait for the app to fully launch."

/// Shared logger for scripting commands.
private let logger = DiagnosticsLogger.scripting

// MARK: - Helper

/// Checks if PlayerService.shared is available. Must be called from main thread.
@MainActor
private func getPlayerService() -> PlayerService? {
    PlayerService.shared
}

// MARK: - PlayCommand

/// Play command: start or resume playback.
@objc(KasetPlayCommand)
final class PlayCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        // AppleScript commands run on the main thread
        guard let playerService = MainActor.assumeIsolated({ getPlayerService() }) else {
            logger.error("Play command failed: PlayerService.shared is nil")
            scriptErrorNumber = errPlayerNotAvailable
            scriptErrorString = playerNotAvailableMessage
            return nil
        }
        logger.info("Executing play command")
        Task { @MainActor in
            await playerService.resume()
        }
        return nil
    }
}

// MARK: - PauseCommand

/// Pause command: pause playback.
@objc(KasetPauseCommand)
final class PauseCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        guard let playerService = MainActor.assumeIsolated({ getPlayerService() }) else {
            logger.error("Pause command failed: PlayerService.shared is nil")
            scriptErrorNumber = errPlayerNotAvailable
            scriptErrorString = playerNotAvailableMessage
            return nil
        }
        logger.info("Executing pause command")
        Task { @MainActor in
            await playerService.pause()
        }
        return nil
    }
}

// MARK: - PlayPauseCommand

/// PlayPause command: toggle play/pause state.
@objc(KasetPlayPauseCommand)
final class PlayPauseCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        guard let playerService = MainActor.assumeIsolated({ getPlayerService() }) else {
            logger.error("PlayPause command failed: PlayerService.shared is nil")
            scriptErrorNumber = errPlayerNotAvailable
            scriptErrorString = playerNotAvailableMessage
            return nil
        }
        logger.info("Executing playPause command")
        Task { @MainActor in
            await playerService.playPause()
        }
        return nil
    }
}

// MARK: - NextTrackCommand

/// NextTrack command: skip to the next track.
@objc(KasetNextTrackCommand)
final class NextTrackCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        guard let playerService = MainActor.assumeIsolated({ getPlayerService() }) else {
            logger.error("NextTrack command failed: PlayerService.shared is nil")
            scriptErrorNumber = errPlayerNotAvailable
            scriptErrorString = playerNotAvailableMessage
            return nil
        }
        logger.info("Executing next track command")
        Task { @MainActor in
            await playerService.next()
        }
        return nil
    }
}

// MARK: - PreviousTrackCommand

/// PreviousTrack command: go to the previous track.
@objc(KasetPreviousTrackCommand)
final class PreviousTrackCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        guard let playerService = MainActor.assumeIsolated({ getPlayerService() }) else {
            logger.error("PreviousTrack command failed: PlayerService.shared is nil")
            scriptErrorNumber = errPlayerNotAvailable
            scriptErrorString = playerNotAvailableMessage
            return nil
        }
        logger.info("Executing previous track command")
        Task { @MainActor in
            await playerService.previous()
        }
        return nil
    }
}

// MARK: - SetVolumeCommand

/// SetVolume command: set the playback volume (0-100).
@objc(KasetSetVolumeCommand)
final class SetVolumeCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        guard let volumeValue = directParameter as? Int else {
            logger.error("SetVolume command failed: invalid volume parameter")
            scriptErrorNumber = errAECoercionFail
            scriptErrorString = "Volume must be an integer between 0 and 100."
            return nil
        }

        let normalizedVolume = Double(max(0, min(100, volumeValue))) / 100.0

        guard let playerService = MainActor.assumeIsolated({ getPlayerService() }) else {
            logger.error("SetVolume command failed: PlayerService.shared is nil")
            scriptErrorNumber = errPlayerNotAvailable
            scriptErrorString = playerNotAvailableMessage
            return nil
        }
        logger.info("Executing setVolume command with value: \(volumeValue)")
        Task { @MainActor in
            await playerService.setVolume(normalizedVolume)
        }
        return nil
    }
}

// MARK: - ToggleShuffleCommand

/// ToggleShuffle command: toggle shuffle mode.
/// This is a synchronous operation.
@objc(KasetToggleShuffleCommand)
final class ToggleShuffleCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        guard let playerService = MainActor.assumeIsolated({ getPlayerService() }) else {
            logger.error("ToggleShuffle command failed: PlayerService.shared is nil")
            scriptErrorNumber = errPlayerNotAvailable
            scriptErrorString = playerNotAvailableMessage
            return nil
        }
        logger.info("Executing toggleShuffle command")
        MainActor.assumeIsolated {
            playerService.toggleShuffle()
        }
        return nil
    }
}

// MARK: - CycleRepeatCommand

/// CycleRepeat command: cycle through repeat modes (off, all, one).
/// This is a synchronous operation.
@objc(KasetCycleRepeatCommand)
final class CycleRepeatCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        guard let playerService = MainActor.assumeIsolated({ getPlayerService() }) else {
            logger.error("CycleRepeat command failed: PlayerService.shared is nil")
            scriptErrorNumber = errPlayerNotAvailable
            scriptErrorString = playerNotAvailableMessage
            return nil
        }
        logger.info("Executing cycleRepeat command")
        MainActor.assumeIsolated {
            playerService.cycleRepeatMode()
        }
        return nil
    }
}

// MARK: - ToggleMuteCommand

/// ToggleMute command: toggle mute state.
@objc(KasetToggleMuteCommand)
final class ToggleMuteCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        guard let playerService = MainActor.assumeIsolated({ getPlayerService() }) else {
            logger.error("ToggleMute command failed: PlayerService.shared is nil")
            scriptErrorNumber = errPlayerNotAvailable
            scriptErrorString = playerNotAvailableMessage
            return nil
        }
        logger.info("Executing toggleMute command")
        Task { @MainActor in
            await playerService.toggleMute()
        }
        return nil
    }
}

// MARK: - GetPlayerInfoCommand

/// GetPlayerInfo command: returns current player state as JSON.
/// This is a synchronous operation that returns immediately.
@objc(KasetGetPlayerInfoCommand)
final class GetPlayerInfoCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        // AppleScript runs on main thread, so we can assume MainActor isolation
        let result = MainActor.assumeIsolated { () -> String in
            guard let playerService = getPlayerService() else {
                logger.error("GetPlayerInfo command failed: PlayerService.shared is nil")
                return "{\"error\": \"Player not available\"}"
            }

            logger.info("Executing getPlayerInfo command")

            let track = playerService.currentTrack
            let repeatMode = switch playerService.repeatMode {
            case .off: "off"
            case .all: "all"
            case .one: "one"
            }

            let likeStatus = switch playerService.currentTrackLikeStatus {
            case .like: "liked"
            case .dislike: "disliked"
            case .indifferent: "none"
            }

            var info: [String: Any] = [
                "isPlaying": playerService.isPlaying,
                "isPaused": playerService.state == .paused,
                "position": playerService.progress,
                "duration": playerService.duration,
                "volume": Int(playerService.volume * 100),
                "shuffling": playerService.shuffleEnabled,
                "repeating": repeatMode,
                "muted": playerService.isMuted,
                "likeStatus": likeStatus,
            ]

            if let track {
                info["currentTrack"] = [
                    "name": track.title,
                    "artist": track.artistsDisplay,
                    "album": track.album?.title ?? "",
                    "duration": track.duration ?? 0,
                    "videoId": track.videoId,
                    "artworkURL": track.thumbnailURL?.absoluteString ?? "",
                ]
            }

            if let data = try? JSONSerialization.data(withJSONObject: info, options: [.sortedKeys]),
               let json = String(data: data, encoding: .utf8)
            {
                return json
            }

            logger.error("GetPlayerInfo command failed: JSON serialization error")
            return "{}"
        }

        // Set error if player wasn't available (check by looking at result)
        if result.contains("\"error\"") {
            scriptErrorNumber = errPlayerNotAvailable
            scriptErrorString = playerNotAvailableMessage
        }

        return result
    }
}

// MARK: - LikeTrackCommand

/// LikeTrack command: like/unlike the current track.
/// This is a synchronous operation.
@objc(KasetLikeTrackCommand)
final class LikeTrackCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        guard let playerService = MainActor.assumeIsolated({ getPlayerService() }) else {
            logger.error("LikeTrack command failed: PlayerService.shared is nil")
            scriptErrorNumber = errPlayerNotAvailable
            scriptErrorString = playerNotAvailableMessage
            return nil
        }
        logger.info("Executing likeTrack command")
        MainActor.assumeIsolated {
            playerService.likeCurrentTrack()
        }
        return nil
    }
}

// MARK: - DislikeTrackCommand

/// DislikeTrack command: dislike/undislike the current track.
/// This is a synchronous operation.
@objc(KasetDislikeTrackCommand)
final class DislikeTrackCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        guard let playerService = MainActor.assumeIsolated({ getPlayerService() }) else {
            logger.error("DislikeTrack command failed: PlayerService.shared is nil")
            scriptErrorNumber = errPlayerNotAvailable
            scriptErrorString = playerNotAvailableMessage
            return nil
        }
        logger.info("Executing dislikeTrack command")
        MainActor.assumeIsolated {
            playerService.dislikeCurrentTrack()
        }
        return nil
    }
}
