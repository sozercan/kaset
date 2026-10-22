import AppKit
import SwiftUI
import Testing
@testable import Kaset

// MARK: - PlayerBarNavigationTests

@MainActor
@Suite(.serialized, .tags(.model))
struct PlayerBarNavigationTests {
    private static let artist = Artist(id: "UC_TEST_ARTIST", name: "Test Artist")
    private static let albumID = "MPREb_TEST_ALBUM"
    private static let albumPlaylistID = "OLAK5uy_TEST_ALBUM"

    private static func playlist(id: String, libraryTargetId: String? = nil) -> Playlist {
        Playlist(
            id: id,
            title: "Test Album",
            description: nil,
            thumbnailURL: nil,
            trackCount: nil,
            libraryTargetId: libraryTargetId
        )
    }

    // MARK: - Navigation

    @Test("appending(to:) pushes artists and albums onto the path")
    func appendingPushesOntoPath() {
        let store = PathStore()
        let action = PlayerBarNavigationAction.appending(to: store.binding)

        action.openArtist?(Self.artist)
        action.openAlbum?(Self.playlist(id: Self.albumID))

        #expect(store.path.count == 2)
    }

    @Test("Navigation applied to a NavigationStack reaches its root and pushed pages")
    func stackNavigationReachesPushedPages() throws {
        let store = PathStore()
        store.path.append("pushed")
        let probe = ActionProbe()

        let window = Self.host(
            NavigationStack(path: store.binding) {
                ActionReader(label: "root", probe: probe)
                    .navigationDestination(for: String.self) { ActionReader(label: $0, probe: probe) }
            }
            .playerBarMusicNavigation(path: store.binding)
        ) { probe.actions["root"] != nil && probe.actions["pushed"] != nil }
        defer { window.close() }

        let rootAction = try #require(probe.actions["root"])
        let pushedAction = try #require(probe.actions["pushed"])
        #expect(rootAction.openAlbum != nil)

        pushedAction.openArtist?(Self.artist)
        #expect(store.path.count == 2)
    }

    // MARK: - Current Route

    @Test("Only album pages report album IDs, including the loaded library alias")
    func albumIDsIncludeLibraryAlias() {
        let route = Self.playlist(id: Self.albumID)
        let detail = PlaylistDetail(playlist: route, tracks: [], libraryTargetId: Self.albumPlaylistID)

        #expect(PlayerBarCurrentRoute.albumIDs(for: route, detail: nil) == [Self.albumID])
        #expect(PlayerBarCurrentRoute.albumIDs(for: route, detail: detail) == [Self.albumID, Self.albumPlaylistID])
        #expect(PlayerBarCurrentRoute.albumIDs(for: Self.playlist(id: "PL_TEST"), detail: nil).isEmpty)
    }

    @Test("An album opened by its OLAK ID also reports the MPRE ID its tracks name")
    func albumIDsIncludeTrackAlbum() {
        let route = Self.playlist(id: Self.albumPlaylistID)
        let album = Album(id: Self.albumID, title: "Test Album", artists: nil, thumbnailURL: nil, year: nil, trackCount: nil)
        let unnamedAlbum = Album(id: UUID().uuidString, title: "Test Album", artists: nil, thumbnailURL: nil, year: nil, trackCount: nil)
        let detail = PlaylistDetail(
            playlist: route,
            tracks: [
                Song(id: "track-1", title: "Track 1", artists: [Self.artist], album: album, videoId: "video-1"),
                Song(id: "track-2", title: "Track 2", artists: [Self.artist], album: unnamedAlbum, videoId: "video-2"),
            ],
            libraryTargetId: Self.albumPlaylistID
        )

        #expect(PlayerBarCurrentRoute.albumIDs(for: route, detail: detail) == [Self.albumPlaylistID, Self.albumID])
    }

    @Test("Album targets match the current page through either album ID")
    func albumMatchesThroughAlias() {
        let routeIDs: Set = [Self.albumID, Self.albumPlaylistID]

        #expect(PlayerBarCurrentRoute.isAlbum(Self.playlist(id: Self.albumID), in: routeIDs))
        #expect(PlayerBarCurrentRoute.isAlbum(Self.playlist(id: Self.albumPlaylistID), in: routeIDs))
        #expect(PlayerBarCurrentRoute.isAlbum(
            Self.playlist(id: Self.albumID, libraryTargetId: Self.albumPlaylistID),
            in: [Self.albumPlaylistID]
        ))
        #expect(!PlayerBarCurrentRoute.isAlbum(Self.playlist(id: "MPREb_OTHER_ALBUM"), in: routeIDs))
        #expect(!PlayerBarCurrentRoute.isAlbum(Self.playlist(id: Self.albumID), in: []))
    }

    @Test("Artist targets match the current page by channel or library artist ID")
    func artistMatchesChannelID() {
        let libraryArtist = Artist(id: "MPLA\(Self.artist.id)", name: Self.artist.name)

        #expect(PlayerBarCurrentRoute.isArtist(Self.artist, routeArtistID: Self.artist.id))
        #expect(PlayerBarCurrentRoute.isArtist(libraryArtist, routeArtistID: Self.artist.id))
        #expect(!PlayerBarCurrentRoute.isArtist(Self.artist, routeArtistID: "UC_OTHER_ARTIST"))
        #expect(!PlayerBarCurrentRoute.isArtist(Self.artist, routeArtistID: nil))
    }

    // MARK: - Hosting

    private static func host(_ view: some View, until isReady: () -> Bool) -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: view)
        window.orderFrontRegardless()

        // The first hosted window in a test process can take seconds to warm up.
        let deadline = Date().addingTimeInterval(30)
        while !isReady(), Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        return window
    }
}

// MARK: - PathStore

@MainActor
private final class PathStore {
    var path = NavigationPath()

    var binding: Binding<NavigationPath> {
        Binding(get: { self.path }, set: { self.path = $0 })
    }
}

// MARK: - ActionProbe

@MainActor
private final class ActionProbe {
    var actions: [String: PlayerBarNavigationAction] = [:]
}

// MARK: - ActionReader

private struct ActionReader: View {
    let label: String
    let probe: ActionProbe
    @Environment(\.playerBarNavigationAction) private var action

    var body: some View {
        Text(self.label)
            .onAppear { self.probe.actions[self.label] = self.action }
    }
}
