import SwiftUI

// MARK: - RefinePlaylistSheet

@available(macOS 26.0, *)
struct RefinePlaylistSheet: View {
    let tracks: [Song]
    @Binding var isProcessing: Bool
    @Binding var changes: PlaylistChanges?
    @Binding var partialChanges: PlaylistChanges.PartiallyGenerated?
    @Binding var errorMessage: String?
    let onRefine: (String) async -> Void
    let onApply: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var promptText = ""
    @FocusState private var isPromptFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Refine Playlist")
                    .font(.headline)
                Spacer()
                Button {
                    self.dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close")
            }
            .padding()

            Divider()

            if self.isProcessing {
                if let partial = self.partialChanges {
                    self.streamingChangesView(partial)
                } else {
                    self.loadingView
                }
            } else if let changes = self.changes {
                self.changesView(changes)
            } else {
                self.promptView
            }
        }
        .frame(width: 500, height: 400)
        .onAppear {
            self.isPromptFocused = true
        }
    }

    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .controlSize(.regular)
                .frame(width: 20, height: 20)
            Text("Analyzing playlist...")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func streamingChangesView(_ partial: PlaylistChanges.PartiallyGenerated) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.6)
                    .frame(width: 10, height: 10)
                if let reasoning = partial.reasoning {
                    Text(reasoning)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Analyzing...")
                        .font(.subheadline)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if let removals = partial.removals, !removals.isEmpty {
                        Text("Suggested Removals")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .textCase(.uppercase)

                        ForEach(removals, id: \.self) { videoId in
                            if let track = self.tracks.first(where: { $0.videoId == videoId }) {
                                HStack {
                                    Image(systemName: "minus.circle.fill")
                                        .foregroundStyle(.red)
                                    Text(track.title)
                                        .lineLimit(1)
                                    Spacer()
                                    Text(track.artistsDisplay)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                .padding(.vertical, 4)
                            }
                        }
                    }
                }
                .padding(.horizontal)
            }

            Spacer()

            HStack {
                Spacer()
                Text("Processing...")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding()
        }
    }

    private var promptView: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("What would you like to change?")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            TextField(
                "e.g., Remove slow songs, reorder by energy...",
                text: self.$promptText,
                axis: .vertical
            )
            .textFieldStyle(.roundedBorder)
            .lineLimit(3 ... 5)
            .focused(self.$isPromptFocused)

            if let error = self.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack(spacing: 12) {
                self.suggestionChip("Remove duplicates")
                self.suggestionChip("Make it more upbeat")
                self.suggestionChip("Better flow")
            }

            Spacer()

            HStack {
                Spacer()
                Button("Cancel") {
                    self.dismiss()
                }
                .keyboardShortcut(.escape)

                Button("Refine") {
                    Task {
                        await self.onRefine(self.promptText)
                    }
                }
                .buttonStyle(.glassProminent)
                .disabled(self.promptText.trimmingCharacters(in: .whitespaces).isEmpty)
                .keyboardShortcut(.return)
            }
        }
        .padding()
    }

    private func changesView(_ changes: PlaylistChanges) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(changes.reasoning)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.horizontal)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if !changes.removals.isEmpty {
                        Text("Suggested Removals")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .textCase(.uppercase)

                        ForEach(changes.removals, id: \.self) { videoId in
                            if let track = self.tracks.first(where: { $0.videoId == videoId }) {
                                HStack {
                                    Image(systemName: "minus.circle.fill")
                                        .foregroundStyle(.red)
                                    Text(track.title)
                                        .lineLimit(1)
                                    Spacer()
                                    Text(track.artistsDisplay)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                .padding(.vertical, 4)
                            }
                        }
                    }

                    if changes.removals.isEmpty, changes.reorderedIds == nil {
                        Text("No changes suggested. The playlist looks good!")
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal)
            }

            Divider()

            HStack {
                Button("Try Again") {
                    self.changes = nil
                    self.errorMessage = nil
                }

                Spacer()

                Button("Cancel") {
                    self.dismiss()
                }
                .keyboardShortcut(.escape)

                Button("Apply Changes") {
                    self.onApply()
                }
                .buttonStyle(.glassProminent)
                .disabled(changes.removals.isEmpty && changes.reorderedIds == nil)
            }
            .padding()
        }
    }

    private func suggestionChip(_ text: String) -> some View {
        Button {
            self.promptText = text
        } label: {
            Text(text)
                .font(.caption)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.quaternary)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}
