import Foundation

struct WhatsNewVersionStore: @unchecked Sendable {
    private static let keyPrefix = "com.kaset.whatsNew.presented."

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func hasPresented(_ version: WhatsNew.Version) -> Bool {
        self.defaults.bool(forKey: Self.key(for: version))
    }

    var presentedVersions: [WhatsNew.Version] {
        self.defaults.dictionaryRepresentation()
            .keys
            .filter { $0.hasPrefix(Self.keyPrefix) }
            .map { key in
                let versionString = String(key.dropFirst(Self.keyPrefix.count))
                return WhatsNew.Version(stringLiteral: versionString)
            }
    }

    func markPresented(_ version: WhatsNew.Version) {
        self.defaults.set(true, forKey: Self.key(for: version))
    }

    private static func key(for version: WhatsNew.Version) -> String {
        "\(self.keyPrefix)\(version.description)"
    }
}
