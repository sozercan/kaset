import Foundation
import FoundationModels

/// AI-generated summary and analysis of song lyrics.
/// Provides themes, mood analysis, and an explanation of the song's meaning.
@available(macOS 26.0, *)
@Generable
struct LyricsSummary: Sendable {
    /// Key themes or topics in the lyrics (e.g., "love", "loss", "hope").
    @Guide(description: "List of 2-5 key themes or topics found in the lyrics.")
    let themes: [String]

    /// The overall mood or emotional tone of the song.
    @Guide(description: "A single word or short phrase describing the song's mood (e.g., 'melancholic', 'uplifting', 'nostalgic').")
    let mood: String

    /// A brief explanation of what the song is about.
    @Guide(description: "A concise explanation of the song's meaning and message (2-4 sentences). Be insightful but not overly academic.")
    let explanation: String
}
