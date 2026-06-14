import Foundation

/// Prepares song metadata before inserting tracks into the native queue.
enum QueueSongMetadata {
    enum AlbumSongPurpose {
        case queue
        case playback(trackCount: Int)
    }

    static func cleanedArtistPreservingMetadata(_ artist: Artist) -> Artist? {
        var cleanName = artist.name

        if cleanName == "Album" {
            return nil
        }

        if cleanName.hasPrefix("Album, ") {
            cleanName = String(cleanName.dropFirst(7))
        }

        return Artist(
            id: artist.id,
            name: cleanName,
            thumbnailURL: artist.thumbnailURL,
            subtitle: artist.subtitle,
            profileKind: artist.profileKind
        )
    }

    static func songsForQueue(
        _ songs: [Song],
        fallbackArtist: String? = nil,
        fallbackAlbum: Album? = nil
    ) -> [Song] {
        songs.map { song in
            let artists = self.queueArtists(for: song, fallbackArtist: fallbackArtist)
            return self.copy(
                song,
                artists: artists,
                album: song.album ?? fallbackAlbum,
                thumbnailURL: song.thumbnailURL ?? fallbackAlbum?.thumbnailURL
            )
        }
    }

    static func albumSongs(
        _ songs: [Song],
        album: Album,
        purpose: AlbumSongPurpose
    ) -> [Song] {
        let cleanAlbumArtists = (album.artists ?? []).compactMap(Self.cleanedArtistPreservingMetadata)
        let albumForSong = self.albumForSong(
            album,
            artists: cleanAlbumArtists,
            purpose: purpose
        )

        return songs.map { song in
            let baseArtists = !song.artists.isEmpty ? song.artists : cleanAlbumArtists
            let effectiveArtists = baseArtists.compactMap(Self.cleanedArtistPreservingMetadata)
            let artists = effectiveArtists.isEmpty ? cleanAlbumArtists : effectiveArtists

            return self.copy(
                song,
                artists: artists,
                album: albumForSong,
                thumbnailURL: song.thumbnailURL ?? album.thumbnailURL
            )
        }
    }

    private static func queueArtists(for song: Song, fallbackArtist: String?) -> [Artist] {
        var cleanedArtists = song.artists.compactMap(Self.cleanedArtistPreservingMetadata)
        if cleanedArtists.isEmpty,
           let fallbackArtist = self.cleanedFallbackArtistName(fallbackArtist)
        {
            cleanedArtists = [Artist(id: "unknown", name: fallbackArtist)]
        }
        return cleanedArtists
    }

    private static func cleanedFallbackArtistName(_ fallbackArtist: String?) -> String? {
        guard var cleanFallback = fallbackArtist?.trimmingCharacters(in: .whitespacesAndNewlines),
              !cleanFallback.isEmpty
        else { return nil }

        if cleanFallback == "Album" {
            return "Unknown Artist"
        }

        if cleanFallback.hasPrefix("Album, ") {
            cleanFallback = String(cleanFallback.dropFirst(7))
        }

        if cleanFallback.contains("Album,") {
            let parts = cleanFallback.split(separator: ",", maxSplits: 1)
            if parts.count > 1 {
                cleanFallback = String(parts[1]).trimmingCharacters(in: .whitespaces)
            }
        }

        return cleanFallback.isEmpty ? nil : cleanFallback
    }

    private static func albumForSong(
        _ album: Album,
        artists: [Artist],
        purpose: AlbumSongPurpose
    ) -> Album {
        switch purpose {
        case .queue:
            Album(
                id: album.id,
                title: album.title,
                artists: artists,
                thumbnailURL: album.thumbnailURL,
                year: nil,
                trackCount: album.trackCount
            )
        case let .playback(trackCount):
            Album(
                id: album.id,
                title: album.title,
                artists: artists.isEmpty ? nil : artists,
                thumbnailURL: album.thumbnailURL,
                year: album.year,
                trackCount: trackCount
            )
        }
    }

    private static func copy(
        _ song: Song,
        artists: [Artist],
        album: Album?,
        thumbnailURL: URL?
    ) -> Song {
        let carried = song.feedbackTokens
        return Song(
            id: song.id,
            title: song.title,
            artists: artists,
            album: album,
            duration: song.duration,
            thumbnailURL: thumbnailURL,
            videoId: song.videoId,
            isPlayable: song.isPlayable,
            hasVideo: song.hasVideo,
            musicVideoType: song.musicVideoType,
            likeStatus: song.likeStatus,
            isInLibrary: song.isInLibrary,
            feedbackTokens: carried,
            isExplicit: song.isExplicit
        )
    }
}
