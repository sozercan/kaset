import Foundation

// MARK: - SearchResponseParser Support

extension SearchResponseParser {
    static func splitMetadataText(_ text: String) -> [String] {
        text.replacingOccurrences(of: "·", with: "•")
            .split(separator: "•", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    static func descriptionText(from renderer: [String: Any]) -> String? {
        guard let description = renderer["description"] as? [String: Any],
              let runs = description["runs"] as? [[String: Any]]
        else {
            return nil
        }
        let text = ParsingHelpers.joinedRunText(runs).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    static func isYear(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count == 4,
              trimmed.allSatisfy(\.isNumber),
              let year = Int(trimmed)
        else {
            return false
        }
        return (1900 ... 2100).contains(year)
    }

    static func looksLikeDuration(_ text: String) -> Bool {
        if ParsingHelpers.parseDuration(text) != nil {
            return true
        }
        let lowercased = text.lowercased()
        return lowercased.contains(" min")
            || lowercased.contains(" minute")
            || lowercased.contains(" hour")
            || lowercased.contains(" sec")
    }

    static func durationSeconds(_ text: String) -> TimeInterval? {
        if let seconds = ParsingHelpers.parseDuration(text) {
            return seconds
        }

        let lowercased = text.lowercased()
        let number = lowercased.split(whereSeparator: { !$0.isNumber }).first.flatMap { Double($0) }
        guard let number else {
            return nil
        }
        if lowercased.contains("hour") {
            return number * 3600
        }
        if lowercased.contains("min") {
            return number * 60
        }
        if lowercased.contains("sec") {
            return number
        }
        return nil
    }

    static func looksLikePublishedDate(_ text: String) -> Bool {
        let lowercased = text.lowercased()
        if lowercased.contains(" ago") {
            return true
        }
        if text.range(of: #"\b(19|20)\d{2}\b"#, options: .regularExpression) != nil {
            return true
        }
        let monthPrefixes = [
            "jan", "feb", "mar", "apr", "may", "jun",
            "jul", "aug", "sep", "oct", "nov", "dec",
        ]
        return monthPrefixes.contains { lowercased.hasPrefix($0) }
    }

    static func looksLikeCount(_ text: String) -> Bool {
        let lowercased = text.lowercased()
        return lowercased.contains("subscriber")
            || lowercased.contains("view")
            || lowercased.contains("play")
            || lowercased.contains("episode")
            || lowercased.contains("song")
            || lowercased.contains("track")
    }

    static func playbackProgress(from renderer: [String: Any]) -> Double {
        guard let rawProgress = renderer["playbackProgress"] as? Double else {
            return 0
        }
        if rawProgress > 1 {
            return min(rawProgress / 100, 1)
        }
        return max(0, min(rawProgress, 1))
    }

    static func extractContinuationToken(from renderer: [String: Any]) -> String? {
        if let continuations = renderer["continuations"] as? [[String: Any]] {
            for continuation in continuations {
                for key in ["nextContinuationData", "reloadContinuationData"] {
                    guard let continuationData = continuation[key] as? [String: Any],
                          let token = continuationData["continuation"] as? String,
                          !token.isEmpty
                    else {
                        continue
                    }
                    return token
                }
            }
        }

        if let contents = renderer["contents"] as? [[String: Any]] {
            for content in contents {
                if let token = Self.extractContinuationToken(fromContinuationItem: content) {
                    return token
                }
            }
        }
        return nil
    }

    static func extractContinuationToken(fromContinuationItem item: [String: Any]) -> String? {
        guard let renderer = item["continuationItemRenderer"] as? [String: Any],
              let endpoint = renderer["continuationEndpoint"] as? [String: Any],
              let command = endpoint["continuationCommand"] as? [String: Any],
              let token = command["token"] as? String,
              !token.isEmpty
        else {
            return nil
        }
        return token
    }
}
