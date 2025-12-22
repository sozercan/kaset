import Foundation
import FoundationModels

// MARK: - MusicQuery

/// Represents structured search parameters parsed from natural language.
/// The AI extracts these from queries like "upbeat rolling stones songs from the 90s".
@available(macOS 26.0, *)
@Generable
struct MusicQuery: Sendable {
    /// The main search term (artist, song, or general query).
    @Guide(description: "Primary search term - could be artist name, song title, or general query")
    let searchTerm: String

    /// Specific artist name if mentioned.
    @Guide(description: "Artist name if explicitly mentioned (e.g., 'Rolling Stones', 'Taylor Swift'). Empty if not specified.")
    let artist: String

    /// Genre or style of music.
    @Guide(description: """
    Music genre/style if mentioned. Examples:
    rock, pop, jazz, classical, hip-hop, r&b, electronic, country, folk, metal,
    indie, alternative, blues, soul, reggae, punk, disco, funk, latin, k-pop
    """)
    let genre: String

    /// Mood or energy level of the music.
    @Guide(description: """
    Mood/vibe if mentioned. Examples:
    upbeat, chill, relaxing, energetic, sad, happy, melancholic, romantic,
    aggressive, peaceful, dreamy, nostalgic, intense, mellow, groovy, dark
    """)
    let mood: String

    /// Activity the music is for.
    @Guide(description: """
    Activity context if mentioned. Examples:
    workout, study, sleep, party, driving, cooking, meditation, focus, work,
    running, yoga, gaming, dinner, relaxation, morning, night
    """)
    let activity: String

    /// Time period or decade.
    @Guide(description: """
    Era/decade if mentioned. Use format like:
    '1960s', '1970s', '1980s', '1990s', '2000s', '2010s', '2020s'
    Or keywords: 'classic', 'old school', 'vintage', 'modern', 'new', 'recent'
    """)
    let era: String

    /// Specific type or version of music.
    @Guide(description: """
    Music type/version if mentioned. Examples:
    acoustic, live, remix, instrumental, cover, original, unplugged, remastered
    """)
    let version: String

    /// Language preference.
    @Guide(description: "Language if specified (e.g., 'spanish', 'french', 'korean', 'japanese'). Empty if not specified.")
    let language: String

    /// Whether explicit content is desired.
    @Guide(description: "Content preference: 'clean' for family-friendly, 'explicit' if requested, empty for no preference")
    let contentRating: String

    /// Number of songs requested.
    @Guide(description: "Number of songs requested (e.g., 'play 5 songs' → 5). Use 0 if not specified.")
    let count: Int

    // MARK: - Query Construction

    /// Constructs an optimized YouTube Music search query from parsed parameters.
    func buildSearchQuery() -> String {
        var parts: [String] = []

        // Start with artist if specified
        if !self.artist.isEmpty {
            parts.append(self.artist)
        }

        // Add search term if different from artist
        if !self.searchTerm.isEmpty, self.searchTerm.lowercased() != self.artist.lowercased() {
            parts.append(self.searchTerm)
        }

        // Add genre
        if !self.genre.isEmpty {
            parts.append(self.genre)
        }

        // Add mood (can help YouTube Music's semantic search)
        if !self.mood.isEmpty {
            parts.append(self.mood)
        }

        // Add era/decade
        if !self.era.isEmpty {
            // Convert keywords to decades if needed
            let normalizedEra = self.normalizeEra(self.era)
            parts.append(normalizedEra)
        }

        // Add version type
        if !self.version.isEmpty {
            parts.append(self.version)
        }

        // Add language
        if !self.language.isEmpty {
            parts.append(self.language)
        }

        // Add activity context for discovery
        if !self.activity.isEmpty, parts.isEmpty {
            // Only add activity if we have no other search terms
            parts.append("\(self.activity) music")
        }

        // Always end with "songs" to ensure we get songs, not videos/podcasts
        if !parts.isEmpty {
            parts.append("songs")
        }

        return parts.joined(separator: " ")
    }

    /// Normalizes era descriptions to decade format.
    private func normalizeEra(_ era: String) -> String {
        let lowered = era.lowercased()

        // Already a decade format
        if lowered.contains("19") || lowered.contains("20") {
            return era
        }

        // Map common terms
        switch lowered {
        case "classic", "old school", "vintage", "oldies":
            return "classic"
        case "modern", "new", "recent", "current", "latest":
            return "2020s"
        case "retro":
            return "80s 90s"
        default:
            return era
        }
    }

    /// Returns a human-readable description of the query for UI feedback.
    func description() -> String {
        var parts: [String] = []

        if !self.mood.isEmpty { parts.append(self.mood) }
        if !self.genre.isEmpty { parts.append(self.genre) }
        if !self.artist.isEmpty { parts.append("by \(self.artist)") }
        if !self.era.isEmpty { parts.append("from the \(self.era)") }
        if !self.version.isEmpty { parts.append("(\(self.version))") }
        if !self.activity.isEmpty { parts.append("for \(self.activity)") }

        if parts.isEmpty, !self.searchTerm.isEmpty {
            return self.searchTerm
        }

        return parts.joined(separator: " ")
    }
}

// MARK: - Example Queries

/*
 Example natural language queries and how they would be parsed:

 "upbeat rolling stones songs from the 90s"
 → artist: "Rolling Stones", mood: "upbeat", era: "1990s"
 → query: "Rolling Stones upbeat 1990s songs"

 "chill jazz for studying"
 → genre: "jazz", mood: "chill", activity: "study"
 → query: "jazz chill songs"

 "sad acoustic covers"
 → mood: "sad", version: "acoustic cover"
 → query: "sad acoustic cover songs"

 "energetic workout music"
 → mood: "energetic", activity: "workout"
 → query: "workout music songs"

 "80s synthwave"
 → genre: "synthwave", era: "1980s"
 → query: "synthwave 1980s songs"

 "Spanish love songs"
 → language: "spanish", mood: "romantic"
 → query: "spanish romantic songs"

 "live Coldplay performances"
 → artist: "Coldplay", version: "live"
 → query: "Coldplay live songs"

 "instrumental hip hop beats"
 → genre: "hip hop", version: "instrumental"
 → query: "hip hop instrumental songs"

 "classic rock road trip songs"
 → genre: "rock", era: "classic", activity: "driving"
 → query: "rock classic songs"

 "K-pop dance hits"
 → genre: "k-pop", mood: "upbeat"
 → query: "k-pop upbeat songs"
 */
