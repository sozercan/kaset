import Foundation
import Observation

/// Service that romanizes non-Latin lyrics text (e.g., Japanese → romaji, Korean → romanized, Chinese → pinyin).
@MainActor
@Observable
final class RomanizationService {
    /// Whether romanization is enabled (reads from SettingsManager).
    var isEnabled: Bool {
        SettingsManager.shared.romanizationEnabled
    }

    /// In-memory cache: original line text → romanized text (nil if same or not applicable).
    private var cache: [String: String?] = [:]

    /// Romanizes a single line of text. Returns nil if the text is already Latin or romanization produced no change.
    func romanize(_ text: String) -> String? {
        if ScriptDetector.isLatinOnly(text) { return nil }
        if let cached = self.cache[text] { return cached }

        let result: String? = switch ScriptDetector.dominantScript(text) {
        case .japanese: JapaneseRomanizer.romanize(text)
        case .korean: KoreanRomanizer.romanize(text)
        case .chinese: ChineseRomanizer.romanize(text)
        case .thai: ThaiRomanizer.romanize(text)
        case .bengali: BengaliRomanizer.romanize(text)
        case .hindi: HindiRomanizer.romanize(text)
        default: nil
        }

        // Canonicalize and only cache if result differs from original
        let canonicalized = result.map { TextCanonicalizer.canonicalize($0) }
        let finalResult = (canonicalized != nil && canonicalized != text) ? canonicalized : nil
        self.cache[text] = finalResult
        return finalResult
    }

    /// Batch-romanize all lines in a SyncedLyrics. Returns a dictionary mapping line ID → romanized text.
    func romanizeAll(_ lyrics: SyncedLyrics) -> [UUID: String] {
        var results: [UUID: String] = [:]
        for line in lyrics.lines {
            if let romanized = self.romanize(line.text) {
                results[line.id] = romanized
            }
        }
        return results
    }

    /// Clears the romanization cache.
    func clearCache() {
        self.cache.removeAll()
    }
}
