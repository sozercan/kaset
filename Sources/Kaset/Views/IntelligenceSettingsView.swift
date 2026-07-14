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

                // The only OS-level enable path — surfaced right under the
                // availability status so a "Not Enabled" user can act on it.
                Link(destination: URL(string: "x-apple.systempreferences:com.apple.preference.AppleIntelligence")!) {
                    HStack {
                        Text(String(localized: "Apple Intelligence & Siri Settings"))
                        Spacer()
                        Image(systemName: "arrow.up.forward.square")
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text(String(localized: "Apple Intelligence"))
            } footer: {
                Text(String(localized: "AI responses follow your system language settings."))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            Section {
                Toggle("Enable AI Features", isOn: Binding(
                    get: { !self.aiService.isDisabledByUser },
                    set: { self.aiService.isDisabledByUser = !$0 }
                ))
                .disabled(!self.isSystemAvailable)

                Text(String(localized: "When enabled, Kaset can add richer queue analysis, AI-powered playlist refinement, and lyrics explanations."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Command-bar keyboard shortcut reference.
            Section {
                HStack {
                    Image(systemName: "command")
                        .foregroundStyle(.secondary)
                    Text(String(localized: "Command Bar"))
                    Spacer()
                    Text(String(localized: "⌘K"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.quaternary)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }

                Text(String(localized: "Open the command bar to control music with natural language. Try saying \"play something chill\" or \"add jazz to queue\"."))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text(String(localized: "The command bar stays available even if Apple Intelligence is off, with AI enhancing only the richer interpretations and summaries."))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } header: {
                Text(String(localized: "Command Bar"))
            }

            Section {
                Button(String(localized: "Refresh AI Status")) {
                    self.aiService.refreshAvailability()
                }

                Text(String(localized: "Kaset creates fresh AI sessions per request. Refresh the status if Apple Intelligence finishes downloading or becomes available while the app is open."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 400, minHeight: 300)
        .localizedNavigationTitle("Intelligence")
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
            String(localized: "Available")
        case let .unavailable(reason):
            self.titleForUnavailableReason(reason)
        @unknown default:
            String(localized: "Unknown")
        }
    }

    private var availabilityDescription: String {
        switch self.aiService.availability {
        case .available:
            String(localized: "Apple Intelligence is ready to use")
        case let .unavailable(reason):
            self.descriptionForUnavailableReason(reason)
        @unknown default:
            String(localized: "Unable to determine availability")
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
            return String(localized: "Not Supported")
        } else if reasonString.contains("modelNotReady") {
            return String(localized: "Downloading")
        } else if reasonString.contains("appleIntelligenceNotEnabled") {
            return String(localized: "Not Enabled")
        } else if reasonString.contains("languageNotSupported") {
            return String(localized: "Language Not Supported")
        } else {
            return String(localized: "Unavailable")
        }
    }

    /// Returns a user-friendly description for the unavailability reason.
    private func descriptionForUnavailableReason(_ reason: some Any) -> String {
        let reasonString = String(describing: reason)
        if reasonString.contains("deviceNotSupported") {
            return String(localized: "This Mac doesn't support Apple Intelligence. An Apple Silicon Mac is required.")
        } else if reasonString.contains("modelNotReady") {
            return String(localized: "Apple Intelligence is downloading. This may take a few minutes.")
        } else if reasonString.contains("appleIntelligenceNotEnabled") {
            return String(localized: "Enable Apple Intelligence in System Settings to use AI features.")
        } else if reasonString.contains("languageNotSupported") {
            return String(localized: "Change your system language to English or another supported language.")
        } else {
            return String(localized: "Apple Intelligence is currently unavailable.")
        }
    }
}
