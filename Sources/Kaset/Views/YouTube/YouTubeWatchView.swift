import SwiftUI

// MARK: - YouTubeWatchView

/// Watch page for a YouTube video: the extracted video surface with native
/// controls, metadata, and the related list.
///
/// The surface is the singleton `YouTubeWatchWebView`, docked here while
/// this view owns it. Navigating away while playing hands the surface off
/// to the floating window (`YouTubeVideoWindowController`).
struct YouTubeWatchView: View {
    private static let brandAccent = PackageResourceLookup.brandAccent

    let video: YouTubeVideo

    @Environment(AuthService.self) private var authService
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

    /// The ambient backdrop style to render: the user's chosen style, or `.off`
    /// when they've disabled the feature in Settings → YouTube.
    private var ambientStyle: AmbientBackdropStyle {
        self.settings.resolvedAmbientStyle
    }

    /// 0…1 playback position, only while THIS view's video is the one playing,
    /// for the `.live` storyboard crossfade. `nil` otherwise (guards NaN when
    /// duration is still 0 at cold load).
    private var ambientLiveFraction: Double? {
        guard self.youtubePlayer.currentVideo?.videoId == self.video.videoId,
              self.youtubePlayer.duration > 0
        else { return nil }
        return min(max(self.youtubePlayer.progress / self.youtubePlayer.duration, 0), 1)
    }

    /// Storyboard spec for the fine-grained `.live` color, but only while THIS
    /// view's video is the one playing — so a previous video's sheets never
    /// tint a newly-opened watch page.
    private var ambientStoryboardSpec: String? {
        guard self.youtubePlayer.currentVideo?.videoId == self.video.videoId else {
            return nil
        }
        return self.youtubePlayer.storyboardSpec
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                self.videoSurface

                // Below the video: title/metadata + comments down the left,
                // the related rail down the right.
                HStack(alignment: .top, spacing: 24) {
                    VStack(alignment: .leading, spacing: 16) {
                        self.metadataSection

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
        // PROTOTYPE: full-bleed ambient color behind the page. `.ignoresSafeArea`
        // (inside the modifier) lets it bleed under the bottom player-bar inset,
        // so the bar's Liquid Glass capsule refracts the live color.
        .ambientVideoBackdrop(
            videoId: self.video.videoId,
            thumbnailURL: self.video.thumbnailURL,
            style: self.ambientStyle,
            liveFraction: self.ambientLiveFraction,
            storyboardSpec: self.ambientStoryboardSpec
        )
        // The in-page metadata shows the title; keep the bar clean.
        .navigationTitle("")
        // Let the ambient reach under the nav bar, like the other accent pages.
        .toolbarBackgroundVisibility(.hidden, for: .automatic)
        #if DEBUG
            .toolbar {
                self.ambientStylePicker
            }
        #endif
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

    // MARK: - Ambient Style Picker (PROTOTYPE)

    #if DEBUG
        /// DEBUG-only toolbar control to switch ambient styles live on-device.
        /// Binds to the same `SettingsManager` value as the Settings → YouTube
        /// tab, so there is a single source of truth. The whole property is
        /// compiled out of release builds (an empty `@ToolbarContentBuilder`
        /// body would otherwise be invalid).
        @ToolbarContentBuilder
        private var ambientStylePicker: some ToolbarContent {
            ToolbarItem(placement: .automatic) {
                Menu {
                    Picker("Ambient", selection: self.$settings.ambientBackdropStyle) {
                        ForEach(AmbientBackdropStyle.allCases) { style in
                            Text(style.debugLabel).tag(style)
                        }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Image(systemName: "paintpalette")
                }
                .help("Ambient backdrop style (developer)")
            }
        }
    #endif

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
            self.youtubePlayer.play(video: self.video, usesCookieFreeDataStore: self.authService.shouldUseCookieFreePlaybackDataStore)
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
            // Same height as the avatar / name + subscriber-count block.
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

    // MARK: - Related Column

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

    // MARK: - Comments

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

    /// Whether the composer holds postable text (drives the send accent).
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

// MARK: - CommentThread

/// A comment with its action row (like/dislike, replies) and, when
/// expanded, its indented reply thread.
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

// MARK: - CommentRow

/// One comment: avatar, author + time, text, and working like/dislike.
/// The author (avatar/name) navigates to their channel.
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

    /// Wraps content in a channel link when the author's channel is known.
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
            targetSize: CGSize(width: 56, height: 56)
        ) { image in
            image
                .resizable()
                .aspectRatio(contentMode: .fill)
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

// MARK: - RelatedVideoRow

/// Compact related-rail row sized for the right column.
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

// MARK: - AccessibilityID Additions

extension AccessibilityID.YouTubeContent {
    static let watchSurface = "youtubeContent.watchSurface"
    static let commentsSection = "youtubeContent.commentsSection"
    static let commentField = "youtubeContent.commentField"
    static let commentPostButton = "youtubeContent.commentPostButton"
    static let subscribeButton = "youtubeContent.subscribeButton"
    static let watchMoveHere = "youtubeContent.watchMoveHere"
}
