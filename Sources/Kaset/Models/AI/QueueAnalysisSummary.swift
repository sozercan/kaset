import Foundation
import FoundationModels

@available(macOS 26.0, *)
@Generable
struct QueueAnalysisSummary: Equatable {
    @Guide(description: "A short opening sentence that starts from the current song or current queue position.")
    let opening: String

    @Guide(description: "A short phrase describing the queue's vibe, arc, or energy.")
    let vibe: String

    @Guide(description: "Two to four concrete highlight callouts from the queue, using song titles or artist names from the provided list.")
    let highlights: [String]

    @Guide(description: "A concise 3-5 sentence analysis of the queue's flow, taste, and momentum. Natural prose only.")
    let summary: String

    var displayText: String {
        self.summary.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

@available(macOS 26.0, *)
extension QueueAnalysisSummary.PartiallyGenerated {
    var displayText: String? {
        if let summary, !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return summary.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        var parts: [String] = []

        if let opening, !opening.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append(opening.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        if let vibe, !vibe.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append("Vibe: \(vibe.trimmingCharacters(in: .whitespacesAndNewlines)).")
        }

        if let highlights, !highlights.isEmpty {
            parts.append(highlights.joined(separator: ", "))
        }

        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: " ")
    }
}
