import Foundation
import NaturalLanguage

// MARK: - Script

/// Writing systems that can be detected in lyrics text.
enum Script {
    case latin, japanese, korean, chinese, thai, bengali, hindi, unknown
}

// MARK: - ScriptDetector

/// Detects which writing system a string contains using Unicode scalar ranges.
enum ScriptDetector {
    private struct CJKPresence {
        let hasKana: Bool
        let hasCJK: Bool
    }

    private static func cjkPresence(in text: String) -> CJKPresence {
        var hasKana = false
        var hasCJK = false

        for scalar in text.unicodeScalars {
            let v = scalar.value
            // Hiragana U+3040–309F
            if v >= 0x3040, v <= 0x309F {
                hasKana = true
            }
            // Katakana U+30A0–30FF
            else if v >= 0x30A0, v <= 0x30FF {
                hasKana = true
            }
            // CJK Unified Ideographs U+4E00–9FFF
            else if v >= 0x4E00, v <= 0x9FFF {
                hasCJK = true
            }
        }

        return CJKPresence(hasKana: hasKana, hasCJK: hasCJK)
    }

    /// Returns true when NaturalLanguage can confidently classify kana-free CJK text as Japanese,
    /// false when it classifies it as Chinese, or nil when the result is inconclusive.
    private static func isJapaneseCJKText(_ text: String) -> Bool? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)

        guard let language = recognizer.dominantLanguage else {
            return nil
        }

        if language.rawValue == "ja" {
            return true
        }

        if language.rawValue.hasPrefix("zh") {
            return false
        }

        return nil
    }

    /// Returns true if the text contains hiragana, katakana, or CJK ideographs recognized as Japanese.
    static func hasJapanese(_ text: String) -> Bool {
        let presence = self.cjkPresence(in: text)
        if presence.hasKana {
            return true
        }

        guard presence.hasCJK else {
            return false
        }

        return self.isJapaneseCJKText(text) ?? false
    }

    /// Returns true if the text contains Hangul characters.
    static func hasKorean(_ text: String) -> Bool {
        for scalar in text.unicodeScalars {
            let v = scalar.value
            // Hangul Jamo U+1100–11FF
            if v >= 0x1100, v <= 0x11FF { return true }
            // Hangul Syllables U+AC00–D7AF
            if v >= 0xAC00, v <= 0xD7AF { return true }
            // Hangul Compatibility Jamo U+3130–318F
            if v >= 0x3130, v <= 0x318F { return true }
        }
        return false
    }

    /// Returns true if the text contains CJK ideographs without kana (Chinese, not Japanese).
    static func hasChinese(_ text: String) -> Bool {
        let presence = self.cjkPresence(in: text)
        guard presence.hasCJK else {
            return false
        }

        if presence.hasKana {
            return false
        }

        return !(self.isJapaneseCJKText(text) ?? false)
    }

    /// Returns true if the text contains Thai characters.
    static func hasThai(_ text: String) -> Bool {
        text.unicodeScalars.contains { $0.value >= 0x0E00 && $0.value <= 0x0E7F }
    }

    /// Returns true if the text contains Bengali characters.
    static func hasBengali(_ text: String) -> Bool {
        text.unicodeScalars.contains { $0.value >= 0x0980 && $0.value <= 0x09FF }
    }

    /// Returns true if the text contains Devanagari (Hindi) characters.
    static func hasHindi(_ text: String) -> Bool {
        text.unicodeScalars.contains { $0.value >= 0x0900 && $0.value <= 0x097F }
    }

    /// Returns true if all characters are Basic Latin or Latin Extended.
    static func isLatinOnly(_ text: String) -> Bool {
        for scalar in text.unicodeScalars {
            let v = scalar.value
            // Allow Basic Latin (U+0000–007F), Latin-1 Supplement (U+0080–00FF),
            // Latin Extended-A (U+0100–017F), Latin Extended-B (U+0180–024F)
            if v > 0x024F {
                // Also allow common punctuation and symbols
                if v >= 0x2000, v <= 0x206F { continue } // General Punctuation
                if v >= 0x20A0, v <= 0x20CF { continue } // Currency Symbols
                if v >= 0xFE00, v <= 0xFE0F { continue } // Variation Selectors
                if v >= 0xFFF0, v <= 0xFFFF { continue } // Specials
                return false
            }
        }
        return true
    }

    /// Returns the most prevalent non-Latin script in the text.
    static func dominantScript(_ text: String) -> Script {
        // Check in order of specificity
        if self.hasJapanese(text) { return .japanese }
        if self.hasKorean(text) { return .korean }
        if self.hasChinese(text) { return .chinese }
        if self.hasThai(text) { return .thai }
        if self.hasBengali(text) { return .bengali }
        if self.hasHindi(text) { return .hindi }
        if self.isLatinOnly(text) { return .latin }
        return .unknown
    }
}
