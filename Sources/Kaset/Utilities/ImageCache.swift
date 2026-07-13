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

    /// Maximum disk cache size in bytes (200MB).
    private static let defaultMaxDiskCacheSize: Int64 = 200 * 1024 * 1024

    /// Reconcile the approximate disk-size counter periodically to account for
    /// external changes without scanning the cache directory after every write.
    private static let defaultDiskEvictionWriteThreshold = 32

    private let memoryCache = NSCache<NSString, NSImage>()
    /// Keyed by URL + target size (the memory-cache key), so an in-flight
    /// 320×180 fetch is not awaited by a 1280×720 request and handed back the
    /// small downsampled image.
    private var inFlight: [NSString: Task<NSImage?, Never>] = [:]
    private var rawDataInFlight: [String: Task<Data?, Never>] = [:]
    private let fileManager = FileManager.default
    private let session: URLSession
    private let diskCacheURL: URL
    private let maxDiskCacheSize: Int64
    private let diskEvictionWriteThreshold: Int
    private var estimatedDiskCacheSize: Int64?
    private var writesSinceDiskEvictionCheck = 0
    private var diskEvictionTask: Task<Void, Never>?
    private(set) var diskCacheSizeScanCountForTesting = 0

    init(
        diskCacheURL: URL? = nil,
        maxDiskCacheSize: Int64 = ImageCache.defaultMaxDiskCacheSize,
        initialEstimatedDiskCacheSize: Int64? = nil,
        diskEvictionWriteThreshold: Int = ImageCache.defaultDiskEvictionWriteThreshold,
        startsEvictionTask: Bool = true,
        monitorsMemoryPressure: Bool = true,
        session: URLSession = .shared
    ) {
        self.memoryCache.countLimit = 200
        self.memoryCache.totalCostLimit = 50 * 1024 * 1024 // 50MB

        // Set up disk cache directory
        if let diskCacheURL {
            self.diskCacheURL = diskCacheURL
        } else {
            let cacheDir = self.fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first!
            self.diskCacheURL = cacheDir.appendingPathComponent("com.kaset.imagecache", isDirectory: true)
        }
        self.maxDiskCacheSize = maxDiskCacheSize
        self.diskEvictionWriteThreshold = max(1, diskEvictionWriteThreshold)
        self.estimatedDiskCacheSize = initialEstimatedDiskCacheSize
        self.session = session
        try? self.fileManager.createDirectory(at: self.diskCacheURL, withIntermediateDirectories: true)

        // Set up memory pressure monitoring.
        if monitorsMemoryPressure {
            Self.setupMemoryPressureMonitoring(cache: self)
        }

        // Evict disk cache if needed on startup and initialize the size estimate.
        // Perform file system I/O off the main actor.
        if startsEvictionTask {
            Task(priority: .utility) {
                await self.scheduleDiskEviction(force: true)
            }
        }
    }

    /// Sets up monitoring for system memory pressure notifications.
    private static func setupMemoryPressureMonitoring(cache: ImageCache) {
        // Use DispatchSource for memory pressure monitoring
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler {
            Task {
                await cache.clearMemoryCache()
            }
        }
        source.resume()
        // Store the source to prevent deallocation
        Self.memoryPressureSource = source
    }

    // swiftformat:disable modifierOrder
    /// Dispatch source for memory pressure monitoring.
    nonisolated(unsafe) private static var memoryPressureSource: DispatchSourceMemoryPressure?
    // swiftformat:enable modifierOrder

    /// Fetches an image from cache or network.
    /// - Parameters:
    ///   - url: The URL of the image to fetch.
    ///   - targetSize: Optional target size for downsampling. If provided, the image will be
    ///                 downsampled to fit this size, significantly reducing memory usage.
    func image(for url: URL, targetSize: CGSize? = nil) async -> NSImage? {
        // Memory cache is keyed by URL *and* target size: the same thumbnail is
        // requested at different sizes (Home cards at 320×180, the watch
        // placeholder at 1280×720). Keying by URL alone let the first small
        // decode satisfy a later large request, leaving the large view blurry.
        let memoryKey = Self.memoryKey(for: url, targetSize: targetSize)
        if let cached = memoryCache.object(forKey: memoryKey) {
            return cached
        }

        // Coalesce concurrent cold requests for the same URL+size BEFORE any
        // suspension point. The disk read runs off the actor (so decodes
        // parallelize across cores), but registering the in-flight task first
        // means two callers — e.g. the first-screen prefetch and a visible card
        // — share one disk read + at most one network download instead of
        // racing past each other and both downloading.
        if let existing = inFlight[memoryKey] {
            return await existing.value
        }

        let task = Task<NSImage?, Never> { [self] in
            // Disk holds the raw bytes (URL-keyed) and re-decodes at the
            // requested size, so different sizes share one download but get
            // distinct decodes. loadFromDisk is nonisolated (immutable state),
            // run detached so the decode does not serialize on the actor.
            if let diskImage = await Task.detached(priority: .userInitiated, operation: {
                self.loadFromDisk(url: url, targetSize: targetSize)
            }).value {
                self.memoryCache.setObject(diskImage, forKey: memoryKey)
                return diskImage
            }

            // Cold miss: download raw bytes once per URL, then decode independently per target size.
            guard let data = await self.rawImageData(for: url),
                  let image = Self.createImage(from: data, targetSize: targetSize)
            else { return nil }
            let cost = targetSize != nil ? Int(image.size.width * image.size.height * 4) : data.count
            self.memoryCache.setObject(image, forKey: memoryKey, cost: cost)
            return image
        }

        self.inFlight[memoryKey] = task
        let result = await task.value
        self.inFlight.removeValue(forKey: memoryKey)
        return result
    }

    /// Memory-cache key combining the URL with the requested decode size, so
    /// decodes at different sizes for the same URL do not evict one another.
    private static func memoryKey(for url: URL, targetSize: CGSize?) -> NSString {
        guard let targetSize else { return url.absoluteString as NSString }
        return "\(url.absoluteString)@\(Int(targetSize.width))x\(Int(targetSize.height))" as NSString
    }

    private static func isSuccessfulResponse(_ response: URLResponse) -> Bool {
        guard let httpResponse = response as? HTTPURLResponse else { return true }
        return (200 ..< 300).contains(httpResponse.statusCode)
    }

    private func rawImageData(for url: URL) async -> Data? {
        let key = self.cacheKey(for: url)
        if let existing = self.rawDataInFlight[key] {
            return await existing.value
        }

        let task = Task<Data?, Never> { [session] in
            do {
                let (data, response) = try await session.data(from: url)
                guard Self.isSuccessfulResponse(response) else { return nil }
                return data
            } catch {
                return nil
            }
        }
        self.rawDataInFlight[key] = task
        let data = await task.value
        self.rawDataInFlight.removeValue(forKey: key)
        if let data {
            self.saveToDisk(url: url, data: data)
        }
        return data
    }

    private static func uniqued(_ urls: [URL]) -> [URL] {
        var seen = Set<URL>()
        return urls.filter { seen.insert($0).inserted }
    }

    /// Prefetches images with controlled concurrency to avoid network congestion.
    /// Supports cooperative cancellation from SwiftUI's structured concurrency.
    /// - Parameters:
    ///   - urls: URLs to prefetch.
    ///   - targetSize: Optional target size for downsampling.
    ///   - maxConcurrent: Maximum number of concurrent fetches (default: 4).
    func prefetch(urls: [URL], targetSize: CGSize? = nil, maxConcurrent: Int = maxConcurrentPrefetch) async {
        let urls = Self.uniqued(urls)
        let maxConcurrent = max(1, maxConcurrent)

        // Use structured concurrency directly - cancellation propagates automatically
        // when SwiftUI's .task is cancelled (view disappears or id changes)
        await withTaskGroup(of: Void.self) { group in
            var inProgress = 0
            for url in urls {
                // Check cancellation before starting new work
                guard !Task.isCancelled else { break }

                // Skip if already in memory cache
                if self.memoryCache.object(forKey: Self.memoryKey(for: url, targetSize: targetSize)) != nil {
                    continue
                }

                // Wait for a slot if we're at capacity
                if inProgress >= maxConcurrent {
                    await group.next()
                    inProgress -= 1
                }

                group.addTask(priority: .utility) {
                    guard !Task.isCancelled else { return }
                    _ = await self.image(for: url, targetSize: targetSize)
                }
                inProgress += 1
            }
            // Wait for remaining tasks (will be cancelled if parent is cancelled)
            await group.waitForAll()
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
        self.rawDataInFlight.removeAll()
    }

    /// Clears both memory and disk caches.
    func clearAllCaches() {
        self.clearMemoryCache()
        try? self.fileManager.removeItem(at: self.diskCacheURL)
        try? self.fileManager.createDirectory(at: self.diskCacheURL, withIntermediateDirectories: true)
        self.estimatedDiskCacheSize = 0
    }

    /// Returns the total size of the disk cache in bytes.
    func diskCacheSize() -> Int64 {
        let size = self.scanDiskCacheSize()
        self.estimatedDiskCacheSize = size
        return size
    }

    private func scanDiskCacheSize() -> Int64 {
        self.diskCacheSizeScanCountForTesting += 1
        var totalSize: Int64 = 0
        guard let enumerator = fileManager.enumerator(
            at: diskCacheURL,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }
        for case let fileURL as URL in enumerator {
            if let fileSize = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                totalSize += Int64(fileSize)
            }
        }
        return totalSize
    }

    // MARK: - Disk Cache Helpers

    // swiftformat:disable modifierOrder
    nonisolated private func cacheKey(for url: URL) -> String {
        let data = Data(url.absoluteString.utf8)
        let hash = SHA256.hash(data: data)
        return hash.compactMap { String(format: "%02x", $0) }.joined()
    }

    nonisolated private func diskCachePath(for url: URL) -> URL {
        self.diskCacheURL.appendingPathComponent(self.cacheKey(for: url))
    }

    /// Reads and decodes a cached image off the actor. `nonisolated` so warm
    /// disk hits — `Data(contentsOf:)` plus the ImageIO downsample in
    /// `createImage` — run concurrently across cores instead of serializing on
    /// the `ImageCache` actor (every visible card used to queue its decode
    /// behind the others). Touches only immutable state (`diskCacheURL`).
    nonisolated private func loadFromDisk(url: URL, targetSize: CGSize? = nil) -> NSImage? {
        let path = self.diskCachePath(for: url)
        guard let data = try? Data(contentsOf: path) else {
            return nil
        }
        return Self.createImage(from: data, targetSize: targetSize)
    }

    // swiftformat:enable modifierOrder

    private func saveToDisk(url: URL, data: Data) {
        let path = self.diskCachePath(for: url)
        let previousSize = self.fileSize(at: path)
        do {
            try data.write(to: path, options: .atomic)
        } catch {
            return
        }

        if let estimatedDiskCacheSize {
            self.estimatedDiskCacheSize = max(0, estimatedDiskCacheSize - previousSize + Int64(data.count))
            self.writesSinceDiskEvictionCheck += 1
            self.scheduleDiskEvictionIfNeededAfterWrite()
        } else {
            // First write before the startup/lazy size scan completes. Coalesce a
            // single forced reconciliation instead of scanning on every save.
            self.scheduleDiskEviction(force: true)
        }
    }

    private func fileSize(at url: URL) -> Int64 {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else { return 0 }
        return Int64(size)
    }

    private func scheduleDiskEvictionIfNeededAfterWrite() {
        guard let estimatedDiskCacheSize else {
            self.scheduleDiskEviction(force: true)
            return
        }

        let shouldReconcile = self.writesSinceDiskEvictionCheck >= self.diskEvictionWriteThreshold
        let shouldEvict = estimatedDiskCacheSize > self.maxDiskCacheSize
        if shouldReconcile || shouldEvict {
            self.scheduleDiskEviction(force: shouldReconcile)
        }
    }

    private func scheduleDiskEviction(force: Bool = false) {
        if self.diskEvictionTask != nil {
            return
        }
        if !force, let estimatedDiskCacheSize, estimatedDiskCacheSize <= self.maxDiskCacheSize {
            return
        }

        let task = Task(priority: .utility) {
            await self.evictDiskCacheIfNeeded(force: force)
        }
        self.diskEvictionTask = task
    }

    // MARK: - Disk Cache Eviction

    /// Metadata for a cached file used during eviction.
    private struct CachedFileInfo {
        let url: URL
        let modificationDate: Date
        let fileSize: Int
    }

    /// Evicts oldest files until disk cache is under the size limit.
    /// Uses LRU (Least Recently Used) eviction based on file modification dates.
    /// Marked async to document the I/O-bound nature and satisfy actor isolation.
    private func evictDiskCacheIfNeeded(force: Bool = false) async {
        defer {
            self.diskEvictionTask = nil
            self.writesSinceDiskEvictionCheck = 0
        }

        if !force, let estimatedDiskCacheSize, estimatedDiskCacheSize <= self.maxDiskCacheSize {
            return
        }

        // One directory pass gives both exact size and eviction metadata. This
        // avoids the previous save path's diskCacheSize() pass plus a second
        // directory listing to choose victims.
        guard let files = self.cachedFilesForEviction() else { return }
        let currentSize = files.reduce(Int64(0)) { $0 + Int64($1.fileSize) }
        self.estimatedDiskCacheSize = currentSize
        guard currentSize > self.maxDiskCacheSize else { return }

        let sortedFiles = files.sorted { $0.modificationDate < $1.modificationDate }
        var sizeToFree = currentSize - self.maxDiskCacheSize
        var freedSize: Int64 = 0
        for fileInfo in sortedFiles where sizeToFree > 0 {
            do {
                try self.fileManager.removeItem(at: fileInfo.url)
                let fileSize = Int64(fileInfo.fileSize)
                sizeToFree -= fileSize
                freedSize += fileSize
            } catch {
                continue
            }
        }
        self.estimatedDiskCacheSize = max(0, currentSize - freedSize)
    }

    private func cachedFilesForEviction() -> [CachedFileInfo]? {
        self.diskCacheSizeScanCountForTesting += 1
        guard let files = try? fileManager.contentsOfDirectory(
            at: diskCacheURL,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        return files.compactMap { url -> CachedFileInfo? in
            guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
                  let date = values.contentModificationDate,
                  let size = values.fileSize
            else { return nil }
            return CachedFileInfo(url: url, modificationDate: date, fileSize: size)
        }
    }

    func saveToDiskForTesting(url: URL, data: Data) {
        self.saveToDisk(url: url, data: data)
    }

    func estimatedDiskCacheSizeForTesting() -> Int64? {
        self.estimatedDiskCacheSize
    }

    func evictDiskCacheIfNeededForTesting(force: Bool = false) async {
        await self.evictDiskCacheIfNeeded(force: force)
    }

    func waitForScheduledDiskEvictionForTesting() async {
        guard let task = self.diskEvictionTask else { return }
        await task.value
    }

    func diskCachePathForTesting(url: URL) -> URL {
        self.diskCachePath(for: url)
    }
}
