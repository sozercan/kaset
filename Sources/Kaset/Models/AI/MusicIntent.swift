import Foundation
import FoundationModels

// MARK: - MusicIntent

/// Represents a user's intent when using natural language music commands.
/// The model generates this from free-form text like "play some jazz" or "skip this song".
@available(macOS 26.0, *)
@Generable
struct MusicIntent: Equatable {
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
        ContentSourceResolver.buildSearchQuery(from: self)
    }

    /// Returns a human-readable description for UI feedback.
    func queryDescription() -> String {
        ContentSourceResolver.queryDescription(for: self)
    }

    /// Suggests the best content source based on the parsed intent.
    /// - Returns: The recommended content source for this intent.
    func suggestedContentSource() -> ContentSource {
        ContentSourceResolver.suggestedContentSource(for: self)
    }
}

// MARK: - MusicAction

/// Actions that can be performed via natural language commands.
@available(macOS 26.0, *)
@Generable
enum MusicAction: String, CaseIterable {
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
enum ContentSource: String, CustomStringConvertible {
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
