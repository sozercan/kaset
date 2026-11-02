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
    @State private var showTechnicalDetails: Bool

    init(review: ExtensionPermissionReview, isApproving: Bool, cancel: @escaping () -> Void, approve: @escaping () -> Void) {
        self.review = review
        self.isApproving = isApproving
        self.cancel = cancel
        self.approve = approve
        self._showTechnicalDetails = State(initialValue: review.permissions.permissions.contains {
            ExtensionPermissions.accessDescription(for: $0) == nil
        })
    }

    var body: some View {
        VStack(spacing: 0) {
            self.header

            ViewThatFits(in: .vertical) {
                self.reviewContent
                    .fixedSize(horizontal: false, vertical: true)

                ScrollView {
                    self.reviewContent
                }
                .scrollBounceBehavior(.basedOnSize)
            }
            .frame(maxHeight: .infinity, alignment: .top)

            Divider()
            self.footer
        }
        .frame(width: 480, height: 540)
        .interactiveDismissDisabled(self.isApproving)
    }

    private var reviewContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(String(localized: "When turned on, it can:"))
                .font(.subheadline)
                .foregroundStyle(.secondary)

            self.accessSummary

            Text(self.privacyNotice)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            self.technicalDetails
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
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
                Text(String(localized: "Turn on this extension?"))
                    .font(.title3.weight(.semibold))
                Text(self.review.name)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .help(self.review.name)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
    }

    private var privacyNotice: String {
        if self.review.permissions.requestsPageAccess {
            return String(localized: "It could read and share information shown while you’re signed in. Only turn it on if you trust it.")
        }
        return String(localized: "An extension can share the information it can access. Only turn it on if you trust it.")
    }

    private var accessSummary: some View {
        VStack(alignment: .leading, spacing: 18) {
            if self.review.permissions.permissions.contains("cookies") {
                self.permissionSummary("cookies")
            }
            if !self.review.permissions.websitePatterns.isEmpty {
                let websites = Set(self.review.permissions.websitePatterns.map { ExtensionPermissions.websiteName(for: $0) }).sorted()
                self.accessRow(
                    symbol: "globe",
                    title: String(localized: "Read and change pages"),
                    detail: websites.joined(separator: "\n")
                )
            }
            ForEach(self.review.permissions.permissions.filter { $0 != "cookies" }, id: \.self) { permission in
                self.permissionSummary(permission)
            }
            if self.review.permissions.websitePatterns.isEmpty, self.review.permissions.permissions.isEmpty {
                self.accessRow(
                    symbol: "doc",
                    title: String(localized: "No extra access requested"),
                    detail: String(localized: "No webpage or sign-in access has been requested.")
                )
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: .rect(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.35), lineWidth: 0.5)
        }
    }

    @ViewBuilder
    private func permissionSummary(_ permission: String) -> some View {
        if let description = ExtensionPermissions.accessDescription(for: permission) {
            self.accessRow(symbol: description.symbol, title: description.title, detail: description.detail, isSensitive: permission == "cookies")
        } else {
            self.accessRow(
                symbol: "exclamationmark.triangle",
                title: String(localized: "Other access requested"),
                detail: String(localized: "Kaset can’t explain this request. Check Technical details before turning it on."),
                isSensitive: true
            )
        }
    }

    private func accessRow(symbol: String, title: String, detail: String, isSensitive: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .foregroundStyle(isSensitive ? Color.orange : Color.secondary)
                .frame(width: 20, height: 18)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: title)
                    .font(.callout.weight(.medium))
                Text(verbatim: detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    private var technicalDetails: some View {
        DisclosureGroup(isExpanded: self.$showTechnicalDetails) {
            VStack(alignment: .leading, spacing: 10) {
                if !self.review.permissions.websitePatterns.isEmpty {
                    Text(String(localized: "Read and change pages on these websites:"))
                        .font(.caption.weight(.semibold))
                    ForEach(self.review.permissions.websitePatterns, id: \.self) { pattern in
                        Text(verbatim: pattern)
                            .font(.system(.caption, design: .monospaced))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if !self.review.permissions.permissions.isEmpty {
                    Text(String(localized: "Required API permissions:"))
                        .font(.caption.weight(.semibold))
                    Text(verbatim: self.review.permissions.permissions.joined(separator: ", "))
                        .font(.system(.caption, design: .monospaced))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(String(localized: "Optional permissions are not granted. Changes to required access need another review."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .textSelection(.enabled)
            .padding(.top, 10)
        } label: {
            Text(String(localized: "Technical details"))
                .font(.callout)
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(String(localized: "Takes effect after restarting Kaset."))
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                Spacer()
                Button(String(localized: "Not Now"), action: self.cancel)
                    .buttonStyle(.bordered)
                    .keyboardShortcut(.cancelAction)
                Button(action: self.approve) {
                    HStack(spacing: 6) {
                        if self.isApproving {
                            ProgressView().controlSize(.small)
                        }
                        Text(self.isApproving ? String(localized: "Turning On…") : String(localized: "Turn On"))
                    }
                }
                .compatGlassProminentButton()
            }
            .controlSize(.large)
            .buttonBorderShape(.capsule)
            .disabled(self.isApproving)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }
}
