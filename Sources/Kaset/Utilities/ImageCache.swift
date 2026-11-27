import AppKit
import CoreGraphics
import CryptoKit
import Foundation
import ImageIO

actor ImageCache {
    static let shared = ImageCache()

    private static let maxConcurrentPrefetch = 4

    private static let defaultMaxDiskCacheSize: Int64 = 200 * 1024 * 1024

    private static let defaultDiskEvictionWriteThreshold = 32

    // swiftformat:disable modifierOrder
    nonisolated(unsafe) private let memoryCache = NSCache<NSString, NSImage>()
    // swiftformat:enable modifierOrder
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
        self.memoryCache.totalCostLimit = 50 * 1024 * 1024

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

        if monitorsMemoryPressure {
            Self.setupMemoryPressureMonitoring(cache: self)
        }

        if startsEvictionTask {
            Task(priority: .utility) {
                await self.scheduleDiskEviction(force: true)
            }
        }
    }

    private static func setupMemoryPressureMonitoring(cache: ImageCache) {
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler {
            Task {
                await cache.clearMemoryCache()
            }
        }
        source.resume()
        Self.memoryPressureSource = source
    }

    // swiftformat:disable modifierOrder
    nonisolated(unsafe) private static var memoryPressureSource: DispatchSourceMemoryPressure?
    // swiftformat:enable modifierOrder

    nonisolated func cachedImage(for url: URL, targetSize: CGSize? = nil) -> NSImage? {
        self.memoryCache.object(forKey: Self.memoryKey(for: url, targetSize: targetSize))
    }

    func image(for url: URL, targetSize: CGSize? = nil) async -> NSImage? {
        let memoryKey = Self.memoryKey(for: url, targetSize: targetSize)
        if let cached = memoryCache.object(forKey: memoryKey) {
            return cached
        }

        if let existing = inFlight[memoryKey] {
            return await existing.value
        }

        let task = Task<NSImage?, Never> { [self] in
            if let diskImage = await Task.detached(priority: .userInitiated, operation: {
                self.loadFromDisk(url: url, targetSize: targetSize)
            }).value {
                self.memoryCache.setObject(diskImage, forKey: memoryKey)
                return diskImage
            }

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

    func prefetch(urls: [URL], targetSize: CGSize? = nil, maxConcurrent: Int = maxConcurrentPrefetch) async {
        let urls = Self.uniqued(urls)
        let maxConcurrent = max(1, maxConcurrent)

        await withTaskGroup(of: Void.self) { group in
            var inProgress = 0
            for url in urls {
                guard !Task.isCancelled else { break }

                if self.memoryCache.object(forKey: Self.memoryKey(for: url, targetSize: targetSize)) != nil {
                    continue
                }

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
            await group.waitForAll()
        }
    }

    private static func createImage(from data: Data, targetSize: CGSize?) -> NSImage? {
        guard let targetSize else {
            return NSImage(data: data)
        }

        let options: [CFString: Any] = [
            kCGImageSourceShouldCache: false,
        ]

        guard let source = CGImageSourceCreateWithData(data as CFData, options as CFDictionary) else {
            return NSImage(data: data)
        }

        let maxDimension = max(targetSize.width, targetSize.height) * 2
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

    func clearMemoryCache() {
        self.memoryCache.removeAllObjects()
        self.inFlight.removeAll()
        self.rawDataInFlight.removeAll()
    }

    func clearAllCaches() {
        self.clearMemoryCache()
        try? self.fileManager.removeItem(at: self.diskCacheURL)
        try? self.fileManager.createDirectory(at: self.diskCacheURL, withIntermediateDirectories: true)
        self.estimatedDiskCacheSize = 0
    }

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

    // swiftformat:disable modifierOrder
    nonisolated private func cacheKey(for url: URL) -> String {
        let data = Data(url.absoluteString.utf8)
        let hash = SHA256.hash(data: data)
        return hash.compactMap { String(format: "%02x", $0) }.joined()
    }

    nonisolated private func diskCachePath(for url: URL) -> URL {
        self.diskCacheURL.appendingPathComponent(self.cacheKey(for: url))
    }

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

    private struct CachedFileInfo {
        let url: URL
        let modificationDate: Date
        let fileSize: Int
    }

    private func evictDiskCacheIfNeeded(force: Bool = false) async {
        defer {
            self.diskEvictionTask = nil
            self.writesSinceDiskEvictionCheck = 0
        }

        if !force, let estimatedDiskCacheSize, estimatedDiskCacheSize <= self.maxDiskCacheSize {
            return
        }

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
