import AppKit
import SwiftUI
import Testing
@testable import Kaset

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
            playlistPlayAction: nil,
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
        cell.configure(item: item, rank: nil, allowsLikeActions: false, playlistPlayAction: nil, environment: EnvironmentValues())
        cell.setHovered(true, animated: false)
        cell.configure(item: item, rank: nil, allowsLikeActions: false, playlistPlayAction: nil, environment: EnvironmentValues())
        #expect(cell.isHovered)
        #expect(cell.item == item)
    }
}
