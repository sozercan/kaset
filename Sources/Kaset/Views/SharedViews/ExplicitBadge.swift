import SwiftUI

struct ExplicitBadge: View {
    var body: some View {
        Text(String(localized: "E"))
            .font(.system(size: 8, weight: .semibold))
            .foregroundStyle(.background)
            .frame(width: 12, height: 12)
            .background(.secondary, in: .rect(cornerRadius: 2.5))
            .accessibilityLabel(Text(String(localized: "Explicit")))
    }
}

#Preview {
    ExplicitBadge()
        .padding()
}
