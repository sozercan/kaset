import Foundation

// MARK: - Artist Formatting Helpers

@available(macOS 26.0, *)
extension PlaylistDetailView {
    func headerArtists(for detail: PlaylistDetail) -> [Artist] {
        if let author = self.cleanedArtist(detail.author) {
            return [author]
        }

        return self.uniqueArtists(from: detail.tracks.flatMap(\.artists))
    }

    func trackArtistsDisplay(for track: Song, fallbackAuthor: String?) -> String? {
        let artists = self.uniqueArtists(from: track.artists)
        if !artists.isEmpty {
            return artists.map(\.name).joined(separator: ", ")
        }

        guard let fallbackArtist = self.cleanedArtistName(fallbackAuthor) else { return nil }
        return fallbackArtist
    }

    func uniqueArtists(from artists: [Artist]) -> [Artist] {
        var seen = Set<String>()
        var uniqueArtists: [Artist] = []

        for artist in artists {
            guard let cleanedArtist = self.cleanedArtist(artist) else { continue }
            let key = cleanedArtist.hasNavigableId ? cleanedArtist.id : cleanedArtist.name.lowercased()
            guard seen.insert(key).inserted else { continue }
            uniqueArtists.append(cleanedArtist)
        }

        return uniqueArtists
    }

    func cleanedArtist(_ artist: Artist?) -> Artist? {
        guard let artist,
              let name = self.cleanedArtistName(artist.name)
        else { return nil }

        return Artist(
            id: artist.id,
            name: name,
            thumbnailURL: artist.thumbnailURL,
            subtitle: artist.subtitle,
            profileKind: artist.profileKind
        )
    }

    func cleanedArtistName(_ name: String?) -> String? {
        guard var cleanName = name?.trimmingCharacters(in: .whitespacesAndNewlines),
              !cleanName.isEmpty
        else { return nil }

        if cleanName == "Album" {
            return nil
        }

        if cleanName.hasPrefix("Album, ") {
            cleanName = String(cleanName.dropFirst(7))
        } else if cleanName.contains("Album,") {
            let parts = cleanName.split(separator: ",", maxSplits: 1)
            if parts.count > 1 {
                cleanName = String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        return cleanName.isEmpty ? nil : cleanName
    }
}
