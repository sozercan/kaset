import Foundation
import Testing
@testable import Kaset

@MainActor
struct SidebarPinnedItemsManagerTests {
    var manager: SidebarPinnedItemsManager

    init() {
        self.manager = SidebarPinnedItemsManager(skipLoad: true)
    }

    @Test("Adds playlist and album pins in insertion order")
    func addsPlaylistAndAlbumPins() {
        let playlist = SidebarPinnedItem.from(TestFixtures.makePlaylist(id: "VL-playlist-1", title: "Road Mix"))
        let album = SidebarPinnedItem.from(TestFixtures.makeAlbum(id: "MPRE-album-1", title: "Night Album"))

        self.manager.add(playlist)
        self.manager.add(album)

        #expect(self.manager.items.map(\.contentId) == ["VL-playlist-1", "MPRE-album-1"])
        #expect(self.manager.isPinned(playlist) == true)
        #expect(self.manager.isPinned(album) == true)
    }

    @Test("Does not add duplicate sidebar pins")
    func ignoresDuplicatePins() {
        let playlist = SidebarPinnedItem.from(TestFixtures.makePlaylist(id: "VL-playlist-1", title: "Road Mix"))

        self.manager.add(playlist)
        self.manager.add(playlist)

        #expect(self.manager.items.count == 1)
    }

    @Test("Treats raw and browse playlist IDs as the same pin")
    func ignoresEquivalentPlaylistAliases() {
        let rawPlaylist = SidebarPinnedItem.from(TestFixtures.makePlaylist(id: "PL-playlist-1", title: "Road Mix"))
        let browsePlaylist = SidebarPinnedItem.from(TestFixtures.makePlaylist(id: "VLPL-playlist-1", title: "Road Mix"))

        self.manager.add(rawPlaylist)
        self.manager.add(browsePlaylist)

        #expect(self.manager.items.map(\.contentId) == ["PL-playlist-1"])
        #expect(self.manager.isPinned(browsePlaylist))
    }

    @Test("Toggles pins on and off")
    func togglesPins() {
        let album = SidebarPinnedItem.from(TestFixtures.makeAlbum(id: "MPRE-album-1", title: "Night Album"))

        self.manager.toggle(album)
        #expect(self.manager.isPinned(album) == true)

        self.manager.toggle(album)
        #expect(self.manager.isPinned(album) == false)
    }

    @Test("Toggling an equivalent playlist alias removes every persisted alias")
    func togglesEquivalentPlaylistAlias() {
        let rawPlaylist = SidebarPinnedItem.from(TestFixtures.makePlaylist(id: "PL-playlist-1", title: "Road Mix"))
        let browsePlaylist = SidebarPinnedItem.from(TestFixtures.makePlaylist(id: "VLPL-playlist-1", title: "Road Mix"))
        self.manager.reset(with: [rawPlaylist, browsePlaylist])

        self.manager.toggle(browsePlaylist)

        #expect(self.manager.items.isEmpty)
    }

    @Test("Removes and restores every persisted alias of a playlist")
    func removesAndRestoresEveryPlaylistAlias() {
        let rawPlaylist = SidebarPinnedItem.from(TestFixtures.makePlaylist(id: "PL-playlist-1", title: "Road Mix"))
        let album = SidebarPinnedItem.from(TestFixtures.makeAlbum(id: "MPRE-album-1", title: "Night Album"))
        let browsePlaylist = SidebarPinnedItem.from(TestFixtures.makePlaylist(id: "VLPL-playlist-1", title: "Road Mix"))
        self.manager.reset(with: [rawPlaylist, album, browsePlaylist])

        let removedPins = self.manager.removePlaylistPins(matching: "VLPL-playlist-1")

        #expect(removedPins.map(\.item.contentId) == ["PL-playlist-1", "VLPL-playlist-1"])
        #expect(self.manager.items.map(\.contentId) == ["MPRE-album-1"])

        self.manager.restore(removedPins)

        #expect(self.manager.items.map(\.contentId) == ["PL-playlist-1", "MPRE-album-1", "VLPL-playlist-1"])
    }

    @Test("Moves pins by drag source and destination")
    func movesPins() {
        let first = SidebarPinnedItem.from(TestFixtures.makePlaylist(id: "VL-first", title: "First"))
        let second = SidebarPinnedItem.from(TestFixtures.makePlaylist(id: "VL-second", title: "Second"))
        let third = SidebarPinnedItem.from(TestFixtures.makeAlbum(id: "MPRE-third", title: "Third"))
        self.manager.reset(with: [first, second, third])

        self.manager.move(from: IndexSet(integer: 0), to: 3)

        #expect(self.manager.items.map(\.contentId) == ["VL-second", "MPRE-third", "VL-first"])
    }

    @Test("Classifies one-track albums as singles")
    func classifiesSingles() {
        let singleAlbum = Album(
            id: "MPRE-single",
            title: "One Song",
            artists: [Artist(id: "UC123", name: "Artist")],
            thumbnailURL: nil,
            year: "2026",
            trackCount: 1
        )
        let single = SidebarPinnedItem.from(singleAlbum)

        #expect(single.typeLabel == "Single")
        #expect(single.systemImage == "music.note")
    }
}
