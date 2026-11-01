import Foundation

// MARK: - LyricsSimilarity

/// String similarity for validating lyrics results against a reference (the
/// better-lyrics approach: reject a provider's lyrics when they don't match
/// YouTube Music's own lyrics, since a large mismatch means the wrong
/// recording or a bad match).
///
/// Uses a word-level Sørensen–Dice coefficient on the normalized word sets.
/// Returns 1.0 when the strings are identical, 0.0 when they share no words.
enum LyricsSimilarity {
    /// Similarity between two lyric texts in `0.0 ... 1.0`.
    static func similarity(_ a: String, _ b: String) -> Double {
        let wordsA = Self.wordSet(a)
        let wordsB = Self.wordSet(b)
        guard !wordsA.isEmpty, !wordsB.isEmpty else { return 0.0 }
        let intersection = wordsA.intersection(wordsB).count
        return 2.0 * Double(intersection) / Double(wordsA.count + wordsB.count)
    }

    /// Normalized set of words from a lyric text.
    private static func wordSet(_ text: String) -> Set<String> {
        let normalized = text.precomposedStringWithCompatibilityMapping.lowercased()
        let tokens = normalized.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        var result = Set<String>()
        for token in tokens {
            if token.unicodeScalars.contains(where: { $0.properties.isIdeographic || (0x3040 ... 0x30FF).contains($0.value) || (0xAC00 ... 0xD7AF).contains($0.value) }) {
                // Character tokens survive source differences in line breaks and spacing.
                result.formUnion(token.map(String.init))
            } else {
                result.insert(token)
            }
        }
        return result
    }

    /// Whether the lyric text is solely an "[instrumental only]" marker, which
    /// should not be presented as lyrics (better-lyrics skips these).
    static func isInstrumentalOnly(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.range(
            of: #"^\s*\[?instrumental\s*only\]?\s*$"#,
            options: .regularExpression,
            range: trimmed.startIndex ..< trimmed.endIndex,
            locale: nil
        ) != nil
    }
}
