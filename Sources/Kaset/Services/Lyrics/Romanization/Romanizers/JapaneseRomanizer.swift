import Foundation

/// Romanizes Japanese text using macOS's built-in CFStringTokenizer.
/// Handles kanji, hiragana, and katakana → romaji conversion.
enum JapaneseRomanizer {
    static func romanize(_ text: String) -> String? {
        let cfText = text as CFString
        let nsText = text as NSString
        let range = CFRangeMake(0, CFStringGetLength(cfText))
        let locale = Locale(identifier: "ja") as CFLocale

        guard let tokenizer = CFStringTokenizerCreate(
            kCFAllocatorDefault,
            cfText,
            range,
            kCFStringTokenizerUnitWord,
            locale
        ) else {
            return nil
        }

        var result = ""
        var tokenType = CFStringTokenizerAdvanceToNextToken(tokenizer)

        while tokenType != [] {
            let tokenRange = CFStringTokenizerGetCurrentTokenRange(tokenizer)
            let token = nsText.substring(with: NSRange(
                location: tokenRange.location,
                length: tokenRange.length
            ))

            if ScriptDetector.isLatinOnly(token) {
                if !result.isEmpty {
                    result += " "
                }
                result += token
                tokenType = CFStringTokenizerAdvanceToNextToken(tokenizer)
                continue
            }

            if let latin = CFStringTokenizerCopyCurrentTokenAttribute(
                tokenizer,
                kCFStringTokenizerAttributeLatinTranscription
            ) as? String {
                if !result.isEmpty {
                    result += " "
                }
                result += latin
            } else {
                // Preserve non-tokenizable characters (spaces, punctuation)
                result += token
            }
            tokenType = CFStringTokenizerAdvanceToNextToken(tokenizer)
        }

        let trimmed = result.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }
}
