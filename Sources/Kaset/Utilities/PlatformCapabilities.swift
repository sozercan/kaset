enum PlatformCapabilities {
    static var supportsFoundationModels: Bool {
        Self.supportsFoundationModels(usesLegacyMacOS15UI: false)
    }

    static func supportsFoundationModels(usesLegacyMacOS15UI: Bool) -> Bool {
        guard !usesLegacyMacOS15UI else { return false }

        if #available(macOS 26.0, *) {
            return true
        } else {
            return false
        }
    }

    static var supportsCommandBar: Bool {
        Self.supportsCommandBar(usesLegacyMacOS15UI: false)
    }

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
