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

        // ERA-FIRST STRATEGY: When era is specified, lead with it for better YTM results
        // "90s dance hits" works better than "dance 1990s songs"
        if !self.era.isEmpty {
            let shortEra = self.normalizeEra(self.era)
            parts.append(shortEra)

            // Combine mood into genre-like descriptor for era queries
            // "90s dance" or "90s rock" instead of "90s energetic"
            if !self.mood.isEmpty {
                let genreFromMood = self.moodToGenre(self.mood)
                parts.append(genreFromMood)
            } else if !self.genre.isEmpty {
                parts.append(self.genre)
            }

            // Add "hits" for era queries without artist - works better with YTM
            if self.artist.isEmpty {
                parts.append("hits")
            }
        }

        // Artist (after era if present)
        if !self.artist.isEmpty {
            parts.append(self.artist)
        }

        // Add base query if different from artist
        if !self.query.isEmpty, self.query.lowercased() != self.artist.lowercased() {
            parts.append(self.query)
        }

        // Add genre (if not already added in era block)
        if !self.genre.isEmpty, self.era.isEmpty {
            parts.append(self.genre)
        }

        // Add mood (if not already converted in era block)
        if !self.mood.isEmpty, self.era.isEmpty {
            parts.append(self.mood)
        }

        // Add version type
        if !self.version.isEmpty {
            parts.append(self.version)
        }

        // Add activity for discovery (only if no other terms)
        if !self.activity.isEmpty, parts.isEmpty {
            parts.append("\(self.activity) music")
        }

        // Append "songs" only if we don't have "hits" already
        if !parts.isEmpty, !parts.contains("hits") {
            parts.append("songs")
        }

        return parts.joined(separator: " ")
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

        if !self.mood.isEmpty { parts.append(self.mood) }
        if !self.genre.isEmpty { parts.append(self.genre) }
        if !self.artist.isEmpty { parts.append("by \(self.artist)") }
        if !self.era.isEmpty { parts.append("from the \(self.era)") }
        if !self.version.isEmpty { parts.append("(\(self.version))") }
        if !self.activity.isEmpty { parts.append("for \(self.activity)") }

        if parts.isEmpty {
            return self.query
        }

        return parts.joined(separator: " ")
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
