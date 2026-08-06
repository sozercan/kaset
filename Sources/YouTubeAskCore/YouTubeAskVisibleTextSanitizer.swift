import Foundation

// MARK: - YouTubeAskSanitizedText

package struct YouTubeAskSanitizedText: Equatable, Sendable {
    package let text: String
    package let wasTruncated: Bool
}

// MARK: - YouTubeAskVisibleTextSanitizer

package enum YouTubeAskVisibleTextSanitizer {
    package static func sanitizeChipLabel(_ value: String) -> YouTubeAskSanitizedText? {
        guard let sanitized = sanitize(value),
              sanitized.count <= YouTubeAskLimits.maximumChipCharacters
        else {
            return nil
        }
        return YouTubeAskSanitizedText(text: sanitized, wasTruncated: false)
    }

    package static func sanitizeAnswer(_ value: String) -> YouTubeAskSanitizedText? {
        guard let sanitized = sanitize(value) else { return nil }
        let wasTruncated = sanitized.count > YouTubeAskLimits.maximumAnswerCharacters
        let text = wasTruncated
            ? String(sanitized.prefix(YouTubeAskLimits.maximumAnswerCharacters))
            : sanitized
        return YouTubeAskSanitizedText(text: text, wasTruncated: wasTruncated)
    }

    private static let bidirectionalControlValues: Set<UInt32> = [
        0x061C,
        0x200E,
        0x200F,
        0x202A,
        0x202B,
        0x202C,
        0x202D,
        0x202E,
        0x2066,
        0x2067,
        0x2068,
        0x2069,
    ]

    private static func sanitize(_ value: String) -> String? {
        var result = Self.removingTerminalAndControlSequences(value)
        result = Self.replacingMarkdownLinks(in: result)
        result = Self.replacingLinks(in: result)
        result = Self.replacingHighEntropyIdentifiers(in: result)
        result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? nil : result
    }

    private static func removingTerminalAndControlSequences(_ value: String) -> String {
        let scalars = Array(value.unicodeScalars)
        var result = String.UnicodeScalarView()
        result.reserveCapacity(scalars.count)
        var index = 0

        while index < scalars.count {
            let scalar = scalars[index]
            switch scalar.value {
            case 0x1B:
                index = Self.indexAfterEscapeSequence(in: scalars, startingAt: index)
            case 0x9B:
                index = Self.indexAfterControlSequence(in: scalars, startingAt: index + 1)
            case 0x90, 0x98, 0x9D, 0x9E, 0x9F:
                index = Self.indexAfterStringControl(in: scalars, startingAt: index + 1)
            default:
                if Self.bidirectionalControlValues.contains(scalar.value)
                    || Self.isDisallowedControl(scalar)
                {
                    index += 1
                } else {
                    result.append(scalar)
                    index += 1
                }
            }
        }

        return String(result)
    }

    private static func indexAfterEscapeSequence(
        in scalars: [UnicodeScalar],
        startingAt index: Int
    ) -> Int {
        let nextIndex = index + 1
        guard nextIndex < scalars.count else { return scalars.count }

        switch scalars[nextIndex].value {
        case 0x5B:
            return Self.indexAfterControlSequence(in: scalars, startingAt: nextIndex + 1)
        case 0x50, 0x58, 0x5D, 0x5E, 0x5F:
            return Self.indexAfterStringControl(in: scalars, startingAt: nextIndex + 1)
        default:
            return min(nextIndex + 1, scalars.count)
        }
    }

    private static func indexAfterControlSequence(
        in scalars: [UnicodeScalar],
        startingAt index: Int
    ) -> Int {
        var cursor = index
        while cursor < scalars.count {
            let value = scalars[cursor].value
            cursor += 1
            if (0x40 ... 0x7E).contains(value) {
                return cursor
            }
        }
        return scalars.count
    }

    private static func indexAfterStringControl(
        in scalars: [UnicodeScalar],
        startingAt index: Int
    ) -> Int {
        var cursor = index
        while cursor < scalars.count {
            if scalars[cursor].value == 0x07 {
                return cursor + 1
            }
            if scalars[cursor].value == 0x1B,
               cursor + 1 < scalars.count,
               scalars[cursor + 1].value == 0x5C
            {
                return cursor + 2
            }
            cursor += 1
        }
        return scalars.count
    }

    private static func isDisallowedControl(_ scalar: UnicodeScalar) -> Bool {
        switch scalar.value {
        case 0x09, 0x0A:
            false
        case 0x00 ... 0x1F, 0x7F ... 0x9F:
            true
        default:
            false
        }
    }

    private static func replacingMarkdownLinks(in value: String) -> String {
        self.replacingMatches(
            in: value,
            pattern: #"(?i)\[([^\]\r\n]{1,500})\]\(\s*https?://[^\s)]+\s*\)"#,
            template: "$1"
        )
    }

    private static func replacingLinks(in value: String) -> String {
        let withoutAutoLinks = Self.replacingMatches(
            in: value,
            pattern: #"(?i)<https?://[^\s<>]+>"#,
            template: "[link omitted]"
        )
        let withoutHTTPLinks = Self.replacingMatches(
            in: withoutAutoLinks,
            pattern: #"(?i)https?://[^\s<>()\[\]{}]+"#,
            template: "[link omitted]"
        )
        return Self.replacingMatches(
            in: withoutHTTPLinks,
            pattern: #"(?i)(?<![A-Za-z0-9_])www\.[^\s<>()\[\]{}]+"#,
            template: "[link omitted]"
        )
    }

    private static func replacingMatches(
        in value: String,
        pattern: String,
        template: String
    ) -> String {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return value }
        let range = NSRange(value.startIndex ..< value.endIndex, in: value)
        return expression.stringByReplacingMatches(
            in: value,
            options: [],
            range: range,
            withTemplate: template
        )
    }

    private static func replacingHighEntropyIdentifiers(in value: String) -> String {
        var result = ""
        var candidateScalars = String.UnicodeScalarView()

        func appendToken() {
            guard !candidateScalars.isEmpty else { return }
            let candidate = String(candidateScalars)
            result.append(contentsOf: Self.isLikelyOpaqueIdentifier(candidate)
                ? "[opaque omitted]"
                : candidate)
            candidateScalars.removeAll(keepingCapacity: true)
        }

        for scalar in value.unicodeScalars {
            if Self.isOpaqueTokenScalar(scalar) {
                candidateScalars.append(scalar)
            } else {
                appendToken()
                result.unicodeScalars.append(scalar)
            }
        }
        appendToken()
        return result
    }

    private static func isOpaqueTokenScalar(_ scalar: UnicodeScalar) -> Bool {
        switch scalar.value {
        case 0x2D, 0x2E, 0x30 ... 0x39, 0x3D, 0x41 ... 0x5A, 0x5F, 0x61 ... 0x7A:
            true
        default:
            false
        }
    }

    private static func isLikelyOpaqueIdentifier(_ value: String) -> Bool {
        if self.isUUIDLike(value) {
            return true
        }

        let scalars = value.unicodeScalars.filter { $0.value != 0x3D }
        guard scalars.count >= 48 else { return false }

        let isHex = scalars.allSatisfy { scalar in
            (0x30 ... 0x39).contains(scalar.value)
                || (0x41 ... 0x46).contains(scalar.value)
                || (0x61 ... 0x66).contains(scalar.value)
        }
        let distinctValues = Set(scalars.map(\.value))
        if isHex, scalars.count >= 40, distinctValues.count >= 8 {
            return true
        }

        var hasLowercase = false
        var hasUppercase = false
        var hasDigit = false
        var hasSeparator = false
        var frequencies: [UInt32: Int] = [:]
        for scalar in scalars {
            frequencies[scalar.value, default: 0] += 1
            switch scalar.value {
            case 0x30 ... 0x39:
                hasDigit = true
            case 0x41 ... 0x5A:
                hasUppercase = true
            case 0x61 ... 0x7A:
                hasLowercase = true
            default:
                hasSeparator = true
            }
        }

        let categoryCount = [hasLowercase, hasUppercase, hasDigit, hasSeparator]
            .filter(\.self)
            .count
        let maximumFrequency = frequencies.values.max() ?? scalars.count
        let isWellDistributed = maximumFrequency * 4 <= scalars.count
        if distinctValues.count >= 12, categoryCount >= 2, isWellDistributed {
            return true
        }
        return scalars.count >= 64
            && distinctValues.count >= 16
            && maximumFrequency * 5 <= scalars.count
    }

    private static func isUUIDLike(_ value: String) -> Bool {
        let parts = value.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.map(\.count) == [8, 4, 4, 4, 12] else { return false }
        return parts.joined().unicodeScalars.allSatisfy { scalar in
            (0x30 ... 0x39).contains(scalar.value)
                || (0x41 ... 0x46).contains(scalar.value)
                || (0x61 ... 0x66).contains(scalar.value)
        }
    }
}
