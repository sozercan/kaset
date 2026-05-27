import Foundation

// MARK: - HTMLLyricsExtractor

enum HTMLLyricsExtractor {
    static func firstMatch(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) else {
            return nil
        }

        let range = NSRange(text.startIndex ..< text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              match.numberOfRanges > 1,
              let resultRange = Range(match.range(at: 1), in: text)
        else {
            return nil
        }

        return String(text[resultRange])
    }

    static func matches(in text: String, pattern: String) -> [String] {
        guard let regex = try? NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) else {
            return []
        }

        let range = NSRange(text.startIndex ..< text.endIndex, in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard match.numberOfRanges > 1,
                  let resultRange = Range(match.range(at: 1), in: text)
            else {
                return nil
            }

            return String(text[resultRange])
        }
    }

    static func cleanLyricsHTML(_ html: String) -> String {
        var text = html
        text = text.replacingOccurrences(
            of: #"(?i)<br\s*/?>"#,
            with: "\n",
            options: .regularExpression
        )
        text = text.replacingOccurrences(
            of: #"(?i)</(div|p|span|section|li|h\d)>"#,
            with: "\n",
            options: .regularExpression
        )
        text = text.replacingOccurrences(
            of: #"<[^>]+>"#,
            with: "",
            options: .regularExpression
        )

        return self.normalizeWhitespace(self.decodeHTMLEntities(text))
    }

    static func normalizeWhitespace(_ text: String) -> String {
        let lines = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }

        var normalized: [String] = []
        var previousWasEmpty = true
        for line in lines {
            if line.isEmpty {
                if !previousWasEmpty {
                    normalized.append("")
                }
                previousWasEmpty = true
            } else {
                normalized.append(line)
                previousWasEmpty = false
            }
        }

        while normalized.last?.isEmpty == true {
            normalized.removeLast()
        }

        return normalized.joined(separator: "\n")
    }

    static func decodeHTMLEntities(_ text: String) -> String {
        var decoded = text
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&nbsp;", with: " ")

        decoded = self.decodeNumericEntities(decoded, prefix: "&#x", radix: 16)
        decoded = self.decodeNumericEntities(decoded, prefix: "&#", radix: 10)
        return decoded
    }

    private static func decodeNumericEntities(_ text: String, prefix: String, radix: Int) -> String {
        guard let regex = try? NSRegularExpression(pattern: "\(NSRegularExpression.escapedPattern(for: prefix))([0-9A-Fa-f]+);") else {
            return text
        }

        let nsText = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length)).reversed()
        let mutable = NSMutableString(string: text)

        for match in matches {
            guard match.numberOfRanges > 1 else { continue }
            let numberText = nsText.substring(with: match.range(at: 1))
            guard let scalarValue = UInt32(numberText, radix: radix),
                  let scalar = UnicodeScalar(scalarValue)
            else {
                continue
            }

            mutable.replaceCharacters(in: match.range, with: String(Character(scalar)))
        }

        return String(mutable)
    }
}
