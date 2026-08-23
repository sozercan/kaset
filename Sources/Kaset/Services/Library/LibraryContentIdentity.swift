import Foundation

/// Centralizes Library identity semantics that YouTube Music exposes through multiple ID shapes.
///
/// Library playlist tiles can surface either a `VL...` browse ID or the raw playlist ID, while
/// followed artists can surface as `MPLAUC...` library browse IDs or public `UC...` channel IDs.
/// This module gives parsers, view models, and test adapters one interface for equality,
/// canonical artist values, and stable de-duplication.
enum LibraryContentIdentity {
    static func playlistKey(for playlistID: String) -> String {
        if playlistID.hasPrefix("VL") {
            return String(playlistID.dropFirst(2))
        }

        return playlistID
    }

    static func playlistKey(for playlist: Playlist) -> String {
        self.playlistKey(for: playlist.id)
    }

    static func artistKey(for artistID: String) -> String {
        Artist.publicChannelId(for: artistID) ?? artistID
    }

    static func artistKey(for artist: Artist) -> String {
        self.artistKey(for: artist.id)
    }

    static func albumKey(albumId: String, targetPlaylistId: String? = nil) -> String {
        targetPlaylistId ?? albumId
    }

    static func albumKey(for album: Album) -> String {
        self.albumKey(albumId: album.id, targetPlaylistId: album.libraryTargetId)
    }

    static func albumKeys(for album: Album) -> Set<String> {
        var keys = Set([album.id])
        if let libraryTargetId = album.libraryTargetId {
            keys.insert(libraryTargetId)
        }
        return keys
    }

    static func albumsMatch(_ lhs: Album, _ rhs: Album) -> Bool {
        !self.albumKeys(for: lhs).isDisjoint(with: self.albumKeys(for: rhs))
    }

    static func canonicalArtist(_ artist: Artist, libraryArtistID: String? = nil) -> Artist {
        let canonicalArtistID = self.artistKey(for: libraryArtistID ?? artist.id)
        if artist.id == canonicalArtistID {
            return artist
        }

        return Artist(
            id: canonicalArtistID,
            name: artist.name,
            thumbnailURL: artist.thumbnailURL,
            subtitle: artist.subtitle,
            profileKind: artist.profileKind
        )
    }

    static func deduplicatedPlaylists(_ playlists: [Playlist]) -> [Playlist] {
        var seenPlaylistKeys: Set<String> = []
        var deduplicatedPlaylists: [Playlist] = []

        for playlist in playlists {
            guard seenPlaylistKeys.insert(self.playlistKey(for: playlist)).inserted else { continue }
            deduplicatedPlaylists.append(playlist)
        }

        return deduplicatedPlaylists
    }

    static func deduplicatedArtists(_ artists: [Artist]) -> [Artist] {
        var seenArtistKeys: Set<String> = []
        var deduplicatedArtists: [Artist] = []

        for artist in artists {
            let canonicalArtist = self.canonicalArtist(artist)
            guard seenArtistKeys.insert(self.artistKey(for: canonicalArtist)).inserted else { continue }
            deduplicatedArtists.append(canonicalArtist)
        }

        return deduplicatedArtists
    }

    static func deduplicatedAlbums(_ albums: [Album]) -> [Album] {
        var seenAlbumKeys: Set<String> = []
        var deduplicatedAlbums: [Album] = []

        for album in albums {
            let albumKeys = self.albumKeys(for: album)
            guard seenAlbumKeys.isDisjoint(with: albumKeys) else { continue }
            seenAlbumKeys.formUnion(albumKeys)
            deduplicatedAlbums.append(album)
        }

        return deduplicatedAlbums
    }

    static func containsPlaylist(_ playlistID: String, in libraryPlaylistIDs: Set<String>) -> Bool {
        let playlistKey = self.playlistKey(for: playlistID)
        return libraryPlaylistIDs.contains { self.playlistKey(for: $0) == playlistKey }
    }

    static func removingPlaylist(_ playlistID: String, from libraryPlaylistIDs: Set<String>) -> Set<String> {
        let playlistKey = self.playlistKey(for: playlistID)
        return libraryPlaylistIDs.filter { self.playlistKey(for: $0) != playlistKey }
    }
}
