import AppKit
import Testing
@testable import Kaset

// MARK: - CopyLinkSharingPickerDelegateTests

@Suite("Share picker Copy Link", .tags(.service))
@MainActor
struct CopyLinkSharingPickerDelegateTests {
    private static let link = "https://music.youtube.com/watch?v=test-video"
    private let delegate = CopyLinkSharingPickerDelegate()

    private func services(for items: [Any], proposed: [NSSharingService]) -> [NSSharingService] {
        self.delegate.sharingServicePicker(
            NSSharingServicePicker(items: items),
            sharingServicesForItems: items,
            proposedSharingServices: proposed
        )
    }

    private func service(titled title: String) -> NSSharingService {
        NSSharingService(title: title, image: NSImage(), alternateImage: nil) {}
    }

    @Test("Copy Link comes first, followed by the proposed services in order")
    func prependsCopyLink() throws {
        let url = try #require(URL(string: Self.link))
        let proposed = [self.service(titled: "AirDrop"), self.service(titled: "Mail")]

        let services = self.services(for: [url], proposed: proposed)

        #expect(services.map(\.title) == [String(localized: "Copy Link"), "AirDrop", "Mail"])
    }

    @Test("Copy Link is not added when the system already proposes one")
    func skipsDuplicateCopyLink() throws {
        let url = try #require(URL(string: Self.link))
        let proposed = [self.service(titled: String(localized: "Copy Link").uppercased()), self.service(titled: "Mail")]

        let services = self.services(for: [url], proposed: proposed)

        #expect(services == proposed)
    }

    @Test("Copy Link is not added when no item is a URL")
    func skipsNonURLItems() {
        let proposed = [self.service(titled: "Mail")]

        let services = self.services(for: ["not a url"], proposed: proposed)

        #expect(services == proposed)
    }

    @Test("Copying writes the link as both a URL and a string")
    func copyWritesURLAndString() throws {
        let url = try #require(URL(string: Self.link))
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.setString("stale", forType: .string)

        CopyLinkSharingPickerDelegate.copy(url, to: pasteboard)

        #expect(pasteboard.string(forType: .string) == Self.link)
        #expect(pasteboard.string(forType: .URL) == Self.link)
    }
}
