import Foundation

/// Lyrics provider that fetches timed (synced) lyrics from YouTube Music's API.
/// Uses the "next" endpoint to extract `timedLyricsModel` data with per-line timestamps.
final class YTMusicSyncedProvider: LyricsProvider {
    let name = "YTMusic"

    private let client: any YTMusicClientProtocol

    init(client: any YTMusicClientProtocol) {
        self.client = client
    }

    func search(info: LyricsSearchInfo) async -> LyricResult {
        do {
            return try await self.client.getTimedLyrics(videoId: info.videoId)
        } catch {
            return .unavailable
        }
    }
}
