import Foundation

enum TextCanonicalizer {
    static func canonicalize(_ text: String) -> String {
        var s = text
        s = s.replacingOccurrences(of: "\\s{2,}", with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: " ' ", with: "'")
        s = s.replacingOccurrences(of: " ,", with: ",")
        s = s.replacingOccurrences(of: " .", with: ".")
        s = s.replacingOccurrences(of: "[\u{00A0}\u{2009}\u{200A}\u{202F}]", with: " ", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespaces)
    }
}
