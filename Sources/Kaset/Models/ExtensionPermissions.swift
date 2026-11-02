import Foundation
import WebKit

// MARK: - ExtensionPermissions

/// The access Kaset grants when loading an extension. Optional permissions are excluded.
struct ExtensionPermissions: Codable, Equatable {
    let permissions: [String]
    let websitePatterns: [String]

    @MainActor
    init(webExtension: WKWebExtension) {
        self.permissions = webExtension.requestedPermissions.map(\.rawValue).sorted()
        let contentMatches = WebKitManager.contentScriptMatchPatterns(from: webExtension.manifest)
        self.websitePatterns = Set(
            webExtension.requestedPermissionMatchPatterns.map(\.string) + contentMatches.map(\.string)
        ).sorted()
    }
}

// MARK: - ExtensionPermissionReview

struct ExtensionPermissionReview: Identifiable {
    let id: String
    let name: String
    let permissions: ExtensionPermissions
}

// MARK: - ExtensionConsentError

enum ExtensionConsentError: LocalizedError {
    case unavailable
    case accessChanged

    var errorDescription: String? {
        switch self {
        case .unavailable:
            String(localized: "The extension could not be read. Remove it and add it again.")
        case .accessChanged:
            String(localized: "The extension's access changed. Review it again before enabling it.")
        }
    }
}
