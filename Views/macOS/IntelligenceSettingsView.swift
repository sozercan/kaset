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
        case .unavailable:
            Image(systemName: "exclamationmark.triangle.fill")
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
        case .unavailable:
            "Unavailable"
        @unknown default:
            "Unknown"
        }
    }

    private var availabilityDescription: String {
        switch self.aiService.availability {
        case .available:
            "Apple Intelligence is ready to use"
        case .unavailable:
            "Apple Intelligence is unavailable on this device or not enabled"
        @unknown default:
            "Unable to determine availability"
        }
    }
}
