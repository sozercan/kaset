import Foundation

// MARK: - SyncedLyricsLine

/// A single time-stamped lyrics line.
struct SyncedLyricsLine: Identifiable, Sendable, Equatable {
    let id = UUID()

    /// Timestamp in seconds from the start of the track.
    let time: TimeInterval

    /// The lyrics text for this line.
    let text: String

    /// Whether this is an empty / instrumental break line.
    var isInterlude: Bool {
        self.text.trimmingCharacters(in: .whitespaces).isEmpty
    }
}

// MARK: - SyncedLyrics

/// Parsed synced (time-stamped) lyrics for a song.
struct SyncedLyrics: Sendable, Equatable {
    /// All time-stamped lines sorted by time.
    let lines: [SyncedLyricsLine]

    /// Plain text fallback (non-synced).
    let plainText: String?

    /// Source attribution.
    let source: String?

    /// Track metadata from the API.
    let trackName: String?
    let artistName: String?

    /// Whether synced lyrics are available.
    var hasSyncedLines: Bool {
        !self.lines.isEmpty
    }

    /// Returns the index of the line that should be highlighted at the given playback time.
    func currentLineIndex(at time: TimeInterval) -> Int? {
        guard !self.lines.isEmpty else { return nil }

        // Binary search for the last line whose time <= current playback time
        var low = 0
        var high = self.lines.count - 1
        var result: Int?

        while low <= high {
            let mid = (low + high) / 2
            if self.lines[mid].time <= time {
                result = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }

        return result
    }

    /// An empty instance when no synced lyrics are found.
    static let unavailable = SyncedLyrics(
        lines: [],
        plainText: nil,
        source: nil,
        trackName: nil,
        artistName: nil
    )

    // MARK: - LRC Parsing

    /// Parses an LRC-format string into `SyncedLyricsLine` items.
    ///
    /// LRC format: `[mm:ss.xx]Lyrics text`
    /// Example: `[00:18.75]We're no strangers to love`
    static func parseLRC(_ lrcString: String) -> [SyncedLyricsLine] {
        let pattern = #"\[(\d{2}):(\d{2})\.(\d{2,3})\](.*)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }

        var lines: [SyncedLyricsLine] = []

        for rawLine in lrcString.components(separatedBy: "\n") {
            let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            let range = NSRange(trimmed.startIndex..., in: trimmed)
            guard let match = regex.firstMatch(in: trimmed, range: range),
                  match.numberOfRanges >= 5
            else { continue }

            guard let minRange = Range(match.range(at: 1), in: trimmed),
                  let secRange = Range(match.range(at: 2), in: trimmed),
                  let msRange = Range(match.range(at: 3), in: trimmed),
                  let textRange = Range(match.range(at: 4), in: trimmed)
            else { continue }

            guard let minutes = Double(trimmed[minRange]),
                  let seconds = Double(trimmed[secRange]),
                  let millisPart = Double(trimmed[msRange])
            else { continue }

            // Handle both 2-digit (centiseconds) and 3-digit (milliseconds) fractions
            let msFraction: Double = trimmed[msRange].count == 2
                ? millisPart / 100.0
                : millisPart / 1000.0

            let time = minutes * 60.0 + seconds + msFraction
            let text = String(trimmed[textRange])

            lines.append(SyncedLyricsLine(time: time, text: text))
        }

        return lines.sorted { $0.time < $1.time }
    }
}
