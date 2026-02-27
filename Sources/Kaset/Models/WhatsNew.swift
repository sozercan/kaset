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
    struct Version: Hashable, Comparable, Codable, Sendable {
        let major: Int
        let minor: Int
        let patch: Int

        init(major: Int, minor: Int, patch: Int) {
            self.major = major
            self.minor = minor
            self.patch = patch
        }

        /// Returns the minor-release version (patch set to 0).
        var minorRelease: Version {
            Version(major: self.major, minor: self.minor, patch: 0)
        }

        // MARK: Comparable

        static func < (lhs: Version, rhs: Version) -> Bool {
            if lhs.major != rhs.major { return lhs.major < rhs.major }
            if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
            return lhs.patch < rhs.patch
        }

        // MARK: CustomStringConvertible

        var description: String {
            "\(self.major).\(self.minor).\(self.patch)"
        }
    }
}

// MARK: - WhatsNew.Version + ExpressibleByStringLiteral

extension WhatsNew.Version: ExpressibleByStringLiteral {
    init(stringLiteral value: String) {
        let parts = value.components(separatedBy: ".").compactMap(Int.init)
        self.major = parts.indices.contains(0) ? parts[0] : 0
        self.minor = parts.indices.contains(1) ? parts[1] : 0
        self.patch = parts.indices.contains(2) ? parts[2] : 0
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
    struct Feature: Hashable, Sendable {
        /// SF Symbol name for the feature icon.
        let icon: String

        /// Short feature title.
        let title: String

        /// Longer description of the feature.
        let subtitle: String
    }
}
