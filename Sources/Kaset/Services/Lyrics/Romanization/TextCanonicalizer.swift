import Foundation

/// Cleans up lyrics text by normalizing spacing and punctuation.
enum TextCanonicalizer {
    static func canonicalize(_ text: String) -> String {
        var s = text
        // Collapse multiple spaces
        s = s.replacingOccurrences(of: "\\s{2,}", with: " ", options: .regularExpression)
        // Fix contractions: "can ' t" → "can't"
        s = s.replacingOccurrences(of: " ' ", with: "'")
        // Remove space before punctuation
        s = s.replacingOccurrences(of: " ,", with: ",")
        s = s.replacingOccurrences(of: " .", with: ".")
        // Normalize Unicode spaces (NBSP, thin space, hair space, narrow no-break space)
        s = s.replacingOccurrences(of: "[\u{00A0}\u{2009}\u{200A}\u{202F}]", with: " ", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespaces)
    }
}
