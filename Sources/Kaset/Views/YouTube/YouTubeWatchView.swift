import SwiftUI

// MARK: - YouTubeWatchView

/// Watch page for a YouTube video: the extracted video surface with native
/// controls, metadata, and the related list.
///
/// The surface is the singleton `YouTubeWatchWebView`, docked here while
/// this view owns it. Navigating away while playing hands the surface off
/// to the floating window (`YouTubeVideoWindowController`).
struct YouTubeWatchView: View {
    let video: YouTubeVideo

    @Environment(YouTubePlayerService.self) private var youtubePlayer
    @State private var viewModel: YouTubeWatchViewModel

    init(video: YouTubeVideo, client: any YouTubeClientProtocol) {
        self.video = video
        self._viewModel = State(
            initialValue: YouTubeWatchViewModel(video: video, client: client)
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                self.videoSurface

                self.metadataSection

                Divider()

                self.relatedSection
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 20)
        }
        .navigationTitle(Text(self.video.title))
        .task {
            self.startOrAdoptPlayback()
            await self.viewModel.load()
            // Feed the related list to the player so the bar's next/previous
            // buttons can skip between videos.
            if self.youtubePlayer.currentVideo?.videoId == self.video.videoId {
                self.youtubePlayer.setUpNext(self.viewModel.data.related)
            }
        }
        .onDisappear {
            self.youtubePlayer.inlineSurfaceWillDisappear(videoId: self.video.videoId)
        }
    }

    // MARK: - Video Surface

    /// Whether this view currently presents the live playback surface.
    private var presentsLiveSurface: Bool {
        self.youtubePlayer.currentVideo?.videoId == self.video.videoId
            && self.youtubePlayer.surfaceLocation == .inline
    }

    /// Whether this view's video is currently playing in the floating window.
    private var playsInFloatingWindow: Bool {
        self.youtubePlayer.currentVideo?.videoId == self.video.videoId
            && self.youtubePlayer.surfaceLocation == .floating
    }

    @ViewBuilder
    private var videoSurface: some View {
        if self.presentsLiveSurface {
            // Clean video surface — playback is controlled from the
            // Liquid Glass player bar at the bottom of the window.
            YouTubeWatchSurfaceView()
                .aspectRatio(16 / 9, contentMode: .fit)
                .clipShape(.rect(cornerRadius: 12))
                .accessibilityIdentifier(AccessibilityID.YouTubeContent.watchSurface)
        } else if self.playsInFloatingWindow {
            // Native PiP-style placeholder while the video plays in the
            // pop-out window.
            Rectangle()
                .fill(.black)
                .aspectRatio(16 / 9, contentMode: .fit)
                .overlay {
                    VStack(spacing: 12) {
                        Image(systemName: "pip.exit")
                            .font(.system(size: 40))
                            .foregroundStyle(.white.opacity(0.7))
                        Text("This video is playing in the pop-out player.", comment: "Watch view placeholder while popped out")
                            .font(.callout)
                            .foregroundStyle(.white.opacity(0.7))
                        Button {
                            self.youtubePlayer.dockInline()
                            HapticService.toggle()
                        } label: {
                            Text("Move Video Here", comment: "Button that docks the popped-out video back inline")
                                .font(.system(size: 12, weight: .semibold))
                        }
                        .buttonStyle(.bordered)
                        .tint(.white)
                        .accessibilityIdentifier(AccessibilityID.YouTubeContent.watchMoveHere)
                    }
                }
                .clipShape(.rect(cornerRadius: 12))
                .accessibilityIdentifier(AccessibilityID.YouTubeContent.watchSurface)
        } else {
            Button {
                self.startOrAdoptPlayback()
            } label: {
                CachedAsyncImage(
                    url: self.video.thumbnailURL,
                    targetSize: CGSize(width: 1280, height: 720)
                ) { image in
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } placeholder: {
                    Rectangle().fill(.black)
                }
                .aspectRatio(16 / 9, contentMode: .fit)
                .overlay {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 56))
                        .foregroundStyle(.white.opacity(0.9))
                        .shadow(radius: 8)
                }
                .clipShape(.rect(cornerRadius: 12))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(localized: "Play video"))
            .accessibilityIdentifier(AccessibilityID.YouTubeContent.watchSurface)
        }
    }

    /// Starts playback of this view's video, or adopts the surface if this
    /// video is already playing (e.g. docking back from the floating window).
    private func startOrAdoptPlayback() {
        if self.youtubePlayer.currentVideo?.videoId == self.video.videoId {
            if self.youtubePlayer.surfaceLocation == .floating {
                self.youtubePlayer.dockInline()
            }
        } else {
            self.youtubePlayer.play(video: self.video)
        }
        self.youtubePlayer.activeInlineVideoId = self.video.videoId
    }

    // MARK: - Metadata

    private var metadataSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(self.viewModel.data.videoTitle ?? self.video.title)
                .font(.title2.bold())
                .lineLimit(3)

            let meta = [
                self.viewModel.data.viewCountText ?? self.video.viewCountText,
                self.viewModel.data.publishedText ?? self.video.publishedText,
            ].compactMap(\.self)
            if !meta.isEmpty {
                Text(meta.joined(separator: " · "))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if let channel = self.viewModel.data.channel {
                HStack(spacing: 12) {
                    NavigationLink(value: YouTubeRoute.channel(channelId: channel.channelId)) {
                        HStack(spacing: 10) {
                            CachedAsyncImage(
                                url: channel.thumbnailURL,
                                targetSize: CGSize(width: 72, height: 72)
                            ) { image in
                                image
                                    .resizable()
                                    .aspectRatio(contentMode: .fill)
                            } placeholder: {
                                Circle().fill(.quaternary)
                            }
                            .frame(width: 36, height: 36)
                            .clipShape(.circle)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(channel.name)
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(.primary)
                                if let subscriberCountText = channel.subscriberCountText {
                                    Text(subscriberCountText)
                                        .font(.system(size: 11))
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    self.subscribeButton

                    Spacer(minLength: 0)
                }
            }
        }
    }

    private var subscribeButton: some View {
        Button {
            Task {
                await self.viewModel.toggleSubscribed()
            }
        } label: {
            Text(
                self.viewModel.isSubscribed
                    ? String(localized: "Subscribed")
                    : String(localized: "Subscribe")
            )
            .font(.system(size: 12, weight: .semibold))
        }
        .buttonStyle(.bordered)
        .tint(self.viewModel.isSubscribed ? nil : .red)
        .accessibilityIdentifier(AccessibilityID.YouTubeContent.subscribeButton)
    }

    // MARK: - Related

    @ViewBuilder
    private var relatedSection: some View {
        Text("Related", comment: "Related videos section header")
            .font(.title3.bold())

        switch self.viewModel.loadingState {
        case .idle, .loading:
            ForEach(0 ..< 5, id: \.self) { _ in
                HStack(spacing: 12) {
                    SkeletonView.rectangle(cornerRadius: 8)
                        .frame(width: 160, height: 90)
                    VStack(alignment: .leading, spacing: 6) {
                        SkeletonView.rectangle(cornerRadius: 4)
                            .frame(width: 240, height: 12)
                        SkeletonView.rectangle(cornerRadius: 4)
                            .frame(width: 140, height: 10)
                    }
                    Spacer()
                }
            }
        case let .error(error):
            Text(error.message)
                .font(.callout)
                .foregroundStyle(.secondary)
        case .loaded, .loadingMore:
            LazyVStack(alignment: .leading, spacing: 10) {
                ForEach(self.viewModel.data.related) { related in
                    NavigationLink(value: YouTubeRoute.watch(related)) {
                        VideoRowView(video: related)
                    }
                    .buttonStyle(.interactiveRow)
                }
            }
        }
    }
}

// MARK: - AccessibilityID Additions

extension AccessibilityID.YouTubeContent {
    static let watchSurface = "youtubeContent.watchSurface"
    static let subscribeButton = "youtubeContent.subscribeButton"
    static let watchMoveHere = "youtubeContent.watchMoveHere"
}
