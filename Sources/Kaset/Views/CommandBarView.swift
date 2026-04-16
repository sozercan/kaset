import FoundationModels
import SwiftUI

// MARK: - CommandBarView

/// A floating command bar for natural language music control.
/// Accessible via Cmd+K, allows users to control playback with voice-like commands.
@available(macOS 26.0, *)
struct CommandBarView: View {
    /// The YTMusicClient for search operations.
    let client: any YTMusicClientProtocol

    /// Playback service used for suggestions and command execution.
    let playerService: PlayerService

    /// Binding to control visibility (used for dismiss).
    @Binding var isPresented: Bool

    /// Shared search view model for routing search-only intents into the Search tab.
    let searchViewModel: SearchViewModel?
    @State private var viewModel: CommandBarViewModel

    /// Focus state for the text field.
    @FocusState private var isInputFocused: Bool

    @Namespace private var commandBarNamespace

    init(
        client: any YTMusicClientProtocol,
        playerService: PlayerService,
        isPresented: Binding<Bool>,
        navigationSelection: Binding<NavigationItem?>,
        searchFocusTrigger: Binding<Bool>,
        searchViewModel: SearchViewModel? = nil
    ) {
        self.client = client
        self.playerService = playerService
        self._isPresented = isPresented
        self.searchViewModel = searchViewModel
        self._viewModel = State(initialValue: CommandBarViewModel(
            client: client,
            playerService: playerService,
            searchRouter: { query in
                navigationSelection.wrappedValue = .search
                searchViewModel?.selectedFilter = .all
                searchViewModel?.query = query.trimmingCharacters(in: .whitespacesAndNewlines)
                if let searchViewModel, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    searchViewModel.searchImmediately()
                }
                isPresented.wrappedValue = false
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(100))
                    searchFocusTrigger.wrappedValue = true
                }
            },
            dismissAction: {
                isPresented.wrappedValue = false
            }
        ))
    }

    var body: some View {
        @Bindable var viewModel = self.viewModel

        GlassEffectContainer(spacing: 0) {
            VStack(spacing: 0) {
                // Input field
                HStack(spacing: 12) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 16))
                        .foregroundStyle(.tint)

                    TextField(String(localized: "Ask anything about music..."), text: $viewModel.inputText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 16))
                        .focused(self.$isInputFocused)
                        .accessibilityIdentifier(AccessibilityID.MainWindow.commandBarInput)
                        .onSubmit {
                            viewModel.submit()
                        }
                        .disabled(viewModel.isInteractionDisabled)

                    if viewModel.isProcessing {
                        ProgressView()
                            .controlSize(.small)
                            .scaleEffect(0.7)
                            .frame(width: 11, height: 11)
                    } else if !viewModel.inputText.isEmpty {
                        Button {
                            viewModel.inputText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(String(localized: "Clear input"))
                        .disabled(viewModel.isInteractionDisabled)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)

                Divider()
                    .opacity(0.3)

                // Status area
                if let error = viewModel.errorMessage {
                    self.errorView(error)
                } else if let result = viewModel.resultMessage {
                    self.resultView(result)
                } else {
                    self.suggestionsView(isDisabled: viewModel.isInteractionDisabled)
                }
            }
            .frame(width: 500)
            .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 20))
            .glassEffectID("commandBar", in: self.commandBarNamespace)
        }
        .glassEffectTransition(.materialize)
        .accessibilityIdentifier(AccessibilityID.MainWindow.commandBar)
        .onAppear {
            viewModel.handleAppear()
            self.isInputFocused = true
        }
        .onDisappear {
            viewModel.cancelActiveRequest()
        }
        .onExitCommand {
            viewModel.dismiss()
        }
    }

    // MARK: - Subviews

    private func errorView(_ error: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)

            Text(error)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 16)
    }

    private func resultView(_ result: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)

            Text(result)
                .font(.subheadline)
                .foregroundStyle(.primary)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 16)
    }

    private func suggestionsView(isDisabled: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(self.suggestionsHeaderText)
                .font(.caption)
                .foregroundStyle(.tertiary)

            // First row: contextual suggestions based on playback state
            HStack(spacing: 8) {
                ForEach(self.contextualSuggestions.prefix(3), id: \.self) { suggestion in
                    SuggestionChip(text: suggestion) {
                        self.viewModel.executeSuggestion(suggestion)
                    }
                }
            }

            // Second row: discovery suggestions
            HStack(spacing: 8) {
                ForEach(self.discoverySuggestions.prefix(3), id: \.self) { suggestion in
                    SuggestionChip(text: suggestion) {
                        self.viewModel.executeSuggestion(suggestion)
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .disabled(isDisabled)
    }

    /// Header text for suggestions, contextual based on playback state.
    private var suggestionsHeaderText: String {
        if self.playerService.currentTrack != nil {
            String(localized: "What would you like to do?")
        } else if !self.playerService.queue.isEmpty {
            String(localized: "What would you like to do with your queue?")
        } else {
            String(localized: "Try commands like:")
        }
    }

    /// Suggestions that adapt to current playback context.
    private var contextualSuggestions: [String] {
        var suggestions: [String] = []

        if let track = self.playerService.currentTrack {
            if self.playerService.isPlaying {
                suggestions.append("Pause")
            } else {
                suggestions.append("Resume")
            }

            let artist = track.artists.first?.name ?? ""
            if !artist.isEmpty {
                suggestions.append("Play more by \(artist)")
            } else {
                suggestions.append("Play more like this")
            }

            suggestions.append("I like this")
        } else if !self.playerService.queue.isEmpty {
            suggestions.append("Play")
            suggestions.append("Shuffle my queue")
            suggestions.append("Clear queue")
        } else {
            suggestions.append("Play something chill")
            suggestions.append("Play top hits")
            suggestions.append("Shuffle my library")
        }

        return suggestions
    }

    /// Suggestions for discovering new music.
    private var discoverySuggestions: [String] {
        if self.playerService.currentTrack != nil {
            ["Add jazz to queue", "Skip this song", "What's in my queue?"]
        } else if !self.playerService.queue.isEmpty {
            ["Add more songs", "Play something different", "Start over"]
        } else {
            ["Play upbeat music", "Workout playlist", "Something to focus"]
        }
    }
}

// MARK: - SuggestionChip

@available(macOS 26.0, *)
private struct SuggestionChip: View {
    let text: String
    let action: () -> Void

    var body: some View {
        Button(action: self.action) {
            Text(self.text)
                .font(.caption)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.quaternary)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    @Previewable @State var isPresented = true
    @Previewable @State var navigationSelection: NavigationItem?
    @Previewable @State var searchFocusTrigger = false
    let playerService = PlayerService()
    let authService = AuthService()
    let client = YTMusicClient(authService: authService, webKitManager: .shared)
    CommandBarView(
        client: client,
        playerService: playerService,
        isPresented: $isPresented,
        navigationSelection: $navigationSelection,
        searchFocusTrigger: $searchFocusTrigger
    )
    .padding(40)
    .frame(width: 600, height: 300)
}
