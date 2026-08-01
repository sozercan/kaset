import Testing
@testable import Kaset

@Suite("Mock UI-test YouTube Music Library")
struct MockUITestYTMusicClientLibraryTests {
    @Test("Library albums use distinct browse and mutation identities")
    @MainActor
    func libraryAlbumsUseDistinctBrowseAndMutationIdentities() async throws {
        let content = try await MockUITestYTMusicClient().getLibraryContent()
        let browseIds = content.albums.map(\.id)
        let libraryTargetIds = try content.albums.map { album in
            try #require(album.libraryTargetId)
        }

        #expect(content.albums.count == 4)
        #expect(browseIds.allSatisfy { $0.hasPrefix("MPRE") })
        #expect(libraryTargetIds.allSatisfy { $0.hasPrefix("OLAK") })
        #expect(Set(browseIds).count == browseIds.count)
        #expect(Set(libraryTargetIds).count == libraryTargetIds.count)
        #expect(zip(browseIds, libraryTargetIds).allSatisfy { identityPair in identityPair.0 != identityPair.1 })
        for album in content.albums {
            #expect(album.hasNavigableId)
        }
    }

    @Test("Library album details preserve the matching mutation target")
    @MainActor
    func libraryAlbumDetailsPreserveMatchingMutationTarget() async throws {
        let client = MockUITestYTMusicClient()
        let content = try await client.getLibraryContent()
        let albums = content.albums

        for album in albums {
            let response = try await client.getPlaylist(id: album.id)

            #expect(response.detail.id == album.id)
            #expect(response.detail.title == album.title)
            #expect(response.detail.isAlbum)
            #expect(response.detail.libraryTargetId == album.libraryTargetId)
            #expect(!response.detail.tracks.isEmpty)
        }
    }
}
