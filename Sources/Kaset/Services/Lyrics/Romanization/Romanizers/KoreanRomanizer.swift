import Foundation

/// Romanizes Korean text using algorithmic Hangul decomposition.
/// Implements Revised Romanization of Korean.
enum KoreanRomanizer {
    // Hangul syllable block: (initial × 21 + medial) × 28 + final + 0xAC00
    private static let hangulBase: UInt32 = 0xAC00
    private static let initialCount = 19
    private static let medialCount = 21
    private static let finalCount = 28

    /// Initial consonants (choseong) in Revised Romanization
    private static let initials = [
        "g", "kk", "n", "d", "tt", "r", "m", "b", "pp",
        "s", "ss", "", "j", "jj", "ch", "k", "t", "p", "h",
    ]

    /// Medial vowels (jungseong)
    private static let medials = [
        "a", "ae", "ya", "yae", "eo", "e", "yeo", "ye", "o",
        "wa", "wae", "oe", "yo", "u", "wo", "we", "wi", "yu",
        "eu", "ui", "i",
    ]

    /// Final consonants (jongseong) — index 0 is no final consonant
    private static let finals = [
        "", "k", "k", "k", "n", "n", "n", "t",
        "l", "l", "l", "l", "l", "l", "l", "l",
        "m", "p", "p", "t", "t", "ng", "t", "t",
        "k", "t", "p", "t",
    ]

    static func romanize(_ text: String) -> String? {
        var result = ""

        for scalar in text.unicodeScalars {
            let value = scalar.value
            if value >= Self.hangulBase, value <= 0xD7A3 {
                let syllableIndex = value - Self.hangulBase
                let initialIndex = Int(syllableIndex / UInt32(Self.medialCount * Self.finalCount))
                let medialIndex = Int((syllableIndex % UInt32(Self.medialCount * Self.finalCount)) / UInt32(Self.finalCount))
                let finalIndex = Int(syllableIndex % UInt32(Self.finalCount))

                result += Self.initials[initialIndex]
                result += Self.medials[medialIndex]
                result += Self.finals[finalIndex]
            } else {
                // Pass through non-Hangul characters (spaces, punctuation, Latin)
                result += String(scalar)
            }
        }

        let trimmed = result.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }
}
