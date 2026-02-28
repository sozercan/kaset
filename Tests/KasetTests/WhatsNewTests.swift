import Foundation
import Testing
@testable import Kaset

// MARK: - WhatsNewVersionTests

@Suite("WhatsNew.Version", .tags(.model))
struct WhatsNewVersionTests {
    @Test("Parses full semver string")
    func parsesFullSemver() {
        let version: WhatsNew.Version = "1.2.3"
        #expect(version.major == 1)
        #expect(version.minor == 2)
        #expect(version.patch == 3)
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

    @Test("Version is Codable")
    func codable() throws {
        let version = WhatsNew.Version(major: 2, minor: 3, patch: 4)
        let data = try JSONEncoder().encode(version)
        let decoded = try JSONDecoder().decode(WhatsNew.Version.self, from: data)
        #expect(decoded == version)
    }
}

// MARK: - WhatsNewVersionStoreTests

@Suite("WhatsNewVersionStore", .serialized, .tags(.service))
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

@Suite("WhatsNewProvider", .serialized, .tags(.service))
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
}
