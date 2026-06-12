import CryptoKit
import Foundation

/// Pure helpers shared by Kaset's InnerTube clients (YouTube Music and YouTube).
///
/// Kept deliberately small: `YTMusicClient` is not refactored onto this to
/// avoid touching the proven music path; `YouTubeClient` composes these from
/// day one.
enum InnerTubeSupport {
    /// Computes the `SAPISIDHASH` authorization value for an InnerTube request.
    ///
    /// The hash input embeds the request origin, so the value computed for
    /// `https://music.youtube.com` is NOT valid for `https://www.youtube.com`
    /// and vice versa — each client must pass its own origin.
    static func sapisidHash(sapisid: String, origin: String, timestamp: Int) -> String {
        let input = "\(timestamp) \(sapisid) \(origin)"
        let hash = Insecure.SHA1.hash(data: Data(input.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return "\(timestamp)_\(hash)"
    }
}
