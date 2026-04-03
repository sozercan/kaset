import Foundation

/// Romanizes Chinese text to pinyin using macOS's built-in CFStringTokenizer.
enum ChineseRomanizer {
    static func romanize(_ text: String) -> String? {
        let cfText = text as CFString
        let range = CFRangeMake(0, CFStringGetLength(cfText))
        let locale = Locale(identifier: "zh") as CFLocale

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
            if let latin = CFStringTokenizerCopyCurrentTokenAttribute(
                tokenizer,
                kCFStringTokenizerAttributeLatinTranscription
            ) as? String {
                if !result.isEmpty {
                    result += " "
                }
                result += latin
            } else {
                let tokenRange = CFStringTokenizerGetCurrentTokenRange(tokenizer)
                let start = text.index(text.startIndex, offsetBy: tokenRange.location)
                let end = text.index(start, offsetBy: tokenRange.length)
                let token = String(text[start ..< end])
                result += token
            }
            tokenType = CFStringTokenizerAdvanceToNextToken(tokenizer)
        }

        let trimmed = result.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }
}
