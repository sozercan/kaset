import Foundation
import YouTubeExtraction

extension OfflineStorageManager {
    func mergedSongRecord(
        _ record: OfflineSongRecord,
        sourcePlaylistIDs: [String],
        sourcePlaylistTitles: [String],
        lyrics: OfflineLyricsRecord? = nil
    ) -> OfflineSongRecord {
        let playlistIDs = Array(Set(record.sourcePlaylistIds + sourcePlaylistIDs)).sorted()
        let playlistTitles = Array(Set(record.sourcePlaylistTitles + sourcePlaylistTitles)).sorted()
        return OfflineSongRecord(
            id: record.id,
            song: record.song,
            savedAt: record.savedAt,
            fileName: record.fileName,
            fileExtension: record.fileExtension,
            mimeType: record.mimeType,
            byteCount: record.byteCount,
            thumbnailFileName: record.thumbnailFileName,
            sourcePlaylistIds: playlistIDs,
            sourcePlaylistTitles: playlistTitles,
            lyrics: Self.preferredLyrics(new: lyrics, existing: record.lyrics)
        )
    }

    func playlistSongs(for playlistId: String) -> [OfflineSongRecord] {
        guard let playlist = self.manifest.playlists.first(where: { $0.id == playlistId }) else {
            return []
        }

        let songsByID = Dictionary(uniqueKeysWithValues: self.manifest.songs.map { ($0.id, $0) })
        return playlist.songVideoIds.compactMap { songsByID[$0] }
    }

    func playlistRecord(for playlistId: String) -> OfflinePlaylistRecord? {
        self.manifest.playlists.first { $0.id == playlistId }
    }

    func songRecord(for videoId: String) -> OfflineSongRecord? {
        self.manifest.songs.first { $0.id == videoId }
    }

    func lyricsResult(for videoId: String) -> LyricResult? {
        self.songRecord(for: videoId)?.lyrics?.lyricResult()
    }

    func removingSource(
        from record: OfflineSongRecord,
        sourcePlaylistId: String,
        sourcePlaylistTitle: String?
    ) -> OfflineSongRecord? {
        let remainingSourcePlaylistIds = record.sourcePlaylistIds.filter { $0 != sourcePlaylistId }
        let remainingSourcePlaylistTitles = if let sourcePlaylistTitle {
            record.sourcePlaylistTitles.filter { $0 != sourcePlaylistTitle }
        } else {
            record.sourcePlaylistTitles
        }

        guard !remainingSourcePlaylistIds.isEmpty else { return nil }

        return OfflineSongRecord(
            id: record.id,
            song: record.song,
            savedAt: record.savedAt,
            fileName: record.fileName,
            fileExtension: record.fileExtension,
            mimeType: record.mimeType,
            byteCount: record.byteCount,
            thumbnailFileName: record.thumbnailFileName,
            sourcePlaylistIds: remainingSourcePlaylistIds,
            sourcePlaylistTitles: remainingSourcePlaylistTitles,
            lyrics: record.lyrics
        )
    }

    func mergeOfflineResults(
        playlist: Playlist,
        songVideoIds: [String],
        resolvedSongs: [OfflineSongRecord],
        existingPlaylist: OfflinePlaylistRecord?
    ) {
        let playlistRecord = OfflinePlaylistRecord(
            id: playlist.id,
            playlist: playlist,
            savedAt: existingPlaylist?.savedAt ?? Date(),
            songVideoIds: songVideoIds
        )

        self.manifest.playlists.removeAll { $0.id == playlist.id }
        self.manifest.playlists.append(playlistRecord)

        for record in resolvedSongs {
            self.upsert(songRecord: record)
        }

        self.manifest.updatedAt = Date()
        self.save()
    }

    func upsert(songRecord record: OfflineSongRecord) {
        if let index = self.manifest.songs.firstIndex(where: { $0.id == record.id }) {
            let existing = self.manifest.songs[index]
            self.manifest.songs[index] = OfflineSongRecord(
                id: existing.id,
                song: record.song,
                savedAt: existing.savedAt,
                fileName: existing.fileName,
                fileExtension: existing.fileExtension,
                mimeType: existing.mimeType,
                byteCount: existing.byteCount,
                thumbnailFileName: record.thumbnailFileName ?? existing.thumbnailFileName,
                sourcePlaylistIds: Array(Set(existing.sourcePlaylistIds + record.sourcePlaylistIds)).sorted(),
                sourcePlaylistTitles: Array(Set(existing.sourcePlaylistTitles + record.sourcePlaylistTitles)).sorted(),
                lyrics: Self.preferredLyrics(new: record.lyrics, existing: existing.lyrics)
            )
        } else {
            self.manifest.songs.append(record)
        }
    }

    static func preferredLyrics(new: OfflineLyricsRecord?, existing: OfflineLyricsRecord?) -> OfflineLyricsRecord? {
        guard let new else { return existing }
        guard let existing else { return new }
        return new.rank >= existing.rank ? new : existing
    }

    func load() {
        do {
            let indexURL = self.indexFileURL()
            guard self.fileManager.fileExists(atPath: indexURL.path) else {
                DiagnosticsLogger.ui.debug("Offline storage manifest not found, starting fresh")
                return
            }

            let data = try Data(contentsOf: indexURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .secondsSince1970
            let decoded = try decoder.decode(OfflineManifest.self, from: data)
            self.manifest = decoded
            DiagnosticsLogger.ui.info("Loaded offline storage manifest with \(decoded.playlists.count) playlists and \(decoded.songs.count) songs")
        } catch {
            DiagnosticsLogger.ui.error("Failed to load offline storage manifest: \(error.localizedDescription)")
            self.manifest = OfflineManifest(
                version: Self.Constants.manifestVersion,
                updatedAt: .distantPast,
                libraryPlaylists: [],
                playlists: [],
                songs: []
            )
        }
    }

    func save() {
        guard !self.skipPersistence else { return }

        self.saveTask?.cancel()
        let snapshot = self.manifest
        let rootURL = self.rootURL
        let fileManager = self.fileManager

        self.saveTask = Task(priority: .utility) {
            try? await Task.sleep(for: Self.Constants.debounceInterval)
            guard !Task.isCancelled else { return }

            do {
                try Self.createStorageDirectories(rootURL: rootURL, fileManager: fileManager)
                try Self.clearJSONFiles(
                    in: rootURL.appendingPathComponent(Self.Constants.playlistsFolderName, isDirectory: true),
                    fileManager: fileManager
                )
                try Self.clearJSONFiles(
                    in: rootURL.appendingPathComponent(Self.Constants.songsFolderName, isDirectory: true),
                    fileManager: fileManager
                )
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .secondsSince1970
                let data = try encoder.encode(snapshot)
                try data.write(to: Self.indexFileURL(rootURL: rootURL), options: .atomic)
                try Self.writePlaylistMappings(snapshot.playlists, rootURL: rootURL)
                try Self.writeSongRecords(snapshot.songs, rootURL: rootURL)
            } catch {
                DiagnosticsLogger.ui.error("Failed to save offline storage manifest: \(error.localizedDescription)")
            }
        }
    }

    func mediaFileURL(for record: OfflineSongRecord) -> URL {
        Self.mediaFileURL(
            rootURL: self.rootURL,
            videoId: record.id,
            fileExtension: record.fileExtension
        )
    }

    func mediaURL(for videoId: String) -> URL? {
        let mediaDirectory = self.rootURL.appendingPathComponent(Self.Constants.mediaFolderName, isDirectory: true)
        guard let enumerator = self.fileManager.enumerator(
            at: mediaDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        let preferredExtensions = ["mp3", "m4a", "caf", "wav", "webm", "bin"]
        var candidates: [URL] = []
        let prefix = Self.sanitizedFileName(videoId)
        while let fileURL = enumerator.nextObject() as? URL {
            guard fileURL.lastPathComponent.hasPrefix(prefix) else { continue }
            guard preferredExtensions.contains(fileURL.pathExtension.lowercased()) else { continue }
            candidates.append(fileURL)
        }

        return candidates.min {
            let lhsIndex = preferredExtensions.firstIndex(of: $0.pathExtension.lowercased()) ?? .max
            let rhsIndex = preferredExtensions.firstIndex(of: $1.pathExtension.lowercased()) ?? .max
            return lhsIndex < rhsIndex
        }
    }

    func deleteSongFiles(videoId: String) {
        let mediaDirectory = self.rootURL.appendingPathComponent(Self.Constants.mediaFolderName, isDirectory: true)
        let songsDirectory = self.rootURL.appendingPathComponent(Self.Constants.songsFolderName, isDirectory: true)
        let filePrefix = Self.sanitizedFileName(videoId)

        if let enumerator = self.fileManager.enumerator(
            at: mediaDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) {
            for case let fileURL as URL in enumerator where fileURL.lastPathComponent.hasPrefix(filePrefix) {
                try? self.fileManager.removeItem(at: fileURL)
            }
        }

        try? self.fileManager.removeItem(at: songsDirectory.appendingPathComponent("\(videoId).json"))
    }

    func deletePlaylistMappingFile(playlistId: String) {
        let playlistURL = self.playlistsFolderURL().appendingPathComponent("\(Self.sanitizedFileName(playlistId)).json")
        try? self.fileManager.removeItem(at: playlistURL)
    }

    private static func createStorageDirectories(rootURL: URL, fileManager: FileManager) throws {
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(
            at: rootURL.appendingPathComponent(Constants.playlistsFolderName, isDirectory: true),
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(
            at: rootURL.appendingPathComponent(Constants.songsFolderName, isDirectory: true),
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(
            at: rootURL.appendingPathComponent(Constants.mediaFolderName, isDirectory: true),
            withIntermediateDirectories: true
        )
    }

    private static func clearJSONFiles(in directory: URL, fileManager: FileManager) throws {
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        while let fileURL = enumerator.nextObject() as? URL {
            if fileURL.pathExtension != "json" {
                continue
            }
            try fileManager.removeItem(at: fileURL)
        }
    }

    private static func writePlaylistMappings(
        _ playlists: [OfflinePlaylistRecord],
        rootURL: URL
    ) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        for playlist in playlists {
            let data = try encoder.encode(playlist)
            try data.write(
                to: rootURL
                    .appendingPathComponent(Self.Constants.playlistsFolderName, isDirectory: true)
                    .appendingPathComponent("\(Self.sanitizedFileName(playlist.id)).json"),
                options: .atomic
            )
        }
    }

    private static func writeSongRecords(
        _ songs: [OfflineSongRecord],
        rootURL: URL
    ) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        for song in songs {
            let data = try encoder.encode(song)
            try data.write(
                to: rootURL
                    .appendingPathComponent(Self.Constants.songsFolderName, isDirectory: true)
                    .appendingPathComponent("\(Self.sanitizedFileName(song.id)).json"),
                options: .atomic
            )
        }
    }

    static func bestStreamFormats(from playerResponse: [String: Any]) -> [[String: Any]] {
        self.audioFormats(from: playerResponse)
    }

    static func playabilityMessage(from playerResponse: [String: Any]) -> String? {
        guard let playabilityStatus = playerResponse["playabilityStatus"] as? [String: Any],
              let status = playabilityStatus["status"] as? String,
              status != "OK"
        else {
            return nil
        }

        let reason = (playabilityStatus["reason"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let reason, !reason.isEmpty {
            return reason
        }

        return "Track is unavailable for offline download."
    }

    static func requiresPlayerJavaScript(for formats: [[String: Any]]) -> Bool {
        formats.contains { format in
            if YouTubeStreamURLResolver.encryptedSignature(from: format) != nil {
                return true
            }

            guard let url = YouTubeStreamURLResolver.baseURL(from: format) else {
                return false
            }

            return YouTubeStreamURLResolver.queryValue(name: "n", in: url) != nil
        }
    }

    private static func audioFormats(from playerResponse: [String: Any]) -> [[String: Any]] {
        guard let streamingData = playerResponse["streamingData"] as? [String: Any] else {
            return []
        }

        let adaptiveFormats = streamingData["adaptiveFormats"] as? [[String: Any]] ?? []
        let formats = streamingData["formats"] as? [[String: Any]] ?? []
        let allFormats = adaptiveFormats + formats

        let audioOnly = allFormats.filter { format in
            guard let mimeType = format["mimeType"] as? String else { return false }
            return mimeType.contains("audio/")
        }

        return audioOnly.sorted { lhs, rhs in
            let lhsScore = Self.formatScore(lhs)
            let rhsScore = Self.formatScore(rhs)
            return lhsScore > rhsScore
        }
    }

    private static func formatScore(_ format: [String: Any]) -> Int {
        let mimeType = (format["mimeType"] as? String) ?? ""
        let bitrate = (format["bitrate"] as? Int) ?? 0
        let contentLength = Self.intValue(format["contentLength"]) ?? 0
        let mimeBonus = mimeType.contains("audio/mp4") ? 1_000_000_000 : 0
        return mimeBonus + bitrate + Int(contentLength / 10000)
    }

    static func url(from format: [String: Any]) -> URL? {
        YouTubeStreamURLResolver.baseURL(from: format)
    }

    static func downloadAudio(
        from url: URL,
        mimeType: String,
        song: Song,
        rootURL: URL,
        fileManager: FileManager
    ) async throws -> DownloadedAudio {
        let tempURL: URL
        if url.isFileURL {
            tempURL = url
        } else {
            let downloaded = try await URLSession.shared.download(from: url)
            tempURL = downloaded.0
            guard let httpResponse = downloaded.1 as? HTTPURLResponse, (200 ..< 300).contains(httpResponse.statusCode) else {
                throw YTMusicError.apiError(message: "Failed to download audio for \(song.title)", code: nil)
            }
            if let responseMimeType = httpResponse.value(forHTTPHeaderField: "Content-Type"), !responseMimeType.isEmpty {
                return try await Self.persistDownloadedAudio(
                    tempURL: tempURL,
                    mimeType: responseMimeType,
                    song: song,
                    rootURL: rootURL,
                    fileManager: fileManager
                )
            }
        }

        let effectiveMimeType = mimeType.isEmpty ? Self.mimeType(for: tempURL.pathExtension) : mimeType
        return try await Self.persistDownloadedAudio(
            tempURL: tempURL,
            mimeType: effectiveMimeType,
            song: song,
            rootURL: rootURL,
            fileManager: fileManager
        )
    }

    static func persistDownloadedAudio(
        tempURL: URL,
        mimeType: String,
        song: Song,
        rootURL: URL,
        fileManager: FileManager
    ) async throws -> DownloadedAudio {
        let sourceExtension = tempURL.pathExtension.isEmpty
            ? Self.preferredAudioExtension(for: mimeType)
            : tempURL.pathExtension.lowercased()
        let downloadedSize = try fileManager.attributesOfItem(atPath: tempURL.path)[.size] as? NSNumber
        let byteCount = downloadedSize?.int64Value ?? 0

        let mediaDirectory = rootURL.appendingPathComponent(Self.Constants.mediaFolderName, isDirectory: true)
        try fileManager.createDirectory(at: mediaDirectory, withIntermediateDirectories: true)
        let sourceURL = mediaDirectory.appendingPathComponent("\(Self.sanitizedFileName(song.videoId)).\(sourceExtension)")
        if let enumerator = fileManager.enumerator(
            at: mediaDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) {
            while let fileURL = enumerator.nextObject() as? URL {
                if fileURL.lastPathComponent.hasPrefix(Self.sanitizedFileName(song.videoId)) {
                    try? fileManager.removeItem(at: fileURL)
                }
            }
        }
        if fileManager.fileExists(atPath: sourceURL.path) {
            try? fileManager.removeItem(at: sourceURL)
        }
        try fileManager.copyItem(at: tempURL, to: sourceURL)

        let finalURL: URL
        if sourceExtension == "mp3" {
            finalURL = sourceURL
        } else if let converted = try? await Self.convertToMP3(sourceURL: sourceURL, song: song, rootURL: rootURL) {
            finalURL = converted
            try? fileManager.removeItem(at: sourceURL)
        } else {
            finalURL = sourceURL
        }

        let thumbnailFileName = await Self.persistThumbnail(
            song: song,
            rootURL: rootURL,
            fileManager: fileManager
        )

        return DownloadedAudio(
            fileName: finalURL.lastPathComponent,
            fileExtension: finalURL.pathExtension,
            mimeType: mimeType.isEmpty ? Self.mimeType(for: finalURL.pathExtension) : mimeType,
            byteCount: byteCount,
            thumbnailFileName: thumbnailFileName
        )
    }

    static func persistThumbnail(
        song: Song,
        rootURL: URL,
        fileManager: FileManager
    ) async -> String? {
        guard let thumbnailSourceURL = song.thumbnailURL?.highQualityThumbnailURL ?? song.fallbackThumbnailURL else {
            return nil
        }

        do {
            let (tempURL, mimeType) = try await Self.downloadThumbnailData(from: thumbnailSourceURL)
            let thumbnailExtension = Self.preferredThumbnailExtension(
                mimeType: mimeType,
                url: thumbnailSourceURL,
                fallbackExtension: tempURL.pathExtension
            )

            let mediaDirectory = rootURL.appendingPathComponent(Self.Constants.mediaFolderName, isDirectory: true)
            try fileManager.createDirectory(at: mediaDirectory, withIntermediateDirectories: true)

            let thumbnailFileName = "\(Self.sanitizedFileName(song.videoId))-thumb.\(thumbnailExtension)"
            let thumbnailURL = mediaDirectory.appendingPathComponent(thumbnailFileName)
            if fileManager.fileExists(atPath: thumbnailURL.path) {
                try? fileManager.removeItem(at: thumbnailURL)
            }

            if tempURL.isFileURL {
                try fileManager.copyItem(at: tempURL, to: thumbnailURL)
            } else {
                try Data(contentsOf: tempURL).write(to: thumbnailURL, options: .atomic)
            }

            return thumbnailFileName
        } catch {
            DiagnosticsLogger.ui.warning(
                "Failed to save thumbnail for \(song.title, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            return nil
        }
    }

    private static func downloadThumbnailData(from url: URL) async throws -> (URL, String?) {
        if url.isFileURL {
            return (url, self.mimeType(for: url.pathExtension))
        }

        let downloaded = try await URLSession.shared.download(from: url)
        let tempURL = downloaded.0
        guard let httpResponse = downloaded.1 as? HTTPURLResponse, (200 ..< 300).contains(httpResponse.statusCode) else {
            throw YTMusicError.apiError(message: "Failed to download thumbnail", code: nil)
        }
        return (tempURL, httpResponse.value(forHTTPHeaderField: "Content-Type"))
    }

    private static func preferredThumbnailExtension(
        mimeType: String?,
        url: URL,
        fallbackExtension: String
    ) -> String {
        if let mimeType {
            if mimeType.contains("image/webp") {
                return "webp"
            }
            if mimeType.contains("image/png") {
                return "png"
            }
            if mimeType.contains("image/jpeg") || mimeType.contains("image/jpg") {
                return "jpg"
            }
        }

        let pathExtension = url.pathExtension.isEmpty ? fallbackExtension : url.pathExtension
        return pathExtension.isEmpty ? "jpg" : pathExtension.lowercased()
    }

    private static func convertToMP3(sourceURL: URL, song: Song, rootURL: URL) async throws -> URL {
        let outputURL = Self.mediaFileURL(
            rootURL: rootURL,
            videoId: song.videoId,
            fileExtension: "mp3"
        )
        if FileManager.default.fileExists(atPath: outputURL.path) {
            return outputURL
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
        process.arguments = [sourceURL.path, outputURL.path, "-f", "mp3", "-d", "mp3"]

        let pipe = Pipe()
        process.standardError = pipe
        process.standardOutput = pipe

        try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { _ in
                if process.terminationStatus == 0 {
                    continuation.resume(returning: ())
                } else {
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    let message = String(data: data, encoding: .utf8) ?? "afconvert failed"
                    continuation.resume(throwing: YTMusicError.unknown(message: message))
                }
            }

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }

        return outputURL
    }

    private static func preferredAudioExtension(for mimeType: String) -> String {
        if mimeType.contains("audio/mpeg") {
            return "mp3"
        }
        if mimeType.contains("audio/mp4") {
            return "m4a"
        }
        if mimeType.contains("audio/x-caf") {
            return "caf"
        }
        if mimeType.contains("audio/wav") || mimeType.contains("audio/x-wav") {
            return "wav"
        }
        if mimeType.contains("audio/webm") {
            return "webm"
        }
        return "bin"
    }

    private static func mimeType(for fileExtension: String) -> String {
        switch fileExtension.lowercased() {
        case "mp3": "audio/mpeg"
        case "m4a", "mp4": "audio/mp4"
        case "caf": "audio/x-caf"
        case "wav": "audio/wav"
        case "webm": "audio/webm"
        default: "application/octet-stream"
        }
    }

    private static func intValue(_ value: Any?) -> Int64? {
        switch value {
        case let intValue as Int:
            Int64(intValue)
        case let int64Value as Int64:
            int64Value
        case let number as NSNumber:
            number.int64Value
        case let string as String:
            Int64(string)
        default:
            nil
        }
    }

    private static func sanitizedFileName(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let scalarString = value.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }
        return String(scalarString)
    }

    private func playlistsFolderURL() -> URL {
        self.rootURL.appendingPathComponent(Self.Constants.playlistsFolderName, isDirectory: true)
    }

    private func indexFileURL() -> URL {
        Self.indexFileURL(rootURL: self.rootURL)
    }

    private static func indexFileURL(rootURL: URL) -> URL {
        rootURL.appendingPathComponent(Constants.indexFileName)
    }

    private static func mediaFileURL(rootURL: URL, videoId: String, fileExtension: String) -> URL {
        rootURL
            .appendingPathComponent(Constants.mediaFolderName, isDirectory: true)
            .appendingPathComponent("\(self.sanitizedFileName(videoId)).\(fileExtension)")
    }

    static func defaultRootURL() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return appSupport.appendingPathComponent("Kaset", isDirectory: true).appendingPathComponent(
            Self.Constants.folderName,
            isDirectory: true
        )
    }
}
