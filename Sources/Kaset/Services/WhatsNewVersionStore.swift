import Foundation

// MARK: - WhatsNewVersionStore

/// Persists which app versions have had their "What's New" sheet presented.
struct WhatsNewVersionStore: @unchecked Sendable {
    /// UserDefaults key prefix for presented versions.
    private static let keyPrefix = "com.kaset.whatsNew.presented."

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: - Read

    /// Whether the given version has already been presented.
    func hasPresented(_ version: WhatsNew.Version) -> Bool {
        self.defaults.bool(forKey: Self.key(for: version))
    }

    /// All versions that have been marked as presented.
    var presentedVersions: [WhatsNew.Version] {
        self.defaults.dictionaryRepresentation()
            .keys
            .filter { $0.hasPrefix(Self.keyPrefix) }
            .map { key in
                let versionString = String(key.dropFirst(Self.keyPrefix.count))
                return WhatsNew.Version(stringLiteral: versionString)
            }
    }

    // MARK: - Write

    /// Marks a version as presented so it won't be shown again.
    func markPresented(_ version: WhatsNew.Version) {
        self.defaults.set(true, forKey: Self.key(for: version))
    }

    // MARK: - Private

    private static func key(for version: WhatsNew.Version) -> String {
        "\(self.keyPrefix)\(version.description)"
    }
}
