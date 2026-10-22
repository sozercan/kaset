import SwiftUI

// MARK: - MiniPlayerGlassIconLabel

struct MiniPlayerGlassIconLabel: View {
    let systemName: String
    let isActive: Bool
    let size: CGFloat
    var fontSize: CGFloat = 14

    var body: some View {
        Image(systemName: self.systemName)
            .font(.system(size: self.fontSize, weight: .bold))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(self.isActive ? PackageResourceLookup.brandAccent : .white.opacity(0.94))
            .frame(width: self.size, height: self.size)
            .background(self.isActive ? PackageResourceLookup.brandAccent.opacity(0.20) : .white.opacity(0.05), in: .circle)
            .overlay {
                Circle()
                    .stroke(self.isActive ? PackageResourceLookup.brandAccent.opacity(0.90) : .white.opacity(0.26), lineWidth: self.isActive ? 1.2 : 1)
            }
            .contentShape(.circle)
    }
}
