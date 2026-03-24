import Foundation

// MARK: - LyricsSearchInfo

/// Information needed to search for lyrics.
struct LyricsSearchInfo {
    let title: String
    let artist: String
    let album: String?
    let duration: TimeInterval? // seconds
    let videoId: String
}

// MARK: - LyricsProvider

/// Protocol all lyrics providers conform to.
protocol LyricsProvider: Sendable {
    var name: String { get }
    func search(info: LyricsSearchInfo) async -> LyricResult
}
