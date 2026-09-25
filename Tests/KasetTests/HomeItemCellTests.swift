import AppKit
import SwiftUI
import Testing
@testable import Kaset

// MARK: - HomeItemCellTests

@Suite(.tags(.model))
@MainActor
struct HomeItemCellTests {
    private static func song(
        id: String = "v1",
        title: String = "Song",
        artists: String = "Artist",
        musicVideoType: MusicVideoType? = nil,
        isExplicit: Bool? = nil
    ) -> Song {
        Song(
            id: id,
            title: title,
            artists: [Artist(id: "a1", name: artists)],
            videoId: id,
            musicVideoType: musicVideoType,
            isExplicit: isExplicit
        )
    }

    @Test("Video songs render wide, everything else square")
    func widthFollowsVideoMode() {
        #expect(HomeItemCell.width(for: .song(Self.song())) == HomeItemCell.squareWidth)
        #expect(HomeItemCell.width(for: .song(Self.song(musicVideoType: .omv))) == HomeItemCell.videoWidth)
        #expect(HomeItemCell.width(for: .song(Self.song(musicVideoType: .atv))) == HomeItemCell.squareWidth)
        #expect(HomeItemCell.width(for: .album(Album(id: "al", title: "Album", artists: nil, thumbnailURL: nil, year: nil, trackCount: nil))) == HomeItemCell.squareWidth)
    }

    @Test("Video songs are detected from the video type or a views subtitle")
    func videoSongDetection() {
        #expect(HomeSectionItem.song(Self.song(musicVideoType: .omv)).isVideoSong)
        #expect(!HomeSectionItem.song(Self.song(musicVideoType: .atv)).isVideoSong)
        #expect(HomeSectionItem.song(Self.song(artists: "1.2M views")).isVideoSong)
        #expect(!HomeSectionItem.song(Self.song(artists: "Artist")).isVideoSong)
    }

    @Test("Thumbnail candidates are unique and prefer the wide frame for video")
    func thumbnailCandidates() {
        let plain = HomeSectionItem.song(Self.song())
        let plainURLs = HomeItemCell.thumbnailURLs(for: plain)
        #expect(plainURLs.count <= 1)

        let video = HomeSectionItem.song(Self.song(musicVideoType: .omv))
        let videoURLs = HomeItemCell.thumbnailURLs(for: video)
        #expect(Set(videoURLs).count == videoURLs.count)
        if let first = videoURLs.first, case let .song(song) = video {
            #expect(first == song.wideHighQualityThumbnailURL)
        }
    }

    @Test("Configuring a cell exposes title, subtitle and explicit state to accessibility")
    func accessibilityLabel() {
        let cell = HomeItemCell(frame: NSRect(x: 0, y: 0, width: 160, height: HomeItemCell.height))
        cell.configure(
            item: .song(Self.song(title: "Track", artists: "Band", isExplicit: true)),
            rank: 3,
            allowsLikeActions: false,
            quickPlayAction: nil,
            environment: EnvironmentValues()
        )
        let label = cell.accessibilityLabel() ?? ""
        #expect(label.contains("Track"))
        #expect(label.contains("Band"))
        #expect(label.contains("Explicit"))
        #expect(cell.accessibilityRole() == .button)
        // No like control without a personal account, even when hovered.
        cell.setHovered(true, animated: false)
        #expect(cell.likeButtonFrame == nil)
    }

    @Test("A reconfigured cell with the same item keeps its state without work")
    func reconfigureSameItemIsIdempotent() {
        let item = HomeSectionItem.song(Self.song(title: "Same"))
        let cell = HomeItemCell(frame: .zero)
        cell.configure(item: item, rank: nil, allowsLikeActions: false, quickPlayAction: nil, environment: EnvironmentValues())
        cell.setHovered(true, animated: false)
        cell.configure(item: item, rank: nil, allowsLikeActions: false, quickPlayAction: nil, environment: EnvironmentValues())
        #expect(cell.isHovered)
        #expect(cell.item == item)
    }

    @Test("Refreshing the same song updates the native card's metadata")
    func reconfigureSongMetadata() {
        let original = HomeSectionItem.song(Self.song(title: "Original", artists: "Artist"))
        let updated = HomeSectionItem.song(Self.song(title: "Updated", artists: "Band", isExplicit: true))
        let cell = HomeItemCell(frame: .zero)
        cell.configure(item: original, rank: nil, allowsLikeActions: false, quickPlayAction: nil, environment: EnvironmentValues())
        cell.setHovered(true, animated: false)

        cell.configure(item: updated, rank: nil, allowsLikeActions: false, quickPlayAction: nil, environment: EnvironmentValues())

        #expect(cell.item?.title == "Updated")
        #expect(cell.isHovered)
        let label = cell.accessibilityLabel() ?? ""
        #expect(label.contains("Updated"))
        #expect(label.contains("Band"))
        #expect(label.contains("Explicit"))
    }

    @Test("Changing playlist play availability updates native accessibility actions")
    func reconfigurePlaylistPlayAction() {
        let item = HomeSectionItem.playlist(Playlist(id: "playlist", title: "Playlist", description: nil, thumbnailURL: nil, trackCount: nil))
        let cell = HomeItemCell(frame: .zero)
        cell.configure(item: item, rank: nil, allowsLikeActions: false, quickPlayAction: nil, environment: EnvironmentValues())
        #expect(cell.accessibilityCustomActions()?.isEmpty == true)

        cell.configure(item: item, rank: nil, allowsLikeActions: false, quickPlayAction: {}, environment: EnvironmentValues())
        #expect(cell.accessibilityCustomActions()?.count == 1)

        cell.configure(item: item, rank: nil, allowsLikeActions: false, quickPlayAction: nil, environment: EnvironmentValues())
        #expect(cell.accessibilityCustomActions()?.isEmpty == true)
    }

    @Test("Hovered playlists and albums with a play action expose a centered play button")
    func playButtonFrame() {
        let items: [HomeSectionItem] = [
            .playlist(Playlist(id: "playlist", title: "Playlist", description: nil, thumbnailURL: nil, trackCount: nil)),
            .album(Album(id: "album", title: "Album", artists: nil, thumbnailURL: nil, year: nil, trackCount: nil)),
        ]
        for item in items {
            var plays = 0
            let cell = HomeItemCell(frame: .zero)
            cell.configure(item: item, rank: nil, allowsLikeActions: false, quickPlayAction: { plays += 1 }, environment: EnvironmentValues())
            #expect(cell.playButtonFrame == nil)

            cell.setHovered(true, animated: false)
            let frame = cell.playButtonFrame
            #expect(frame?.midX == HomeItemCell.width(for: item) / 2)
            #expect(frame?.midY == HomeItemCell.artworkHeight / 2)
            #expect(cell.subviews.count == 1)

            cell.performPlayAction()
            #expect(plays == 1)

            cell.configure(item: item, rank: nil, allowsLikeActions: false, quickPlayAction: nil, environment: EnvironmentValues())
            #expect(cell.playButtonFrame == nil)
            #expect(cell.subviews.isEmpty)
        }
    }

    @Test("Songs keep a decorative play icon without a play button")
    func songHasNoPlayButton() {
        let cell = HomeItemCell(frame: .zero)
        cell.configure(item: .song(Self.song()), rank: nil, allowsLikeActions: false, quickPlayAction: {}, environment: EnvironmentValues())
        cell.setHovered(true, animated: false)
        #expect(cell.playButtonFrame == nil)
        #expect(cell.subviews.count == 1)
    }

    @Test("Moving hover between cards releases each inactive play host")
    func releasesPlayOverlayAfterHover() {
        let cells = (0 ..< 3).map { index in
            let cell = HomeItemCell(frame: .zero)
            cell.configure(item: .song(Self.song(id: "hover-\(index)")), rank: nil, allowsLikeActions: false, quickPlayAction: nil, environment: EnvironmentValues())
            return cell
        }

        for cell in cells {
            cell.setHovered(true, animated: false)
            #expect(cells.reduce(0) { $0 + $1.subviews.count } == 1)

            cell.setHovered(false, animated: false)
            let hasNoPlayOverlays = cells.allSatisfy(\.subviews.isEmpty)
            #expect(hasNoPlayOverlays)
        }
    }

    @Test("Chart ranks have a renderable native image")
    func chartRankImage() throws {
        let cell = HomeItemCell(frame: NSRect(x: 0, y: 0, width: 160, height: HomeItemCell.height))
        cell.configure(item: .song(Self.song()), rank: 1, allowsLikeActions: false, quickPlayAction: nil, environment: EnvironmentValues())
        cell.layoutSubtreeIfNeeded()

        let rankLayer = try #require(Self.layers(in: cell.layer).first { $0.contentsGravity == .topLeft })
        _ = try Self.image(in: rankLayer)
        #expect(!rankLayer.isHidden)
    }

    @Test("Native glyphs keep their point size when the display scale changes")
    func glyphBackingScaleChanges() throws {
        let cell = HomeItemCell(frame: NSRect(x: 0, y: 0, width: 160, height: HomeItemCell.height))
        cell.configure(item: .song(Self.song()), rank: nil, allowsLikeActions: true, quickPlayAction: nil, environment: EnvironmentValues())
        cell.setLiked(true)
        let window = HomeItemTestWindow(contentRect: cell.frame, styleMask: .borderless, backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = cell
        var placeholderSize: NSSize?

        for scale: CGFloat in [2, 1, 2] {
            window.simulatedScale = scale
            cell.viewDidChangeBackingProperties()
            cell.layoutSubtreeIfNeeded()
            let layers = Self.layers(in: cell.layer)
            let likeLayer = try #require(layers.first { $0.contentsGravity == .center && $0.bounds.width == 22 })
            let likeImage = try Self.image(in: likeLayer)
            #expect(likeLayer.contentsScale == scale)
            #expect(CGFloat(likeImage.width) / likeLayer.contentsScale == 22)
            #expect(CGFloat(likeImage.height) / likeLayer.contentsScale == 22)

            let placeholderLayer = try #require(layers.first { $0.contentsGravity == .center && $0.bounds.width == 160 })
            let placeholderImage = try Self.image(in: placeholderLayer)
            let size = NSSize(
                width: CGFloat(placeholderImage.width) / placeholderLayer.contentsScale,
                height: CGFloat(placeholderImage.height) / placeholderLayer.contentsScale
            )
            if let placeholderSize {
                #expect(size == placeholderSize)
            } else {
                placeholderSize = size
            }
        }
    }

    @Test("Tab reaches Like independently of card activation", arguments: [UInt16(36), 76, 49])
    func keyboardLikeAction(activationKey: UInt16) throws {
        let cell = HomeItemCell(frame: .zero)
        cell.configure(item: .song(Self.song()), rank: nil, allowsLikeActions: true, quickPlayAction: nil, environment: EnvironmentValues())
        var likes = 0
        var activations = 0
        cell.likeAction = { likes += 1 }
        cell.activateAction = { activations += 1 }

        try cell.keyDown(with: Self.keyEvent(48))
        #expect(cell.likeButtonFrame != nil)
        #expect(cell.focusRingMaskBounds == cell.likeButtonFrame)
        try cell.keyDown(with: Self.keyEvent(activationKey))
        #expect(likes == 1)
        #expect(activations == 0)

        try cell.keyDown(with: Self.keyEvent(48, modifiers: [.shift]))
        #expect(cell.likeButtonFrame == nil)
        try cell.keyDown(with: Self.keyEvent(activationKey))
        #expect(likes == 1)
        #expect(activations == 1)

        try cell.keyDown(with: Self.keyEvent(48))
        cell.configure(item: .song(Self.song()), rank: nil, allowsLikeActions: false, quickPlayAction: nil, environment: EnvironmentValues())
        #expect(cell.likeButtonFrame == nil)
        try cell.keyDown(with: Self.keyEvent(activationKey))
        #expect(likes == 1)
        #expect(activations == 2)
    }

    @Test("Focused Like handles Space before the playback menu shortcut")
    func focusedSpaceKeyEquivalent() throws {
        let cell = HomeItemCell(frame: NSRect(x: 0, y: 0, width: 160, height: HomeItemCell.height))
        cell.configure(item: .song(Self.song()), rank: nil, allowsLikeActions: true, quickPlayAction: nil, environment: EnvironmentValues())
        let window = HomeItemTestWindow(contentRect: cell.frame, styleMask: .borderless, backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = cell
        window.simulatedFirstResponder = cell
        var likes = 0
        cell.likeAction = { likes += 1 }
        try cell.keyDown(with: Self.keyEvent(48))

        let space = try Self.keyEvent(49)
        #expect(cell.performKeyEquivalent(with: space))
        #expect(likes == 1)

        let modifiedSpace = try Self.keyEvent(49, modifiers: [.command])
        #expect(!cell.performKeyEquivalent(with: modifiedSpace))
        window.simulatedFirstResponder = NSResponder()
        #expect(!cell.performKeyEquivalent(with: space))
        #expect(likes == 1)
    }

    @Test("RTL cards mirror text, rating controls, and chart ranks after an in-place direction change")
    func layoutDirectionMirrorsCard() throws {
        let cell = HomeItemCell(frame: NSRect(x: 0, y: 0, width: 160, height: HomeItemCell.height))
        let item = HomeSectionItem.song(Self.song(title: "Track", artists: "Band", isExplicit: true))
        let window = HomeItemTestWindow(contentRect: cell.frame, styleMask: .borderless, backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = cell

        for direction in [LayoutDirection.leftToRight, .rightToLeft, .leftToRight] {
            cell.needsLayout = false
            cell.needsDisplay = false
            var environment = EnvironmentValues()
            environment.layoutDirection = direction
            cell.configure(item: item, rank: 1, allowsLikeActions: true, quickPlayAction: nil, environment: environment)
            cell.setLiked(true)
            #expect(cell.needsLayout)
            #expect(cell.needsDisplay)
            cell.layoutSubtreeIfNeeded()

            let isRTL = direction == .rightToLeft
            let likeFrame = try #require(cell.likeButtonFrame)
            #expect(likeFrame.minX == (isRTL ? 6 : 132))
            let layers = Self.layers(in: cell.layer)
            let likeLayer = try #require(layers.first { $0.contentsGravity == .center && $0.bounds.width == 22 })
            #expect(likeLayer.frame == likeFrame)
            let rankLayer = try #require(layers.first { [.topLeft, .topRight].contains($0.contentsGravity) })
            #expect(rankLayer.contentsGravity == (isRTL ? .topRight : .topLeft))
            #expect(rankLayer.frame.minX == (isRTL ? 0 : 8))

            let bitmap = try #require(cell.bitmapImageRepForCachingDisplay(in: cell.bounds))
            cell.cacheDisplay(in: cell.bounds, to: bitmap)
            let scale = CGFloat(bitmap.pixelsHigh) / cell.bounds.height
            var minX = bitmap.pixelsWide
            var maxX = -1
            for y in Int(HomeItemCell.artworkHeight * scale) ..< bitmap.pixelsHigh {
                for x in 0 ..< bitmap.pixelsWide where (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.1 {
                    minX = min(minX, x)
                    maxX = max(maxX, x)
                }
            }
            try #require(maxX >= minX)
            if isRTL {
                #expect(minX > bitmap.pixelsWide / 2)
                #expect(maxX >= bitmap.pixelsWide - 3)
            } else {
                #expect(minX <= 2)
                #expect(maxX < bitmap.pixelsWide / 2)
            }
        }
    }

    @Test("Loaded video artwork retains its backdrop while square artwork hides the placeholder", arguments: [MusicVideoType.omv, .atv])
    func loadedArtworkBackdrop(videoType: MusicVideoType) async throws {
        let id = UUID().uuidString
        let thumbnailURL = try #require(URL(string: "https://example.com/\(id).png"))
        let song = Song(id: id, title: "Track", artists: [], thumbnailURL: thumbnailURL, videoId: id, musicVideoType: videoType)
        let item = HomeSectionItem.song(song)
        let url = try #require(HomeItemCell.thumbnailURLs(for: item).first)
        let cache = ImageCache.shared
        try await cache.saveToDiskForTesting(url: url, data: Self.artworkData())
        let diskPath = await cache.diskCachePathForTesting(url: url)
        defer { try? FileManager.default.removeItem(at: diskPath) }
        let size = NSSize(width: HomeItemCell.width(for: item), height: HomeItemCell.artworkHeight)
        let cached = await cache.image(for: url, targetSize: size)
        try #require(cached != nil)

        let cell = HomeItemCell(frame: NSRect(x: 0, y: 0, width: size.width, height: HomeItemCell.height))
        cell.configure(item: item, rank: nil, allowsLikeActions: false, quickPlayAction: nil, environment: EnvironmentValues())
        cell.layoutSubtreeIfNeeded()
        let layers = Self.layers(in: cell.layer)
        let imageLayer = try #require(layers.first { $0.contentsGravity == (item.isVideoSong ? .resizeAspect : .resizeAspectFill) })
        #expect(imageLayer.contents != nil)
        #expect(!imageLayer.isHidden)
        let backdrop = try #require(layers.compactMap { $0 as? CAGradientLayer }.first)
        #expect(backdrop.isHidden == !item.isVideoSong)
    }

    private static func artworkData() throws -> Data {
        let image = NSImage(size: NSSize(width: 32, height: 32))
        image.lockFocus()
        NSColor.systemBlue.setFill()
        NSRect(x: 0, y: 0, width: 32, height: 32).fill()
        image.unlockFocus()
        let tiff = try #require(image.tiffRepresentation)
        let bitmap = try #require(NSBitmapImageRep(data: tiff))
        return try #require(bitmap.representation(using: .png, properties: [:]))
    }

    private static func layers(in layer: CALayer?) -> [CALayer] {
        guard let layer else { return [] }
        return [layer] + (layer.sublayers ?? []).flatMap { Self.layers(in: $0) }
    }

    private static func image(in layer: CALayer) throws -> CGImage {
        let contents = try #require(layer.contents)
        try #require(CFGetTypeID(contents as CFTypeRef) == CGImage.typeID)
        return unsafeBitCast(contents as AnyObject, to: CGImage.self)
    }

    private static func keyEvent(_ keyCode: UInt16, modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
        let characters = keyCode == 48 ? "\t" : keyCode == 49 ? " " : "\r"
        return try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
            windowNumber: 0, context: nil, characters: characters, charactersIgnoringModifiers: characters,
            isARepeat: false, keyCode: keyCode
        ))
    }
}

// MARK: - HomeItemTestWindow

@MainActor
private final class HomeItemTestWindow: NSWindow {
    var simulatedScale: CGFloat = 2
    var simulatedFirstResponder: NSResponder?

    override var backingScaleFactor: CGFloat {
        self.simulatedScale
    }

    override var firstResponder: NSResponder? {
        self.simulatedFirstResponder ?? super.firstResponder
    }
}
