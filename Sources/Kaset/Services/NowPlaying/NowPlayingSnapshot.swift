import Foundation

// MARK: - NowPlayingSurfaceID

struct NowPlayingSurfaceID: RawRepresentable, Hashable, Codable, Identifiable, ExpressibleByStringLiteral {
    let rawValue: String

    var id: String {
        self.rawValue
    }

    init(rawValue: String) {
        self.rawValue = rawValue
    }

    init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    init(stringLiteral value: String) {
        self.rawValue = value
    }

    static let lyricsSidebar = Self("lyricsSidebar")
    static let miniPlayerLyrics = Self("miniPlayerLyrics")
    static let musicIsland = Self("musicIsland")
    static let boringNotchBridge = Self("boringNotchBridge")
}

// MARK: - NowPlayingSnapshot

struct NowPlayingSnapshot: Equatable {
    let playbackState: PlayerService.PlaybackState
    let track: NowPlayingTrackSnapshot?
    let elapsedSeconds: TimeInterval?
    let durationSeconds: TimeInterval?
    let volume: Double
    let shuffleEnabled: Bool
    let repeatMode: PlayerService.RepeatMode
    let likeStatus: LikeStatus
    let currentLyricLine: SyncedLyricLine?

    static let empty = Self(
        playbackState: .idle,
        track: nil,
        elapsedSeconds: nil,
        durationSeconds: nil,
        volume: 1,
        shuffleEnabled: false,
        repeatMode: .off,
        likeStatus: .indifferent,
        currentLyricLine: nil
    )
}

// MARK: - NowPlayingTrackSnapshot

struct NowPlayingTrackSnapshot: Equatable {
    let title: String
    let artist: String?
    let albumTitle: String?
    let artworkURL: URL?
    let videoID: String?
}
