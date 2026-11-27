import Foundation

struct LyricsSearchInfo {
    let title: String
    let artist: String
    let album: String?
    let duration: TimeInterval?
    let videoId: String
}

protocol LyricsProvider: Sendable {
    var name: String { get }
    func search(info: LyricsSearchInfo) async -> LyricResult
}
