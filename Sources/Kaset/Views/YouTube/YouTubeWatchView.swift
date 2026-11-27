import SwiftUI

struct YouTubeWatchView: View {
    fileprivate static let brandAccent = PackageResourceLookup.brandAccent

    let video: YouTubeVideo

    @Environment(AuthService.self) private var authService
    @Environment(AccountService.self) private var accountService
    @Environment(YouTubePlayerService.self) private var youtubePlayer
    @State private var viewModel: YouTubeWatchViewModel

    init(video: YouTubeVideo, client: any YouTubeClientProtocol) {
        self.video = video
        self._viewModel = State(
            initialValue: YouTubeWatchViewModel(video: video, client: client)
        )
    }

    @State private var commentDraft = ""
    @State private var settings = SettingsManager.shared
    @State private var isVideoControlsRegionOnScreen = true

    private var ambientStyle: AmbientBackdropStyle {
        self.settings.resolvedAmbientStyle
    }

    private var ambientLiveFraction: Double? {
        guard self.youtubePlayer.currentVideo?.videoId == self.video.videoId,
              self.youtubePlayer.duration > 0
        else { return nil }
        return min(max(self.youtubePlayer.progress / self.youtubePlayer.duration, 0), 1)
    }

    private var ambientStoryboardSpec: String? {
        guard self.youtubePlayer.currentVideo?.videoId == self.video.videoId else {
            return nil
        }
        return self.youtubePlayer.storyboardSpec
    }

    private var askAccountScope: YouTubeAskAccountScopeObservation {
        YouTubeAskAccountScopeObservation(
            authenticationGeneration: self.authService.accountIdentityGeneration,
            hasPersonalAccount: self.authService.hasPersonalAccount,
            accountScopeID: self.accountService.currentAccountScopeID,
            isPrimaryAccount: self.accountService.currentAccount?.isPrimary,
            verifiedIdentitySequence: self.accountService.verifiedIdentitySequence
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                self.videoSurface
                    .onGeometryChange(for: Bool.self) { [bottomInset = self.bottomPlayerBarHeight] proxy in
                        YouTubeInlineControlsVisibility.isControlsRegionVisible(
                            videoSize: proxy.size,
                            visibleBounds: proxy.bounds(of: .scrollView),
                            bottomInset: bottomInset
                        )
                    } action: { isVisible in
                        self.isVideoControlsRegionOnScreen = isVisible
                    }

                HStack(alignment: .top, spacing: 24) {
                    VStack(alignment: .leading, spacing: 16) {
                        self.metadataSection

                        if !self.viewModel.data.chapters.isEmpty {
                            Divider()

                            self.chaptersSection
                        }

                        Divider()

                        self.commentsSection
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    self.relatedColumn
                        .frame(width: 360)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 20)
        }
        .disabled(self.viewModel.ask.isExpanded)
        .ambientVideoBackdrop(
            videoId: self.video.videoId,
            thumbnailURL: self.video.thumbnailURL,
            style: self.ambientStyle,
            liveFraction: self.ambientLiveFraction,
            storyboardSpec: self.ambientStoryboardSpec
        )
        .navigationTitle(String(localized: ""))
        .toolbarBackgroundVisibility(.hidden, for: .automatic)
        .toolbar {
            if self.viewModel.ask.isAvailable {
                ToolbarItem(placement: .primaryAction) {
                    YouTubeAskToolbarButton(viewModel: self.viewModel.ask)
                }
            }
        }
        .overlay {
            YouTubeAskFloatingOverlay(
                viewModel: self.viewModel.ask,
                playerOffsetMilliseconds: self.askPlayerOffsetMilliseconds
            )
        }
        .youtubeAskAccessibilityAnnouncements(viewModel: self.viewModel.ask)
        .task {
            self.startOrAdoptPlayback()
        }
        .task(id: self.askAccountScope) {
            let accountScope = self.askAccountScope
            await self.viewModel.load(accountScope: accountScope)
            YouTubeWatchPlaybackLifecycle.synchronizeLoadedData(
                videoId: self.video.videoId,
                player: self.youtubePlayer,
                data: self.viewModel.data
            )
        }
        .onDisappear {
            self.viewModel.cancel()
            self.youtubePlayer.inlineSurfaceWillDisappear(videoId: self.video.videoId)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .youtubePlayerBarInset(isHidden: self.showsControlsOnVideo)
    }

    private var askPlayerOffsetMilliseconds: Int64 {
        guard self.youtubePlayer.currentVideo?.videoId == self.video.videoId else {
            return 0
        }
        return YouTubeAskPlayerOffset.milliseconds(for: self.youtubePlayer.progress)
    }

    private var presentsLiveSurface: Bool {
        self.youtubePlayer.currentVideo?.videoId == self.video.videoId
            && self.youtubePlayer.surfaceLocation == .inline
    }

    private var showsControlsOnVideo: Bool {
        self.settings.showYouTubeControlsOnVideo
            && self.presentsLiveSurface
            && self.isVideoControlsRegionOnScreen
            && !self.viewModel.ask.isExpanded
    }

    private var bottomPlayerBarHeight: CGFloat {
        self.showsControlsOnVideo ? 0 : YouTubeInlineControlsVisibility.controlsRegionHeight
    }

    private var playsInFloatingWindow: Bool {
        self.youtubePlayer.currentVideo?.videoId == self.video.videoId
            && self.youtubePlayer.surfaceLocation == .floating
    }

    @ViewBuilder
    private var videoSurface: some View {
        if self.presentsLiveSurface {
            YouTubeWatchSurfaceView()
                .accessibilityIdentifier(AccessibilityID.YouTubeContent.watchSurface)
                .aspectRatio(16 / 9, contentMode: .fit)
                .youtubeInlineVideoControls(isEnabled: self.showsControlsOnVideo)
                .clipShape(.rect(cornerRadius: 12))
        } else if self.playsInFloatingWindow {
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
                        .scaledToFill()
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

    private func startOrAdoptPlayback(startAt: Double? = nil) {
        YouTubeWatchPlaybackLifecycle.presentSurface(
            video: self.video,
            player: self.youtubePlayer,
            usesCookieFreeDataStore: self.authService.shouldUseCookieFreePlaybackDataStore,
            startAt: startAt,
            data: self.viewModel.data
        )
    }

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
                                targetSize: CGSize(width: 36, height: 36)
                            ) { image in
                                image
                                    .resizable()
                                    .scaledToFill()
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

                    if self.hasPersonalAccount {
                        self.subscribeButton
                    }

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
            .foregroundStyle(self.viewModel.isSubscribed ? AnyShapeStyle(.primary) : AnyShapeStyle(.white))
            .padding(.horizontal, 16)
            .frame(height: 36)
            .compatGlass(
                interactive: true,
                tint: self.viewModel.isSubscribed ? nil : Self.brandAccent,
                in: Capsule()
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(AccessibilityID.YouTubeContent.subscribeButton)
    }

    private var chaptersSection: some View {
        YouTubeChaptersSection(
            chapters: self.viewModel.data.chapters,
            isActiveChapter: self.isActiveChapter,
            canSeekToChapter: self.canSeekToChapter,
            seekToChapter: self.seekToChapter
        )
    }

    private func seekToChapter(_ chapter: YouTubeChapter) {
        guard self.canSeekToChapter(chapter) else { return }
        if self.youtubePlayer.currentVideo?.videoId != self.video.videoId {
            self.startOrAdoptPlayback(startAt: chapter.startTime)
            return
        }
        self.youtubePlayer.seek(to: chapter.startTime)
    }

    private func canSeekToChapter(_ chapter: YouTubeChapter) -> Bool {
        if let chapterVideoId = chapter.videoId, chapterVideoId != self.video.videoId {
            return false
        }
        guard self.youtubePlayer.currentVideo?.videoId == self.video.videoId else {
            return true
        }
        return self.youtubePlayer.duration > 0
            && !self.youtubePlayer.isPlaybackLoading
            && !self.youtubePlayer.isShowingAd
    }

    private func isActiveChapter(_ chapter: YouTubeChapter) -> Bool {
        guard self.youtubePlayer.currentVideo?.videoId == self.video.videoId else { return false }
        let currentTime = self.youtubePlayer.progress
        guard currentTime >= chapter.startTime else { return false }
        if let endTime = chapter.endTime {
            return currentTime < endTime
        }
        guard let index = self.viewModel.data.chapters.firstIndex(where: { $0.id == chapter.id }) else {
            return false
        }
        let nextIndex = self.viewModel.data.chapters.index(after: index)
        guard nextIndex < self.viewModel.data.chapters.endIndex else { return true }
        return currentTime < self.viewModel.data.chapters[nextIndex].startTime
    }

    private var relatedColumn: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Related", comment: "Related videos section header")
                .font(.title3.bold())

            switch self.viewModel.loadingState {
            case .idle, .loading:
                ForEach(0 ..< 5, id: \.self) { _ in
                    HStack(spacing: 12) {
                        SkeletonView.rectangle(cornerRadius: 8)
                            .frame(width: 140, height: 79)
                        VStack(alignment: .leading, spacing: 6) {
                            SkeletonView.rectangle(cornerRadius: 4)
                                .frame(width: 160, height: 12)
                            SkeletonView.rectangle(cornerRadius: 4)
                                .frame(width: 100, height: 10)
                        }
                        Spacer(minLength: 0)
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
                            RelatedVideoRow(video: related)
                        }
                        .buttonStyle(.interactiveRow)
                    }
                }
            }
        }
    }

    private var commentsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Comments", comment: "Comments section header")
                .font(.title3.bold())

            self.commentComposer

            if self.viewModel.comments.isEmpty, !self.viewModel.isLoadingComments {
                Text("No comments yet.", comment: "Empty comments section")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(self.viewModel.comments) { comment in
                        CommentThread(comment: comment, viewModel: self.viewModel, allowsActions: self.hasPersonalAccount)
                    }
                }
            }

            if self.viewModel.isLoadingComments {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity)
            } else if self.viewModel.canLoadMoreComments {
                Button {
                    Task {
                        await self.viewModel.loadMoreComments()
                    }
                } label: {
                    Text("Show more comments", comment: "Load more comments button")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(Self.brandAccent, in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .accessibilityIdentifier(AccessibilityID.YouTubeContent.commentsSection)
    }

    private var commentComposer: some View {
        HStack(spacing: 10) {
            TextField(
                self.hasPersonalAccount && self.viewModel.canComment
                    ? String(localized: "Add a comment…")
                    : String(localized: "Sign in to comment"),
                text: self.$commentDraft
            )
            .textFieldStyle(.plain)
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background(.quaternary.opacity(0.5), in: Capsule())
            .disabled(!self.hasPersonalAccount || !self.viewModel.canComment)
            .onSubmit {
                self.submitComment()
            }
            .accessibilityIdentifier(AccessibilityID.YouTubeContent.commentField)

            Button {
                self.submitComment()
            } label: {
                Group {
                    if self.viewModel.isPostingComment {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "paperplane.fill")
                            .font(.system(size: 12, weight: .semibold))
                    }
                }
                .frame(width: 30, height: 30)
                .foregroundStyle(self.hasCommentDraft ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                .compatGlass(
                    interactive: true,
                    tint: self.hasCommentDraft && self.viewModel.canComment ? Self.brandAccent : nil,
                    in: Circle()
                )
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(
                !self.hasPersonalAccount
                    || !self.viewModel.canComment
                    || self.viewModel.isPostingComment
                    || self.commentDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            )
            .accessibilityLabel(String(localized: "Post comment"))
            .accessibilityIdentifier(AccessibilityID.YouTubeContent.commentPostButton)
        }
    }

    private var hasPersonalAccount: Bool {
        self.authService.hasPersonalAccount
    }

    private var hasCommentDraft: Bool {
        !self.commentDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func submitComment() {
        let draft = self.commentDraft
        Task {
            if await self.viewModel.postComment(text: draft) {
                self.commentDraft = ""
            }
        }
    }
}

private struct CommentThread: View {
    let comment: YouTubeComment
    let viewModel: YouTubeWatchViewModel
    let allowsActions: Bool

    @State private var showsReplies = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            CommentRow(
                comment: self.comment,
                isLiked: self.viewModel.likedComments.contains(self.comment.id),
                isDisliked: self.viewModel.dislikedComments.contains(self.comment.id),
                onLike: {
                    Task {
                        await self.viewModel.likeComment(self.comment)
                    }
                },
                onDislike: {
                    Task {
                        await self.viewModel.dislikeComment(self.comment)
                    }
                },
                allowsActions: self.allowsActions
            )

            if self.comment.repliesContinuation != nil {
                Button {
                    self.showsReplies.toggle()
                    if self.showsReplies {
                        Task {
                            await self.viewModel.loadReplies(for: self.comment)
                        }
                    }
                } label: {
                    Label(
                        self.showsReplies
                            ? String(localized: "Hide replies")
                            : String(localized: "View replies"),
                        systemImage: self.showsReplies ? "chevron.up" : "chevron.down"
                    )
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
                .padding(.leading, 38)
            }

            if self.showsReplies {
                if self.viewModel.loadingReplies.contains(self.comment.id) {
                    ProgressView()
                        .controlSize(.small)
                        .padding(.leading, 38)
                } else if let replies = self.viewModel.repliesByComment[self.comment.id] {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(replies) { reply in
                            CommentRow(
                                comment: reply,
                                isLiked: self.viewModel.likedComments.contains(reply.id),
                                isDisliked: self.viewModel.dislikedComments.contains(reply.id),
                                onLike: {
                                    Task {
                                        await self.viewModel.likeComment(reply)
                                    }
                                },
                                onDislike: {
                                    Task {
                                        await self.viewModel.dislikeComment(reply)
                                    }
                                },
                                allowsActions: self.allowsActions
                            )
                        }
                    }
                    .padding(.leading, 38)
                }
            }
        }
    }
}

private struct CommentRow: View {
    let comment: YouTubeComment
    let isLiked: Bool
    let isDisliked: Bool
    let onLike: () -> Void
    let onDislike: () -> Void
    let allowsActions: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            self.authorLink {
                self.avatar
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    self.authorLink {
                        Text(self.comment.author)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                    }

                    if let publishedText = self.comment.publishedText {
                        Text(publishedText)
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                }

                Text(self.comment.text)
                    .font(.system(size: 12))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)

                HStack(spacing: 14) {
                    Button(action: self.onLike) {
                        HStack(spacing: 4) {
                            Image(systemName: self.isLiked ? "hand.thumbsup.fill" : "hand.thumbsup")
                                .font(.system(size: 11))
                            if let likeCountText = self.comment.likeCountText, !likeCountText.isEmpty {
                                Text(likeCountText)
                                    .font(.system(size: 11))
                            }
                        }
                        .foregroundStyle(self.isLiked ? AnyShapeStyle(.red) : AnyShapeStyle(.tertiary))
                    }
                    .buttonStyle(.plain)
                    .disabled(!self.allowsActions || self.comment.likeAction == nil)
                    .accessibilityLabel(String(localized: "Like comment"))

                    Button(action: self.onDislike) {
                        Image(systemName: self.isDisliked ? "hand.thumbsdown.fill" : "hand.thumbsdown")
                            .font(.system(size: 11))
                            .foregroundStyle(self.isDisliked ? AnyShapeStyle(.red) : AnyShapeStyle(.tertiary))
                    }
                    .buttonStyle(.plain)
                    .disabled(!self.allowsActions || self.comment.dislikeAction == nil)
                    .accessibilityLabel(String(localized: "Dislike comment"))
                }
                .padding(.top, 2)
            }
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func authorLink(@ViewBuilder content: () -> some View) -> some View {
        if let channelId = self.comment.authorChannelId {
            NavigationLink(value: YouTubeRoute.channel(channelId: channelId)) {
                content()
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } else {
            content()
        }
    }

    private var avatar: some View {
        CachedAsyncImage(
            url: self.comment.authorAvatarURL,
            targetSize: CGSize(width: 28, height: 28)
        ) { image in
            image
                .resizable()
                .scaledToFill()
        } placeholder: {
            Circle()
                .fill(.quaternary)
                .overlay {
                    Image(systemName: "person.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
        }
        .frame(width: 28, height: 28)
        .clipShape(.circle)
    }
}

struct YouTubeChaptersSection: View {
    let chapters: [YouTubeChapter]
    let isActiveChapter: (YouTubeChapter) -> Bool
    let canSeekToChapter: (YouTubeChapter) -> Bool
    let seekToChapter: (YouTubeChapter) -> Void

    @State private var isExpanded: Bool

    init(
        chapters: [YouTubeChapter],
        isActiveChapter: @escaping (YouTubeChapter) -> Bool,
        canSeekToChapter: @escaping (YouTubeChapter) -> Bool,
        seekToChapter: @escaping (YouTubeChapter) -> Void,
        initiallyExpanded: Bool = true
    ) {
        self.chapters = chapters
        self.isActiveChapter = isActiveChapter
        self.canSeekToChapter = canSeekToChapter
        self.seekToChapter = seekToChapter
        self._isExpanded = State(initialValue: initiallyExpanded)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                self.isExpanded.toggle()
            } label: {
                HStack(spacing: 6) {
                    Text("Chapters", comment: "Video chapters section header")
                        .font(.title3.bold())

                    Image(systemName: self.isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
            }
            .buttonStyle(.plain)
            .accessibilityValue(
                self.isExpanded ? String(localized: "Showing") : String(localized: "Hidden")
            )

            if self.isExpanded {
                CarouselShelf(
                    accessibilityLabel: String(localized: "Video chapters"),
                    pageFraction: 0.82,
                    showsControls: true,
                    controlVerticalAlignment: .center,
                    contentInset: 0
                ) {
                    LazyHStack(alignment: .top, spacing: 10) {
                        ForEach(self.chapters) { chapter in
                            Button {
                                self.seekToChapter(chapter)
                            } label: {
                                ChapterCard(chapter: chapter, isActive: self.isActiveChapter(chapter))
                            }
                            .buttonStyle(.interactiveRow)
                            .accessibilityLabel(
                                String(localized: "Jump to chapter: \(chapter.title)")
                            )
                            .disabled(!self.canSeekToChapter(chapter))
                        }
                    }
                    .padding(.vertical, 2)
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityIdentifier(AccessibilityID.YouTubeContent.chaptersSection)
    }
}

private struct ChapterCard: View {
    let chapter: YouTubeChapter
    let isActive: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            self.thumbnail
                .frame(width: 160, height: 90)
                .clipShape(.rect(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 3) {
                Text(self.chapter.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2, reservesSpace: true)
                    .multilineTextAlignment(.leading)

                Text(self.chapter.timeText ?? Self.formatTime(self.chapter.startTime))
                    .font(.caption)
                    .foregroundStyle(self.isActive ? YouTubeWatchView.brandAccent : .secondary)
            }
        }
        .padding(8)
        .frame(width: 176, alignment: .leading)
        .background(self.isActive ? YouTubeWatchView.brandAccent.opacity(0.14) : Color.secondary.opacity(0.08), in: .rect(cornerRadius: 12))
        .contentShape(.rect(cornerRadius: 10))
    }

    private var thumbnail: some View {
        CachedAsyncImage(
            url: self.chapter.thumbnailURL,
            targetSize: CGSize(width: 192, height: 108)
        ) { image in
            image
                .resizable()
                .scaledToFill()
        } placeholder: {
            Rectangle()
                .fill(.quaternary)
                .overlay {
                    Image(systemName: "text.append")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
        }
    }

    private static func formatTime(_ seconds: TimeInterval) -> String {
        let totalSeconds = max(0, Int(seconds.rounded(.down)))
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }
}

private struct RelatedVideoRow: View {
    let video: YouTubeVideo

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VideoThumbnailView(video: self.video)
                .frame(width: 140)

            VStack(alignment: .leading, spacing: 3) {
                Text(self.video.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                if let channelName = self.video.channelName {
                    Text(channelName)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                if let viewCountText = self.video.viewCountText {
                    Text(viewCountText)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

extension AccessibilityID.YouTubeContent {
    static let watchSurface = "youtubeContent.watchSurface"
    static let chaptersSection = "youtubeContent.chaptersSection"
    static let commentsSection = "youtubeContent.commentsSection"
    static let commentField = "youtubeContent.commentField"
    static let commentPostButton = "youtubeContent.commentPostButton"
    static let subscribeButton = "youtubeContent.subscribeButton"
    static let watchMoveHere = "youtubeContent.watchMoveHere"
}
