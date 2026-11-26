import Foundation
import FoundationModels

@available(macOS 26.0, *)
@Generable
struct LyricsSummary {
    @Guide(description: "List of 2-5 key themes or topics found in the lyrics.")
    let themes: [String]

    @Guide(description: "A single word or short phrase describing the song's mood (e.g., 'melancholic', 'uplifting', 'nostalgic').")
    let mood: String

    @Guide(description: "A concise explanation of the song's meaning and message (2-4 sentences). Be insightful but not overly academic.")
    let explanation: String
}
