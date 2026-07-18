import AppKit
import SwiftUI

// MARK: - QueueFooterIconButton

struct QueueFooterIconButton: View {
    let systemImage: String
    let helpText: String
    let accessibilityLabel: String
    var isEnabled: Bool = true
    var tint: Color = .secondary
    let action: () -> Void

    var body: some View {
        Button {
            guard self.isEnabled else { return }
            self.action()
        } label: {
            Image(systemName: self.systemImage)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(self.tint)
                .frame(width: 20, height: 20)
        }
        .buttonStyle(.plain)
        .disabled(!self.isEnabled)
        .opacity(self.isEnabled ? 1 : 0.45)
        .help(self.helpText)
        .accessibilityLabel(self.accessibilityLabel)
    }
}

// MARK: - QueueFooterActions

struct QueueFooterActions: View {
    @Environment(PlayerService.self) private var playerService
    @Environment(AuthService.self) private var authService

    @State private var isSavingPlaylist = false

    private var canSaveQueueAsPlaylist: Bool {
        self.authService.hasPersonalAccount
            && !self.playerService.queue.isEmpty
            && !self.isSavingPlaylist
            && self.playerService.ytMusicClient != nil
    }

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 8) {
                QueueFooterIconButton(
                    systemImage: "arrow.uturn.backward",
                    helpText: String(localized: "Undo the last queue change."),
                    accessibilityLabel: String(localized: "Undo"),
                    isEnabled: self.playerService.canUndoQueue
                ) {
                    let intent = self.playerService.beginMusicPlaybackIntent()
                    Task { await self.playerService.undoQueue(intent: intent) }
                }

                QueueFooterIconButton(
                    systemImage: "arrow.uturn.forward",
                    helpText: String(localized: "Redo the last undone queue change."),
                    accessibilityLabel: String(localized: "Redo"),
                    isEnabled: self.playerService.canRedoQueue
                ) {
                    let intent = self.playerService.beginMusicPlaybackIntent()
                    Task { await self.playerService.redoQueue(intent: intent) }
                }
            }

            HStack(spacing: 0) {
                Spacer(minLength: 16)

                QueueFooterIconButton(
                    systemImage: "shuffle",
                    helpText: String(localized: "Shuffle the queue, keeping the current song first."),
                    accessibilityLabel: String(localized: "Shuffle"),
                    isEnabled: !self.playerService.queue.isEmpty
                ) {
                    self.playerService.shuffleQueue()
                }

                Spacer()

                Group {
                    QueueFooterIconButton(
                        systemImage: "text.badge.plus",
                        helpText: self.isSavingPlaylist
                            ? String(localized: "Saving queue as playlist…")
                            : String(localized: "Save the current queue as a new private playlist."),
                        accessibilityLabel: String(localized: "Save to Playlist"),
                        isEnabled: self.canSaveQueueAsPlaylist
                    ) {
                        self.presentSaveQueueAsPlaylistDialog()
                    }
                }
                .accessibilityIdentifier(AccessibilityID.Queue.saveToPlaylistButton)

                Spacer()

                QueueFooterIconButton(
                    systemImage: "trash",
                    helpText: String(localized: "Clear the entire queue and stop playback."),
                    accessibilityLabel: String(localized: "Clear Queue"),
                    isEnabled: !self.playerService.queue.isEmpty,
                    tint: .red
                ) {
                    let intent = self.playerService.beginMusicPlaybackIntent()
                    Task {
                        await self.playerService.stopAndClearQueue(intent: intent)
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func presentSaveQueueAsPlaylistDialog() {
        guard self.authService.hasPersonalAccount, !self.isSavingPlaylist else { return }
        let songs = self.playerService.queue
        guard !songs.isEmpty else { return }
        let owner = self.playerService.currentAccountMutationOwner

        let alert = NSAlert()
        alert.messageText = "Save Queue to Playlist"
        alert.informativeText = "Create a private playlist with all \(songs.count) songs from your queue."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let titleField = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        titleField.placeholderString = "Playlist name"
        alert.accessoryView = titleField

        let handleResponse: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .alertFirstButtonReturn else { return }
            let title = titleField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else {
                self.presentSaveQueueErrorAlert(message: "Playlist name is required.")
                return
            }
            Task {
                await self.saveQueueAsPlaylist(
                    title: title,
                    songs: songs,
                    owner: owner
                )
            }
        }

        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            alert.beginSheetModal(for: window, completionHandler: handleResponse)
        } else {
            handleResponse(alert.runModal())
        }
    }

    private func saveQueueAsPlaylist(
        title: String,
        songs: [Song],
        owner: MusicAccountMutationOwner
    ) async {
        guard self.authService.hasPersonalAccount,
              self.playerService.acceptsAccountMutationOwner(owner),
              !self.isSavingPlaylist
        else { return }
        self.isSavingPlaylist = true
        defer { self.isSavingPlaylist = false }

        do {
            _ = try await self.playerService.saveQueueAsPlaylist(
                title: title,
                songs: songs,
                owner: owner
            )
            self.presentSaveQueueSuccessAlert(title: title, songCount: songs.count)
        } catch {
            DiagnosticsLogger.ui.error("Failed to save queue as playlist: \(error.localizedDescription)")
            self.presentSaveQueueErrorAlert(message: "Unable to save queue as playlist. Please try again.")
        }
    }

    private func presentSaveQueueSuccessAlert(title: String, songCount: Int) {
        let alert = NSAlert()
        alert.messageText = "Playlist Saved"
        alert.informativeText = "\"\(title)\" was created with \(songCount) songs."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func presentSaveQueueErrorAlert(message: String) {
        let alert = NSAlert()
        alert.messageText = "Save Failed"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
