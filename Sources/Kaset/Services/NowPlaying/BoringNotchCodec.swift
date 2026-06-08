import Foundation

enum BoringNotchCodec {
    static func playerInfoPayload(type: String, snapshot: NowPlayingSnapshot) -> [String: Any] {
        var payload: [String: Any] = [
            "type": type,
            "isPaused": snapshot.playbackState != .playing,
            "repeatMode": Self.repeatModeValue(snapshot.repeatMode),
            "repeatModeString": Self.repeatModeString(snapshot.repeatMode),
            "isShuffled": snapshot.shuffleEnabled,
            "volume": max(0, min(100, snapshot.volume * 100)),
        ]

        if let track = snapshot.track {
            payload["title"] = track.title
            if let artist = track.artist {
                payload["artist"] = artist
            }
            if let albumTitle = track.albumTitle {
                payload["album"] = albumTitle
            }
            if let artworkURL = track.artworkURL {
                payload["imageSrc"] = artworkURL.absoluteString
            }
            if let videoID = track.videoID {
                payload["videoId"] = videoID
            }
        }

        if let elapsedSeconds = snapshot.elapsedSeconds {
            payload["elapsedSeconds"] = elapsedSeconds
        }
        if let durationSeconds = snapshot.durationSeconds {
            payload["songDuration"] = durationSeconds
        }

        payload["song"] = payload.filter { $0.key != "type" }
        return payload
    }

    static func songPayload(snapshot: NowPlayingSnapshot) -> [String: Any] {
        var payload = Self.playerInfoPayload(type: "PLAYER_INFO", snapshot: snapshot)
        payload.removeValue(forKey: "type")
        return payload
    }

    static func likeStatePayload(snapshot: NowPlayingSnapshot) -> [String: Any] {
        let state: Any = switch snapshot.likeStatus {
        case .like:
            "LIKE"
        case .dislike:
            "DISLIKE"
        case .indifferent:
            NSNull()
        }
        return ["state": state]
    }

    static func command(method: String, path: String, body: Data) -> NowPlayingCommand? {
        switch (method, path) {
        case ("POST", "/api/v1/play"):
            .play
        case ("POST", "/api/v1/pause"):
            .pause
        case ("POST", "/api/v1/toggle-play"):
            .togglePlay
        case ("POST", "/api/v1/next"):
            .next
        case ("POST", "/api/v1/previous"):
            .previous
        case ("POST", "/api/v1/seek-to"):
            self.jsonBodyValue(body, key: "seconds").map { .seek(seconds: $0) }
        case ("POST", "/api/v1/volume"):
            self.jsonBodyValue(body, key: "volume").map { .setVolume($0 / 100) }
        case ("POST", "/api/v1/shuffle"):
            .toggleShuffle
        case ("POST", "/api/v1/switch-repeat"):
            .cycleRepeatMode
        case ("POST", "/api/v1/like"):
            .like
        case ("POST", "/api/v1/dislike"):
            .dislike
        default:
            nil
        }
    }

    static func repeatModeValue(_ mode: PlayerService.RepeatMode) -> Int {
        switch mode {
        case .off:
            0
        case .all:
            1
        case .one:
            2
        }
    }

    static func repeatModeString(_ mode: PlayerService.RepeatMode) -> String {
        switch mode {
        case .off:
            "NONE"
        case .all:
            "ALL"
        case .one:
            "ONE"
        }
    }

    private static func jsonBodyValue(_ data: Data, key: String) -> Double? {
        guard !data.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }

        if let number = object[key] as? NSNumber {
            return number.doubleValue
        }
        if let string = object[key] as? String {
            return Double(string)
        }
        return nil
    }
}
