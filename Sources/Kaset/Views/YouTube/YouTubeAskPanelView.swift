import AppKit
import SwiftUI

// MARK: - YouTubeAskToolbarButton

struct YouTubeAskToolbarButton: View {
    let viewModel: YouTubeAskViewModel

    var body: some View {
        let accessibilityLabel = self.viewModel.isExpanded
            ? String(localized: "Collapse Ask Gemini")
            : String(localized: "Expand Ask Gemini")

        Button {
            self.viewModel.toggleExpanded()
        } label: {
            Image(systemName: "sparkles")
                .font(.system(size: 14))
                .foregroundStyle(.primary)
        }
        .help(accessibilityLabel)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityIdentifier(AccessibilityID.YouTubeContent.askButton)
    }
}

// MARK: - YouTubeAskFloatingOverlay

struct YouTubeAskFloatingOverlay: View {
    private static let bottomPadding: CGFloat = 16

    let viewModel: YouTubeAskViewModel
    let playerOffsetMilliseconds: Int64

    var body: some View {
        if self.viewModel.isAvailable, self.viewModel.isExpanded {
            GeometryReader { geometry in
                ZStack {
                    Rectangle()
                        .fill(.clear)
                        .contentShape(Rectangle())
                        .ignoresSafeArea()
                        .accessibilityIdentifier(AccessibilityID.YouTubeContent.askOverlay)
                        .onTapGesture {
                            self.viewModel.setExpanded(false)
                        }

                    VStack(spacing: 0) {
                        YouTubeAskPanelView(
                            viewModel: self.viewModel,
                            maximumHeight: max(
                                0,
                                geometry.size.height
                                    - MainWindowLayout.aiTaskSurfaceTopPadding
                                    - Self.bottomPadding
                            ),
                            playerOffsetMilliseconds: self.playerOffsetMilliseconds
                        )
                        .transition(.opacity.combined(with: .scale(scale: 0.95)))

                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .padding(.top, MainWindowLayout.aiTaskSurfaceTopPadding)

                    YouTubeAskEscapeKeyMonitor {
                        self.viewModel.setExpanded(false)
                    }
                    .frame(width: 0, height: 0)
                    .accessibilityHidden(true)
                }
            }
            .animation(.easeInOut(duration: 0.15), value: self.viewModel.isExpanded)
        }
    }
}

// MARK: - YouTubeAskEscapeKeyMonitor

private struct YouTubeAskEscapeKeyMonitor: NSViewRepresentable {
    let dismiss: @MainActor () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(dismiss: self.dismiss)
    }

    func makeNSView(context: Context) -> YouTubeAskEscapeMonitorView {
        let view = YouTubeAskEscapeMonitorView(frame: .zero)
        view.isHidden = true
        view.windowDidChange = { [weak coordinator = context.coordinator] window in
            coordinator?.window = window
        }
        context.coordinator.window = view.window
        context.coordinator.install()
        return view
    }

    func updateNSView(_ view: YouTubeAskEscapeMonitorView, context: Context) {
        context.coordinator.dismiss = self.dismiss
        context.coordinator.window = view.window
    }

    static func dismantleNSView(_ view: YouTubeAskEscapeMonitorView, coordinator: Coordinator) {
        view.windowDidChange = nil
        coordinator.window = nil
        coordinator.uninstall()
    }

    @MainActor
    final class Coordinator {
        var dismiss: @MainActor () -> Void
        weak var window: NSWindow?
        private var monitor: Any?

        init(dismiss: @escaping @MainActor () -> Void) {
            self.dismiss = dismiss
        }

        func install() {
            guard self.monitor == nil else { return }
            self.monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self,
                      event.keyCode == 53,
                      event.window === self.window,
                      self.window?.isKeyWindow == true
                else {
                    return event
                }
                self.dismiss()
                return nil
            }
        }

        func uninstall() {
            guard let monitor = self.monitor else { return }
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }
}

// MARK: - YouTubeAskEscapeMonitorView

@MainActor
private final class YouTubeAskEscapeMonitorView: NSView {
    var windowDidChange: ((NSWindow?) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        self.windowDidChange?(self.window)
    }
}

// MARK: - YouTubeAskPanelView

/// Floating, watch-scoped Ask Gemini panel. It presents YouTube-generated
/// messages and server-issued suggestions in the same compact shell as the
/// music command bar.
struct YouTubeAskPanelView: View {
    private static let headerReservedHeight: CGFloat = 58

    private enum FocusTarget: Hashable {
        case input
        case close
        case suggestion(YouTubeAskSuggestion.ID)
        case newChat
    }

    private enum ScrollTarget: Hashable {
        case message(UUID)
        case status
        case suggestion(YouTubeAskSuggestion.ID)
        case newChat
    }

    let viewModel: YouTubeAskViewModel
    let maximumHeight: CGFloat
    let playerOffsetMilliseconds: Int64

    @Namespace private var askPanelNamespace
    @FocusState private var focusedControl: FocusTarget?

    var body: some View {
        @Bindable var viewModel = self.viewModel

        CompatGlassContainer(spacing: 0) {
            VStack(spacing: 0) {
                self.inputRow(text: $viewModel.inputText)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)

                Divider()
                    .opacity(0.3)

                ScrollViewReader { proxy in
                    ScrollView(.vertical) {
                        self.panelContent
                            .padding(.trailing, 4)
                    }
                    .frame(maxHeight: self.contentMaximumHeight)
                    .fixedSize(horizontal: false, vertical: true)
                    .scrollBounceBehavior(.basedOnSize)
                    .task(id: self.preferredScrollTarget) {
                        await Task.yield()
                        guard !Task.isCancelled,
                              let target = self.preferredScrollTarget
                        else {
                            return
                        }
                        proxy.scrollTo(target, anchor: .bottom)
                    }
                }
            }
            .frame(width: 500)
            .compatGlass(interactive: true, in: .rect(cornerRadius: 20))
            .compatGlassID("youtubeAskPanel", in: self.askPanelNamespace)
        }
        .compatGlassTransition(.materialize)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.YouTubeContent.askPanel)
        .task(id: self.preferredFocusTarget) {
            await Task.yield()
            guard !Task.isCancelled,
                  let target = self.preferredFocusTarget
            else {
                return
            }
            self.focusedControl = target
        }
    }

    private var panelContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(
                "Responses are generated by YouTube and may be inaccurate.",
                comment: "Disclosure shown in the YouTube Ask Gemini panel"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            self.expandedContent
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var contentMaximumHeight: CGFloat {
        max(0, min(520, self.maximumHeight - Self.headerReservedHeight))
    }

    private var preferredFocusTarget: FocusTarget? {
        // A renewed composer command belongs to the latest conversation
        // revision and should regain focus even after earlier transcript turns.
        if self.viewModel.acceptsFreeTextInput {
            return .input
        }
        guard !self.viewModel.hasStarted else { return nil }
        if self.viewModel.presentationError != nil || self.viewModel.isBusy {
            return .close
        }
        if !self.viewModel.requiresNewChat,
           let suggestionID = self.viewModel.suggestions.first?.id
        {
            return .suggestion(suggestionID)
        }
        if self.viewModel.canStartNewChat {
            return .newChat
        }
        return .close
    }

    private var preferredScrollTarget: ScrollTarget? {
        if self.viewModel.presentationError != nil || self.viewModel.activity != .idle {
            return .status
        }
        if !self.viewModel.hasStarted,
           !self.viewModel.requiresNewChat,
           let suggestionID = self.viewModel.suggestions.first?.id
        {
            return .suggestion(suggestionID)
        }
        if let messageID = self.viewModel.messages.last?.id {
            return .message(messageID)
        }
        if !self.viewModel.requiresNewChat,
           let suggestionID = self.viewModel.suggestions.first?.id
        {
            return .suggestion(suggestionID)
        }
        if self.viewModel.canStartNewChat {
            return .newChat
        }
        return nil
    }

    private func inputRow(text: Binding<String>) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "sparkles")
                .font(.system(size: 16))
                .foregroundStyle(.tint)

            TextField(String(localized: "Ask anything about this video..."), text: text)
                .textFieldStyle(.plain)
                .font(.system(size: 16))
                .focused(self.$focusedControl, equals: .input)
                .onSubmit {
                    guard self.viewModel.canSubmitInput else { return }
                    self.viewModel.submitInput(
                        playerOffsetMilliseconds: self.playerOffsetMilliseconds
                    )
                }
                .disabled(!self.viewModel.acceptsFreeTextInput)
                .accessibilityIdentifier(AccessibilityID.YouTubeContent.askInput)

            if self.viewModel.isBusy {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.7)
                    .frame(width: 11, height: 11)
            } else if !self.viewModel.inputText.isEmpty {
                Button {
                    self.viewModel.inputText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .disabled(self.viewModel.isBusy)
                .accessibilityLabel(String(localized: "Clear input"))
            }

            Divider()
                .frame(height: 18)
                .opacity(0.3)

            self.closeButton
        }
    }

    private var closeButton: some View {
        Button {
            self.viewModel.setExpanded(false)
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .focused(self.$focusedControl, equals: .close)
        .accessibilityLabel(String(localized: "Collapse Ask Gemini"))
        .accessibilityIdentifier(AccessibilityID.YouTubeContent.askToggle)
    }

    private var expandedContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !self.viewModel.messages.isEmpty {
                self.transcript
            }

            if let error = self.viewModel.presentationError {
                self.errorStatus(error)
                    .id(ScrollTarget.status)
            } else if self.viewModel.activity != .idle {
                self.progressStatus
                    .id(ScrollTarget.status)
            }

            if !self.viewModel.suggestions.isEmpty, !self.viewModel.requiresNewChat {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Try asking:")
                        .font(.caption)
                        .foregroundStyle(.tertiary)

                    self.suggestions
                }
            }

            if self.viewModel.canStartNewChat {
                Button {
                    self.viewModel.startNewChat()
                } label: {
                    Label(String(localized: "New Chat"), systemImage: "arrow.clockwise")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                }
                .buttonStyle(.bordered)
                .disabled(self.viewModel.isBusy)
                .focused(self.$focusedControl, equals: .newChat)
                .id(ScrollTarget.newChat)
                .accessibilityIdentifier(AccessibilityID.YouTubeContent.askNewChat)
            }
        }
    }

    private var transcript: some View {
        LazyVStack(alignment: .leading, spacing: 10) {
            ForEach(self.viewModel.messages) { message in
                self.messageView(message)
                    .id(ScrollTarget.message(message.id))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier(AccessibilityID.YouTubeContent.askTranscript)
    }

    @ViewBuilder
    private func messageView(_ message: YouTubeAskMessage) -> some View {
        switch message.role {
        case .user:
            Text(verbatim: message.text)
                .font(.callout.weight(.medium))
                .foregroundStyle(.primary)
                .multilineTextAlignment(.leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(Color.accentColor.opacity(0.12), in: .rect(cornerRadius: 10))
                .frame(maxWidth: .infinity, alignment: .trailing)
                .accessibilityLabel(
                    String(
                        localized: "You asked: \(message.text)",
                        comment: "VoiceOver label for a user turn in the YouTube Ask Gemini transcript"
                    )
                )
        case .assistant:
            VStack(alignment: .leading, spacing: 2) {
                YouTubeAskMarkdownView(markdown: message.text)

                if message.wasTruncated {
                    Text(verbatim: YouTubeAskMarkdown.truncationIndicator)
                        .font(.callout)
                        .accessibilityHidden(true)
                }
            }
            .foregroundStyle(.primary)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(
                String(
                    localized: "YouTube response: \(YouTubeAskMarkdown.plainText(from: message.text, wasTruncated: message.wasTruncated))",
                    comment: "VoiceOver label for an assistant turn in the YouTube Ask Gemini transcript"
                )
            )
        }
    }

    private var suggestions: some View {
        YouTubeAskSuggestionFlowLayout(horizontalSpacing: 8, verticalSpacing: 8) {
            ForEach(Array(self.viewModel.suggestions.enumerated()), id: \.element.id) { index, suggestion in
                Button {
                    self.viewModel.selectSuggestion(id: suggestion.id)
                } label: {
                    Text(verbatim: suggestion.text)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(.quaternary, in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(self.viewModel.isBusy)
                .focused(self.$focusedControl, equals: .suggestion(suggestion.id))
                .id(ScrollTarget.suggestion(suggestion.id))
                .accessibilityIdentifier(AccessibilityID.YouTubeContent.askSuggestion(index: index))
            }
        }
    }

    private var progressStatus: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text(self.activityText)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(AccessibilityID.YouTubeContent.askStatus)
    }

    private func errorStatus(_ error: YouTubeAskPresentationError) -> some View {
        Label(YouTubeAskAccessibilityCopy.errorText(for: error), systemImage: "exclamationmark.triangle")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier(AccessibilityID.YouTubeContent.askStatus)
    }

    private var activityText: String {
        switch self.viewModel.activity {
        case .idle:
            ""
        case .preparing:
            String(localized: "Preparing Ask Gemini…")
        case .sending:
            String(localized: "Sending…")
        }
    }
}

// MARK: - YouTubeAskSuggestionFlowLayout

private struct YouTubeAskSuggestionFlowLayout: Layout {
    let horizontalSpacing: CGFloat
    let verticalSpacing: CGFloat

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache _: inout ()
    ) -> CGSize {
        let maximumWidth = proposal.width ?? .greatestFiniteMagnitude
        let measured = self.measure(subviews: subviews, maximumWidth: maximumWidth)
        return CGSize(
            width: proposal.width ?? measured.width,
            height: measured.height
        )
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal _: ProposedViewSize,
        subviews: Subviews,
        cache _: inout ()
    ) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(ProposedViewSize(
                width: bounds.width,
                height: nil
            ))
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + self.verticalSpacing
                rowHeight = 0
            }
            subview.place(
                at: CGPoint(x: x, y: y),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: size.width, height: size.height)
            )
            x += size.width + self.horizontalSpacing
            rowHeight = max(rowHeight, size.height)
        }
    }

    private func measure(
        subviews: Subviews,
        maximumWidth: CGFloat
    ) -> CGSize {
        var rowWidth: CGFloat = 0
        var rowHeight: CGFloat = 0
        var measuredWidth: CGFloat = 0
        var measuredHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(ProposedViewSize(
                width: maximumWidth,
                height: nil
            ))
            let proposedWidth = rowWidth == 0
                ? size.width
                : rowWidth + self.horizontalSpacing + size.width
            if rowWidth > 0, proposedWidth > maximumWidth {
                measuredWidth = max(measuredWidth, rowWidth)
                measuredHeight += rowHeight + self.verticalSpacing
                rowWidth = size.width
                rowHeight = size.height
            } else {
                rowWidth = proposedWidth
                rowHeight = max(rowHeight, size.height)
            }
        }

        measuredWidth = max(measuredWidth, rowWidth)
        measuredHeight += rowHeight
        return CGSize(width: measuredWidth, height: measuredHeight)
    }
}

// MARK: - YouTube Ask Accessibility Announcements

extension View {
    func youtubeAskAccessibilityAnnouncements(viewModel: YouTubeAskViewModel) -> some View {
        self.modifier(YouTubeAskAccessibilityAnnouncementsModifier(viewModel: viewModel))
    }
}

// MARK: - YouTubeAskAccessibilityAnnouncementsModifier

private struct YouTubeAskAccessibilityAnnouncementsModifier: ViewModifier {
    let viewModel: YouTubeAskViewModel

    func body(content: Content) -> some View {
        content
            .onChange(of: self.viewModel.accessibilityAnnouncementSequence) { _, _ in
                guard let announcement = self.viewModel.accessibilityAnnouncement else { return }
                self.postLiveRegionAnnouncement(
                    YouTubeAskAccessibilityCopy.announcementText(for: announcement)
                )
            }
            .onChange(of: self.viewModel.presentationError) { _, error in
                guard let error else { return }
                self.postLiveRegionAnnouncement(YouTubeAskAccessibilityCopy.errorText(for: error))
            }
    }

    private func postLiveRegionAnnouncement(_ message: String) {
        NSAccessibility.post(
            element: NSApplication.shared,
            notification: .announcementRequested,
            userInfo: [
                .announcement: message,
                .priority: NSAccessibilityPriorityLevel.medium.rawValue,
            ]
        )
    }
}

// MARK: - YouTubeAskAccessibilityCopy

private enum YouTubeAskAccessibilityCopy {
    static func errorText(for error: YouTubeAskPresentationError) -> String {
        switch error {
        case .authentication:
            String(localized: "Sign in again to use Ask Gemini.")
        case .rateLimited:
            String(localized: "Ask Gemini is temporarily rate limited. Try again later.")
        case .preparation:
            String(localized: "Ask Gemini couldn’t prepare this chat.")
        case .restartRequired:
            String(localized: "Start a new chat to continue.")
        }
    }

    static func announcementText(
        for announcement: YouTubeAskViewModel.AccessibilityAnnouncement
    ) -> String {
        switch announcement {
        case .responseReady:
            String(localized: "Ask Gemini response ready")
        case .newChatReady:
            String(localized: "New Ask Gemini chat ready")
        }
    }
}

// MARK: - AccessibilityID.YouTubeContent

extension AccessibilityID.YouTubeContent {
    static let askButton = "youtubeContent.askButton"
    static let askOverlay = "youtubeContent.askOverlay"
    static let askPanel = "youtubeContent.askPanel"
    static let askInput = "youtubeContent.askInput"
    static let askToggle = "youtubeContent.askToggle"
    static let askTranscript = "youtubeContent.askTranscript"
    static let askNewChat = "youtubeContent.askNewChat"
    static let askStatus = "youtubeContent.askStatus"

    static func askSuggestion(index: Int) -> String {
        "youtubeContent.askSuggestion.\(index)"
    }
}
