import Foundation
import os

// MARK: - OfflineService

/// Manages offline song downloads and the local song manifest.
///
/// Songs are persisted as individual JSON files keyed by `videoId` in a
/// dedicated cache directory, with a manifest file tracking all downloaded entries.
@MainActor
@Observable
final class OfflineService {
    static let shared = OfflineService()

    private let cacheDir: URL
    private let manifestURL: URL
    private let logger = DiagnosticsLogger.api

    /// All songs that have been downloaded for offline access.
    private(set) var downloadedSongs: [Song] = []

    var isOfflineModeActive: Bool {
        SettingsManager.shared.offlineModeEnabled
    }

    /// Number of downloaded songs.
    var downloadCount: Int {
        self.downloadedSongs.count
    }

    private init() {
        let fm = FileManager.default
        let caches = try? fm.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let base = caches ?? URL(fileURLWithPath: NSTemporaryDirectory())
        self.cacheDir = base.appendingPathComponent("KasetOfflineCache", isDirectory: true)
        self.manifestURL = self.cacheDir.appendingPathComponent("offline_manifest.json")
        try? fm.createDirectory(at: self.cacheDir, withIntermediateDirectories: true)
        self.downloadedSongs = Self.loadManifest(from: self.manifestURL)
    }

    // MARK: - Public API

    /// Downloads a song for offline access by persisting its metadata.
    func downloadSong(_ song: Song) {
        guard !self.isDownloaded(videoId: song.videoId) else {
            self.logger.info("Song already downloaded: \(song.title, privacy: .public)")
            return
        }

        // Write individual song file
        let songFile = self.songFile(for: song.videoId)
        do {
            let data = try JSONEncoder().encode(song)
            try data.write(to: songFile, options: .atomic)
        } catch {
            self.logger.error("Failed to write offline song \(song.title, privacy: .public): \(error.localizedDescription)")
            return
        }

        self.downloadedSongs.append(song)
        self.saveManifest()
        self.logger.info("Downloaded song for offline: \(song.title, privacy: .public)")
    }

    /// Removes a downloaded song by its video ID.
    func removeSong(videoId: String) {
        let songFile = self.songFile(for: videoId)
        try? FileManager.default.removeItem(at: songFile)

        self.downloadedSongs.removeAll { $0.videoId == videoId }
        self.saveManifest()
        self.logger.info("Removed offline song: \(videoId)")
    }

    /// Returns `true` if the song with the given video ID is downloaded.
    func isDownloaded(videoId: String) -> Bool {
        self.downloadedSongs.contains { $0.videoId == videoId }
    }

    /// Removes all downloaded songs and clears the cache.
    func clearAllDownloads() {
        try? FileManager.default.removeItem(at: self.cacheDir)
        try? FileManager.default.createDirectory(at: self.cacheDir, withIntermediateDirectories: true)
        self.downloadedSongs.removeAll()
        self.logger.info("Cleared all offline downloads")
    }

    // MARK: - Legacy API (used by existing callers)

    func cacheResponse(_ data: Data, for key: String) {
        let file = self.cacheFile(for: key)
        do {
            try data.write(to: file, options: .atomic)
        } catch {
            self.logger.error("Failed to write offline cache for \(key): \(error.localizedDescription)")
        }
    }

    func loadCachedResponse(for key: String) -> Data? {
        let file = self.cacheFile(for: key)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        return try? Data(contentsOf: file)
    }

    func clearCache() {
        self.clearAllDownloads()
    }

    // MARK: - Persistence

    private func saveManifest() {
        do {
            let data = try JSONEncoder().encode(self.downloadedSongs)
            try data.write(to: self.manifestURL, options: .atomic)
        } catch {
            self.logger.error("Failed to save offline manifest: \(error.localizedDescription)")
        }
    }

    private static func loadManifest(from url: URL) -> [Song] {
        guard let data = try? Data(contentsOf: url),
              let songs = try? JSONDecoder().decode([Song].self, from: data)
        else {
            return []
        }
        return songs
    }

    private func songFile(for videoId: String) -> URL {
        self.cacheDir.appendingPathComponent("song_\(videoId).json")
    }

    private func cacheFile(for key: String) -> URL {
        let safe = key.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? UUID().uuidString
        return self.cacheDir.appendingPathComponent(safe)
    }
}
