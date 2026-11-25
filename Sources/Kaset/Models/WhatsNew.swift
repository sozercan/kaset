import Foundation

struct WhatsNew: Identifiable {
    let version: Version

    let title: String

    let features: [Feature]

    let releaseNotes: String?

    let learnMoreURL: URL?

    var id: Version {
        self.version
    }

    init(
        version: Version,
        title: String,
        features: [Feature] = [],
        releaseNotes: String? = nil,
        learnMoreURL: URL? = nil
    ) {
        self.version = version
        self.title = title
        self.features = features
        self.releaseNotes = releaseNotes
        self.learnMoreURL = learnMoreURL
    }
}

extension WhatsNew {
    struct Version: Hashable, Comparable, Codable, CustomStringConvertible {
        let major: Int
        let minor: Int
        let patch: Int
        private let suffix: String

        init(major: Int, minor: Int, patch: Int, suffix: String = "") {
            self.major = major
            self.minor = minor
            self.patch = patch
            self.suffix = suffix
        }

        var minorRelease: Version {
            Version(major: self.major, minor: self.minor, patch: 0)
        }

        static func < (lhs: Version, rhs: Version) -> Bool {
            if lhs.major != rhs.major {
                return lhs.major < rhs.major
            }
            if lhs.minor != rhs.minor {
                return lhs.minor < rhs.minor
            }
            if lhs.patch != rhs.patch {
                return lhs.patch < rhs.patch
            }
            return self.compareSuffix(lhs.suffix, rhs.suffix)
        }

        var description: String {
            "\(self.major).\(self.minor).\(self.patch)\(self.suffix)"
        }

        private static func compareSuffix(_ lhs: String, _ rhs: String) -> Bool {
            guard lhs != rhs else { return false }
            if lhs.isEmpty {
                return false
            }
            if rhs.isEmpty {
                return true
            }
            return lhs.compare(rhs, options: [.numeric]) == .orderedAscending
        }
    }
}

extension WhatsNew.Version: ExpressibleByStringLiteral {
    private struct ParsedComponents {
        let major: Int
        let minor: Int
        let patch: Int
        let suffix: String
    }

    init(stringLiteral value: String) {
        let components = Self.parse(value.trimmingCharacters(in: .whitespacesAndNewlines))
        self.init(
            major: components.major,
            minor: components.minor,
            patch: components.patch,
            suffix: components.suffix
        )
    }

    private static let parser = try? NSRegularExpression(pattern: #"^(\d+)(?:\.(\d+))?(?:\.(\d+))?(.*)$"#)

    private static func parse(_ value: String) -> ParsedComponents {
        guard !value.isEmpty,
              let match = parser?.firstMatch(in: value, range: NSRange(value.startIndex..., in: value))
        else {
            return ParsedComponents(major: 0, minor: 0, patch: 0, suffix: "")
        }

        return ParsedComponents(
            major: Self.intCapture(in: value, match: match, at: 1),
            minor: Self.intCapture(in: value, match: match, at: 2),
            patch: Self.intCapture(in: value, match: match, at: 3),
            suffix: Self.stringCapture(in: value, match: match, at: 4)
        )
    }

    private static func intCapture(in value: String, match: NSTextCheckingResult, at index: Int) -> Int {
        Int(self.stringCapture(in: value, match: match, at: index)) ?? 0
    }

    private static func stringCapture(in value: String, match: NSTextCheckingResult, at index: Int) -> String {
        let range = match.range(at: index)
        guard range.location != NSNotFound,
              let swiftRange = Range(range, in: value)
        else {
            return ""
        }

        return String(value[swiftRange])
    }
}

extension WhatsNew.Version {
    static func current(in bundle: Bundle = .main) -> WhatsNew.Version {
        let versionString = bundle.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
        return .init(stringLiteral: versionString)
    }
}

extension WhatsNew {
    struct Feature: Hashable {
        let icon: String

        let title: String

        let subtitle: String
    }
}
