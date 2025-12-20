import SwiftUI

/// Sidebar navigation for the main window.
struct Sidebar: View {
    @Binding var selection: NavigationItem?

    var body: some View {
        List(selection: $selection) {
            Section {
                ForEach(NavigationItem.allCases) { item in
                    NavigationLink(value: item) {
                        Label(item.rawValue, systemImage: item.icon)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 300)
        .navigationTitle("YouTube Music")
    }
}

#Preview {
    Sidebar(selection: .constant(.home))
        .frame(width: 220)
}
