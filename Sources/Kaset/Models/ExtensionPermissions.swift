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

    var requestsPageAccess: Bool {
        !self.websitePatterns.isEmpty || self.permissions.contains("activeTab") || self.permissions.contains("scripting")
    }

    @MainActor
    static func websiteName(for pattern: String) -> String {
        guard let match = try? WKWebExtension.MatchPattern(string: pattern) else { return pattern }
        if match.scheme == "file" {
            return String(localized: "Webpages opened from files")
        }
        if match.matchesAllURLs || match.host == "*" {
            return String(localized: "All websites")
        }
        guard let host = match.host else { return pattern }
        switch host {
        case "music.youtube.com":
            return String(localized: "YouTube Music")
        case "youtube.com", "www.youtube.com":
            return String(localized: "YouTube")
        case "*.youtube.com":
            return String(localized: "All YouTube websites")
        case "accounts.google.com":
            return String(localized: "Google sign-in")
        default:
            if host.hasPrefix("*.") {
                let domain = String(host.dropFirst(2))
                return String(localized: "All \(domain) websites")
            }
            return host
        }
    }

    static func accessDescription(for permission: String) -> ExtensionAccessDescription? {
        switch permission {
        case "cookies":
            ExtensionAccessDescription(symbol: "person.crop.circle.badge.exclamationmark", title: String(localized: "Access your sign-in data"), detail: String(localized: "This could let it act as you on websites where you’re signed in."))
        case "storage":
            ExtensionAccessDescription(symbol: "archivebox", title: String(localized: "Save information"), detail: String(localized: "Remember its settings and other data."))
        case "unlimitedStorage":
            ExtensionAccessDescription(symbol: "externaldrive", title: String(localized: "Use more storage"), detail: String(localized: "Save data without the usual storage limit."))
        case "activeTab":
            ExtensionAccessDescription(symbol: "doc.text", title: String(localized: "Access the page you’re using"), detail: String(localized: "Access a page after you interact with the extension."))
        case "alarms":
            ExtensionAccessDescription(symbol: "clock", title: String(localized: "Run tasks later"), detail: String(localized: "Schedule its own background tasks."))
        case "clipboardWrite":
            ExtensionAccessDescription(symbol: "doc.on.clipboard", title: String(localized: "Copy information"), detail: String(localized: "Replace what you last copied."))
        case "contextMenus", "menus":
            ExtensionAccessDescription(symbol: "cursorarrow.click", title: String(localized: "Add menu options"), detail: String(localized: "Add its own actions to right-click menus."))
        case "tabs":
            ExtensionAccessDescription(symbol: "rectangle.on.rectangle", title: String(localized: "See what’s open in Kaset"), detail: String(localized: "Read the names and addresses of its webpages."))
        case "webNavigation":
            ExtensionAccessDescription(symbol: "arrow.triangle.branch", title: String(localized: "Follow page changes"), detail: String(localized: "See when pages open or change in Kaset."))
        case "webRequest":
            ExtensionAccessDescription(symbol: "network", title: String(localized: "See website connections"), detail: String(localized: "See how pages connect to websites it can access."))
        case "declarativeNetRequest", "declarativeNetRequestWithHostAccess":
            ExtensionAccessDescription(symbol: "line.3.horizontal.decrease.circle", title: String(localized: "Change website connections"), detail: String(localized: "Block connections or send them to another website."))
        case "declarativeNetRequestFeedback":
            ExtensionAccessDescription(symbol: "network", title: String(localized: "See details of website connections"), detail: String(localized: "Check which connections matched its rules."))
        case "scripting":
            ExtensionAccessDescription(symbol: "wand.and.stars", title: String(localized: "Change webpages"), detail: String(localized: "Run its own code on websites it can access."))
        case "nativeMessaging":
            ExtensionAccessDescription(symbol: "app.connected.to.app.below.fill", title: String(localized: "Talk to a companion app"), detail: String(localized: "Request a connection to its companion app."))
        default:
            nil
        }
    }
}

// MARK: - ExtensionAccessDescription

struct ExtensionAccessDescription: Equatable {
    let symbol: String
    let title: String
    let detail: String
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
