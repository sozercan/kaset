import Foundation
import Observation
import YouTubeExtraction

/// Manages offline playlist/song storage and media downloads.
@MainActor
@Observable
final class OfflineStorageManager {
    static let shared = OfflineStorageManager()

    enum Constants {
        static let folderName = "offline-storage"
        static let indexFileName = "index.json"
        static let playlistsFolderName = "playlists"
        static let songsFolderName = "songs"
        static let mediaFolderName = "media"
        static let manifestVersion = 1
        static let debounceInterval: Duration = .milliseconds(120)
        static let maxConcurrentDownloads = 3
    }

    struct OfflinePlaylistRecord: Codable, Hashable, Identifiable {
        let id: String
        let playlist: Playlist
        let savedAt: Date
        let songVideoIds: [String]

        var songCount: Int {
            self.songVideoIds.count
        }
    }

    struct OfflineSongRecord: Codable, Hashable, Identifiable {
        let id: String
        let song: Song
        let savedAt: Date
        let fileName: String
        let fileExtension: String
        let mimeType: String
        let byteCount: Int64
        let thumbnailFileName: String?
        let sourcePlaylistIds: [String]
        let sourcePlaylistTitles: [String]
        let lyrics: OfflineLyricsRecord?

        var videoId: String {
            self.id
        }
    }

    struct OfflineLyricsRecord: Codable, Hashable {
        enum Kind: String, Codable, Hashable {
            case synced
            case plain
        }

        struct TimedWordRecord: Codable, Hashable {
            let timeInMs: Int
            let word: String
        }

        struct LineRecord: Codable, Hashable {
            let timeInMs: Int
            let duration: Int
            let text: String
            let words: [TimedWordRecord]?
            let romanizedText: String?
        }

        let kind: Kind
        let source: String?
        let plainText: String?
        let lines: [LineRecord]

        var rank: Int {
            switch self.kind {
            case .synced:
                2
            case .plain:
                1
            }
        }

        static func make(from result: LyricResult) -> OfflineLyricsRecord? {
            switch result {
            case let .synced(lyrics) where !lyrics.isEmpty:
                OfflineLyricsRecord(
                    kind: .synced,
                    source: lyrics.source,
                    plainText: nil,
                    lines: lyrics.lines.map { line in
                        LineRecord(
                            timeInMs: line.timeInMs,
                            duration: line.duration,
                            text: line.text,
                            words: line.words?.map { TimedWordRecord(timeInMs: $0.timeInMs, word: $0.word) },
                            romanizedText: line.romanizedText
                        )
                    }
                )
            case let .plain(lyrics) where lyrics.isAvailable:
                OfflineLyricsRecord(
                    kind: .plain,
                    source: lyrics.source,
                    plainText: lyrics.text,
                    lines: []
                )
            case .synced, .plain, .unavailable:
                nil
            }
        }

        func lyricResult() -> LyricResult {
            switch self.kind {
            case .synced:
                let syncedLines = self.lines.map { lineRecord in
                    var line = SyncedLyricLine(
                        timeInMs: lineRecord.timeInMs,
                        duration: lineRecord.duration,
                        text: lineRecord.text,
                        words: lineRecord.words?.map { TimedWord(timeInMs: $0.timeInMs, word: $0.word) }
                    )
                    line.romanizedText = lineRecord.romanizedText
                    return line
                }
                return .synced(SyncedLyrics(lines: syncedLines, source: self.source ?? "Offline"))
            case .plain:
                return .plain(Lyrics(text: self.plainText ?? "", source: self.source))
            }
        }
    }

    struct OfflineManifest: Codable {
        var version: Int
        var updatedAt: Date
        var libraryPlaylists: [Playlist]
        var playlists: [OfflinePlaylistRecord]
        var songs: [OfflineSongRecord]
    }

    struct DownloadedAudio {
        let fileName: String
        let fileExtension: String
        let mimeType: String
        let byteCount: Int64
        let thumbnailFileName: String?
    }

    private struct ProviderLyricsResult {
        let provider: String
        let providerIndex: Int
        let result: LyricResult
    }

    let fileManager: FileManager
    let rootURL: URL
    let skipPersistence: Bool
    let streamURLResolver: YouTubeStreamURLResolver

    var manifest: OfflineManifest
    var saveTask: Task<Void, Never>?
    private var saveTasks: [String: Task<Void, Never>] = [:]
    private var saveTaskTokens: [String: UUID] = [:]

    var isSyncing = false
    var progressMessage: String = ""
    var lastSyncDate: Date?
    var lastErrorMessage: String?

    init(
        rootURL: URL? = nil,
        skipLoad: Bool = UITestConfig.isUITestMode,
        skipPersistence: Bool = UITestConfig.isUITestMode
    ) {
        self.fileManager = .default
        self.rootURL = rootURL ?? Self.defaultRootURL()
        self.skipPersistence = skipPersistence
        self.streamURLResolver = YouTubeStreamURLResolver()
        self.manifest = OfflineManifest(
            version: Self.Constants.manifestVersion,
            updatedAt: .distantPast,
            libraryPlaylists: [],
            playlists: [],
            songs: []
        )

        if !skipLoad {
            self.load()
        }
    }

    var libraryPlaylists: [Playlist] {
        self.manifest.libraryPlaylists
    }

    var playlists: [OfflinePlaylistRecord] {
        self.manifest.playlists.sorted { $0.savedAt > $1.savedAt }
    }

    var songs: [OfflineSongRecord] {
        self.manifest.songs.sorted { $0.savedAt > $1.savedAt }
    }

    var totalSongCount: Int {
        self.manifest.songs.count
    }

    var totalPlaylistCount: Int {
        self.manifest.playlists.count
    }

    func isSavingSong(videoId: String) -> Bool {
        self.saveTasks[self.saveTaskKey(kind: "song", id: videoId)] != nil
    }

    func isSavingPlaylist(playlistId: String) -> Bool {
        self.saveTasks[self.saveTaskKey(kind: "playlist", id: playlistId)] != nil
    }

    func startSavingSong(_ song: Song, using client: any YTMusicClientProtocol) {
        let key = self.saveTaskKey(kind: "song", id: song.videoId)
        self.saveTasks[key]?.cancel()
        let token = UUID()
        self.saveTaskTokens[key] = token

        let task = Task { @MainActor in
            defer {
                if self.saveTaskTokens[key] == token {
                    self.saveTaskTokens.removeValue(forKey: key)
                    self.saveTasks.removeValue(forKey: key)
                }
            }
            await self.saveSong(song, using: client)
        }
        self.saveTasks[key] = task
    }

    func startSavingPlaylist(_ playlist: Playlist, using client: any YTMusicClientProtocol) {
        let key = self.saveTaskKey(kind: "playlist", id: playlist.id)
        self.saveTasks[key]?.cancel()
        let token = UUID()
        self.saveTaskTokens[key] = token

        let task = Task { @MainActor in
            defer {
                if self.saveTaskTokens[key] == token {
                    self.saveTaskTokens.removeValue(forKey: key)
                    self.saveTasks.removeValue(forKey: key)
                }
            }
            await self.savePlaylist(playlist, using: client)
        }
        self.saveTasks[key] = task
    }

    func cancelSavingSong(videoId: String) {
        let key = self.saveTaskKey(kind: "song", id: videoId)
        self.saveTasks[key]?.cancel()
    }

    func cancelSavingPlaylist(playlistId: String) {
        let key = self.saveTaskKey(kind: "playlist", id: playlistId)
        self.saveTasks[key]?.cancel()
    }

    func toggleSongOfflineStorage(_ song: Song, using client: any YTMusicClientProtocol) {
        if self.songRecord(for: song.videoId) != nil {
            self.cancelSavingSong(videoId: song.videoId)
            self.removeSong(videoId: song.videoId)
            return
        }

        if self.isSavingSong(videoId: song.videoId) {
            self.cancelSavingSong(videoId: song.videoId)
            return
        }

        self.startSavingSong(song, using: client)
    }

    func togglePlaylistOfflineStorage(_ playlist: Playlist, using client: any YTMusicClientProtocol) {
        if self.playlistRecord(for: playlist.id) != nil {
            self.cancelSavingPlaylist(playlistId: playlist.id)
            self.removePlaylist(playlistId: playlist.id)
            return
        }

        if self.isSavingPlaylist(playlistId: playlist.id) {
            self.cancelSavingPlaylist(playlistId: playlist.id)
            return
        }

        self.startSavingPlaylist(playlist, using: client)
    }

    func refreshLibraryPlaylists(using client: any YTMusicClientProtocol) async {
        do {
            let playlists = try await client.getLibraryPlaylists()
            self.manifest.libraryPlaylists = playlists
            self.manifest.updatedAt = Date()
            self.save()

            if SettingsManager.shared.offlineStorageEnabled {
                await self.syncLibraryPlaylists(using: client, playlists: playlists)
            }
        } catch {
            self.lastErrorMessage = error.localizedDescription
            DiagnosticsLogger.ui.error("Failed to refresh library playlists for offline storage: \(error.localizedDescription)")
        }
    }

    func syncLibraryPlaylists(
        using client: any YTMusicClientProtocol,
        playlists: [Playlist]? = nil
    ) async {
        guard SettingsManager.shared.offlineStorageEnabled else { return }
        guard !self.isSyncing else { return }

        let libraryPlaylists = playlists ?? self.manifest.libraryPlaylists
        guard !libraryPlaylists.isEmpty else { return }

        self.isSyncing = true
        self.progressMessage = String(localized: "Syncing offline storage...")
        defer {
            self.isSyncing = false
            self.progressMessage = ""
            self.lastSyncDate = Date()
            self.save()
        }

        await withTaskGroup(of: Void.self) { group in
            var inFlight = 0
            for playlist in libraryPlaylists {
                guard !Task.isCancelled else { break }

                if inFlight >= Self.Constants.maxConcurrentDownloads {
                    await group.next()
                    inFlight -= 1
                }

                group.addTask { [client] in
                    await self.savePlaylist(playlist, using: client)
                }
                inFlight += 1
            }

            await group.waitForAll()
        }
    }

    func savePlaylist(_ playlist: Playlist, using client: any YTMusicClientProtocol) async {
        do {
            let tracks = try await client.getPlaylistAllTracks(playlistId: playlist.id)
            await self.savePlaylist(playlist, tracks: tracks, using: client)
        } catch {
            self.lastErrorMessage = error.localizedDescription
            DiagnosticsLogger.ui.error("Failed to fetch playlist tracks for offline storage: \(error.localizedDescription)")
        }
    }

    func savePlaylist(
        _ playlist: Playlist,
        tracks: [Song],
        using client: any YTMusicClientProtocol
    ) async {
        guard !Task.isCancelled else { return }
        let cleanedTracks = tracks.filter(\.isPlayable)
        let songVideoIds = cleanedTracks.map(\.videoId)
        let existingSongs = Dictionary(uniqueKeysWithValues: self.manifest.songs.map { ($0.id, $0) })
        let existingPlaylist = self.manifest.playlists.first { $0.id == playlist.id }
        let sourcePlaylistIDs = [playlist.id]
        let sourcePlaylistTitles = [playlist.title]

        var resolvedSongs: [OfflineSongRecord] = []
        await withTaskGroup(of: OfflineSongRecord?.self) { group in
            for song in cleanedTracks {
                group.addTask {
                    await self.resolveSongRecord(
                        song: song,
                        sourcePlaylistIDs: sourcePlaylistIDs,
                        sourcePlaylistTitles: sourcePlaylistTitles,
                        existingRecord: existingSongs[song.videoId],
                        client: client
                    )
                }
            }

            for await record in group {
                if let record {
                    resolvedSongs.append(record)
                }
            }
        }

        guard !Task.isCancelled else { return }
        self.mergeOfflineResults(
            playlist: playlist,
            songVideoIds: songVideoIds,
            resolvedSongs: resolvedSongs,
            existingPlaylist: existingPlaylist
        )
    }

    func saveSong(_ song: Song, using client: any YTMusicClientProtocol) async {
        guard !Task.isCancelled else { return }
        let existingSong = self.manifest.songs.first { $0.id == song.videoId }
        if let record = await self.resolveSongRecord(
            song: song,
            sourcePlaylistIDs: [song.videoId],
            sourcePlaylistTitles: [song.title],
            existingRecord: existingSong,
            client: client
        ) {
            guard !Task.isCancelled else { return }
            self.upsert(songRecord: record)
            self.save()
        }
    }

    func removeSong(videoId: String) {
        guard let existingRecord = self.manifest.songs.first(where: { $0.id == videoId }) else { return }
        self.cancelSavingSong(videoId: videoId)

        if let updatedRecord = self.removingSource(
            from: existingRecord,
            sourcePlaylistId: videoId,
            sourcePlaylistTitle: existingRecord.song.title
        ) {
            if let index = self.manifest.songs.firstIndex(where: { $0.id == videoId }) {
                self.manifest.songs[index] = updatedRecord
            }
        } else {
            self.manifest.songs.removeAll { $0.id == videoId }
            self.deleteSongFiles(videoId: videoId)
        }
        self.manifest.updatedAt = Date()
        self.save()
    }

    func removePlaylist(playlistId: String) {
        let removedPlaylist = self.manifest.playlists.first { $0.id == playlistId }
        self.cancelSavingPlaylist(playlistId: playlistId)
        self.manifest.playlists.removeAll { $0.id == playlistId }
        self.deletePlaylistMappingFile(playlistId: playlistId)

        for index in self.manifest.songs.indices.reversed() {
            let record = self.manifest.songs[index]
            guard record.sourcePlaylistIds.contains(playlistId) else { continue }

            if let updatedRecord = self.removingSource(
                from: record,
                sourcePlaylistId: playlistId,
                sourcePlaylistTitle: removedPlaylist?.playlist.title
            ) {
                self.manifest.songs[index] = updatedRecord
            } else {
                self.manifest.songs.remove(at: index)
                self.deleteSongFiles(videoId: record.id)
            }
        }
        self.manifest.updatedAt = Date()
        self.save()
    }

    private func resolveSongRecord(
        song: Song,
        sourcePlaylistIDs: [String],
        sourcePlaylistTitles: [String],
        existingRecord: OfflineSongRecord?,
        client: any YTMusicClientProtocol
    ) async -> OfflineSongRecord? {
        do {
            guard !Task.isCancelled else { return nil }
            if let existingRecord,
               self.fileManager.fileExists(atPath: self.mediaFileURL(for: existingRecord).path)
            {
                let lyrics: OfflineLyricsRecord? = if let existingLyrics = existingRecord.lyrics {
                    existingLyrics
                } else {
                    await self.fetchOfflineLyrics(for: song, client: client)
                }
                let thumbnailFileName = await self.ensureThumbnail(
                    for: song,
                    existingRecord: existingRecord
                )
                return self.mergedSongRecord(
                    OfflineSongRecord(
                        id: existingRecord.id,
                        song: existingRecord.song,
                        savedAt: existingRecord.savedAt,
                        fileName: existingRecord.fileName,
                        fileExtension: existingRecord.fileExtension,
                        mimeType: existingRecord.mimeType,
                        byteCount: existingRecord.byteCount,
                        thumbnailFileName: thumbnailFileName ?? existingRecord.thumbnailFileName,
                        sourcePlaylistIds: existingRecord.sourcePlaylistIds,
                        sourcePlaylistTitles: existingRecord.sourcePlaylistTitles,
                        lyrics: existingRecord.lyrics
                    ),
                    sourcePlaylistIDs: sourcePlaylistIDs,
                    sourcePlaylistTitles: sourcePlaylistTitles,
                    lyrics: lyrics
                )
            }

            guard !Task.isCancelled else { return nil }
            let playerResponse = try await client.getPlayer(videoId: song.videoId)
            if let playabilityMessage = Self.playabilityMessage(from: playerResponse) {
                self.lastErrorMessage = playabilityMessage
                DiagnosticsLogger.ui.warning(
                    "Skipping offline download for \(song.title, privacy: .public): \(playabilityMessage, privacy: .public)"
                )
                return nil
            }

            let candidateFormats = Self.bestStreamFormats(from: playerResponse)
            guard !candidateFormats.isEmpty else {
                self.lastErrorMessage = "No downloadable audio stream available for \(song.title)"
                return nil
            }
            let playerContext: YouTubePlayerContext? = if Self.requiresPlayerJavaScript(for: candidateFormats) {
                await YouTubePlayerContextProvider.shared.currentContext(videoId: song.videoId)
            } else {
                nil
            }
            let poToken = YouTubePOToken.token(from: playerResponse) ?? YouTubePOToken.configuredGVSToken()

            let downloaded = await self.downloadOfflineAudio(
                song: song,
                candidateFormats: candidateFormats,
                client: client,
                playerJavaScriptURL: playerContext?.javaScriptURL,
                poToken: poToken
            )
            guard let downloaded else {
                if Task.isCancelled {
                    return nil
                }
                self.lastErrorMessage = "Failed to download audio for \(song.title)"
                return nil
            }
            guard !Task.isCancelled else { return nil }
            let lyrics = await self.fetchOfflineLyrics(for: song, client: client)

            return OfflineSongRecord(
                id: song.videoId,
                song: song,
                savedAt: Date(),
                fileName: downloaded.fileName,
                fileExtension: downloaded.fileExtension,
                mimeType: downloaded.mimeType,
                byteCount: downloaded.byteCount,
                thumbnailFileName: downloaded.thumbnailFileName,
                sourcePlaylistIds: sourcePlaylistIDs,
                sourcePlaylistTitles: sourcePlaylistTitles,
                lyrics: lyrics
            )
        } catch is CancellationError {
            return nil
        } catch {
            self.lastErrorMessage = error.localizedDescription
            DiagnosticsLogger.ui.error(
                "Failed to save offline song \(song.title, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            return nil
        }
    }

    private func fetchOfflineLyrics(
        for song: Song,
        client: any YTMusicClientProtocol
    ) async -> OfflineLyricsRecord? {
        guard !Task.isCancelled else { return nil }
        let searchInfo = LyricsSearchInfo(
            title: song.title,
            artist: song.artistsDisplay,
            album: song.album?.title,
            duration: song.duration,
            videoId: song.videoId
        )
        let providers: [LyricsProvider] = if client is YTMusicClient {
            [
                YTMusicSyncedProvider(client: client),
                LRCLibProvider(),
            ]
        } else {
            [
                YTMusicSyncedProvider(client: client),
            ]
        }
        var providerResults: [ProviderLyricsResult] = []

        await withTaskGroup(of: ProviderLyricsResult?.self) { group in
            for (providerIndex, provider) in providers.enumerated() {
                group.addTask {
                    let result = await provider.search(info: searchInfo)
                    return ProviderLyricsResult(
                        provider: provider.name,
                        providerIndex: providerIndex,
                        result: result
                    )
                }
            }

            for await result in group {
                if let result {
                    providerResults.append(result)
                }
            }
        }

        if let result = Self.bestLyricsResult(from: providerResults),
           let record = OfflineLyricsRecord.make(from: result)
        {
            return record
        }

        do {
            guard !Task.isCancelled else { return nil }
            let plainLyrics = try await client.getLyrics(videoId: song.videoId)
            return OfflineLyricsRecord.make(from: .plain(plainLyrics))
        } catch is CancellationError {
            return nil
        } catch {
            DiagnosticsLogger.ui.warning(
                "Failed to save offline lyrics for \(song.title, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            return nil
        }
    }

    private static func bestLyricsResult(from results: [ProviderLyricsResult]) -> LyricResult? {
        var best: ProviderLyricsResult?
        for candidate in results {
            guard candidate.result.isAvailable else { continue }
            guard let currentBest = best else {
                best = candidate
                continue
            }

            if Self.isBetterLyricsResult(candidate, than: currentBest) {
                best = candidate
            }
        }

        return best?.result
    }

    private static func isBetterLyricsResult(
        _ candidate: ProviderLyricsResult,
        than currentBest: ProviderLyricsResult
    ) -> Bool {
        let candidateRank = Self.lyricsRank(candidate.result)
        let currentRank = Self.lyricsRank(currentBest.result)
        if candidateRank != currentRank {
            return candidateRank > currentRank
        }

        if case .plain = candidate.result,
           case .plain = currentBest.result
        {
            let candidateIsYTMusic = candidate.provider == "YTMusic"
            let currentIsYTMusic = currentBest.provider == "YTMusic"
            if candidateIsYTMusic != currentIsYTMusic {
                return candidateIsYTMusic
            }
        }

        return candidate.providerIndex < currentBest.providerIndex
    }

    private static func lyricsRank(_ result: LyricResult) -> Int {
        switch result {
        case .synced:
            2
        case .plain:
            1
        case .unavailable:
            0
        }
    }

    private func downloadOfflineAudio(
        song: Song,
        candidateFormats: [[String: Any]],
        client: any YTMusicClientProtocol,
        playerJavaScriptURL: URL?,
        poToken: String?
    ) async -> DownloadedAudio? {
        for streamFormat in candidateFormats {
            guard !Task.isCancelled else { return nil }
            guard let parsedStreamFormat = YouTubeStreamURLResolver.streamFormat(from: streamFormat) else {
                continue
            }

            guard let streamURL = await self.streamURLResolver.resolvedURL(
                from: parsedStreamFormat,
                playerJavaScriptURL: playerJavaScriptURL,
                poToken: poToken
            ) else {
                continue
            }

            guard !Task.isCancelled else { return nil }
            let mimeType = (streamFormat["mimeType"] as? String) ?? ""

            do {
                return if let authenticatedClient = client as? YTMusicClient {
                    try await authenticatedClient.downloadAuthenticatedAudio(
                        from: streamURL,
                        mimeType: mimeType,
                        song: song,
                        rootURL: self.rootURL,
                        fileManager: self.fileManager
                    )
                } else {
                    try await Self.downloadAudio(
                        from: streamURL,
                        mimeType: mimeType,
                        song: song,
                        rootURL: self.rootURL,
                        fileManager: self.fileManager
                    )
                }
            } catch is CancellationError {
                return nil
            } catch {
                DiagnosticsLogger.ui.warning(
                    "Download failed for \(song.title, privacy: .public) on candidate format: \(error.localizedDescription, privacy: .public)"
                )
            }
        }

        return nil
    }

    private func ensureThumbnail(
        for song: Song,
        existingRecord: OfflineSongRecord?
    ) async -> String? {
        if let thumbnailFileName = existingRecord?.thumbnailFileName {
            let mediaDirectory = self.rootURL.appendingPathComponent(Self.Constants.mediaFolderName, isDirectory: true)
            let thumbnailURL = mediaDirectory.appendingPathComponent(thumbnailFileName)
            if self.fileManager.fileExists(atPath: thumbnailURL.path) {
                return thumbnailFileName
            }
        }

        return await Self.persistThumbnail(
            song: song,
            rootURL: self.rootURL,
            fileManager: self.fileManager
        )
    }

    private func saveTaskKey(kind: String, id: String) -> String {
        "\(kind):\(id)"
    }

    func localThumbnailURL(for videoId: String) -> URL? {
        guard let record = self.songRecord(for: videoId),
              let thumbnailFileName = record.thumbnailFileName
        else {
            return nil
        }

        let mediaDirectory = self.rootURL.appendingPathComponent(Self.Constants.mediaFolderName, isDirectory: true)
        let thumbnailURL = mediaDirectory.appendingPathComponent(thumbnailFileName)
        return self.fileManager.fileExists(atPath: thumbnailURL.path) ? thumbnailURL : nil
    }
}
