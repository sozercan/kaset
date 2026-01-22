import AppKit
import Foundation

// MARK: - AppleScript Commands

/// Play command: start or resume playback.
@objc(KasetPlayCommand)
final class PlayCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        Task { @MainActor in
            guard let playerService = PlayerService.shared else { return }
            await playerService.resume()
        }
        return nil
    }
}

/// Pause command: pause playback.
@objc(KasetPauseCommand)
final class PauseCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        Task { @MainActor in
            guard let playerService = PlayerService.shared else { return }
            await playerService.pause()
        }
        return nil
    }
}

/// PlayPause command: toggle play/pause state.
@objc(KasetPlayPauseCommand)
final class PlayPauseCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        Task { @MainActor in
            guard let playerService = PlayerService.shared else { return }
            await playerService.playPause()
        }
        return nil
    }
}

/// NextTrack command: skip to the next track.
@objc(KasetNextTrackCommand)
final class NextTrackCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        Task { @MainActor in
            guard let playerService = PlayerService.shared else { return }
            await playerService.next()
        }
        return nil
    }
}

/// PreviousTrack command: go to the previous track.
@objc(KasetPreviousTrackCommand)
final class PreviousTrackCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        Task { @MainActor in
            guard let playerService = PlayerService.shared else { return }
            await playerService.previous()
        }
        return nil
    }
}

/// SetVolume command: set the playback volume (0-100).
@objc(KasetSetVolumeCommand)
final class SetVolumeCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        guard let volumeValue = self.directParameter as? Int else {
            scriptErrorNumber = errAECoercionFail
            return nil
        }

        let normalizedVolume = Double(max(0, min(100, volumeValue))) / 100.0

        Task { @MainActor in
            guard let playerService = PlayerService.shared else { return }
            await playerService.setVolume(normalizedVolume)
        }
        return nil
    }
}

/// ToggleShuffle command: toggle shuffle mode.
@objc(KasetToggleShuffleCommand)
final class ToggleShuffleCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        Task { @MainActor in
            guard let playerService = PlayerService.shared else { return }
            playerService.toggleShuffle()
        }
        return nil
    }
}

/// CycleRepeat command: cycle through repeat modes (off, all, one).
@objc(KasetCycleRepeatCommand)
final class CycleRepeatCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        Task { @MainActor in
            guard let playerService = PlayerService.shared else { return }
            playerService.cycleRepeatMode()
        }
        return nil
    }
}

/// ToggleMute command: toggle mute state.
@objc(KasetToggleMuteCommand)
final class ToggleMuteCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        Task { @MainActor in
            guard let playerService = PlayerService.shared else { return }
            await playerService.toggleMute()
        }
        return nil
    }
}

/// GetPlayerInfo command: returns current player state as JSON.
@objc(KasetGetPlayerInfoCommand)
final class GetPlayerInfoCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        // AppleScript runs on main thread, so we can assume MainActor isolation
        let result: String = MainActor.assumeIsolated {
            guard let playerService = PlayerService.shared else {
                return "{\"error\": \"Player not available\"}"
            }

            let track = playerService.currentTrack
            let repeatMode: String = switch playerService.repeatMode {
            case .off: "off"
            case .all: "all"
            case .one: "one"
            }

            let likeStatus: String = switch playerService.currentTrackLikeStatus {
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

            return "{}"
        }
        return result
    }
}

/// LikeTrack command: like/unlike the current track.
@objc(KasetLikeTrackCommand)
final class LikeTrackCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        Task { @MainActor in
            guard let playerService = PlayerService.shared else { return }
            playerService.likeCurrentTrack()
        }
        return nil
    }
}

/// DislikeTrack command: dislike/undislike the current track.
@objc(KasetDislikeTrackCommand)
final class DislikeTrackCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        Task { @MainActor in
            guard let playerService = PlayerService.shared else { return }
            playerService.dislikeCurrentTrack()
        }
        return nil
    }
}
