import Foundation

// MARK: - WhatsNew

/// Represents a "What's New" entry for a specific app version.
struct WhatsNew: Identifiable {
    /// The app version this entry corresponds to.
    let version: Version

    /// The headline title displayed at the top of the sheet.
    let title: String

    /// The list of features to showcase (used for static/fallback entries).
    let features: [Feature]

    /// Markdown body from release notes (used for dynamic entries from GitHub).
    let releaseNotes: String?

    /// Optional URL to open when the user taps "Learn more".
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

// MARK: WhatsNew.Version

extension WhatsNew {
    /// A semantic version with major, minor, and patch components.
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

        /// Returns the minor-release version (patch set to 0).
        var minorRelease: Version {
            Version(major: self.major, minor: self.minor, patch: 0)
        }

        // MARK: Comparable

        static func < (lhs: Version, rhs: Version) -> Bool {
            if lhs.major != rhs.major { return lhs.major < rhs.major }
            if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
            if lhs.patch != rhs.patch { return lhs.patch < rhs.patch }
            return self.compareSuffix(lhs.suffix, rhs.suffix)
        }

        // MARK: CustomStringConvertible

        var description: String {
            "\(self.major).\(self.minor).\(self.patch)\(self.suffix)"
        }

        private static func compareSuffix(_ lhs: String, _ rhs: String) -> Bool {
            guard lhs != rhs else { return false }
            if lhs.isEmpty { return false }
            if rhs.isEmpty { return true }
            return lhs.compare(rhs, options: [.numeric]) == .orderedAscending
        }
    }
}

// MARK: - WhatsNew.Version + ExpressibleByStringLiteral

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

// MARK: - Version+current

extension WhatsNew.Version {
    /// Retrieves the current app version from the main bundle's `CFBundleShortVersionString`.
    static func current(in bundle: Bundle = .main) -> WhatsNew.Version {
        let versionString = bundle.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
        return .init(stringLiteral: versionString)
    }
}

// MARK: - WhatsNew.Feature

extension WhatsNew {
    /// A single feature to display in the "What's New" sheet.
    struct Feature: Hashable {
        /// SF Symbol name for the feature icon.
        let icon: String

        /// Short feature title.
        let title: String

        /// Longer description of the feature.
        let subtitle: String
    }
}
