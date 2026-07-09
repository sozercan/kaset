import SwiftUI

struct LoadMoreFooter: View {
    let isLoading: Bool
    let title: LocalizedStringResource
    let loadingTitle: LocalizedStringResource
    var autoLoad: Bool = false
    var autoLoadTrigger = 0
    let action: @MainActor () async -> Void

    @State private var lastAutoLoadTrigger: Int?

    var body: some View {
        VStack(spacing: 0) {
            if self.isLoading {
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
        .task(id: self.autoLoadTrigger) {
            await self.autoLoadIfNeeded()
        }
        .onChange(of: self.isLoading) { _, isLoading in
            guard !isLoading else { return }
            Task { await self.autoLoadIfNeeded() }
        }
        .onDisappear {
            self.lastAutoLoadTrigger = nil
        }
    }

    @MainActor
    private func autoLoadIfNeeded() async {
        guard self.autoLoad,
              !self.isLoading,
              self.lastAutoLoadTrigger != self.autoLoadTrigger
        else { return }

        self.lastAutoLoadTrigger = self.autoLoadTrigger
        await self.action()
    }
}
