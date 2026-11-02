import AppKit
import Foundation
import SwiftUI

// MARK: - ExtensionsSettingsView

/// Settings view for managing user-installed web extensions.
struct ExtensionsSettingsView: View {
    @State private var manager = ExtensionsManager.shared
    @State private var showRestartAlert = false
    @State private var pendingChangeDescription = ""
    @State private var configuringExtensionPage: WebKitManager.ExtensionPage?
    @State private var permissionReview: ExtensionPermissionReview?
    @State private var isReviewingPermissions = false
    @State private var extensionError: String?

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                // Glass Section
                CompatGlassContainer(spacing: 0) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(String(localized: "Installed Extensions"))
                            .font(.headline)
                            .padding(.horizontal, 16)
                            .padding(.top, 16)
                            .padding(.bottom, 8)

                        if self.manager.extensions.isEmpty {
                            HStack(spacing: 10) {
                                Image(systemName: "puzzlepiece.extension")
                                    .font(.title2)
                                    .foregroundStyle(.quaternary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(String(localized: "No Extensions Added"))
                                        .font(.body)
                                        .foregroundStyle(.secondary)
                                    Text(String(localized: "Add a WebKit-compatible extension to get started."))
                                        .font(.caption)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                        } else {
                            ForEach(self.manager.extensions) { ext in
                                self.extensionRow(ext)
                                if ext.id != self.manager.extensions.last?.id {
                                    Divider()
                                        .padding(.leading, 16)
                                        .opacity(0.3)
                                }
                            }
                        }

                        Button {
                            Task { @MainActor in
                                await self.presentOpenPanel()
                            }
                        } label: {
                            Label(String(localized: "Add Extension…"), systemImage: "plus.circle")
                                .foregroundStyle(.blue)
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                    }
                    .compatGlass(in: .rect(cornerRadius: 14))
                }

                // Footer section
                VStack(alignment: .leading, spacing: 6) {
                    Text(String(localized: "About Extensions"))
                        .font(.headline)
                        .padding(.bottom, 2)

                    Text(String(localized: "Extensions are loaded at launch via the native WebKit extension API. Changes take effect after restarting Kaset."))
                        .foregroundStyle(.secondary)

                    HStack(spacing: 4) {
                        Image(systemName: "info.circle")
                        Text(
                            "Only WebKit-compatible extensions (with a valid **manifest.json**) are supported.",
                            bundle: AppLocalization.bundle
                        )
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 8)
            }
            .padding(20)
        }
        .frame(minWidth: 460, minHeight: 400)
        .navigationTitle(String(localized: "Extensions"))
        .disabled(self.isReviewingPermissions)
        .alert(String(localized: "Extension Error"), isPresented: Binding(
            get: { self.extensionError != nil },
            set: {
                if !$0 {
                    self.extensionError = nil
                }
            }
        )) {
            Button(String(localized: "OK")) { self.extensionError = nil }
        } message: {
            Text(self.extensionError ?? "")
        }
        .alert("Restart Required", isPresented: self.$showRestartAlert) {
            Button(String(localized: "Later")) {}
            Button(String(localized: "Restart Now")) {
                self.restartApp()
            }
            .keyboardShortcut(.defaultAction)
        } message: {
            Text("\(self.pendingChangeDescription) will take effect after restarting Kaset.")
        }
        .sheet(item: self.$configuringExtensionPage) { extensionPage in
            NavigationStack {
                ExtensionOptionsView(page: extensionPage)
                    .frame(minWidth: 600, minHeight: 450)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button(String(localized: "Done")) {
                                self.configuringExtensionPage = nil
                            }
                        }
                    }
            }
        }
        .sheet(item: self.$permissionReview) { review in
            ExtensionPermissionReviewView(review: review, isApproving: self.isReviewingPermissions) {
                self.permissionReview = nil
            } approve: {
                Task { @MainActor in
                    self.isReviewingPermissions = true
                    defer { self.isReviewingPermissions = false }
                    do {
                        try await self.manager.approveExtension(review)
                        self.permissionReview = nil
                        self.pendingChangeDescription = "\"\(review.name)\""
                        self.showRestartAlert = true
                    } catch {
                        self.permissionReview = nil
                        self.extensionError = error.localizedDescription
                    }
                }
            }
        }
    }

    // MARK: - Extension Row

    private func extensionRow(_ ext: ManagedExtension) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "puzzlepiece.extension.fill")
                .foregroundStyle(ext.isEnabled ? .blue : .secondary)
                .font(.title3)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(ext.name)
                    .font(.body)
                Text(ext.approvedPermissions == nil ? String(localized: "Review Required") : String(localized: ext.isEnabled ? "Enabled" : "Disabled"))
                    .font(.caption)
                    .foregroundStyle(ext.isEnabled ? .green : .secondary)
            }

            Spacer()

            Toggle(ext.name, isOn: Binding(
                get: { ext.isEnabled },
                set: { _ in
                    if ext.isEnabled {
                        self.manager.disableExtension(id: ext.id)
                        self.pendingChangeDescription = "\"\(ext.name)\""
                        self.showRestartAlert = true
                    } else {
                        Task { @MainActor in
                            await self.reviewPermissions(id: ext.id)
                        }
                    }
                }
            ))
            .labelsHidden()

            if ext.isEnabled, let extensionPage = WebKitManager.shared.extensionPage(forExtensionId: ext.id) {
                Button(String(localized: "Options…")) {
                    self.configuringExtensionPage = extensionPage
                }
                .buttonStyle(.plain)
                .foregroundStyle(.blue)
                .help(String(localized: "Configure extension"))
            }

            Button(role: .destructive) {
                self.manager.removeExtension(id: ext.id)
                self.pendingChangeDescription = "Removing \"\(ext.name)\""
                self.showRestartAlert = true
            } label: {
                Image(systemName: "trash")
                    .foregroundStyle(.red)
            }
            .buttonStyle(.plain)
            .help(String(localized: "Remove extension"))
            .accessibilityLabel("Remove \(ext.name)")
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 16)
    }

    // MARK: - Helpers

    /// Shows an NSOpenPanel to pick an extension directory.
    /// `beginSheetModal` silently fails on SwiftUI Settings TabView windows,
    /// so we use `runModal()` with explicit panel activation.
    private func presentOpenPanel() async {
        DiagnosticsLogger.extensions.info("presentOpenPanel() called")

        let panel = NSOpenPanel()
        panel.title = "Select Extension Folder"
        panel.message = "Select the folder containing the extension's 'manifest.json' file."
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.level = .modalPanel

        let response = panel.runModal()
        guard response == .OK, let url = panel.url else { return }

        do {
            let id = try self.manager.addExtension(at: url)
            await self.reviewPermissions(id: id)
        } catch {
            let errorDesc = error.localizedDescription
            DiagnosticsLogger.extensions.error("Failed to add extension: \(errorDesc, privacy: .public)")
            self.extensionError = errorDesc
        }
    }

    private func reviewPermissions(id: String) async {
        self.isReviewingPermissions = true
        defer { self.isReviewingPermissions = false }
        do {
            self.permissionReview = try await self.manager.permissionReview(id: id)
        } catch {
            self.extensionError = error.localizedDescription
        }
    }

    private func restartApp() {
        DiagnosticsLogger.extensions.info("Restarting app...")
        let url = Bundle.main.bundleURL
        // Use a shell script to wait a second after we terminate, ensuring we don't
        // conflict with the existing process during re-launch.
        let shellScript = "sleep 0.5; open '\(url.path)'"
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", shellScript]
        do {
            try task.run()
            NSApplication.shared.terminate(nil)
        } catch {
            DiagnosticsLogger.extensions.error("Failed to run restart script: \(error.localizedDescription)")
            // Fallback to simple open
            let fallbackTask = Process()
            fallbackTask.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            fallbackTask.arguments = [url.path]
            try? fallbackTask.run()
            NSApplication.shared.terminate(nil)
        }
    }
}

// MARK: - ExtensionPermissionReviewView

private struct ExtensionPermissionReviewView: View {
    let review: ExtensionPermissionReview
    let isApproving: Bool
    let cancel: () -> Void
    let approve: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            self.header

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text(String(localized: "Extensions can read signed-in page data and send data to other services. Only enable code you trust."))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if self.review.permissions.permissions.contains("cookies") {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "exclamationmark.shield")
                                .foregroundStyle(.orange)
                                .accessibilityHidden(true)
                            Text(String(localized: "Cookie access can expose your Google session."))
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                        }
                        .font(.callout)
                        .padding(12)
                        .background(Color.orange.opacity(0.08), in: .rect(cornerRadius: 12))
                    }

                    if !self.review.permissions.websitePatterns.isEmpty {
                        self.websiteAccess
                    }
                    if !self.review.permissions.permissions.isEmpty {
                        self.apiAccess
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollBounceBehavior(.basedOnSize)

            Divider()
            self.footer
        }
        .frame(width: 480, height: 600)
        .interactiveDismissDisabled(self.isApproving)
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "puzzlepiece.extension.fill")
                .font(.system(size: 26, weight: .medium))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.tint)
                .frame(width: 52, height: 52)
                .background(Color.accentColor.opacity(0.1), in: .rect(cornerRadius: 14))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(String(localized: "Review Extension Access"))
                    .font(.title3.weight(.semibold))
                Text(self.review.name)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .help(self.review.name)
            }
            Spacer(minLength: 0)
        }
        .padding(24)
    }

    private var websiteAccess: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "Read and change pages on these websites:"))
                .font(.subheadline.weight(.semibold))

            VStack(spacing: 0) {
                ForEach(self.review.permissions.websitePatterns, id: \.self) { pattern in
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "globe")
                            .foregroundStyle(.secondary)
                            .frame(width: 20)
                            .accessibilityHidden(true)
                        Text(verbatim: pattern)
                            .font(.system(.callout, design: .monospaced))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .padding(12)
                    if pattern != self.review.permissions.websitePatterns.last {
                        Divider().padding(.leading, 44)
                    }
                }
            }
            .background(Color(nsColor: .controlBackgroundColor), in: .rect(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color(nsColor: .separatorColor).opacity(0.35), lineWidth: 0.5)
            }
        }
    }

    private var apiAccess: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "Required API permissions:"))
                .font(.subheadline.weight(.semibold))

            VStack(spacing: 0) {
                ForEach(self.review.permissions.permissions, id: \.self) { permission in
                    self.permissionRow(permission)
                    if permission != self.review.permissions.permissions.last {
                        Divider().padding(.leading, 44)
                    }
                }
            }
            .background(Color(nsColor: .controlBackgroundColor), in: .rect(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color(nsColor: .separatorColor).opacity(0.35), lineWidth: 0.5)
            }
        }
    }

    private func permissionRow(_ permission: String) -> some View {
        let presentation: (symbol: String, title: String) = switch permission {
        case "cookies":
            ("key.horizontal", String(localized: "Read and change cookies"))
        case "storage":
            ("internaldrive", String(localized: "Store extension data"))
        default:
            ("gearshape", permission)
        }

        return HStack(alignment: .top, spacing: 12) {
            Image(systemName: presentation.symbol)
                .foregroundStyle(permission == "cookies" ? Color.orange : Color.secondary)
                .frame(width: 20, height: 18)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: presentation.title)
                    .font(.callout.weight(.medium))
                if presentation.title != permission {
                    Text(verbatim: permission)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .accessibilityElement(children: .combine)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(String(localized: "Optional permissions are not granted. Changes to required access need another review."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                Spacer()
                Button(String(localized: "Cancel"), action: self.cancel)
                    .buttonStyle(.bordered)
                    .keyboardShortcut(.cancelAction)
                Button(action: self.approve) {
                    HStack(spacing: 6) {
                        if self.isApproving {
                            ProgressView().controlSize(.small)
                        }
                        Text(String(localized: "Allow and Enable"))
                    }
                }
                .compatGlassProminentButton()
            }
            .controlSize(.large)
            .buttonBorderShape(.capsule)
            .disabled(self.isApproving)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
    }
}
