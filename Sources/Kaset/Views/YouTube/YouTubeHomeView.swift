import SwiftUI

struct YouTubeHomeView: View {
    let viewModel: YouTubeHomeViewModel

    private static let columns = [
        GridItem(.adaptive(minimum: 210, maximum: 320), spacing: 16),
    ]

    var body: some View {
        Group {
            switch self.viewModel.loadingState {
            case .idle, .loading:
                self.loadingGrid
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
                if self.viewModel.sections.isEmpty,
                   self.viewModel.videos.isEmpty,
                   !self.viewModel.hasMoreVideos,
                   !self.viewModel.hasMoreTopicRails,
                   !self.viewModel.isLoadingTopicRails
                {
                    ContentUnavailableView {
                        Label(String(localized: "No recommendations yet"), systemImage: "play.rectangle")
                    } description: {
                        Text("Watch some videos to build your feed.", comment: "Empty YouTube home feed description")
                    }
                } else {
                    self.feedContent
                }
            }
        }
        .navigationTitle(Text("Home", comment: "YouTube home feed title"))
        .accessibilityIdentifier(AccessibilityID.YouTubeContent.homeGrid)
        .task(id: ObjectIdentifier(self.viewModel)) {
            await self.viewModel.load()
        }
    }

    private var feedContent: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 32) {
                ForEach(self.viewModel.sections) { section in
                    self.sectionRail(section)
                        .transition(.opacity)
                }

                if self.viewModel.hasMoreTopicRails || self.viewModel.isLoadingTopicRails {
                    LoadMoreFooter(
                        isLoading: self.viewModel.isLoadingTopicRails,
                        title: "Load more topics",
                        loadingTitle: "Loading topics...",
                        autoLoad: true,
                        autoLoadTrigger: self.viewModel.sections.count
                    ) {
                        await self.viewModel.loadMoreTopicRails()
                    }
                    .transition(.opacity)
                }

                if !self.viewModel.videos.isEmpty || self.viewModel.hasMoreVideos {
                    self.forYouGrid
                }
            }
            .padding(.vertical, 20)
            .animation(AppAnimation.smooth, value: self.viewModel.sections.map(\.id))
        }
        .pullToRefresh {
            await self.viewModel.refresh()
        }
    }

    private func sectionRail(_ section: YouTubeHomeSection) -> some View {
        CarouselShelfSection(
            accessibilityLabel: section.title,
            items: section.videos,
            itemAlignment: .top,
            contentInset: DetailContentLayout.horizontalInset
        ) {
            Text(section.title)
                .font(.title2)
                .fontWeight(.semibold)
        } itemContent: { video in
            NavigationLink(value: YouTubeRoute.watch(video)) {
                VideoCard(video: video)
                    .frame(width: 284)
            }
            .buttonStyle(.interactiveCard)
        }
    }

    private var forYouGrid: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !self.viewModel.sections.isEmpty, !self.viewModel.videos.isEmpty {
                Text("For you", comment: "YouTube home recommendation grid heading")
                    .font(.title2)
                    .fontWeight(.semibold)
                    .padding(.horizontal, DetailContentLayout.horizontalInset)
            }

            LazyVGrid(columns: Self.columns, spacing: 20) {
                ForEach(self.viewModel.videos) { video in
                    NavigationLink(value: YouTubeRoute.watch(video)) {
                        VideoCard(video: video)
                    }
                    .buttonStyle(.interactiveCard)
                }

                if self.viewModel.hasMoreVideos {
                    ProgressView()
                        .controlSize(.small)
                        .gridCellColumns(1)
                        .task(id: self.viewModel.videos.count) {
                            await self.viewModel.loadMore()
                        }
                }
            }
            .padding(.horizontal, DetailContentLayout.horizontalInset)
        }
        .task(id: self.firstThumbnailBatchKey) {
            let urls = self.viewModel.videos.prefix(12).compactMap(\.thumbnailURL)
            guard !urls.isEmpty else { return }
            await ImageCache.shared.prefetch(
                urls: Array(urls),
                targetSize: CGSize(width: 320, height: 180)
            )
        }
    }

    private var firstThumbnailBatchKey: String {
        self.viewModel.videos.prefix(12).map(\.videoId).joined(separator: ",")
    }

    private var loadingGrid: some View {
        ScrollView {
            LazyVGrid(columns: Self.columns, spacing: 20) {
                ForEach(0 ..< 12, id: \.self) { _ in
                    VStack(alignment: .leading, spacing: 8) {
                        SkeletonView.rectangle(cornerRadius: 8)
                            .aspectRatio(16 / 9, contentMode: .fit)
                            .frame(maxWidth: .infinity)
                        SkeletonView.rectangle(cornerRadius: 4)
                            .frame(width: 220, height: 12)
                        SkeletonView.rectangle(cornerRadius: 4)
                            .frame(width: 140, height: 10)
                    }
                }
            }
            .padding(.vertical, 20)
            .detailScrollContentInset()
        }
        .disabled(true)
    }
}

extension AccessibilityID.YouTubeContent {
    static let homeGrid = "youtubeContent.homeGrid"
}
