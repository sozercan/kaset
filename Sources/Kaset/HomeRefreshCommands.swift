import SwiftUI

extension FocusedValues {
    @Entry var homeRefreshAction: (() -> Void)?
}

// MARK: - HomeRefreshCommands

/// Exposes a source-aware Home refresh in the View menu. Home surfaces publish
/// the action for their scene, so the command is disabled everywhere else.
struct HomeRefreshCommands: Commands {
    @FocusedValue(\.homeRefreshAction) private var refreshHome

    var body: some Commands {
        CommandGroup(before: .sidebar) {
            Button(String(localized: "Refresh")) {
                self.refreshHome?()
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .disabled(self.refreshHome == nil)
        }
    }
}
