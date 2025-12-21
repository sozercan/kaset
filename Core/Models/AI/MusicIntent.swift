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
