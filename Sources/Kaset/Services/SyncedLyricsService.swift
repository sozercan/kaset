import Foundation
import os

// MARK: - MatchScore Model

/// Structured scoring for LRCLIB match candidates.
/// Combines multiple factors (duration, title, artist, lyrics quality) into a single confidence score.
private struct MatchScore {
    let candidate: [String: Any]
    let durationScore: Double  // 0...1, 1 = perfect match
    let titleScore: Double     // 0...1, 1 = exact match
    let artistScore: Double    // 0...1, 1 = exact match
    let lyricsQuality: Double  // 0...1, 1 = synced, 0 = plain only
    let isVersionMismatch: Bool // true if this is clearly a different version
    
    /// Weighted total confidence (0...1).
    /// Duration is most important, followed by title match, artist, lyrics type.
    var confidence: Double {
        guard !isVersionMismatch else { return 0 }
        return 0.40 * durationScore
            + 0.35 * titleScore
            + 0.15 * artistScore
            + 0.10 * lyricsQuality
    }
}

// MARK: - SyncedLyricsService

/// Fetches time-synced lyrics from the LRCLIB open-source API with intelligent matching.
///
/// LRCLIB (https://lrclib.net) provides synced lyrics in LRC format.
/// The service searches by artist name + track name and uses a multi-factor scoring system
/// to pick the most reliable match, handling common variations (radio edits, remasters, etc.).
///
/// This service is `nonisolated` so network requests don't block the
/// main actor, following the project convention from ADR-0008.
final class SyncedLyricsService: Sendable {
    static let shared = SyncedLyricsService()

    private let baseURL = "https://lrclib.net/api"
    private let logger = DiagnosticsLogger.api

    /// Thread-safe in-memory cache keyed by "artist|title|durationBucket".
    private let cache = SendableCache()

    private init() {}

    // MARK: - Public API

    /// Fetches synced lyrics for a given track.
    ///
    /// Tries the LRCLIB `/get` endpoint first (exact match), validates the result
    /// using multi-factor scoring, and falls back to `/search` with intelligent filtering if needed.
    ///
    /// - Parameters:
    ///   - title: The track title.
    ///   - artist: The artist name.
    ///   - duration: Duration in seconds – **strongly recommended** for accurate matching.
    /// - Returns: Parsed `SyncedLyrics`, or `.unavailable`.
    func fetchLyrics(
        title: String,
        artist: String,
        duration: TimeInterval? = nil
    ) async -> SyncedLyrics {
        let cleanArtist = Self.cleanArtistName(artist)
        let cleanTitle = Self.cleanTrackTitle(title)

        // Cache key includes duration bucket to avoid stale "unavailable" entries blocking future queries
        let durationBucket = duration.map { String(Int($0 / 10) * 10) } ?? "unknown"
        let cacheKey = "\(cleanArtist.lowercased())|\(title.lowercased())|\(durationBucket)"
        
        if let cached = self.cache.get(cacheKey) {
            return cached
        }

        func cacheAndReturn(_ result: SyncedLyrics) -> SyncedLyrics {
            self.cache.set(cacheKey, value: result)
            return result
        }

        // Collect the best plain-lyrics result as fallback in case no synced lyrics are found.
        var bestPlain: SyncedLyrics?

        // 1. Try /get with the ORIGINAL title first (e.g. "Indigo (feat. Avery Anna)")
        //    LRCLIB often stores feat./ft. as part of the official track name.
        if let result = await self.fetchExact(title: title, artist: cleanArtist, duration: duration) {
            if result.hasSyncedLines { return cacheAndReturn(result) }
            if bestPlain == nil { bestPlain = result }
        }

        // 2. Try /get with the cleaned title (e.g. "Indigo")
        if cleanTitle != title {
            if let result = await self.fetchExact(title: cleanTitle, artist: cleanArtist, duration: duration) {
                if result.hasSyncedLines { return cacheAndReturn(result) }
                if bestPlain == nil { bestPlain = result }
            }
        }

        // 3. Search with original title (best chance for synced results)
        if let result = await self.fetchSearch(title: title, artist: cleanArtist, duration: duration) {
            if result.hasSyncedLines { return cacheAndReturn(result) }
            if bestPlain == nil { bestPlain = result }
        }

        // 4. Search with cleaned title
        if cleanTitle != title {
            if let result = await self.fetchSearch(title: cleanTitle, artist: cleanArtist, duration: duration) {
                if result.hasSyncedLines { return cacheAndReturn(result) }
                if bestPlain == nil { bestPlain = result }
            }
        }

        // 5. Fallback: search with only the first artist word (handles "&" vs "und" vs "and")
        let firstArtistWord = Self.artistLeadingWords(cleanArtist).first ?? cleanArtist
        if firstArtistWord.lowercased() != cleanArtist.lowercased() {
            if let result = await self.fetchSearch(title: cleanTitle, artist: firstArtistWord, duration: duration) {
                if result.hasSyncedLines { return cacheAndReturn(result) }
                if bestPlain == nil { bestPlain = result }
            }
        }

        // 6. Return the best plain-lyrics result if we found one (better than nothing)
        if let plain = bestPlain {
            return cacheAndReturn(plain)
        }

        self.logger.info("SyncedLyricsService: no lyrics for '\(title)' by '\(cleanArtist)'")
        let unavailable = SyncedLyrics.unavailable
        self.cache.set(cacheKey, value: unavailable)
        return unavailable
    }

    // MARK: - Private Endpoints

    /// LRCLIB `/api/get` – exact match by artist + track + duration.
    /// Validates using intelligent duration tolerance (not fixed 5s).
    private func fetchExact(
        title: String,
        artist: String,
        duration: TimeInterval?
    ) async -> SyncedLyrics? {
        var components = URLComponents(string: "\(self.baseURL)/get")!
        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "track_name", value: title),
            URLQueryItem(name: "artist_name", value: artist),
        ]
        if let dur = duration, dur > 0 {
            queryItems.append(URLQueryItem(name: "duration", value: String(Int(dur))))
        }
        components.queryItems = queryItems

        guard let url = components.url else { return nil }

        do {
            let (data, response) = try await URLSession.shared.data(from: url)

            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return nil }

            // Validate duration with adaptive tolerance
            if let expectedDur = duration, expectedDur > 0,
               let resultDur = json["duration"] as? Double, resultDur > 0
            {
                if !Self.durationMatches(expected: expectedDur, actual: resultDur) {
                    self.logger.debug("SyncedLyricsService: /get duration mismatch (\(resultDur)s vs \(expectedDur)s) – skipping")
                    return nil
                }
            }

            return Self.parseLyricsObject(json)
        } catch {
            self.logger.debug("SyncedLyricsService: /get failed – \(error.localizedDescription)")
            return nil
        }
    }

    /// LRCLIB `/api/search` – keyword search with intelligent filtering.
    private func fetchSearch(
        title: String,
        artist: String,
        duration: TimeInterval?
    ) async -> SyncedLyrics? {
        var components = URLComponents(string: "\(self.baseURL)/search")!
        // Search with both artist and title for best results
        components.queryItems = [
            URLQueryItem(name: "track_name", value: title),
            URLQueryItem(name: "artist_name", value: artist),
        ]

        guard let url = components.url else { return nil }

        do {
            let (data, response) = try await URLSession.shared.data(from: url)

            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200,
                  let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
                  !array.isEmpty
            else { return nil }

            return Self.pickBestResult(
                from: array,
                expectedTitle: title,
                expectedArtist: artist,
                expectedDuration: duration
            )
        } catch {
            self.logger.debug("SyncedLyricsService: /search failed – \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Result Selection

    /// Picks the best matching result from a search array using multi-factor scoring.
    ///
    /// Scoring pipeline:
    /// 1. Score each candidate on duration, title, artist, lyrics quality
    /// 2. Reject obvious version mismatches (e.g. live, remix, instrumental versions)
    /// 3. Filter out candidates with confidence < 0.5
    /// 4. Among remaining, pick highest confidence; tie-break by duration match
    private static func pickBestResult(
        from array: [[String: Any]],
        expectedTitle: String,
        expectedArtist: String,
        expectedDuration: TimeInterval?
    ) -> SyncedLyrics? {
        // Score all candidates
        var scores: [MatchScore] = []
        for entry in array {
            if let score = Self.scoreCandidate(entry, expectedTitle: expectedTitle, expectedArtist: expectedArtist, expectedDuration: expectedDuration) {
                scores.append(score)
            }
        }

        // Filter: must have synced lyrics or plain lyrics
        let withLyrics = scores.filter {
            (($0.candidate["syncedLyrics"] as? String) ?? "").isEmpty == false
                || (($0.candidate["plainLyrics"] as? String) ?? "").isEmpty == false
        }

        guard !withLyrics.isEmpty else { return nil }

        // Filter: confidence must be >= 0.5 (moderate match)
        let confident = withLyrics.filter { $0.confidence >= 0.5 }
        let candidates = confident.isEmpty ? withLyrics : confident

        // Sort: by confidence (desc), then by duration match (asc)
        let sorted = candidates.sorted { a, b in
            if abs(a.confidence - b.confidence) > 0.01 {
                return a.confidence > b.confidence
            }
            // Tie-break: closer duration match wins
            let aDur = (a.candidate["duration"] as? Double) ?? 0
            let bDur = (b.candidate["duration"] as? Double) ?? 0
            if let exp = expectedDuration, exp > 0 {
                return abs(aDur - exp) < abs(bDur - exp)
            }
            return false
        }

        if let best = sorted.first {
            return Self.parseLyricsObject(best.candidate)
        }

        return nil
    }

    /// Scores a single LRCLIB result candidate.
    fileprivate static func scoreCandidate(
        _ entry: [String: Any],
        expectedTitle: String,
        expectedArtist: String,
        expectedDuration: TimeInterval?
    ) -> MatchScore? {
        let resultTitle = (entry["trackName"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        let resultArtist = (entry["artistName"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        let resultDur = entry["duration"] as? Double ?? 0
        let hasSynced = (entry["syncedLyrics"] as? String ?? "").isEmpty == false
        let hasPlain = (entry["plainLyrics"] as? String ?? "").isEmpty == false

        guard !resultTitle.isEmpty, !resultArtist.isEmpty else { return nil }
        guard hasSynced || hasPlain else { return nil }

        // Check for version mismatch (live, instrumental, remix as main content)
        let isVersionMismatch = Self.isVersionMismatch(resultTitle)

        // Duration score
        var durationScore = 0.0
        if let expected = expectedDuration, expected > 0 {
            durationScore = Self.durationSimilarity(expected: expected, actual: resultDur)
        } else {
            // No duration provided – give neutral score
            durationScore = 0.5
        }

        // Title score
        let titleScore = Self.titleSimilarity(expected: expectedTitle, actual: resultTitle)

        // Artist score
        let artistScore = Self.artistSimilarity(expected: expectedArtist, actual: resultArtist)

        // Lyrics quality score
        let lyricsQuality = hasSynced ? 1.0 : 0.3

        return MatchScore(
            candidate: entry,
            durationScore: durationScore,
            titleScore: titleScore,
            artistScore: artistScore,
            lyricsQuality: lyricsQuality,
            isVersionMismatch: isVersionMismatch
        )
    }

    /// Checks if a title indicates a different version (live, remix, instrumental, etc).
    fileprivate static func isVersionMismatch(_ title: String) -> Bool {
        let lower = title.lowercased()
        let versionPatterns = [
            "\\b(live)\\b",
            "\\b(remix)\\b",
            "\\b(instrumental)\\b",
            "\\b(karaoke)\\b",
            "\\b(acapella)\\b",
            "\\b(cover)\\b",
        ]
        
        for pattern in versionPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
               regex.firstMatch(in: lower, range: NSRange(lower.startIndex..., in: lower)) != nil {
                return true
            }
        }
        
        return false
    }

    /// Computes duration similarity (0...1, 1 = exact match).
    /// Adaptive tolerance: strict near 200–300s, more lenient at extremes.
    fileprivate static func durationSimilarity(expected: TimeInterval, actual: Double) -> Double {
        let delta = abs(actual - expected)
        
        // Define tolerance tiers based on typical song duration
        let tolerance: TimeInterval
        if expected < 100 {
            tolerance = 3  // Very short tracks: strict
        } else if expected < 250 {
            tolerance = 5  // Standard pop/rock: moderate (±5s for radio edits)
        } else {
            tolerance = 10  // Longer tracks, symphonic, etc: lenient (±10s for remaster variations)
        }

        if delta <= tolerance {
            return 1.0 - (delta / tolerance) * 0.3  // 0.7...1.0 range
        } else if delta <= tolerance * 2 {
            return 0.3 - ((delta - tolerance) / tolerance) * 0.2  // 0.1...0.3 range
        } else {
            return 0  // Hard reject for 2x+ tolerance difference
        }
    }

    /// Computes title similarity (0...1, 1 = exact match).
    fileprivate static func titleSimilarity(expected: String, actual: String) -> Double {
        let expLower = expected.lowercased()
        let actLower = actual.lowercased()

        // Exact match
        if expLower == actLower { return 1.0 }

        // One contains the other (handles minor punctuation)
        if expLower.contains(actLower) { return 0.95 }
        if actLower.contains(expLower) { return 0.95 }

        // Token-based similarity
        let expTokens = Set(Self.titleTokens(expected))
        let actTokens = Set(Self.titleTokens(actual))

        guard !expTokens.isEmpty, !actTokens.isEmpty else { return 0 }

        let intersection = expTokens.intersection(actTokens).count
        let union = expTokens.union(actTokens).count
        let jaccardSimilarity = Double(intersection) / Double(union)

        // Require at least 60% token overlap
        return jaccardSimilarity >= 0.6 ? jaccardSimilarity : 0
    }

    /// Extracts significant tokens from a title (length >= 2, excluding common stopwords).
    fileprivate static func titleTokens(_ title: String) -> [String] {
        let lower = title.lowercased()
        let stopwords = Set(["the", "a", "an", "and", "or", "but", "of", "to", "in"])
        
        return lower
            .components(separatedBy: .alphanumerics.inverted)
            .map { $0.lowercased() }
            .filter { $0.count >= 2 && !stopwords.contains($0) }
    }

    /// Computes artist similarity (0...1, 1 = exact match).
    fileprivate static func artistSimilarity(expected: String, actual: String) -> Double {
        let expLower = expected.lowercased()
        let actLower = actual.lowercased()

        // Exact match
        if expLower == actLower { return 1.0 }

        // One contains the other
        if expLower.contains(actLower) { return 0.95 }
        if actLower.contains(expLower) { return 0.95 }

        // Leading words must match (first two words)
        let expWords = Self.artistLeadingWords(expected)
        let actWords = Self.artistLeadingWords(actual)

        guard !expWords.isEmpty, !actWords.isEmpty else { return 0 }

        // First word must match
        if expWords[0] != actWords[0] { return 0 }

        // One word: 0.9, both words match: 1.0
        if expWords.count == 1 || actWords.count == 1 { return 0.9 }
        if expWords[1] == actWords[1] { return 1.0 }

        return 0.8  // First word matched, second differs slightly
    }

    /// Checks if a duration is within acceptable tolerance of expected.
    /// Used in /get endpoint validation.
    private static func durationMatches(expected: TimeInterval, actual: Double) -> Bool {
        let score = durationSimilarity(expected: expected, actual: actual)
        return score > 0  // Any match is acceptable at /get level
    }

    /// Extracts the first two significant words from an artist name for loose matching.
    /// Normalises "&" / "und" / "and" and strips punctuation.
    fileprivate static func artistLeadingWords(_ name: String) -> [String] {
        let normalized = name
            .lowercased()
            .replacingOccurrences(of: "&", with: " ")
            .replacingOccurrences(of: " und ", with: " ")
            .replacingOccurrences(of: " and ", with: " ")
        return normalized
            .components(separatedBy: .alphanumerics.inverted)
            .filter { !$0.isEmpty && $0.count >= 2 }
    }

    // MARK: - Parsing

    /// Converts a single LRCLIB JSON object to `SyncedLyrics`.
    private static func parseLyricsObject(_ json: [String: Any]) -> SyncedLyrics? {
        let syncedLRC = json["syncedLyrics"] as? String
        let plainText = json["plainLyrics"] as? String
        let trackName = json["trackName"] as? String
        let artistName = json["artistName"] as? String

        let lines: [SyncedLyricsLine]
        if let lrc = syncedLRC, !lrc.isEmpty {
            lines = SyncedLyrics.parseLRC(lrc)
        } else {
            lines = []
        }

        guard !lines.isEmpty || (plainText != nil && !plainText!.isEmpty) else {
            return nil
        }

        return SyncedLyrics(
            lines: lines,
            plainText: plainText,
            source: "LRCLIB",
            trackName: trackName,
            artistName: artistName
        )
    }

    // MARK: - String Cleaning

    /// Strips feature credits, extra info in parens/brackets, and normalises whitespace.
    private static func cleanArtistName(_ raw: String) -> String {
        var cleaned = raw

        // Remove "feat.", "ft.", "featuring" suffixes first
        let featPatterns = [" feat.", " feat ", " ft.", " ft ", " featuring ", " x "]
        for pattern in featPatterns {
            if let range = cleaned.range(of: pattern, options: .caseInsensitive) {
                cleaned = String(cleaned[..<range.lowerBound])
            }
        }

        // Take only the first artist if comma separated
        if let commaIndex = cleaned.firstIndex(of: ",") {
            cleaned = String(cleaned[..<commaIndex])
        }

        // Don't strip "&" / "und" – keep the full name so artistsMatch() can handle it

        return cleaned.trimmingCharacters(in: .whitespaces)
    }

    /// Strips metadata suffixes in parentheses/brackets that cause LRCLIB misses.
    /// Does NOT remove (feat. ...) or (ft. ...) – those are part of official titles in LRCLIB.
    private static func cleanTrackTitle(_ raw: String) -> String {
        var cleaned = raw

        // Only remove parenthesised/bracketed metadata that is NOT feat./ft. credits
        let patterns = [
            #"\s*\((?:Official|Music|Lyric|Audio|Video|Visualizer|Remix|Live|Remaster).*?\)"#,
            #"\s*\[(?:Official|Music|Lyric|Audio|Video|Visualizer|Remix|Live|Remaster).*?\]"#,
        ]
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                cleaned = regex.stringByReplacingMatches(
                    in: cleaned,
                    range: NSRange(cleaned.startIndex..., in: cleaned),
                    withTemplate: ""
                )
            }
        }
        return cleaned.trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Sendable Cache

    /// Thread-safe cache backed by a locked dictionary.
    private final class SendableCache: Sendable {
        private let storage = OSAllocatedUnfairLock(initialState: [String: SyncedLyrics]())
        private let limit = 100

        func get(_ key: String) -> SyncedLyrics? {
            self.storage.withLock { $0[key] }
        }

        func set(_ key: String, value: SyncedLyrics) {
            self.storage.withLock { dict in
                if dict.count >= self.limit {
                    dict.removeValue(forKey: dict.keys.first ?? "")
                }
                dict[key] = value
            }
        }
    }
}
