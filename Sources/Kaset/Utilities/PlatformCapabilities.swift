// MARK: - PlatformCapabilities

/// Runtime feature gates for APIs that are unavailable on older macOS versions.
enum PlatformCapabilities {
    /// Foundation Models-backed features require macOS 26+.
    static var supportsFoundationModels: Bool {
        Self.supportsFoundationModels(usesLegacyMacOS15UI: false)
    }

    /// Foundation Models-backed UI should be suppressed when debugging the legacy macOS 15 UI.
    static func supportsFoundationModels(usesLegacyMacOS15UI: Bool) -> Bool {
        guard !usesLegacyMacOS15UI else { return false }

        if #available(macOS 26.0, *) {
            return true
        } else {
            return false
        }
    }

    /// The command bar is backed by Foundation Models types and is macOS 26+ only.
    static var supportsCommandBar: Bool {
        Self.supportsCommandBar(usesLegacyMacOS15UI: false)
    }

    /// The command bar is hidden when the legacy macOS 15 UI is being debugged.
    static func supportsCommandBar(usesLegacyMacOS15UI: Bool) -> Bool {
        guard self.supportsFoundationModels(usesLegacyMacOS15UI: usesLegacyMacOS15UI) else {
            return false
        }

        if #available(macOS 26.0, *) {
            return true
        } else {
            return false
        }
    }
}
