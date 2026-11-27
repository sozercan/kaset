import AppKit
import CoreGraphics
import Foundation
import Testing
import WebKit
@testable import Kaset

@Suite("YouTube surface alignment & pagination")
@MainActor
struct YouTubeWatchSurfaceAndPagingTests {
    @Test("Pixel-aligned bounds stay inside fractional container bounds without overscan cropping")
    func pixelAlignedBounds() {
        let fractional = NSRect(x: 0.25, y: 0.25, width: 640.3, height: 360.3)
        let aligned2x = YouTubeWatchContainerView.pixelAlignedBounds(fractional, backingScaleFactor: 2.0)
        #expect(aligned2x.minX >= fractional.minX)
        #expect(aligned2x.minY >= fractional.minY)
        #expect(aligned2x.maxX <= fractional.maxX)
        #expect(aligned2x.maxY <= fractional.maxY)
        #expect((aligned2x.minX * 2.0).rounded() == aligned2x.minX * 2.0)
        #expect((aligned2x.width * 2.0).rounded() == aligned2x.width * 2.0)
        #expect((aligned2x.height * 2.0).rounded() == aligned2x.height * 2.0)

        let aligned1x = YouTubeWatchContainerView.pixelAlignedBounds(fractional, backingScaleFactor: 1.0)
        #expect(aligned1x.minX == 1.0)
        #expect(aligned1x.maxX == 640.0)
        #expect(aligned1x.width == 639.0)
        #expect(aligned1x.height == 359.0)

        let exact = NSRect(x: 0, y: 0, width: 800, height: 450)
        #expect(YouTubeWatchContainerView.pixelAlignedBounds(exact, backingScaleFactor: 2.0) == exact)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        let container = YouTubeWatchContainerView(frame: NSRect(x: 0.25, y: 0.25, width: 640.3, height: 360.3))
        let webView = WKWebView(frame: .zero)
        container.addSubview(webView)
        window.contentView?.addSubview(container)
        container.layoutSubtreeIfNeeded()

        #expect(container.bounds.contains(webView.frame))
        let backingRect = container.convertToBacking(webView.frame)
        #expect(backingRect.minX.rounded() == backingRect.minX)
        #expect(backingRect.minY.rounded() == backingRect.minY)
        #expect(backingRect.width.rounded() == backingRect.width)
        #expect(backingRect.height.rounded() == backingRect.height)
    }

    @Test("YouTubeHomeViewModel advances cursor generation, preserves videos on stalled cursor, and stops on cycles")
    func filteredContinuationPagesAndStalledCursor() async {
        let mockClient = MockYouTubeClient()
        let initialVideo = MockYouTubeClient.makeVideo(videoId: "existing-0")
        mockClient.homeFeed = YouTubeFeed(videos: [initialVideo], continuation: "c1")
        mockClient.homeContinuationPages = [
            YouTubeFeed(videos: [initialVideo], continuation: "c2"),
            YouTubeFeed(videos: [initialVideo], continuation: "c3"),
            YouTubeFeed(videos: [initialVideo], continuation: "c4"),
            YouTubeFeed(videos: [initialVideo], continuation: "c5"),
            YouTubeFeed(videos: [initialVideo], continuation: "c6"),
            YouTubeFeed(videos: [MockYouTubeClient.makeVideo(videoId: "fresh-6")], continuation: "c7"),
            YouTubeFeed(videos: [MockYouTubeClient.makeVideo(videoId: "fresh-7")], continuation: "c7"),
        ]

        let viewModel = YouTubeHomeViewModel(client: mockClient)
        await viewModel.load()
        let initialCursorGen = viewModel.paginationCursorGeneration

        await viewModel.loadMore()
        #expect(viewModel.videos.map(\.videoId) == ["existing-0"])
        #expect(viewModel.hasMoreVideos == true)
        #expect(viewModel.paginationCursorGeneration == initialCursorGen + 1)

        await viewModel.loadMore()
        #expect(viewModel.videos.map(\.videoId) == ["existing-0", "fresh-6"])
        #expect(viewModel.hasMoreVideos == true)

        await viewModel.loadMore()
        #expect(viewModel.videos.map(\.videoId) == ["existing-0", "fresh-6", "fresh-7"])
        #expect(viewModel.hasMoreVideos == false)

        let cyclicClient = MockYouTubeClient()
        cyclicClient.homeFeed = YouTubeFeed(videos: [initialVideo], continuation: "cycle-a")
        cyclicClient.homeContinuationPages = [
            YouTubeFeed(videos: [initialVideo], continuation: "cycle-b"),
            YouTubeFeed(videos: [initialVideo], continuation: "cycle-a"),
        ]
        let cyclicViewModel = YouTubeHomeViewModel(client: cyclicClient)
        await cyclicViewModel.load()
        await cyclicViewModel.loadMore()
        #expect(cyclicViewModel.hasMoreVideos == false)
    }
}
