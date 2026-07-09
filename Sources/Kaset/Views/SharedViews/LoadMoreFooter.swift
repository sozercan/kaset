import SwiftUI

struct LoadMoreFooter: View {
    let isLoading: Bool
    let title: LocalizedStringResource
    let loadingTitle: LocalizedStringResource
    var autoLoad: Bool = false
    let action: @MainActor () async -> Void

    @State private var didAutoLoadForCurrentAppearance = false

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
        .task {
            await self.autoLoadIfNeeded()
        }
        .onDisappear {
            self.didAutoLoadForCurrentAppearance = false
        }
    }

    @MainActor
    private func autoLoadIfNeeded() async {
        guard self.autoLoad,
              !self.isLoading,
              !self.didAutoLoadForCurrentAppearance
        else { return }

        self.didAutoLoadForCurrentAppearance = true
        await self.action()
    }
}
