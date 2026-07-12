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

        if let tracklist = self.parseFromChapters(watchNextData, videoId: videoId) {
            self.cache[videoId] = .tracklist(tracklist)
            self.logger.info("Mix tracklist parsed from chapters: \(tracklist.entries.count) entries for \(videoId)")
            return tracklist
        }

        if let tracklist = self.parseFromDescription(
            watchNextData.descriptionText,
            videoTitle: watchNextData.videoTitle,
            videoId: videoId
        ) {
            self.cache[videoId] = .tracklist(tracklist)
            self.logger.info("Mix tracklist parsed from description: \(tracklist.entries.count) entries for \(videoId)")
            return tracklist
        }

        self.cache[videoId] = .noTracklist
        return nil
    }

    // MARK: - Tier 1: Chapter Extraction

    private func parseFromChapters(
        _ watchNextData: WatchNextData,
        videoId: String
    ) -> MixTracklist? {
        let chapters = watchNextData.chapters
        let entries = chapters.enumerated().map { index, chapter -> MixTrackEntry in
            let endTime: TimeInterval? = if index + 1 < chapters.count {
                chapter.endTime.map { min($0, chapters[index + 1].startTime) }
                    ?? chapters[index + 1].startTime
            } else {
                chapter.endTime
            }

            return MixTrackEntry(
                fromChapterTitle: chapter.title,
                startTime: chapter.startTime,
                endTime: endTime
            )
        }

        let tracklist = MixTracklist(videoId: videoId, entries: entries, source: .chapters)
        return tracklist.isMix ? tracklist : nil
    }

    // MARK: - Tier 2: Description Timestamp Extraction

    private struct DescriptionLine {
        let lineIndex: Int
        let startTime: TimeInterval
        let title: String
        let artist: String?
        let hasInlineHeading: Bool
    }

    private struct DescriptionBlock {
        let startLineIndex: Int
        let lines: [DescriptionLine]
        let hasHeading: Bool
    }

    private func parseFromDescription(
        _ description: String?,
        videoTitle: String?,
        videoId: String
    ) -> MixTracklist? {
        guard let description,
              let regex = try? NSRegularExpression(
                  pattern: #"(?:(\d+):)?(\d+):([0-5]\d)(?![\d:])"#
              ),
              let block = self.bestDescriptionTracklistBlock(
                  in: description,
                  videoTitle: videoTitle,
                  regex: regex
              )
        else { return nil }
        let lines = block.lines

        let entries = lines.enumerated().map { index, line in
            // The final entry intentionally remains unbounded here. MixTracklist.effectiveDuration
            // resolves it against the current video's duration during live/provisional playback.
            let endTime = lines.indices.contains(index + 1) ? lines[index + 1].startTime : nil
            return MixTrackEntry(
                startTime: line.startTime,
                endTime: endTime,
                title: line.title,
                artist: line.artist,
                source: .description
            )
        }
        let tracklist = MixTracklist(
            videoId: videoId,
            entries: entries,
            source: .description,
            hasExplicitTracklistSignal: block.hasHeading
        )
        return tracklist.isMix ? tracklist : nil
    }

    private func bestDescriptionTracklistBlock(
        in description: String,
        videoTitle: String?,
        regex: NSRegularExpression
    ) -> DescriptionBlock? {
        let rawLines = description.components(separatedBy: .newlines)
        let blocks = self.descriptionBlocks(in: rawLines, regex: regex).flatMap { block in
            let runs = self.increasingRuns(in: block.lines)
            let headedRunIndex = block.hasHeading
                ? runs.firstIndex(where: { $0.count >= MixTracklist.minEntryCount })
                : nil
            return runs.enumerated().compactMap { runIndex, lines -> DescriptionBlock? in
                guard lines.count >= MixTracklist.minEntryCount else { return nil }
                let hasHeading = runIndex == headedRunIndex
                let artistCount = lines.count(where: { $0.artist != nil })
                let agendaLineCount = lines.count(where: self.isLikelyAgendaLine)
                let genericArtistCount = lines.count(where: { self.isGenericPresenterArtist($0.artist) })
                let hasUnambiguousArtistStructure = artistCount == lines.count
                    && genericArtistCount == 0
                let hasAmbiguousAgendaSignal = !hasUnambiguousArtistStructure
                    && agendaLineCount * 2 >= lines.count
                let hasPresentationAgendaSignal = self.hasPresentationSignal(in: videoTitle)
                    && agendaLineCount * 4 >= lines.count * 3
                let hasStrongHeadinglessSignal = artistCount * 2 >= lines.count
                    && !hasAmbiguousAgendaSignal
                    && !hasPresentationAgendaSignal
                guard hasHeading || hasStrongHeadinglessSignal else { return nil }
                return DescriptionBlock(
                    startLineIndex: lines[0].lineIndex,
                    lines: lines,
                    hasHeading: hasHeading
                )
            }
        }

        return blocks.max(by: { lhs, rhs in
            if lhs.hasHeading != rhs.hasHeading {
                return !lhs.hasHeading && rhs.hasHeading
            }
            if lhs.lines.count != rhs.lines.count {
                return lhs.lines.count < rhs.lines.count
            }
            let lhsArtistCount = lhs.lines.count(where: { $0.artist != nil })
            let rhsArtistCount = rhs.lines.count(where: { $0.artist != nil })
            if lhsArtistCount != rhsArtistCount {
                return lhsArtistCount < rhsArtistCount
            }
            return lhs.startLineIndex < rhs.startLineIndex
        })
    }

    private func descriptionBlocks(
        in rawLines: [String],
        regex: NSRegularExpression
    ) -> [DescriptionBlock] {
        var blocks: [DescriptionBlock] = []
        var currentLines: [DescriptionLine] = []
        var currentStartIndex = 0
        var currentHasHeading = false

        for (index, rawLine) in rawLines.enumerated() {
            if let line = self.descriptionLine(from: rawLine, lineIndex: index, regex: regex) {
                if line.hasInlineHeading, !currentLines.isEmpty {
                    blocks.append(DescriptionBlock(
                        startLineIndex: currentStartIndex,
                        lines: currentLines,
                        hasHeading: currentHasHeading
                    ))
                    currentLines.removeAll(keepingCapacity: true)
                }
                if currentLines.isEmpty {
                    currentStartIndex = index
                    currentHasHeading = line.hasInlineHeading
                        || self.hasTracklistHeading(before: index, in: rawLines)
                }
                currentLines.append(line)
            } else if !currentLines.isEmpty,
                      rawLine.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                continue
            } else if !currentLines.isEmpty {
                blocks.append(DescriptionBlock(
                    startLineIndex: currentStartIndex,
                    lines: currentLines,
                    hasHeading: currentHasHeading
                ))
                currentLines.removeAll(keepingCapacity: true)
                currentHasHeading = false
            }
        }
        if !currentLines.isEmpty {
            blocks.append(DescriptionBlock(
                startLineIndex: currentStartIndex,
                lines: currentLines,
                hasHeading: currentHasHeading
            ))
        }
        return blocks
    }

    private func increasingRuns(in lines: [DescriptionLine]) -> [[DescriptionLine]] {
        guard let first = lines.first else { return [] }
        var runs: [[DescriptionLine]] = []
        var current = [first]

        for line in lines.dropFirst() {
            if let previous = current.last, line.startTime <= previous.startTime {
                runs.append(current)
                current = [line]
            } else {
                current.append(line)
            }
        }
        runs.append(current)
        return runs
    }

    private func descriptionLine(
        from rawLine: String,
        lineIndex: Int,
        regex: NSRegularExpression
    ) -> DescriptionLine? {
        let searchRange = NSRange(rawLine.startIndex..., in: rawLine)
        let matches = regex.matches(in: rawLine, range: searchRange)
        guard let matchIndex = matches.firstIndex(where: { match in
            guard let timestampRange = Range(match.range, in: rawLine) else { return false }
            if timestampRange.lowerBound > rawLine.startIndex {
                let before = rawLine[rawLine.index(before: timestampRange.lowerBound)]
                guard !before.isNumber, before != ":" else { return false }
            }
            if timestampRange.upperBound < rawLine.endIndex,
               rawLine[timestampRange.upperBound].isLetter
            {
                return false
            }
            return self.timeInterval(from: String(rawLine[timestampRange])) != nil
        }) else { return nil }

        let match = matches[matchIndex]
        guard let timestampRange = Range(match.range, in: rawLine),
              let startTime = self.timeInterval(from: String(rawLine[timestampRange]))
        else { return nil }
        let prefix = String(rawLine[..<timestampRange.lowerBound])
        let hasInlineHeading = matchIndex == matches.startIndex
            && self.isTracklistHeading(prefix)
        let label = self.label(
            byRemoving: timestampRange,
            from: rawLine,
            includePrefix: matchIndex == matches.startIndex && !hasInlineHeading
        )
        guard !label.isEmpty else { return nil }
        let parsed = MixTrackEntry.parseArtistTitle(from: label)
        return DescriptionLine(
            lineIndex: lineIndex,
            startTime: startTime,
            title: parsed.title,
            artist: parsed.artist,
            hasInlineHeading: hasInlineHeading
        )
    }

    /// Removes a matched timestamp (plus any wrapping brackets), leading list numbering,
    /// and leftover separator punctuation from a description line.
    private func label(
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

    private func hasTracklistHeading(before startIndex: Int, in rawLines: [String]) -> Bool {
        var index = startIndex
        while index > rawLines.startIndex {
            index -= 1
            let line = rawLines[index]
            if line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                continue
            }
            return self.isTracklistHeading(line)
        }
        return false
    }

    private func isTracklistHeading(_ line: String) -> Bool {
        let words = line.lowercased()
            .components(separatedBy: CharacterSet.letters.inverted)
            .filter { !$0.isEmpty }
        return words == ["tracklist"]
            || words == ["track", "list"]
            || words == ["setlist"]
            || words == ["set", "list"]
    }

    private func hasPresentationSignal(in title: String?) -> Bool {
        guard let title else { return false }
        let words = Set(
            title.lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { !$0.isEmpty }
        )
        let presentationWords: Set = [
            "agenda", "conference", "course", "discussion", "interview", "keynote", "lecture",
            "lesson", "panel", "podcast", "seminar", "summit", "talk", "tutorial", "webinar",
            "workshop",
        ]
        return !words.isDisjoint(with: presentationWords)
    }

    private func isGenericPresenterArtist(_ artist: String?) -> Bool {
        guard let normalizedArtist = artist?
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        else { return false }
        let genericArtists: Set = [
            "guest", "host", "moderator", "panel", "presenter", "speaker", "sponsor",
        ]
        return genericArtists.contains(normalizedArtist)
    }

    private func isLikelyAgendaLine(_ line: DescriptionLine) -> Bool {
        if self.isGenericPresenterArtist(line.artist) {
            return true
        }

        let titleWords = Set(line.title.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty })
        let genericTitleWords: Set = [
            "agenda", "chapter", "closing", "context", "demo", "discussion", "introduction",
            "keynote", "opening", "panel", "questions", "remarks", "session", "sponsor", "topic",
            "welcome",
        ]
        return !titleWords.isDisjoint(with: genericTitleWords)
    }

    private func timeInterval(from timestamp: String) -> TimeInterval? {
        let rawComponents = timestamp.split(separator: ":", omittingEmptySubsequences: false)
        guard rawComponents.count == 2 || rawComponents.count == 3 else { return nil }
        var components: [Int64] = []
        for rawComponent in rawComponents {
            guard let component = Int64(rawComponent) else { return nil }
            components.append(component)
        }
        guard components.count == 2 || components.count == 3,
              components.last.map({ $0 < 60 }) == true
        else { return nil }

        if components.count == 3 {
            guard components[1] < 60 else { return nil }
            guard let hours = self.checkedProduct(components[0], 3600),
                  let minutes = self.checkedProduct(components[1], 60),
                  let subtotal = self.checkedSum(hours, minutes),
                  let total = self.checkedSum(subtotal, components[2])
            else { return nil }
            return TimeInterval(total)
        }
        guard let minutes = self.checkedProduct(components[0], 60),
              let total = self.checkedSum(minutes, components[1])
        else { return nil }
        return TimeInterval(total)
    }

    private func checkedProduct(_ lhs: Int64, _ rhs: Int64) -> Int64? {
        let result = lhs.multipliedReportingOverflow(by: rhs)
        return result.overflow ? nil : result.partialValue
    }

    private func checkedSum(_ lhs: Int64, _ rhs: Int64) -> Int64? {
        let result = lhs.addingReportingOverflow(rhs)
        return result.overflow ? nil : result.partialValue
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
