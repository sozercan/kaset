import Testing
@testable import Kaset

@Suite(.serialized, .tags(.model))
@MainActor
struct ExtensionAccessSummaryTests {
    @Test("Unrelated websites cannot be presented as YouTube Music", arguments: [
        "music.youtube.com.evil.example",
        "not-youtube.com",
        "example.com",
    ])
    func unrelatedWebsitesKeepTheirIdentity(host: String) {
        #expect(ExtensionPermissions.websiteName(for: "https://\(host)/*") == host)
    }

    @Test("Broad website access is clearly described", arguments: ["<all_urls>", "*://*/*", "https://*/*"])
    func broadAccessIsNotNarrowed(pattern: String) {
        #expect(ExtensionPermissions.websiteName(for: pattern) == String(localized: "All websites"))
    }

    @Test("Wildcard domains retain the actual requested domain")
    func wildcardDomainIsVisible() {
        #expect(ExtensionPermissions.websiteName(for: "https://*.example.com/*") == String(localized: "All \("example.com") websites"))
    }

    @Test("Local file pages are not described as website-only access", arguments: ["file:///*", "file://*/*"])
    func localFileAccessIsVisible(pattern: String) {
        #expect(ExtensionPermissions.websiteName(for: pattern) == String(localized: "Webpages opened from files"))
    }

    @Test("Unrecognized permissions require the technical-review fallback")
    func unknownPermissionIsNotGivenAnInventedDescription() {
        #expect(ExtensionPermissions.accessDescription(for: "futurePermission") == nil)
    }
}
