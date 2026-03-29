import Foundation
import Testing
@testable import Kaset

// MARK: - WhatsNewVersionTests

@Suite(.tags(.model))
struct WhatsNewVersionTests {
    @Test("Parses full semver string")
    func parsesFullSemver() {
        let version: WhatsNew.Version = "1.2.3"
        #expect(version.major == 1)
        #expect(version.minor == 2)
        #expect(version.patch == 3)
    }

    @Test("Preserves prerelease suffixes")
    func preservesPrereleaseSuffix() {
        let version: WhatsNew.Version = "1.0.0-beta.1"
        #expect(version.major == 1)
        #expect(version.minor == 0)
        #expect(version.patch == 0)
        #expect(version.description == "1.0.0-beta.1")
    }

    @Test("Preserves dev suffixes")
    func preservesDevSuffix() {
        let version: WhatsNew.Version = "0.0.0-dev.abc123"
        #expect(version.description == "0.0.0-dev.abc123")
    }

    @Test("Parses two-component version")
    func parsesTwoComponents() {
        let version: WhatsNew.Version = "2.5"
        #expect(version.major == 2)
        #expect(version.minor == 5)
        #expect(version.patch == 0)
    }

    @Test("Parses single-component version")
    func parsesSingleComponent() {
        let version: WhatsNew.Version = "3"
        #expect(version.major == 3)
        #expect(version.minor == 0)
        #expect(version.patch == 0)
    }

    @Test("Parses empty string as 0.0.0")
    func parsesEmptyString() {
        let version: WhatsNew.Version = ""
        #expect(version.major == 0)
        #expect(version.minor == 0)
        #expect(version.patch == 0)
    }

    @Test("Description returns semver format")
    func description() {
        let version = WhatsNew.Version(major: 1, minor: 2, patch: 3)
        #expect(version.description == "1.2.3")
    }

    @Test("Versions compare correctly")
    func comparison() {
        let v100: WhatsNew.Version = "1.0.0"
        let v110: WhatsNew.Version = "1.1.0"
        let v111: WhatsNew.Version = "1.1.1"
        let v200: WhatsNew.Version = "2.0.0"

        #expect(v100 < v110)
        #expect(v110 < v111)
        #expect(v111 < v200)
        #expect(v100 < v200)
        #expect(!(v200 < v100))
    }

    @Test("Equal versions are equal")
    func equality() {
        let a = WhatsNew.Version(major: 1, minor: 0, patch: 0)
        let b: WhatsNew.Version = "1.0.0"
        #expect(a == b)
    }

    @Test("minorRelease sets patch to zero")
    func minorRelease() {
        let version = WhatsNew.Version(major: 1, minor: 2, patch: 5)
        let minor = version.minorRelease
        #expect(minor == WhatsNew.Version(major: 1, minor: 2, patch: 0))
    }

    @Test("minorRelease drops prerelease suffix")
    func minorReleaseDropsSuffix() {
        let version: WhatsNew.Version = "1.0.0-beta.1"
        #expect(version.minorRelease.description == "1.0.0")
    }

    @Test("Version is Codable")
    func codable() throws {
        let version = WhatsNew.Version(major: 2, minor: 3, patch: 4)
        let data = try JSONEncoder().encode(version)
        let decoded = try JSONDecoder().decode(WhatsNew.Version.self, from: data)
        #expect(decoded == version)
    }
}

// MARK: - WhatsNewVersionStoreTests

@Suite(.serialized, .tags(.service))
struct WhatsNewVersionStoreTests {
    private let defaults = UserDefaults(suiteName: "com.kaset.test.WhatsNewVersionStore")!

    init() {
        // Clean up before each test suite run
        self.defaults.removePersistentDomain(forName: "com.kaset.test.WhatsNewVersionStore")
    }

    @Test("Unpresented version returns false")
    func unpresentedVersion() {
        let store = WhatsNewVersionStore(defaults: self.defaults)
        let version: WhatsNew.Version = "1.0.0"
        #expect(!store.hasPresented(version))
    }

    @Test("Marking version as presented persists")
    func markPresented() {
        let store = WhatsNewVersionStore(defaults: self.defaults)
        let version: WhatsNew.Version = "1.0.0"

        store.markPresented(version)
        #expect(store.hasPresented(version))
    }

    @Test("Different versions are tracked independently")
    func independentVersions() {
        let store = WhatsNewVersionStore(defaults: self.defaults)
        let v100: WhatsNew.Version = "1.0.0"
        let v110: WhatsNew.Version = "1.1.0"

        store.markPresented(v100)
        #expect(store.hasPresented(v100))
        #expect(!store.hasPresented(v110))
    }

    @Test("Prerelease versions round-trip through the store")
    func prereleaseVersionRoundTrip() {
        let store = WhatsNewVersionStore(defaults: self.defaults)
        let version: WhatsNew.Version = "1.0.0-beta.1"

        store.markPresented(version)

        #expect(store.hasPresented(version))
        #expect(store.presentedVersions.contains(version))
    }

    @Test("presentedVersions returns all marked versions")
    func presentedVersions() {
        let store = WhatsNewVersionStore(defaults: self.defaults)
        let v100: WhatsNew.Version = "1.0.0"
        let v110: WhatsNew.Version = "1.1.0"

        store.markPresented(v100)
        store.markPresented(v110)

        let presented = store.presentedVersions
        #expect(presented.contains(v100))
        #expect(presented.contains(v110))
        #expect(presented.count == 2)
    }
}

// MARK: - WhatsNewProviderTests

@Suite(.serialized, .tags(.service))
struct WhatsNewProviderTests {
    private let defaults = UserDefaults(suiteName: "com.kaset.test.WhatsNewProvider")!

    init() {
        self.defaults.removePersistentDomain(forName: "com.kaset.test.WhatsNewProvider")
    }

    @Test("Returns WhatsNew for unpresented exact version")
    func exactVersionMatch() {
        let store = WhatsNewVersionStore(defaults: self.defaults)
        let result = WhatsNewProvider.staticWhatsNew(for: "1.0.0", store: store)
        #expect(result != nil)
        #expect(result?.version == "1.0.0")
    }

    @Test("Returns nil for already presented version")
    func alreadyPresentedVersion() {
        let store = WhatsNewVersionStore(defaults: self.defaults)
        store.markPresented("1.0.0")
        let result = WhatsNewProvider.staticWhatsNew(for: "1.0.0", store: store)
        #expect(result == nil)
    }

    @Test("Falls back to minor release version")
    func minorReleaseFallback() {
        let store = WhatsNewVersionStore(defaults: self.defaults)
        let result = WhatsNewProvider.staticWhatsNew(for: "1.0.2", store: store)
        #expect(result != nil)
        #expect(result?.version == "1.0.0")
    }

    @Test("Returns nil when minor release already presented")
    func minorReleaseAlreadyPresented() {
        let store = WhatsNewVersionStore(defaults: self.defaults)
        store.markPresented("1.0.0")
        let result = WhatsNewProvider.staticWhatsNew(for: "1.0.2", store: store)
        #expect(result == nil)
    }

    @Test("Returns nil for unknown version with no fallback")
    func unknownVersion() {
        let store = WhatsNewVersionStore(defaults: self.defaults)
        let result = WhatsNewProvider.staticWhatsNew(for: "99.0.0", store: store)
        #expect(result == nil)
    }

    @Test("Fallback collection is not empty")
    func collectionNotEmpty() {
        #expect(!WhatsNewProvider.fallbackCollection.isEmpty)
    }

    @Test("Each fallback entry has at least one feature")
    func entriesHaveFeatures() {
        for entry in WhatsNewProvider.fallbackCollection {
            #expect(!entry.features.isEmpty, "WhatsNew entry for \(entry.version.description) has no features")
        }
    }

    @Test("Can bypass presented-version gating for manual reopen")
    func bypassesPresentedVersionGating() async {
        let store = WhatsNewVersionStore(defaults: self.defaults)
        let session = MockURLProtocol.makeMockSession()
        store.markPresented("1.0.0")

        MockURLProtocol.requestHandler = { request in
            guard let url = request.url else {
                throw URLError(.badURL)
            }

            let body: [String: Any]
            let statusCode: Int

            if url.path == "/repos/sozercan/kaset/releases/tags/v1.0.0" {
                body = [
                    "tag_name": "v1.0.0",
                    "name": "What's New in Kaset 1.0.0",
                    "body": "Release notes",
                    "html_url": "https://github.com/sozercan/kaset/releases/tag/v1.0.0",
                ]
                statusCode = 200
            } else {
                body = [:]
                statusCode = 404
            }

            let data = try JSONSerialization.data(withJSONObject: body)
            guard let response = HTTPURLResponse(
                url: url,
                statusCode: statusCode,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            ) else {
                throw URLError(.badServerResponse)
            }

            return (response, data)
        }
        defer {
            MockURLProtocol.reset()
        }

        let result = await WhatsNewProvider.fetchWhatsNew(
            for: "1.0.0",
            store: store,
            respectingPresentedVersions: false,
            session: session
        )

        #expect(result?.version == "1.0.0")
        #expect(result?.releaseNotes == "Release notes")
    }

    @Test("Fetches the exact prerelease tag")
    func fetchesExactPrereleaseTag() async {
        let session = MockURLProtocol.makeMockSession()

        MockURLProtocol.requestHandler = { request in
            guard let url = request.url else {
                throw URLError(.badURL)
            }

            let body: [String: Any]
            let statusCode: Int

            if url.path == "/repos/sozercan/kaset/releases/tags/v1.0.0-beta.1" {
                body = [
                    "tag_name": "v1.0.0-beta.1",
                    "name": "1.0.0-beta.1",
                    "body": "Beta notes",
                    "html_url": "https://github.com/sozercan/kaset/releases/tag/v1.0.0-beta.1",
                ]
                statusCode = 200
            } else {
                body = [:]
                statusCode = 404
            }

            let data = try JSONSerialization.data(withJSONObject: body)
            guard let response = HTTPURLResponse(
                url: url,
                statusCode: statusCode,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            ) else {
                throw URLError(.badServerResponse)
            }

            return (response, data)
        }
        defer {
            MockURLProtocol.reset()
        }

        let result = await WhatsNewProvider.fetchWhatsNew(
            for: "1.0.0-beta.1",
            store: WhatsNewVersionStore(defaults: self.defaults),
            session: session
        )

        #expect(result?.version.description == "1.0.0-beta.1")
        #expect(result?.releaseNotes == "Beta notes")
    }

    @Test("Extracts the What's New section and normalizes CRLF release notes")
    func extractsWhatsNewSectionFromCRLFReleaseNotes() async {
        let session = MockURLProtocol.makeMockSession()

        MockURLProtocol.requestHandler = { request in
            guard let url = request.url else {
                throw URLError(.badURL)
            }

            let body: [String: Any]
            let statusCode: Int

            if url.path == "/repos/sozercan/kaset/releases/tags/v1.2.3" {
                body = [
                    "tag_name": "v1.2.3",
                    "name": "What's New in Kaset 1.2.3",
                    "body": "Star intro\r\n\r\n## What's New\r\n\r\n### Queue Enhancements\r\n\r\n- Faster queue updates\r\n\r\n## New Contributors\r\n\r\n- @new-contributor made their first contribution\r\n",
                    "html_url": "https://github.com/sozercan/kaset/releases/tag/v1.2.3",
                ]
                statusCode = 200
            } else {
                body = [:]
                statusCode = 404
            }

            let data = try JSONSerialization.data(withJSONObject: body)
            guard let response = HTTPURLResponse(
                url: url,
                statusCode: statusCode,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            ) else {
                throw URLError(.badServerResponse)
            }

            return (response, data)
        }
        defer {
            MockURLProtocol.reset()
        }

        let result = await WhatsNewProvider.fetchWhatsNew(
            for: "1.2.3",
            store: WhatsNewVersionStore(defaults: self.defaults),
            session: session
        )

        #expect(result?.releaseNotes == "### Queue Enhancements\n\n- Faster queue updates")
    }

    @Test("Preserves content inside What's New while dropping sibling wrapper sections")
    func preservesContentInsideWhatsNewSection() async {
        let session = MockURLProtocol.makeMockSession()

        MockURLProtocol.requestHandler = { request in
            guard let url = request.url else {
                throw URLError(.badURL)
            }

            let body: [String: Any]
            let statusCode: Int

            if url.path == "/repos/sozercan/kaset/releases/tags/v0.7.0" {
                body = [
                    "tag_name": "v0.7.0",
                    "name": "What's New in Kaset 0.7.0",
                    "body": """
                    Star intro

                    ## What's New

                    **Queue Enhancements**
                    New side panel mode with drag-and-drop reordering and queue persistence across app restarts

                    **Fixes and improvements**
                    - Uses the correct WebView signal for play/pause state
                    - Fixes duplicate window reopen behavior

                    ## New Contributors

                    - @new-contributor made their first contribution

                    ## Full Changelog

                    - https://github.com/sozercan/kaset/compare/v0.6.0...v0.7.0
                    """,
                    "html_url": "https://github.com/sozercan/kaset/releases/tag/v0.7.0",
                ]
                statusCode = 200
            } else {
                body = [:]
                statusCode = 404
            }

            let data = try JSONSerialization.data(withJSONObject: body)
            guard let response = HTTPURLResponse(
                url: url,
                statusCode: statusCode,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            ) else {
                throw URLError(.badServerResponse)
            }

            return (response, data)
        }
        defer {
            MockURLProtocol.reset()
        }

        let result = await WhatsNewProvider.fetchWhatsNew(
            for: "0.7.0",
            store: WhatsNewVersionStore(defaults: self.defaults),
            session: session
        )

        #expect(result?.releaseNotes == """
        **Queue Enhancements**
        New side panel mode with drag-and-drop reordering and queue persistence across app restarts

        **Fixes and improvements**
        - Uses the correct WebView signal for play/pause state
        - Fixes duplicate window reopen behavior
        """)
    }

    @Test("Strips hidden wrapper sections when no preferred section exists")
    func stripsHiddenWrapperSectionsWithoutWhatsNewHeading() async {
        let session = MockURLProtocol.makeMockSession()

        MockURLProtocol.requestHandler = { request in
            guard let url = request.url else {
                throw URLError(.badURL)
            }

            let body: [String: Any]
            let statusCode: Int

            if url.path == "/repos/sozercan/kaset/releases/tags/v0.8.0" {
                body = [
                    "tag_name": "v0.8.0",
                    "name": "What's New in Kaset 0.8.0",
                    "body": """
                    Brief summary

                    ## Installation

                    - Drag Kaset to Applications

                    ## Verification

                    - SHA256: abc123
                    """,
                    "html_url": "https://github.com/sozercan/kaset/releases/tag/v0.8.0",
                ]
                statusCode = 200
            } else {
                body = [:]
                statusCode = 404
            }

            let data = try JSONSerialization.data(withJSONObject: body)
            guard let response = HTTPURLResponse(
                url: url,
                statusCode: statusCode,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            ) else {
                throw URLError(.badServerResponse)
            }

            return (response, data)
        }
        defer {
            MockURLProtocol.reset()
        }

        let result = await WhatsNewProvider.fetchWhatsNew(
            for: "0.8.0",
            store: WhatsNewVersionStore(defaults: self.defaults),
            session: session
        )

        #expect(result?.releaseNotes == "Brief summary")
    }
}
