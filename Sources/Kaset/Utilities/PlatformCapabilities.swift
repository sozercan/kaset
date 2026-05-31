// MARK: - PlatformCapabilities

/// Runtime feature gates for APIs that are unavailable on older macOS versions.
enum PlatformCapabilities {
    /// Foundation Models-backed features require macOS 26+.
    static var supportsFoundationModels: Bool {
        if #available(macOS 26.0, *) {
            true
        } else {
            false
        }
    }

    /// The command bar is backed by Foundation Models types and is macOS 26+ only.
    static var supportsCommandBar: Bool {
        if #available(macOS 26.0, *) {
            true
        } else {
            false
        }
    }
}
