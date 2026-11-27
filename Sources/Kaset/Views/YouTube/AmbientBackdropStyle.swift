import SwiftUI

enum AmbientBackdropStyle: String, CaseIterable, Identifiable {
    case off
    case soft
    case glow
    case live

    var id: String {
        self.rawValue
    }

    static var userSelectableCases: [AmbientBackdropStyle] {
        [.soft, .glow, .live]
    }

    var displayName: String {
        switch self {
        case .off: String(localized: "Off")
        case .soft: String(localized: "Soft")
        case .glow: String(localized: "Glow")
        case .live: String(localized: "Live (follows video)")
        }
    }
}
