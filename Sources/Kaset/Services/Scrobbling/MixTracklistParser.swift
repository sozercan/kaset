import Foundation
import os

// MARK: - MixTracklistParser

/// Parses tracklists for long mix videos using a two-tier approach:
/// 1. YouTube chapters (structured API data)
/// 2. Description timestamps (regex over timestamped tracklist lines)
///
/// Both tiers read the same `YouTubeClient.getWatchNext(videoId:)` response,
/// which calls the regular YouTube `next` endpoint. The YTMusic `next`
/// endpoint does NOT return chapter or description data (confirmed via API
/// exploration, 2026-07-10).
@MainActor
final class MixTracklistParser {
    private enum CacheEntry {
        case tracklist(MixTracklist)
        case noTracklist
    }

    private let youTubeClient: any YouTubeClientProtocol
    private var cache: [String: CacheEntry] = [:]
    private let logger = DiagnosticsLogger.scrobbling

    init(youTubeClient: any YouTubeClientProtocol) {
        self.youTubeClient = youTubeClient
    }

    /// Parse a tracklist for a video. Returns nil if no tracklist is available.
    /// Results (including confirmed misses) are cached by video ID for the lifetime
    /// of this parser instance; transient fetch failures are not cached.
    func parseTracklist(videoId: String) async -> MixTracklist? {
        if let cached = self.cache[videoId] {
            return switch cached {
            case let .tracklist(tracklist):
                tracklist
            case .noTracklist:
                nil
            }
        }

        let watchNextData: WatchNextData
        do {
            watchNextData = try await self.youTubeClient.getWatchNext(videoId: videoId)
        } catch {
            self.logger.debug("Tracklist fetch failed for \(videoId): \(error.localizedDescription)")
            return nil
        }

        // Tier 1: YouTube chapters
        if let tracklist = self.tracklist(fromChapters: watchNextData.chapters, videoId: videoId) {
            self.cache[videoId] = .tracklist(tracklist)
            self.logger.info("Mix tracklist parsed from chapters: \(tracklist.entries.count) entries for \(videoId)")
            return tracklist
        }

        // Tier 2: description timestamps
        if let description = watchNextData.descriptionText,
           let tracklist = self.tracklist(fromDescription: description, videoId: videoId)
        {
            self.cache[videoId] = .tracklist(tracklist)
            self.logger.info("Mix tracklist parsed from description: \(tracklist.entries.count) entries for \(videoId)")
            return tracklist
        }

        self.cache[videoId] = .noTracklist
        return nil
    }

    // MARK: - Tier 1: Chapter Extraction

    private func tracklist(fromChapters chapters: [YouTubeChapter], videoId: String) -> MixTracklist? {
        // Convert chapters to MixTrackEntry, computing endTime from the next chapter's startTime
        let entries = chapters.enumerated().map { index, chapter -> MixTrackEntry in
            let endTime: TimeInterval? = if index + 1 < chapters.count {
                chapter.endTime.map { min($0, chapters[index + 1].startTime) }
                    ?? chapters[index + 1].startTime
            } else {
                // The final chapter has no following start time, but macro-marker data may
                // still carry its explicit bound. Keep it so short closing tracks can qualify
                // via the normal percentage threshold instead of requiring minSeconds.
                chapter.endTime
            }

            return MixTrackEntry(
                fromChapterTitle: chapter.title,
                startTime: chapter.startTime,
                endTime: endTime
            )
        }

        // A handful of chapters (intro/outro) isn't a real tracklist — MixTracklist.isMix decides.
        let tracklist = MixTracklist(videoId: videoId, entries: entries, source: .chapters)
        return tracklist.isMix ? tracklist : nil
    }

    // MARK: - Tier 2: Description Timestamps

    private func tracklist(fromDescription description: String, videoId: String) -> MixTracklist? {
        let entries = Self.descriptionEntries(from: description)
        let tracklist = MixTracklist(videoId: videoId, entries: entries, source: .description)
        return tracklist.isMix ? tracklist : nil
    }

    /// Extracts timestamped tracklist entries from a video description.
    ///
    /// Each line contributes at most one entry: its first plausible `H:MM:SS` or `M:SS`
    /// timestamp becomes the start time and the rest of the line (minus wrapping brackets,
    /// leading list numbering, and separator punctuation) becomes the artist/title label.
    /// Because descriptions often contain unrelated timestamps (premiere times, social
    /// links), only the longest run of consecutive lines with strictly increasing start
    /// times is kept — a real tracklist is monotonic, stray mentions are not.
    static func descriptionEntries(from description: String) -> [MixTrackEntry] {
        let timestampRegex = /(?:(\d{1,2}):)?(\d{1,2}):([0-5]\d)(?![\d:])/
        var candidates: [(startTime: TimeInterval, label: String)] = []

        for rawLine in description.split(whereSeparator: \.isNewline) {
            let line = String(rawLine)
            // Swift Regex has no lookbehind; reject matches glued to preceding digits/colons or
            // trailing letters ("3:45pm") manually, and skip past invalid H:MM:SS minutes so a
            // bogus first match doesn't drop a line that also carries the real timestamp.
            let matches = line.matches(of: timestampRegex)
            guard let matchIndex = matches.firstIndex(where: { candidate in
                if candidate.range.lowerBound > line.startIndex {
                    let before = line[line.index(before: candidate.range.lowerBound)]
                    guard !before.isNumber, before != ":" else { return false }
                }
                if candidate.range.upperBound < line.endIndex, line[candidate.range.upperBound].isLetter {
                    return false
                }
                if candidate.output.1 != nil, let minutes = Int(candidate.output.2), minutes >= 60 {
                    return false
                }
                return true
            }) else { continue }
            let match = matches[matchIndex]
            let hours = match.output.1.flatMap { Int($0) } ?? 0
            guard let minutes = Int(match.output.2), let seconds = Int(match.output.3) else { continue }

            // When an earlier candidate was rejected, the text before the accepted match still
            // contains that bogus fragment — keep only the suffix so it can't leak into the label.
            let label = Self.label(
                byRemoving: match.range,
                from: line,
                includePrefix: matchIndex == matches.startIndex
            )
            guard !label.isEmpty else { continue }
            candidates.append((TimeInterval(hours * 3600 + minutes * 60 + seconds), label))
        }

        guard !candidates.isEmpty else { return [] }

        var bestStart = 0
        var bestCount = 1
        var runStart = 0
        for index in 1 ..< candidates.count {
            if candidates[index].startTime <= candidates[index - 1].startTime {
                runStart = index
            }
            if index - runStart + 1 > bestCount {
                bestCount = index - runStart + 1
                bestStart = runStart
            }
        }

        let run = candidates[bestStart ..< bestStart + bestCount]
        return run.indices.map { index in
            let candidate = run[index]
            let parsed = MixTrackEntry.parseArtistTitle(from: candidate.label)
            return MixTrackEntry(
                startTime: candidate.startTime,
                endTime: index + 1 < run.endIndex ? run[index + 1].startTime : nil,
                title: parsed.title,
                artist: parsed.artist,
                source: .description
            )
        }
    }

    /// Removes a matched timestamp (plus any wrapping brackets), leading list numbering,
    /// and leftover separator punctuation from a description line.
    private static func label(
        byRemoving timestampRange: Range<String.Index>,
        from line: String,
        includePrefix: Bool
    ) -> String {
        var lower = timestampRange.lowerBound
        var upper = timestampRange.upperBound
        if lower > line.startIndex, upper < line.endIndex {
            let before = line[line.index(before: lower)]
            let after = line[upper]
            if (before == "[" && after == "]") || (before == "(" && after == ")") {
                lower = line.index(before: lower)
                upper = line.index(after: upper)
            }
        }

        return String(includePrefix ? line[..<lower] + line[upper...] : line[upper...])
            .replacingOccurrences(of: #"^\s*\d{1,3}[.)]\s+"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-–—−|:•>~ \t"))
    }

    // MARK: - Cache Management

    /// Clears the cache for a specific video, forcing a re-parse on next access.
    func invalidate(videoId: String) {
        self.cache.removeValue(forKey: videoId)
    }

    /// Clears all cached tracklists.
    func invalidateAll() {
        self.cache.removeAll()
    }
}
