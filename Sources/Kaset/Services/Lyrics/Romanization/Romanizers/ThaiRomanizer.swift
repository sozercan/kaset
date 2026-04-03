import Foundation

/// Romanizes Thai text using macOS's built-in CFStringTokenizer.
enum ThaiRomanizer {
    static func romanize(_ text: String) -> String? {
        let cfText = text as CFString
        let nsText = text as NSString
        let range = CFRangeMake(0, CFStringGetLength(cfText))
        let locale = Locale(identifier: "th") as CFLocale

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
                let token = nsText.substring(with: NSRange(
                    location: tokenRange.location,
                    length: tokenRange.length
                ))
                result += token
            }
            tokenType = CFStringTokenizerAdvanceToNextToken(tokenizer)
        }

        let trimmed = result.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }
}
