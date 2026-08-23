import Foundation

/// Queue and playback actions for album-backed tracks.
@MainActor
enum AlbumPlaybackActions {
    /// Adds an album's songs to play next (immediately after current track).
    @discardableResult
    static func addAlbumToQueueNext(
        _ album: Album,
        client: any YTMusicClientProtocol,
        playerService: PlayerService
    ) -> Task<Void, Never> {
        let queueGeneration = playerService.queueLoadGeneration
        return Task {
            do {
                let songs = try await self.albumSongs(album, client: client, purpose: .queue)
                guard !songs.isEmpty,
                      playerService.isCurrentQueueLoad(queueGeneration)
                else { return }
                playerService.insertNextInQueue(songs)
                DiagnosticsLogger.ui.info("Added album '\(album.title)' (\(songs.count) songs) to play next")
            } catch {
                DiagnosticsLogger.ui.error("Failed to add album to queue: \(error.localizedDescription)")
            }
        }
    }

    /// Adds an album's songs to the end of the queue.
    @discardableResult
    static func addAlbumToQueueLast(
        _ album: Album,
        client: any YTMusicClientProtocol,
        playerService: PlayerService
    ) -> Task<Void, Never> {
        let queueGeneration = playerService.queueLoadGeneration
        return Task {
            do {
                let songs = try await self.albumSongs(album, client: client, purpose: .queue)
                guard !songs.isEmpty,
                      playerService.isCurrentQueueLoad(queueGeneration)
                else { return }
                playerService.appendToQueue(songs)
                DiagnosticsLogger.ui.info("Added album '\(album.title)' (\(songs.count) songs) to end of queue")
            } catch {
                DiagnosticsLogger.ui.error("Failed to add album to queue: \(error.localizedDescription)")
            }
        }
    }

    /// Plays an album immediately, replacing the current queue.
    @discardableResult
    @MainActor
    static func playAlbum(
        _ album: Album,
        client: any YTMusicClientProtocol,
        playerService: PlayerService
    ) -> Task<Void, Never> {
        let intent = playerService.beginMusicPlaybackIntent()
        return Task { @MainActor in
            do {
                let response = try await client.getPlaylist(id: album.id)
                guard playerService.acceptsMusicPlaybackIntent(intent) else { return }
                let songs = QueueSongMetadata.albumSongs(
                    response.detail.tracks,
                    album: album,
                    purpose: .playback(trackCount: response.detail.tracks.count)
                )
                guard !songs.isEmpty else { return }
                await playerService.playQueue(
                    songs,
                    startingAt: 0,
                    deferringSmartShuffleFill: false,
                    intent: intent
                )
                DiagnosticsLogger.ui.info("Playing album '\(album.title)' (\(songs.count) songs)")
            } catch {
                DiagnosticsLogger.ui.error("Failed to play album: \(error.localizedDescription)")
            }
        }
    }

    private static func albumSongs(
        _ album: Album,
        client: any YTMusicClientProtocol,
        purpose: QueueSongMetadata.AlbumSongPurpose
    ) async throws -> [Song] {
        let response = try await client.getPlaylist(id: album.id)
        return QueueSongMetadata.albumSongs(
            response.detail.tracks,
            album: album,
            purpose: purpose
        )
    }
}
