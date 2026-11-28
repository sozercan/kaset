import SwiftUI

struct SidebarFooterView: View {
    @State private var settings = SettingsManager.shared

    var body: some View {
        VStack(spacing: 0) {
            Divider()
                .opacity(0.3)

            SidebarProfileView()

            if self.settings.appExperience.showsSourceToggle {
                SourceToggleView()
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
            }
        }
    }
}

#Preview {
    SidebarFooterView()
        .frame(width: 220)
}
