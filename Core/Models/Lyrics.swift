import Foundation

// MARK: - Lyrics

/// Represents lyrics for a song from YouTube Music.
struct Lyrics: Sendable, Equatable {
    /// The lyrics text, with line breaks preserved.
    let text: String

    /// Source attribution (e.g., "Source: LyricFind").
    let source: String?

    /// Whether the song has lyrics available.
    var isAvailable: Bool { !self.text.isEmpty }

    /// Lyrics split into individual lines for display.
    var lines: [String] {
        self.text.components(separatedBy: "\n")
    }

    /// Creates an empty lyrics instance for songs without lyrics.
    static let unavailable = Lyrics(text: "", source: nil)
}

// MARK: - LyricsBrowseInfo

/// Represents the lyrics browse ID extracted from the next endpoint.
struct LyricsBrowseInfo: Sendable {
    /// The browse ID to fetch lyrics (format: "MPLYt_xxx").
    let browseId: String
}
