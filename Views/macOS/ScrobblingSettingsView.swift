import SwiftUI

// MARK: - ScrobblingSettingsView

/// Settings view for scrobbling services.
/// Iterates all registered services from the coordinator, rendering a reusable row for each.
@available(macOS 26.0, *)
struct ScrobblingSettingsView: View {
    @Environment(ScrobblingCoordinator.self) private var coordinator

    var body: some View {
        Form {
            ForEach(self.coordinator.services, id: \.serviceName) { service in
                ScrobbleServiceRow(service: service)
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 400, minHeight: 300)
        .navigationTitle("Scrobbling")
    }
}

// MARK: - ScrobbleServiceRow

/// A reusable settings row for any scrobbling service backend.
@available(macOS 26.0, *)
struct ScrobbleServiceRow: View {
    let service: any ScrobbleServiceProtocol
    @State private var settings = SettingsManager.shared
    @State private var isAuthenticating = false

    var body: some View {
        Section {
            Toggle(
                "Enable \(self.service.serviceName) Scrobbling",
                isOn: self.enabledBinding
            )

            // Connection status
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Account")
                        .font(.headline)
                    Text(self.connectionStatusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()

                self.connectionButton
            }
            .padding(.vertical, 4)
        } header: {
            Text(self.service.serviceName)
        }
    }

    // MARK: - Bindings

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { self.settings.isServiceEnabled(self.service.serviceName) },
            set: { self.settings.setServiceEnabled(self.service.serviceName, $0) }
        )
    }

    // MARK: - Computed Properties

    private var connectionStatusText: String {
        switch self.service.authState {
        case .disconnected:
            "Not connected"
        case .authenticating:
            "Waiting for authorization…"
        case let .connected(username):
            "Connected as \(username)"
        case let .error(message):
            "Error: \(message)"
        }
    }

    @ViewBuilder
    private var connectionButton: some View {
        switch self.service.authState {
        case .disconnected, .error:
            Button("Connect") {
                Task {
                    self.isAuthenticating = true
                    defer { self.isAuthenticating = false }
                    do {
                        try await self.service.authenticate()
                    } catch {
                        DiagnosticsLogger.scrobbling.error("Auth failed for \(self.service.serviceName): \(error.localizedDescription)")
                    }
                }
            }
            .disabled(self.isAuthenticating)

        case .authenticating:
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Button("Cancel") {
                    Task {
                        await self.service.disconnect()
                    }
                }
            }

        case .connected:
            Button("Disconnect") {
                Task {
                    await self.service.disconnect()
                }
            }
        }
    }
}
