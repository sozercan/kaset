import AppKit
import CoreGraphics
import CryptoKit
import Foundation
import ImageIO

/// Thread-safe image cache with memory and disk caching.
actor ImageCache {
    static let shared = ImageCache()

    /// Maximum concurrent network fetches during prefetching.
    private static let maxConcurrentPrefetch = 4

    private let memoryCache = NSCache<NSURL, NSImage>()
    private var inFlight: [URL: Task<NSImage?, Never>] = [:]
    private let fileManager = FileManager.default
    private let diskCacheURL: URL

    private init() {
        self.memoryCache.countLimit = 200
        self.memoryCache.totalCostLimit = 50 * 1024 * 1024 // 50MB

        // Set up disk cache directory
        let cacheDir = self.fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first!
        self.diskCacheURL = cacheDir.appendingPathComponent("com.kaset.imagecache", isDirectory: true)
        try? self.fileManager.createDirectory(at: self.diskCacheURL, withIntermediateDirectories: true)
    }

    /// Fetches an image from cache or network.
    /// - Parameters:
    ///   - url: The URL of the image to fetch.
    ///   - targetSize: Optional target size for downsampling. If provided, the image will be
    ///                 downsampled to fit this size, significantly reducing memory usage.
    func image(for url: URL, targetSize: CGSize? = nil) async -> NSImage? {
        // Check memory cache
        if let cached = memoryCache.object(forKey: url as NSURL) {
            return cached
        }

        // Check disk cache
        if let diskImage = loadFromDisk(url: url, targetSize: targetSize) {
            self.memoryCache.setObject(diskImage, forKey: url as NSURL)
            return diskImage
        }

        // Check if already fetching
        if let existing = inFlight[url] {
            return await existing.value
        }

        // Fetch from network
        let task = Task<NSImage?, Never> {
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                guard let image = Self.createImage(from: data, targetSize: targetSize) else { return nil }
                let cost = targetSize != nil ? Int(image.size.width * image.size.height * 4) : data.count
                self.memoryCache.setObject(image, forKey: url as NSURL, cost: cost)
                self.saveToDisk(url: url, data: data)
                return image
            } catch {
                return nil
            }
        }

        self.inFlight[url] = task
        let result = await task.value
        self.inFlight.removeValue(forKey: url)
        return result
    }

    /// Prefetches images with controlled concurrency to avoid network congestion.
    /// - Parameters:
    ///   - urls: URLs to prefetch.
    ///   - targetSize: Optional target size for downsampling.
    ///   - maxConcurrent: Maximum number of concurrent fetches (default: 4).
    func prefetch(urls: [URL], targetSize: CGSize? = nil, maxConcurrent: Int = maxConcurrentPrefetch)
        async
    {
        await withTaskGroup(of: Void.self) { group in
            var inProgress = 0
            for url in urls {
                // Wait for a slot if we're at capacity
                if inProgress >= maxConcurrent {
                    await group.next()
                    inProgress -= 1
                }

                group.addTask(priority: .utility) {
                    _ = await self.image(for: url, targetSize: targetSize)
                }
                inProgress += 1
            }
            // Wait for remaining tasks
            await group.waitForAll()
        }
    }

    /// Legacy fire-and-forget prefetch for backward compatibility.
    func prefetch(urls: [URL]) {
        Task.detached(priority: .utility) {
            await self.prefetch(urls: urls, targetSize: CGSize(width: 320, height: 320))
        }
    }

    // MARK: - Image Creation with Downsampling

    /// Creates an NSImage from data, optionally downsampling for memory efficiency.
    private static func createImage(from data: Data, targetSize: CGSize?) -> NSImage? {
        guard let targetSize else {
            return NSImage(data: data)
        }

        // Use ImageIO for memory-efficient downsampling
        let options: [CFString: Any] = [
            kCGImageSourceShouldCache: false,
        ]

        guard let source = CGImageSourceCreateWithData(data as CFData, options as CFDictionary) else {
            return NSImage(data: data)
        }

        let maxDimension = max(targetSize.width, targetSize.height) * 2 // Account for Retina
        let downsampleOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDimension,
        ]

        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(
            source, 0, downsampleOptions as CFDictionary
        )
        else {
            return NSImage(data: data)
        }

        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }

    /// Clears the memory cache.
    func clearMemoryCache() {
        self.memoryCache.removeAllObjects()
        self.inFlight.removeAll()
    }

    /// Clears both memory and disk caches.
    func clearAllCaches() {
        self.clearMemoryCache()
        try? self.fileManager.removeItem(at: self.diskCacheURL)
        try? self.fileManager.createDirectory(at: self.diskCacheURL, withIntermediateDirectories: true)
    }

    // MARK: - Disk Cache Helpers

    private func cacheKey(for url: URL) -> String {
        let data = Data(url.absoluteString.utf8)
        let hash = SHA256.hash(data: data)
        return hash.compactMap { String(format: "%02x", $0) }.joined()
    }

    private func diskCachePath(for url: URL) -> URL {
        self.diskCacheURL.appendingPathComponent(self.cacheKey(for: url))
    }

    private func loadFromDisk(url: URL, targetSize: CGSize? = nil) -> NSImage? {
        let path = self.diskCachePath(for: url)
        guard let data = try? Data(contentsOf: path) else {
            return nil
        }
        return Self.createImage(from: data, targetSize: targetSize)
    }

    private func saveToDisk(url: URL, data: Data) {
        let path = self.diskCachePath(for: url)
        try? data.write(to: path, options: .atomic)
    }
}
