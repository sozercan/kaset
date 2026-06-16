import SwiftUI

// MARK: - YouTubeHomeView

/// The YouTube home (recommended) feed: an adaptive grid of video cards.
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
                   !self.viewModel.hasMoreVideos
                {
                    ContentUnavailableView {
                        Label(String(localized: "No recommendations yet"), systemImage: "play.rectangle")
                    } description: {
                        Text("Watch some videos to build your feed.", comment: "Empty YouTube home feed description")
                    }
                } else {
                    // Route to feedContent when there is anything to show OR more
                    // pages remain — feedContent hosts the pagination sentinel,
                    // which must mount so loadMore() can fetch the next page even
                    // when the first render has no renderable rails/videos yet.
                    self.feedContent
                }
            }
        }
        .navigationTitle(Text("Home", comment: "YouTube home feed title"))
        .accessibilityIdentifier(AccessibilityID.YouTubeContent.homeGrid)
        .task {
            await self.viewModel.load()
        }
    }

    /// Personalized rails (Continue Watching, shelves, topics) stacked above
    /// the "For you" recommendation grid. The ScrollView track stays
    /// edge-to-edge so rails slide under the floating glass sidebar; each rail
    /// and the grid restore their own resting inset.
    private var feedContent: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 32) {
                ForEach(self.viewModel.sections) { section in
                    self.sectionRail(section)
                }

                // Render the grid whenever there are flat videos OR more pages
                // to fetch. The pagination sentinel lives inside the grid, so
                // gating the whole grid on a non-empty `videos` would strand the
                // continuation when the first page's flat videos are all shelf
                // videos (filtered out) but more pages remain.
                if !self.viewModel.videos.isEmpty || self.viewModel.hasMoreVideos {
                    self.forYouGrid
                }
            }
            .padding(.vertical, 20)
        }
    }

    /// A single horizontal rail of video cards with a title header.
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
                // VideoCard has no intrinsic width; pin it for the horizontal
                // LazyHStack (matches the music video card width).
                VideoCard(video: video)
                    .frame(width: 284)
            }
            .buttonStyle(.interactiveCard)
        }
    }

    /// The flat "For you" recommendation grid with infinite-scroll pagination.
    private var forYouGrid: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Show the heading only when there are rails above it AND grid
            // videos to label; an empty grid (just the pagination sentinel)
            // should not show a dangling "For you" title.
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
                        .task {
                            await self.viewModel.loadMore()
                        }
                }
            }
            // Vertical grid insets its resting content; rails above keep their
            // own edge-to-edge track so they slide under the glass sidebar.
            .padding(.horizontal, DetailContentLayout.horizontalInset)
        }
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
        }
        .contentMargins(.horizontal, DetailContentLayout.horizontalInset, for: .scrollContent)
        .disabled(true)
    }
}

// MARK: - AccessibilityID Additions

extension AccessibilityID.YouTubeContent {
    static let homeGrid = "youtubeContent.homeGrid"
}
