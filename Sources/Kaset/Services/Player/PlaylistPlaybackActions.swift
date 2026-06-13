import Foundation

/// Playback actions for playlist-backed queues.
enum PlaylistPlaybackActions {
    struct ContinuationContext {
        let continuationToken: String?
        let existingVideoIds: Set<String>
        let expectedQueueEntryIDs: [UUID]
        let playlist: Playlist
        let client: any YTMusicClientProtocol
        let playerService: PlayerService
    }

    /// Plays a playlist immediately, replacing the current queue.
    static func playPlaylist(
        _ playlist: Playlist,
        client: any YTMusicClientProtocol,
        playerService: PlayerService
    ) {
        Task { @MainActor in
            do {
                let response = try await client.getPlaylist(id: playlist.id)
                var songs = response.detail.tracks

                if self.isRadioPlaylist(playlist.id) {
                    do {
                        let allTracks = try await client.getPlaylistAllTracks(playlistId: playlist.id)
                        if allTracks.count >= songs.count, !allTracks.isEmpty {
                            songs = self.tracksForPlaylistPlayback(
                                browseTracks: response.detail.tracks,
                                queueTracks: allTracks
                            )
                        }
                    } catch {
                        DiagnosticsLogger.ui.debug("Falling back to browse playlist tracks: \(error.localizedDescription)")
                    }
                } else {
                    let playableSongs = self.playableSongsWithPlaylistArtwork(songs, playlist: playlist)
                    guard !playableSongs.isEmpty else { return }

                    await playerService.playQueue(playableSongs, startingAt: 0)
                    DiagnosticsLogger.ui.info("Playing playlist '\(playlist.title)' (\(playableSongs.count) initial songs)")

                    await self.appendContinuations(
                        ContinuationContext(
                            continuationToken: response.continuationToken,
                            existingVideoIds: Set(songs.map(\.videoId)),
                            expectedQueueEntryIDs: playerService.queueEntryIDs,
                            playlist: playlist,
                            client: client,
                            playerService: playerService
                        )
                    )
                    return
                }

                let playableSongs = self.playableSongsWithPlaylistArtwork(songs, playlist: playlist)
                guard !playableSongs.isEmpty else { return }

                await playerService.playQueue(playableSongs, startingAt: 0)
                DiagnosticsLogger.ui.info("Playing playlist '\(playlist.title)' (\(playableSongs.count) songs)")
            } catch {
                DiagnosticsLogger.ui.error("Failed to play playlist: \(error.localizedDescription)")
            }
        }
    }

    static func isRadioPlaylist(_ playlistId: String) -> Bool {
        playlistId.contains("RDCLAK") || playlistId.hasPrefix("RD")
    }

    static func tracksForPlaylistPlayback(browseTracks: [Song], queueTracks: [Song]) -> [Song] {
        var browsePlayabilityByVideoId: [String: Bool] = [:]
        for track in browseTracks {
            browsePlayabilityByVideoId[track.videoId] = track.isPlayable
        }

        return queueTracks.map { track in
            guard let browseIsPlayable = browsePlayabilityByVideoId[track.videoId],
                  browseIsPlayable != track.isPlayable
            else {
                return track
            }

            return self.copy(
                track,
                thumbnailURL: track.thumbnailURL,
                isPlayable: browseIsPlayable
            )
        }
    }

    static func playableSongsWithPlaylistArtwork(_ songs: [Song], playlist: Playlist) -> [Song] {
        songs.filter(\.isPlayable).map { song in
            self.copy(
                song,
                thumbnailURL: song.thumbnailURL ?? playlist.thumbnailURL,
                isPlayable: song.isPlayable
            )
        }
    }

    @MainActor
    static func appendContinuations(_ context: ContinuationContext) async {
        var nextContinuation = context.continuationToken
        var seenVideoIds = context.existingVideoIds

        while let c = nextContinuation, !Task.isCancelled {
            do {
                let response = try await context.client.getPlaylistContinuation(token: c)
                let newTracks = response.tracks.filter { seenVideoIds.insert($0.videoId).inserted }
                guard !newTracks.isEmpty else { break }

                let playableSongs = Self.playableSongsWithPlaylistArtwork(newTracks, playlist: context.playlist)
                if !playableSongs.isEmpty {
                    guard Array(context.playerService.queueEntryIDs.prefix(context.expectedQueueEntryIDs.count)) == context.expectedQueueEntryIDs else {
                        DiagnosticsLogger.ui.debug("Discarding playlist continuations because the queue changed")
                        return
                    }
                    context.playerService.appendToQueue(playableSongs)
                }

                nextContinuation = response.continuationToken
            } catch {
                DiagnosticsLogger.ui.debug("Stopped loading playlist continuations: \(error.localizedDescription)")
                break
            }
        }
    }

    private static func copy(
        _ song: Song,
        thumbnailURL: URL?,
        isPlayable: Bool
    ) -> Song {
        let carried = song.feedbackTokens
        return Song(
            id: song.id,
            title: song.title,
            artists: song.artists,
            album: song.album,
            duration: song.duration,
            thumbnailURL: thumbnailURL,
            videoId: song.videoId,
            isPlayable: isPlayable,
            hasVideo: song.hasVideo,
            musicVideoType: song.musicVideoType,
            likeStatus: song.likeStatus,
            isInLibrary: song.isInLibrary,
            feedbackTokens: carried,
            isExplicit: song.isExplicit
        )
    }
}
