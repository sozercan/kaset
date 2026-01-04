import Foundation
import Testing
@testable import Kaset

/// Tests for FavoritesManager using Swift Testing.
@Suite("FavoritesManager", .serialized, .tags(.service), .timeLimit(.minutes(1)))
@MainActor
struct FavoritesManagerTests {
    // Use a fresh manager for each test (skipLoad to avoid disk state)
    var manager: FavoritesManager

    init() {
        self.manager = FavoritesManager(skipLoad: true)
    }

    // MARK: - Basic Operations

    @Test("Initial state is empty")
    func initialState() {
        #expect(self.manager.items.isEmpty)
        #expect(self.manager.isVisible == false)
    }

    @Test("Add song succeeds")
    func addSong() {
        let song = TestFixtures.makeSong(id: "test-song-1")
        let item = FavoriteItem.from(song)

        self.manager.add(item)

        #expect(self.manager.items.count == 1)
        #expect(self.manager.isVisible == true)
        #expect(self.manager.isPinned(song: song) == true)
    }

    @Test("Add album succeeds")
    func addAlbum() {
        let album = TestFixtures.makeAlbum(id: "MPRE-test-album")
        let item = FavoriteItem.from(album)

        self.manager.add(item)

        #expect(self.manager.items.count == 1)
        #expect(self.manager.isPinned(album: album) == true)
    }

    @Test("Add playlist succeeds")
    func addPlaylist() {
        let playlist = TestFixtures.makePlaylist(id: "VL-test-playlist")
        let item = FavoriteItem.from(playlist)

        self.manager.add(item)

        #expect(self.manager.items.count == 1)
        #expect(self.manager.isPinned(playlist: playlist) == true)
    }

    @Test("Add artist succeeds")
    func addArtist() {
        let artist = TestFixtures.makeArtist(id: "UC-test-artist")
        let item = FavoriteItem.from(artist)

        self.manager.add(item)

        #expect(self.manager.items.count == 1)
        #expect(self.manager.isPinned(artist: artist) == true)
    }

    @Test("Add duplicate is ignored")
    func addDuplicateIgnored() {
        let song = TestFixtures.makeSong(id: "duplicate-song")
        let item1 = FavoriteItem.from(song)
        let item2 = FavoriteItem.from(song)

        self.manager.add(item1)
        self.manager.add(item2)

        #expect(self.manager.items.count == 1)
    }

    @Test("New items added to front")
    func newItemsAddedToFront() {
        let song1 = TestFixtures.makeSong(id: "song-1", title: "First Song")
        let song2 = TestFixtures.makeSong(id: "song-2", title: "Second Song")

        self.manager.add(.from(song1))
        self.manager.add(.from(song2))

        #expect(self.manager.items.count == 2)
        #expect(self.manager.items[0].title == "Second Song")
        #expect(self.manager.items[1].title == "First Song")
    }

    // MARK: - Remove Operations

    @Test("Remove by contentId succeeds")
    func removeByContentId() {
        let song = TestFixtures.makeSong(id: "remove-test")
        self.manager.add(.from(song))
        #expect(self.manager.items.count == 1)

        self.manager.remove(contentId: song.videoId)

        #expect(self.manager.items.isEmpty)
        #expect(self.manager.isPinned(song: song) == false)
    }

    @Test("Remove non-existent item is no-op")
    func removeNonExistent() {
        let song = TestFixtures.makeSong(id: "existing")
        self.manager.add(.from(song))

        self.manager.remove(contentId: "non-existent")

        #expect(self.manager.items.count == 1)
    }

    // MARK: - Toggle Operations

    @Test("Toggle adds then removes")
    func toggleAddsAndRemoves() {
        let song = TestFixtures.makeSong(id: "toggle-test")

        // First toggle should add
        self.manager.toggle(song: song)
        #expect(self.manager.isPinned(song: song) == true)
        #expect(self.manager.items.count == 1)

        // Second toggle should remove
        self.manager.toggle(song: song)
        #expect(self.manager.isPinned(song: song) == false)
        #expect(self.manager.items.isEmpty)
    }

    // MARK: - Move Operations

    @Test("Move item changes position")
    func moveItem() {
        let song1 = TestFixtures.makeSong(id: "move-1", title: "Song 1")
        let song2 = TestFixtures.makeSong(id: "move-2", title: "Song 2")
        let song3 = TestFixtures.makeSong(id: "move-3", title: "Song 3")

        self.manager.add(.from(song1))
        self.manager.add(.from(song2))
        self.manager.add(.from(song3))

        // Order is now: song3, song2, song1 (newest first)
        #expect(self.manager.items[0].title == "Song 3")
        #expect(self.manager.items[1].title == "Song 2")
        #expect(self.manager.items[2].title == "Song 1")

        // Move song1 (index 2) to index 0
        self.manager.move(from: IndexSet(integer: 2), to: 0)

        #expect(self.manager.items[0].title == "Song 1")
        #expect(self.manager.items[1].title == "Song 3")
        #expect(self.manager.items[2].title == "Song 2")
    }

    @Test("Move to top succeeds")
    func moveToTop() {
        let song1 = TestFixtures.makeSong(id: "top-1", title: "Song 1")
        let song2 = TestFixtures.makeSong(id: "top-2", title: "Song 2")
        let song3 = TestFixtures.makeSong(id: "top-3", title: "Song 3")

        self.manager.add(.from(song1))
        self.manager.add(.from(song2))
        self.manager.add(.from(song3))

        // Order is: song3, song2, song1
        // Move song1 to top
        self.manager.moveToTop(contentId: song1.videoId)

        #expect(self.manager.items[0].title == "Song 1")
    }

    @Test("Move to end succeeds")
    func moveToEnd() {
        let song1 = TestFixtures.makeSong(id: "end-1", title: "Song 1")
        let song2 = TestFixtures.makeSong(id: "end-2", title: "Song 2")
        let song3 = TestFixtures.makeSong(id: "end-3", title: "Song 3")

        self.manager.add(.from(song1))
        self.manager.add(.from(song2))
        self.manager.add(.from(song3))

        // Order is: song3, song2, song1
        // Move song3 to end
        self.manager.moveToEnd(contentId: song3.videoId)

        #expect(self.manager.items[2].title == "Song 3")
    }

    // MARK: - isPinned Checks

    @Test("isPinned returns correct state")
    func isPinnedReturnsCorrectState() {
        let song = TestFixtures.makeSong(id: "pinned-test")

        #expect(self.manager.isPinned(song: song) == false)
        #expect(self.manager.isPinned(contentId: song.videoId) == false)

        self.manager.add(.from(song))

        #expect(self.manager.isPinned(song: song) == true)
        #expect(self.manager.isPinned(contentId: song.videoId) == true)
    }

    // MARK: - Clear All

    @Test("Clear all removes all items")
    func clearAllRemovesAll() {
        self.manager.add(.from(TestFixtures.makeSong(id: "clear-1")))
        self.manager.add(.from(TestFixtures.makeSong(id: "clear-2")))
        self.manager.add(.from(TestFixtures.makeSong(id: "clear-3")))

        #expect(self.manager.items.count == 3)

        self.manager.clearAll()

        #expect(self.manager.items.isEmpty)
        #expect(self.manager.isVisible == false)
    }

    // MARK: - FavoriteItem Model Tests

    @Test("FavoriteItem contentId returns correct value")
    func favoriteItemContentId() {
        let song = TestFixtures.makeSong(id: "content-id-test")
        let album = TestFixtures.makeAlbum(id: "MPRE-content-album")
        let playlist = TestFixtures.makePlaylist(id: "VL-content-playlist")
        let artist = TestFixtures.makeArtist(id: "UC-content-artist")

        let songItem = FavoriteItem.from(song)
        let albumItem = FavoriteItem.from(album)
        let playlistItem = FavoriteItem.from(playlist)
        let artistItem = FavoriteItem.from(artist)

        #expect(songItem.contentId == song.videoId)
        #expect(albumItem.contentId == album.id)
        #expect(playlistItem.contentId == playlist.id)
        #expect(artistItem.contentId == artist.id)
    }

    @Test("FavoriteItem title returns correct value")
    func favoriteItemTitle() {
        let song = TestFixtures.makeSong(title: "Test Song Title")
        let album = TestFixtures.makeAlbum(title: "Test Album Title")

        let songItem = FavoriteItem.from(song)
        let albumItem = FavoriteItem.from(album)

        #expect(songItem.title == "Test Song Title")
        #expect(albumItem.title == "Test Album Title")
    }

    @Test("FavoriteItem subtitle returns correct value")
    func favoriteItemSubtitle() {
        let song = TestFixtures.makeSong(artistName: "Test Artist")
        let album = TestFixtures.makeAlbum(artistName: "Album Artist")

        let songItem = FavoriteItem.from(song)
        let albumItem = FavoriteItem.from(album)

        #expect(songItem.subtitle == "Test Artist")
        #expect(albumItem.subtitle == "Album Artist")
    }

    @Test("FavoriteItem typeLabel returns correct value")
    func favoriteItemTypeLabel() {
        let songItem = FavoriteItem.from(TestFixtures.makeSong())
        let albumItem = FavoriteItem.from(TestFixtures.makeAlbum())
        let playlistItem = FavoriteItem.from(TestFixtures.makePlaylist())
        let artistItem = FavoriteItem.from(TestFixtures.makeArtist())

        #expect(songItem.typeLabel == "Song")
        #expect(albumItem.typeLabel == "Album")
        #expect(playlistItem.typeLabel == "Playlist")
        #expect(artistItem.typeLabel == "Artist")
    }

    @Test("FavoriteItem equality based on contentId")
    func favoriteItemEquality() {
        let song = TestFixtures.makeSong(id: "same-id")
        let item1 = FavoriteItem.from(song)
        let item2 = FavoriteItem.from(song)

        // Should be equal even though they have different UUIDs
        #expect(item1 == item2)
        #expect(item1.hashValue == item2.hashValue)
    }

    @Test("FavoriteItem asHomeSectionItem conversion")
    func favoriteItemAsHomeSectionItem() {
        let song = TestFixtures.makeSong(id: "convert-test", title: "Convert Song")
        let item = FavoriteItem.from(song)

        guard let homeSectionItem = item.asHomeSectionItem else {
            Issue.record("Expected non-nil HomeSectionItem")
            return
        }
        #expect(homeSectionItem.title == "Convert Song")
        if case let .song(convertedSong) = homeSectionItem {
            #expect(convertedSong.videoId == "convert-test")
        } else {
            Issue.record("Expected song type")
        }
    }
}
