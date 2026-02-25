import FoundationModels
import SwiftUI

/// Settings view for Apple Intelligence features.
/// Allows users to enable/disable AI features and manage session state.
@available(macOS 26.0, *)
struct IntelligenceSettingsView: View {
    @State private var aiService = FoundationModelsService.shared

    var body: some View {
        Form {
            Section {
                // Availability status
                HStack {
                    self.availabilityIcon
                    VStack(alignment: .leading, spacing: 2) {
                        Text(self.availabilityTitle)
                            .font(.headline)
                        Text(self.availabilityDescription)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(.vertical, 4)
            } header: {
                Text("Apple Intelligence")
            }

            Section {
                Toggle("Enable AI Features", isOn: Binding(
                    get: { !self.aiService.isDisabledByUser },
                    set: { self.aiService.isDisabledByUser = !$0 }
                ))
                .disabled(!self.isSystemAvailable)

                Text("When enabled, you can use natural language commands, AI-powered playlist refinement, and lyrics explanations.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // AI Features section with keyboard shortcut info
            Section {
                HStack {
                    Image(systemName: "command")
                        .foregroundStyle(.secondary)
                    Text("Command Bar")
                    Spacer()
                    Text("⌘K")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.quaternary)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }

                Text("Open the command bar to control music with natural language. Try saying \"play something chill\" or \"add jazz to queue\".")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Quick Access")
            }

            Section {
                Button("Clear AI Context") {
                    self.aiService.clearContext()
                }
                .disabled(!self.aiService.isAvailable)

                Text("Clears the AI session state. Use this if responses seem off or stuck.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Link(destination: URL(string: "x-apple.systempreferences:com.apple.preference.AppleIntelligence")!) {
                    HStack {
                        Text("Apple Intelligence & Siri Settings")
                        Spacer()
                        Image(systemName: "arrow.up.forward.square")
                            .foregroundStyle(.secondary)
                    }
                }
            } footer: {
                Text("AI responses follow your system language settings.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 400, minHeight: 300)
        .navigationTitle("Intelligence")
    }

    // MARK: - Computed Properties

    private var isSystemAvailable: Bool {
        self.aiService.availability == .available
    }

    @ViewBuilder
    private var availabilityIcon: some View {
        switch self.aiService.availability {
        case .available:
            Image(systemName: "sparkles")
                .foregroundStyle(.purple)
                .font(.system(size: 24))
        case let .unavailable(reason):
            Image(systemName: self.iconForUnavailableReason(reason))
                .foregroundStyle(.orange)
                .font(.system(size: 24))
        @unknown default:
            Image(systemName: "questionmark.circle.fill")
                .foregroundStyle(.secondary)
                .font(.system(size: 24))
        }
    }

    private var availabilityTitle: String {
        switch self.aiService.availability {
        case .available:
            "Available"
        case let .unavailable(reason):
            self.titleForUnavailableReason(reason)
        @unknown default:
            "Unknown"
        }
    }

    private var availabilityDescription: String {
        switch self.aiService.availability {
        case .available:
            "Apple Intelligence is ready to use"
        case let .unavailable(reason):
            self.descriptionForUnavailableReason(reason)
        @unknown default:
            "Unable to determine availability"
        }
    }

    // MARK: - Unavailability Reason Helpers

    /// Returns the appropriate icon for the unavailability reason.
    private func iconForUnavailableReason(_ reason: some Any) -> String {
        let reasonString = String(describing: reason)
        if reasonString.contains("deviceNotSupported") {
            return "desktopcomputer.trianglebadge.exclamationmark"
        } else if reasonString.contains("modelNotReady") {
            return "arrow.down.circle"
        } else if reasonString.contains("appleIntelligenceNotEnabled") {
            return "gearshape.circle"
        } else if reasonString.contains("languageNotSupported") {
            return "globe"
        } else {
            return "exclamationmark.triangle.fill"
        }
    }

    /// Returns a short title for the unavailability reason.
    private func titleForUnavailableReason(_ reason: some Any) -> String {
        let reasonString = String(describing: reason)
        if reasonString.contains("deviceNotSupported") {
            return "Not Supported"
        } else if reasonString.contains("modelNotReady") {
            return "Downloading"
        } else if reasonString.contains("appleIntelligenceNotEnabled") {
            return "Not Enabled"
        } else if reasonString.contains("languageNotSupported") {
            return "Language Not Supported"
        } else {
            return "Unavailable"
        }
    }

    /// Returns a user-friendly description for the unavailability reason.
    private func descriptionForUnavailableReason(_ reason: some Any) -> String {
        let reasonString = String(describing: reason)
        if reasonString.contains("deviceNotSupported") {
            return "This Mac doesn't support Apple Intelligence. An Apple Silicon Mac is required."
        } else if reasonString.contains("modelNotReady") {
            return "Apple Intelligence is downloading. This may take a few minutes."
        } else if reasonString.contains("appleIntelligenceNotEnabled") {
            return "Enable Apple Intelligence in System Settings to use AI features."
        } else if reasonString.contains("languageNotSupported") {
            return "Change your system language to English or another supported language."
        } else {
            return "Apple Intelligence is currently unavailable."
        }
    }
}
