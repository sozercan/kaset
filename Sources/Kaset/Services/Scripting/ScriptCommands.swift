import AppKit
import Foundation
import os

private let errPlayerNotAvailable: Int = -1728

private let playerNotAvailableMessage = "Player service not initialized. Please wait for the app to fully launch."

private let invalidVideoIdMessage = "Video ID must be a non-empty string of letters, digits, - and _."

private let invalidVideoIdListMessage = "Video IDs must be a non-empty list of video IDs (letters, digits, - and _)."

private let logger = DiagnosticsLogger.scripting

@MainActor
private func getPlayerService() -> PlayerService? {
    PlayerService.shared
}

private let videoIdCharacters = CharacterSet(
    charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
)

private func scriptVideoId(from value: Any?) -> String? {
    guard let string = value as? String else { return nil }
    let videoId = string.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !videoId.isEmpty,
          videoId.unicodeScalars.allSatisfy(videoIdCharacters.contains)
    else { return nil }
    return videoId
}

private func videoIdList(from parameter: Any?) -> [String]? {
    let values: [Any]
    if let videoId = parameter as? String {
        values = [videoId]
    } else if let array = parameter as? [Any] {
        values = array
    } else {
        return nil
    }
    let videoIds = values.compactMap(scriptVideoId(from:))
    guard !videoIds.isEmpty, videoIds.count == values.count else { return nil }
    return videoIds
}

private extension NSScriptCommand {
    func optionalArgument<T>(_ key: String, default defaultValue: T) -> T? {
        guard let value = self.evaluatedArguments?[key] else { return defaultValue }
        return value as? T
    }

    func zeroBasedIndex(
        fromOneBased index: Int,
        count: Int,
        countDescription: String,
        commandName: String
    ) -> Int? {
        let zeroBasedIndex = index - 1
        guard zeroBasedIndex >= 0, zeroBasedIndex < count else {
            logger.error("\(commandName) command failed: index \(index) out of bounds (1..\(count))")
            self.scriptErrorNumber = -1728
            self.scriptErrorString = "Index out of bounds. \(countDescription)"
            return nil
        }
        return zeroBasedIndex
    }
}

@objc(KasetPlayCommand)
final class PlayCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        guard let playerService = MainActor.assumeIsolated({ getPlayerService() }) else {
            logger.error("Play command failed: PlayerService.shared is nil")
            scriptErrorNumber = errPlayerNotAvailable
            scriptErrorString = playerNotAvailableMessage
            return nil
        }
        logger.info("Executing play command")
        Task { @MainActor in
            if playerService.hasNoLoadedMusicPlayback, !playerService.queueEntries.isEmpty {
                await playerService.playFromQueue(at: playerService.currentIndex)
            } else {
                await playerService.resume()
            }
        }
        return nil
    }
}

@objc(KasetPlayVideoCommand)
final class PlayVideoCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        guard let videoId = scriptVideoId(from: self.directParameter) else {
            logger.error("PlayVideo command failed: invalid or empty video ID")
            self.scriptErrorNumber = errAECoercionFail
            self.scriptErrorString = invalidVideoIdMessage
            return nil
        }

        guard let playerService = MainActor.assumeIsolated({ getPlayerService() }) else {
            logger.error("PlayVideo command failed: PlayerService.shared is nil")
            self.scriptErrorNumber = errPlayerNotAvailable
            self.scriptErrorString = playerNotAvailableMessage
            return nil
        }
        logger.info("Executing play video command with ID: \(videoId)")
        let song = Song.placeholder(videoId: videoId)
        let intent = MainActor.assumeIsolated { playerService.beginRadioPlaybackIntent(for: song) }
        Task { @MainActor in
            await playerService.playWithRadio(song: song, intent: intent)
        }
        return nil
    }
}

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

@objc(KasetGetPlayerInfoCommand)
final class GetPlayerInfoCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
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

        if result.hasPrefix("{\"error\"") {
            scriptErrorNumber = errPlayerNotAvailable
            scriptErrorString = playerNotAvailableMessage
        }

        return result
    }
}

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

@objc(KasetGetPlayQueueCommand)
final class GetPlayQueueCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        let result = MainActor.assumeIsolated { () -> String in
            guard let playerService = getPlayerService() else {
                logger.error("GetPlayQueue command failed: PlayerService.shared is nil")
                return "{\"error\": \"Player not available\"}"
            }

            logger.info("Executing getPlayQueue command")

            let tracks = playerService.queue.map { track -> [String: Any] in
                [
                    "name": track.title,
                    "artist": track.artistsDisplay,
                    "album": track.album?.title ?? "",
                    "duration": track.duration ?? 0,
                    "videoId": track.videoId,
                    "audioVideoId": track.preferredAudioVideoId,
                    "artworkURL": track.thumbnailURL?.absoluteString ?? "",
                ]
            }

            let info: [String: Any] = [
                "currentIndex": playerService.activePlaybackQueueIndex.map { $0 + 1 } ?? 0,
                "tracks": tracks,
            ]

            if let data = try? JSONSerialization.data(withJSONObject: info, options: [.sortedKeys]),
               let json = String(data: data, encoding: .utf8)
            {
                return json
            }

            logger.error("GetPlayQueue command failed: JSON serialization error")
            return "{}"
        }

        if result.hasPrefix("{\"error\"") {
            self.scriptErrorNumber = errPlayerNotAvailable
            self.scriptErrorString = playerNotAvailableMessage
        }

        return result
    }
}

@objc(KasetPlayTrackAtIndexCommand)
final class PlayTrackAtIndexCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        guard let indexValue = self.directParameter as? Int else {
            logger.error("PlayTrackAtIndex command failed: invalid index parameter")
            self.scriptErrorNumber = errAECoercionFail
            self.scriptErrorString = "Track index must be an integer."
            return nil
        }

        guard let playerService = MainActor.assumeIsolated({ getPlayerService() }) else {
            logger.error("PlayTrackAtIndex command failed: PlayerService.shared is nil")
            self.scriptErrorNumber = errPlayerNotAvailable
            self.scriptErrorString = playerNotAvailableMessage
            return nil
        }

        let queueCount = MainActor.assumeIsolated { playerService.queueEntries.count }
        guard let zeroBasedIndex = self.zeroBasedIndex(
            fromOneBased: indexValue,
            count: queueCount,
            countDescription: "The queue contains \(queueCount) tracks.",
            commandName: "PlayTrackAtIndex"
        ) else { return nil }

        let selection = MainActor.assumeIsolated { () -> (UUID, MusicPlaybackReservation)? in
            guard let entryID = playerService.queueEntries[safe: zeroBasedIndex]?.id else { return nil }
            return (entryID, playerService.reserveMusicPlaybackIntent())
        }
        guard let (entryID, reservation) = selection else { return nil }
        logger.info("Executing playTrackAtIndex command with index: \(indexValue)")
        Task { @MainActor in
            guard let intent = playerService.claimMusicPlaybackIntent(
                reservation,
                queueEntryID: entryID
            ) else { return }
            await playerService.playFromQueue(entryID: entryID, intent: intent)
        }
        return nil
    }
}

@objc(KasetPlayVideosCommand)
final class PlayVideosCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        guard let videoIds = videoIdList(from: self.directParameter) else {
            logger.error("PlayVideos command failed: invalid or empty video ID list")
            self.scriptErrorNumber = errAECoercionFail
            self.scriptErrorString = invalidVideoIdListMessage
            return nil
        }

        guard let startingAt = self.optionalArgument("startingAt", default: 1) else {
            logger.error("PlayVideos command failed: invalid starting index parameter")
            self.scriptErrorNumber = errAECoercionFail
            self.scriptErrorString = "Starting index must be an integer."
            return nil
        }

        guard let zeroBasedIndex = self.zeroBasedIndex(
            fromOneBased: startingAt,
            count: videoIds.count,
            countDescription: "The list contains \(videoIds.count) videos.",
            commandName: "PlayVideos"
        ) else { return nil }

        guard let playerService = MainActor.assumeIsolated({ getPlayerService() }) else {
            logger.error("PlayVideos command failed: PlayerService.shared is nil")
            self.scriptErrorNumber = errPlayerNotAvailable
            self.scriptErrorString = playerNotAvailableMessage
            return nil
        }

        logger.info("Executing play videos command with \(videoIds.count) videos starting at \(startingAt)")
        let installedQueue = MainActor.assumeIsolated {
            playerService.installQueue(
                videoIds.map(Song.placeholder(videoId:)),
                startingAt: zeroBasedIndex,
                deferringSmartShuffleFill: false,
                intent: playerService.beginMusicPlaybackIntent()
            )
        }
        guard let installedQueue else { return nil }
        Task { @MainActor in
            await playerService.startInstalledQueue(installedQueue)
        }
        return nil
    }
}

@objc(KasetAddToQueueCommand)
final class AddToQueueCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        guard let videoIds = videoIdList(from: self.directParameter) else {
            logger.error("AddToQueue command failed: invalid or empty video ID list")
            self.scriptErrorNumber = errAECoercionFail
            self.scriptErrorString = invalidVideoIdListMessage
            return nil
        }

        guard let playNext = self.optionalArgument("next", default: false) else {
            logger.error("AddToQueue command failed: invalid next parameter")
            self.scriptErrorNumber = errAECoercionFail
            self.scriptErrorString = "The next parameter must be a boolean."
            return nil
        }

        guard let playerService = MainActor.assumeIsolated({ getPlayerService() }) else {
            logger.error("AddToQueue command failed: PlayerService.shared is nil")
            self.scriptErrorNumber = errPlayerNotAvailable
            self.scriptErrorString = playerNotAvailableMessage
            return nil
        }

        logger.info("Executing add to queue command with \(videoIds.count) videos (next: \(playNext))")
        MainActor.assumeIsolated {
            let songs = videoIds.map(Song.placeholder(videoId:))
            if playNext {
                playerService.insertNextInQueue(songs)
            } else {
                playerService.appendToQueue(songs)
            }
        }
        return nil
    }
}

@objc(KasetRemoveFromQueueCommand)
final class RemoveFromQueueCommand: NSScriptCommand {
    private enum Outcome {
        case removed
        case onlyPlaying
        case notFound
    }

    override func performDefaultImplementation() -> Any? {
        guard let videoId = scriptVideoId(from: self.directParameter) else {
            logger.error("RemoveFromQueue command failed: invalid or empty video ID")
            self.scriptErrorNumber = errAECoercionFail
            self.scriptErrorString = invalidVideoIdMessage
            return nil
        }

        guard let playerService = MainActor.assumeIsolated({ getPlayerService() }) else {
            logger.error("RemoveFromQueue command failed: PlayerService.shared is nil")
            self.scriptErrorNumber = errPlayerNotAvailable
            self.scriptErrorString = playerNotAvailableMessage
            return nil
        }

        let outcome = MainActor.assumeIsolated { () -> Outcome in
            let playingEntryID = playerService.queueEntryIDOwningCurrentPlayback
            var matchesPlayingEntry = false
            var entryIDs = Set<UUID>()
            for entry in playerService.queueEntries
                where entry.song.videoId == videoId || entry.song.preferredAudioVideoId == videoId
            {
                if entry.id == playingEntryID {
                    matchesPlayingEntry = true
                } else {
                    entryIDs.insert(entry.id)
                }
            }
            guard !entryIDs.isEmpty else { return matchesPlayingEntry ? .onlyPlaying : .notFound }
            playerService.removeFromQueue(entryIDs: entryIDs)
            return .removed
        }

        switch outcome {
        case .removed:
            logger.info("Executed remove from queue command with ID: \(videoId)")
        case .onlyPlaying:
            logger.error("RemoveFromQueue command failed: video \(videoId) is playing")
            self.scriptErrorNumber = errAEEventFailed
            self.scriptErrorString = "Cannot remove the video that is playing."
        case .notFound:
            logger.error("RemoveFromQueue command failed: video \(videoId) is not in the queue")
            self.scriptErrorNumber = -1728
            self.scriptErrorString = "The queue does not contain a video with that ID."
        }
        return nil
    }
}
