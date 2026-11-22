import SwiftUI

struct SidebarFooterView: View {
    var body: some View {
        VStack(spacing: 0) {
            Divider()
                .opacity(0.3)

            SidebarProfileView()

            SourceToggleView()
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
        }
    }
}

#Preview {
    SidebarFooterView()
        .frame(width: 220)
}
