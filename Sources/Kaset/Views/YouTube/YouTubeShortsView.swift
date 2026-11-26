import SwiftUI

struct YouTubeShortsView: View {
    let viewModel: YouTubeShortsViewModel

    @Environment(AuthService.self) private var authService
    @Environment(YouTubePlayerService.self) private var youtubePlayer

    @State private var currentShortId: String?

    var body: some View {
        Group {
            switch self.viewModel.loadingState {
            case .idle, .loading:
                LoadingView()
            case let .error(error):
                ErrorView(
                    title: error.title,
                    message: error.message,
                    isRetryable: error.isRetryable
                ) {
                    Task {
                        await self.viewModel.refresh()
                    }
                }
            case .loaded, .loadingMore:
                if self.viewModel.shorts.isEmpty {
                    ContentUnavailableView {
                        Label(String(localized: "No Shorts right now"), systemImage: "rectangle.portrait.on.rectangle.portrait.angled")
                    } description: {
                        Text("Shorts from your feed appear here.", comment: "Empty Shorts surface description")
                    }
                } else {
                    self.pager
                }
            }
        }
        .navigationTitle(Text("Shorts", comment: "YouTube Shorts title"))
        .task(id: ObjectIdentifier(self.viewModel)) {
            self.currentShortId = nil
            await self.viewModel.load()
            if self.currentShortId == nil, let first = self.viewModel.shorts.first {
                self.currentShortId = first.videoId
                self.play(shortId: first.videoId)
            }
        }
        .onDisappear {
            self.stopIfPlayingShort()
        }
    }

    private var pager: some View {
        ScrollView(.vertical) {
            LazyVStack(spacing: 0) {
                ForEach(self.viewModel.shorts) { short in
                    ShortPage(
                        short: short,
                        isActive: self.isPresenting(short)
                    )
                    .containerRelativeFrame(.vertical)
                    .id(short.videoId)
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.viewAligned(limitBehavior: .alwaysByOne))
        .scrollPosition(id: self.$currentShortId)
        .scrollIndicators(.hidden)
        .background(.black)
        .onChange(of: self.currentShortId) { _, shortId in
            guard let shortId else { return }
            self.play(shortId: shortId)
        }
        .accessibilityIdentifier(AccessibilityID.YouTubeContent.shortsPager)
    }

    private func isPresenting(_ short: YouTubeVideo) -> Bool {
        self.youtubePlayer.currentVideo?.videoId == short.videoId
            && self.youtubePlayer.surfaceLocation == .inline
    }

    private func play(shortId: String) {
        guard let short = self.viewModel.shorts.first(where: { $0.videoId == shortId }) else {
            return
        }
        guard self.youtubePlayer.currentVideo?.videoId != short.videoId else { return }
        self.youtubePlayer.play(video: short, usesCookieFreeDataStore: self.authService.shouldUseCookieFreePlaybackDataStore)
        self.youtubePlayer.activeInlineVideoId = short.videoId
    }

    private func stopIfPlayingShort() {
        guard let current = self.youtubePlayer.currentVideo,
              current.isShort,
              self.viewModel.shorts.contains(where: { $0.videoId == current.videoId }),
              self.youtubePlayer.surfaceLocation == .inline
        else {
            return
        }
        self.youtubePlayer.stop()
    }
}

private struct ShortPage: View {
    let short: YouTubeVideo
    let isActive: Bool

    var body: some View {
        Group {
            if self.isActive {
                YouTubeWatchSurfaceView(expectedVideoId: self.short.videoId)
            } else {
                CachedAsyncImage(
                    url: self.short.thumbnailURL,
                    targetSize: CGSize(width: 540, height: 960)
                ) { image in
                    image
                        .resizable()
                        .scaledToFill()
                } placeholder: {
                    Rectangle()
                        .fill(.black)
                        .overlay {
                            ProgressView()
                                .controlSize(.small)
                        }
                }
            }
        }
        .aspectRatio(9 / 16, contentMode: .fit)
        .overlay(alignment: .bottom) {
            self.infoOverlay
                .allowsHitTesting(false)
        }
        .clipShape(.rect(cornerRadius: 12))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(self.short.title)
    }

    private var infoOverlay: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(self.short.title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(2)

            let detail = [self.short.channelName, self.short.viewCountText]
                .compactMap(\.self)
                .joined(separator: " · ")
            if !detail.isEmpty {
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.8))
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background {
            LinearGradient(
                colors: [.clear, .black.opacity(0.6)],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .allowsHitTesting(false)
    }
}

extension AccessibilityID.YouTubeContent {
    static let shortsPager = "youtubeContent.shortsPager"
}
