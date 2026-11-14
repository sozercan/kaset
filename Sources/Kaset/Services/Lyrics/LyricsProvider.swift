import Foundation

// MARK: - LyricsSearchInfo

/// Information needed to search for lyrics.
struct LyricsSearchInfo {
    let title: String
    let artist: String
    let album: String?
    let duration: TimeInterval? // seconds
    let videoId: String
    /// The lyrics are matched against a stream whose recording may differ from
    /// the song's own (a loaded MV can be a live version or a different cut).
    /// Providers must then treat a large duration mismatch as "wrong recording"
    /// and degrade to unsynced lyrics: wrong highlighting is worse than none.
    var requiresCloseDurationMatch = false
}

// MARK: - LyricsProvider

/// Protocol all lyrics providers conform to.
protocol LyricsProvider: Sendable {
    var name: String { get }
    func search(info: LyricsSearchInfo) async -> LyricResult
}
