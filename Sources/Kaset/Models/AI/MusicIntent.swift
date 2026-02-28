import Foundation
import FoundationModels

// MARK: - MusicIntent

/// Represents a user's intent when using natural language music commands.
/// The model generates this from free-form text like "play some jazz" or "skip this song".
@available(macOS 26.0, *)
@Generable
struct MusicIntent: Sendable {
    /// The type of action the user wants to perform.
    @Guide(description: "The action to perform: play, queue, shuffle, like, dislike, skip, previous, pause, resume, search")
    let action: MusicAction

    /// Search query or song/artist name (for play, queue, search actions).
    @Guide(description: "The search query, song title, or artist name. Empty for actions like skip, pause, resume.")
    let query: String

    /// Scope for shuffle action (e.g., "library", "playlist", "artist").
    @Guide(description: "The scope for shuffle: all, library, likes, or empty for single song actions.")
    let shuffleScope: String

    // MARK: - Parsed Query Components (for rich search queries)

    /// Artist name if explicitly mentioned.
    @Guide(description: "Artist name if mentioned (e.g., 'Rolling Stones'). Empty if not specified.")
    let artist: String

    /// Genre or music style.
    @Guide(description: "Genre if mentioned (rock, jazz, hip-hop, classical, electronic, pop, country, r&b, indie, metal, folk, latin, k-pop). Empty if not specified.")
    let genre: String

    /// Mood or energy level.
    @Guide(description: "Mood if mentioned (upbeat, chill, sad, happy, energetic, relaxing, melancholic, romantic, aggressive, peaceful, groovy, dark). Empty if not specified.")
    let mood: String

    /// Time period or decade.
    @Guide(description: "Era if mentioned. Use decade format: '1960s', '1970s', '1980s', '1990s', '2000s', '2010s', '2020s'. Or 'classic' for oldies. Empty if not specified.")
    let era: String

    /// Music type/version.
    @Guide(description: "Version type if mentioned (acoustic, live, remix, instrumental, cover, unplugged). Empty if not specified.")
    let version: String

    /// Activity context.
    @Guide(description: "Activity if mentioned (workout, study, sleep, party, driving, cooking, focus, running, yoga). Empty if not specified.")
    let activity: String

    // MARK: - Query Building

    /// Builds an optimized search query from the parsed components.
    func buildSearchQuery() -> String {
        // If we have a specific query already (like a song title), use it
        if !self.query.isEmpty, self.artist.isEmpty, self.genre.isEmpty, self.mood.isEmpty, self.era.isEmpty {
            return self.query
        }

        var parts: [String] = []
        var hasHits = false

        // Check if the original query contains "hits" - preserve user intent
        let wantsHits = self.queryWantsHits()

        // Build query based on primary identifier (artist > era > generic)
        if !self.artist.isEmpty {
            (parts, hasHits) = self.buildArtistQuery(wantsHits: wantsHits)
        } else if !self.era.isEmpty {
            (parts, hasHits) = self.buildEraQuery()
        } else {
            parts = self.buildGenericQuery()
        }

        // Add additional components
        parts = self.appendAdditionalComponents(to: parts)

        // Append "songs" suffix if we don't have "hits" or "music" already
        let hasMusic = parts.contains { $0.lowercased() == "music" }
        if !parts.isEmpty, !hasHits, !hasMusic {
            parts.append("songs")
        }

        return parts.joined(separator: " ")
    }

    /// Checks if the query contains keywords indicating "hits" style request.
    private func queryWantsHits() -> Bool {
        let queryLower = self.query.lowercased()
        return queryLower.contains("hit") || queryLower.contains("best") ||
            queryLower.contains("greatest") || queryLower.contains("top")
    }

    /// Builds query parts for artist-centric searches.
    private func buildArtistQuery(wantsHits: Bool) -> ([String], Bool) {
        var parts: [String] = [self.artist]
        var hasHits = false

        // For artist + era queries, add era after artist
        if !self.era.isEmpty {
            parts.append(self.normalizeEra(self.era))
        }

        // Add "greatest hits" for artist queries requesting hits
        if wantsHits {
            parts.append("greatest hits")
            hasHits = true
        }

        // Add genre and mood for artist queries
        if !self.genre.isEmpty { parts.append(self.genre) }
        if !self.mood.isEmpty { parts.append(self.mood) }

        return (parts, hasHits)
    }

    /// Builds query parts for era-centric searches (without artist).
    private func buildEraQuery() -> ([String], Bool) {
        var parts: [String] = [self.normalizeEra(self.era)]

        // Combine mood into genre-like descriptor for era queries
        if !self.mood.isEmpty {
            parts.append(self.moodToGenre(self.mood))
        } else if !self.genre.isEmpty {
            parts.append(self.genre)
        }

        // Add "hits" for era-only queries - works better with YTM
        parts.append("hits")
        return (parts, true)
    }

    /// Builds query parts for generic searches (no artist or era).
    private func buildGenericQuery() -> [String] {
        var parts: [String] = []
        if !self.genre.isEmpty { parts.append(self.genre) }
        if !self.mood.isEmpty { parts.append(self.mood) }

        // For mood-only queries, add "music" suffix for better YTM results
        // "chill music" returns better playlists than "chill songs"
        if self.genre.isEmpty, !self.mood.isEmpty, self.artist.isEmpty, self.activity.isEmpty {
            parts.append("music")
        }

        return parts
    }

    /// Appends version and activity components to the query parts.
    private func appendAdditionalComponents(to parts: [String]) -> [String] {
        var result = parts

        // Add cleaned base query if contains useful info
        if !self.query.isEmpty {
            let cleanQuery = self.cleanQueryForAppending(self.query)
            if !cleanQuery.isEmpty, cleanQuery.lowercased() != self.artist.lowercased() {
                result.append(cleanQuery)
            }
        }

        // Add version type
        if !self.version.isEmpty {
            result.append(self.version)
        }

        // Add activity for discovery (only if no other terms)
        if !self.activity.isEmpty, result.isEmpty {
            result.append("\(self.activity) music")
        }

        return result
    }

    /// Removes redundant terms from query for appending.
    private func cleanQueryForAppending(_ query: String) -> String {
        let words = query.lowercased().split(separator: " ")
        let skipWords: Set<String> = [
            "play", "some", "the", "a", "an", "me", "from", "of",
            "songs", "music", "tracks", "hits", "hit", "best", "greatest", "top",
        ]
        let filtered = words.filter { !skipWords.contains(String($0)) }
        return filtered.joined(separator: " ")
    }

    /// Normalizes era to short format that works better with YTM search.
    private func normalizeEra(_ era: String) -> String {
        let lowered = era.lowercased()

        // Convert full decade format to short
        if lowered.contains("1960") { return "60s" }
        if lowered.contains("1970") { return "70s" }
        if lowered.contains("1980") { return "80s" }
        if lowered.contains("1990") { return "90s" }
        if lowered.contains("2000") { return "2000s" }
        if lowered.contains("2010") { return "2010s" }
        if lowered.contains("2020") { return "2020s" }

        // Already short or keyword
        return era
    }

    /// Converts mood to a genre-like term that works better in era queries.
    private func moodToGenre(_ mood: String) -> String {
        let lowered = mood.lowercased()

        // Map moods to more searchable genre-style terms
        switch lowered {
        case "energetic", "upbeat", "happy":
            return "dance"
        case "chill", "relaxing", "peaceful", "mellow":
            return "chill"
        case "sad", "melancholic":
            return "ballads"
        case "romantic":
            return "love"
        case "aggressive", "intense":
            return "rock"
        case "groovy", "funky":
            return "funk"
        case "dark":
            return "alternative"
        default:
            return mood
        }
    }

    /// Returns a human-readable description for UI feedback.
    func queryDescription() -> String {
        var parts: [String] = []

        // Check if user asked for hits/best of
        let queryLower = self.query.lowercased()
        let wantsHits = queryLower.contains("hit") || queryLower.contains("best") ||
            queryLower.contains("greatest") || queryLower.contains("top")

        if !self.mood.isEmpty { parts.append(self.mood) }
        if !self.genre.isEmpty { parts.append(self.genre) }
        if wantsHits { parts.append("hits") }
        if !self.artist.isEmpty { parts.append("by \(self.artist)") }
        if !self.era.isEmpty { parts.append("from the \(self.era)") }
        if !self.version.isEmpty { parts.append("(\(self.version))") }
        if !self.activity.isEmpty { parts.append("for \(self.activity)") }

        if parts.isEmpty {
            return self.query
        }

        return parts.joined(separator: " ")
    }

    /// Suggests the best content source based on the parsed intent.
    /// - Returns: The recommended content source for this intent.
    func suggestedContentSource() -> ContentSource {
        // For artist-specific or era-specific queries, search is better
        if !self.artist.isEmpty {
            return .search
        }

        // For version-specific queries (acoustic, live, cover), search is needed
        if !self.version.isEmpty {
            return .search
        }

        // Keywords suggesting popularity/charts
        let popularityKeywords = ["top", "popular", "trending", "best", "hits", "charts"]
        let queryLower = self.query.lowercased()
        if popularityKeywords.contains(where: { queryLower.contains($0) }) {
            return .charts
        }

        // Pure mood requests are great for Moods & Genres
        let moodMatches = [
            "chill", "relaxing", "calm", "peaceful", "mellow",
            "energetic", "workout", "pump", "hype", "party",
            "focus", "study", "concentration",
            "sad", "melancholic", "heartbreak",
            "happy", "feel good", "upbeat", "uplifting",
            "sleep", "bedtime", "ambient",
            "romantic", "love",
        ]

        let moodLower = self.mood.lowercased()
        let matchesMood = !self.mood.isEmpty && moodMatches.contains { moodLower.contains($0) }
        let matchesQuery = moodMatches.contains { queryLower.contains($0) }

        if matchesMood || matchesQuery {
            return .moodsAndGenres
        }

        // Activity-based requests match well with Moods & Genres
        if !self.activity.isEmpty {
            return .moodsAndGenres
        }

        // Genre-only requests (without artist/era) can use Moods & Genres
        if !self.genre.isEmpty, self.artist.isEmpty, self.era.isEmpty {
            return .moodsAndGenres
        }

        // Default to search
        return .search
    }
}

// MARK: - MusicAction

/// Actions that can be performed via natural language commands.
@available(macOS 26.0, *)
@Generable
enum MusicAction: String, Sendable, CaseIterable {
    case play
    case queue
    case shuffle
    case like
    case dislike
    case skip
    case previous
    case pause
    case resume
    case search
}

// MARK: - ContentSource

/// Hints about where to source content for the best results.
/// Used to route requests to curated endpoints instead of search when appropriate.
enum ContentSource: String, Sendable, CustomStringConvertible {
    /// Use search API (default fallback)
    case search
    /// Use Moods & Genres curated playlists
    case moodsAndGenres
    /// Use Charts for popularity-based requests
    case charts

    var description: String {
        rawValue
    }
}
