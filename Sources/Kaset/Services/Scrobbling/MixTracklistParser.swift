import Foundation
import os

// MARK: - MixTracklistParser

/// Parses tracklists for long mix videos using a two-tier approach:
/// 1. YouTube chapters (structured API data, no LLM needed)
/// 2. Description timestamps (regex first, then Foundation Models fallback)
///
/// Chapters are fetched via `YouTubeClient.getWatchNext(videoId:)`, which calls
/// the regular YouTube `next` endpoint. The YTMusic `next` endpoint does NOT
/// return chapter data (confirmed via API exploration, 2026-07-10).
@MainActor
final class MixTracklistParser {
    private let youTubeClient: any YouTubeClientProtocol
    private var cache: [String: MixTracklist] = [:]
    private let logger = DiagnosticsLogger.scrobbling

    init(youTubeClient: any YouTubeClientProtocol) {
        self.youTubeClient = youTubeClient
    }

    /// Parse a tracklist for a video. Returns nil if no tracklist is available.
    /// Results are cached by video ID for the lifetime of this parser instance.
    func parseTracklist(videoId: String) async -> MixTracklist? {
        if let cached = self.cache[videoId] {
            return cached
        }

        // Tier 1: YouTube chapters via the regular YouTube next endpoint
        if let tracklist = await self.parseFromChapters(videoId: videoId) {
            self.cache[videoId] = tracklist
            self.logger.info("Mix tracklist parsed from chapters: \(tracklist.entries.count) entries for \(videoId)")
            return tracklist
        }

        // Tier 2 (not yet implemented): description parsing. Would extract description text from
        // the next response's engagementPanels, regex-parse timestamp patterns, then fall back to
        // Foundation Models. Requires a WatchNextParser extension for description extraction.

        return nil
    }

    // MARK: - Tier 1: Chapter Extraction

    /// Extract tracklist from YouTube chapters via `YouTubeClient.getWatchNext`.
    private func parseFromChapters(videoId: String) async -> MixTracklist? {
        do {
            let watchNextData = try await self.youTubeClient.getWatchNext(videoId: videoId)
            let chapters = watchNextData.chapters

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
            guard tracklist.isMix else { return nil }
            return tracklist
        } catch {
            self.logger.debug("Chapter extraction failed for \(videoId): \(error.localizedDescription)")
            return nil
        }
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
