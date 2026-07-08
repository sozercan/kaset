import SwiftUI

struct LoadMoreFooter: View {
    let isLoading: Bool
    let title: LocalizedStringResource
    let loadingTitle: LocalizedStringResource
    let action: @MainActor () async -> Void

    var body: some View {
        Group {
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
    }
}
