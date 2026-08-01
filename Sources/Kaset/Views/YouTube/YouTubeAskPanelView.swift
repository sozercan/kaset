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
    let viewModel: YouTubeAskViewModel

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
                            maximumHeight: max(0, geometry.size.height - 32)
                        )
                        .transition(.opacity.combined(with: .scale(scale: 0.95)))

                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .padding(.top, 16)

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

/// Floating, watch-scoped Ask Gemini panel. It only presents server-issued
/// suggestions; free-form input is intentionally not part of this surface.
struct YouTubeAskPanelView: View {
    let viewModel: YouTubeAskViewModel
    let maximumHeight: CGFloat

    @Namespace private var askPanelNamespace
    @FocusState private var isHeaderFocused: Bool

    var body: some View {
        CompatGlassContainer(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                self.header

                Text(
                    "Responses are generated by YouTube and may be inaccurate.",
                    comment: "Disclosure shown in the YouTube Ask Gemini panel"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

                if self.viewModel.isExpanded {
                    Divider()
                        .opacity(0.4)

                    ScrollView(.vertical) {
                        self.expandedContent
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.trailing, 4)
                    }
                    .frame(maxHeight: self.scrollableContentHeight)
                    .scrollBounceBehavior(.basedOnSize)
                }
            }
            .padding(16)
            .frame(width: 500)
            .frame(maxHeight: self.maximumHeight)
            .compatGlass(interactive: true, in: .rect(cornerRadius: 20))
            .compatGlassID("youtubeAskPanel", in: self.askPanelNamespace)
        }
        .compatGlassTransition(.materialize)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.YouTubeContent.askPanel)
        .onAppear {
            self.isHeaderFocused = true
        }
    }

    private var scrollableContentHeight: CGFloat {
        max(0, min(520, self.maximumHeight - 128))
    }

    private var header: some View {
        Button {
            self.viewModel.toggleExpanded()
        } label: {
            HStack(spacing: 9) {
                Image(systemName: "sparkles")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.tint)

                Text("Ask Gemini", comment: "YouTube watch-page Ask Gemini panel title")
                    .font(.headline)
                    .foregroundStyle(.primary)

                Spacer(minLength: 8)

                Image(systemName: self.viewModel.isExpanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focused(self.$isHeaderFocused)
        .accessibilityLabel(
            self.viewModel.isExpanded
                ? String(localized: "Collapse Ask Gemini")
                : String(localized: "Expand Ask Gemini")
        )
        .accessibilityIdentifier(AccessibilityID.YouTubeContent.askToggle)
    }

    private var expandedContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !self.viewModel.messages.isEmpty {
                self.transcript
            }

            if let error = self.viewModel.presentationError {
                self.errorStatus(error)
            } else if self.viewModel.activity != .idle {
                self.progressStatus
            }

            if !self.viewModel.suggestions.isEmpty, !self.viewModel.requiresNewChat {
                self.suggestions
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
                .accessibilityIdentifier(AccessibilityID.YouTubeContent.askNewChat)
            }
        }
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(self.viewModel.messages) { message in
                        self.messageView(message)
                            .id(message.id)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, 4)
            }
            .frame(maxHeight: 240)
            .accessibilityIdentifier(AccessibilityID.YouTubeContent.askTranscript)
            .onChange(of: self.viewModel.messages.map(\.id)) { _, messageIDs in
                guard let lastID = messageIDs.last else { return }
                proxy.scrollTo(lastID, anchor: .bottom)
            }
        }
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
            YouTubeAskMarkdownView(markdown: message.text)
                .foregroundStyle(.primary)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(
                    String(
                        localized: "YouTube response: \(YouTubeAskMarkdown.plainText(from: message.text))",
                        comment: "VoiceOver label for an assistant turn in the YouTube Ask Gemini transcript"
                    )
                )
        }
    }

    private var suggestions: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(self.viewModel.suggestions.enumerated()), id: \.element.id) { index, suggestion in
                Button {
                    self.viewModel.selectSuggestion(id: suggestion.id)
                } label: {
                    Text(verbatim: suggestion.text)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 9)
                        .background(.quaternary.opacity(0.55), in: .rect(cornerRadius: 10))
                        .contentShape(.rect(cornerRadius: 10))
                }
                .buttonStyle(.plain)
                .disabled(self.viewModel.isBusy)
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
    static let askToggle = "youtubeContent.askToggle"
    static let askTranscript = "youtubeContent.askTranscript"
    static let askNewChat = "youtubeContent.askNewChat"
    static let askStatus = "youtubeContent.askStatus"

    static func askSuggestion(index: Int) -> String {
        "youtubeContent.askSuggestion.\(index)"
    }
}
