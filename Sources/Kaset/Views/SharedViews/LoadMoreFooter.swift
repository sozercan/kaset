import SwiftUI

struct LoadMoreFooter: View {
    let isLoading: Bool
    let title: LocalizedStringResource
    let loadingTitle: LocalizedStringResource
    var autoLoad: Bool = false
    var autoLoadTrigger = 0
    let action: @MainActor () async -> Void

    @State private var lastAutoLoadTrigger: Int?
    @State private var isAutoLoadAttemptInFlight = false
    @State private var isVisible = false

    var body: some View {
        VStack(spacing: 0) {
            if self.shouldShowLoadingIndicator {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text(self.loadingTitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } else {
                Button {
                    Task { await self.action() }
                } label: {
                    Label(self.title, systemImage: "arrow.down.circle")
                }
                .buttonStyle(.borderless)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, DetailContentLayout.horizontalInset)
        .padding(.vertical, 12)
        .onAppear {
            self.isVisible = true
            self.scheduleAutoLoadIfNeeded()
        }
        .task(id: self.autoLoadTrigger) {
            await self.autoLoadIfNeeded()
        }
        .onChange(of: self.isLoading) { _, isLoading in
            guard !isLoading else { return }
            self.scheduleAutoLoadIfNeeded()
        }
        .onDisappear {
            self.isVisible = false
            self.lastAutoLoadTrigger = nil
            self.isAutoLoadAttemptInFlight = false
        }
    }

    private var shouldShowLoadingIndicator: Bool {
        self.isLoading
            || self.isAutoLoadAttemptInFlight
            || (self.autoLoad && self.lastAutoLoadTrigger != self.autoLoadTrigger)
    }

    @MainActor
    private var canStartAutoLoad: Bool {
        self.autoLoad
            && self.isVisible
            && !self.isLoading
            && !self.isAutoLoadAttemptInFlight
            && self.lastAutoLoadTrigger != self.autoLoadTrigger
    }

    @MainActor
    private func autoLoadIfNeeded() async {
        guard self.canStartAutoLoad else { return }

        self.lastAutoLoadTrigger = self.autoLoadTrigger
        self.isAutoLoadAttemptInFlight = true
        defer {
            self.isAutoLoadAttemptInFlight = false
            self.scheduleAutoLoadIfNeeded()
        }
        await self.action()
    }

    @MainActor
    private func scheduleAutoLoadIfNeeded() {
        guard self.canStartAutoLoad else { return }
        Task { await self.autoLoadIfNeeded() }
    }
}
