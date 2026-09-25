import SwiftUI

/// Menu commands for the shared app appearance preference.
struct AppearanceCommands: Commands {
    @Binding var appearance: AppAppearance

    var body: some Commands {
        CommandMenu(String(localized: "Appearance")) {
            Picker(String(localized: "Appearance"), selection: self.$appearance) {
                ForEach(AppAppearance.allCases) { appearance in
                    Text(appearance.displayName).tag(appearance)
                }
            }
            .pickerStyle(.inline)
        }
    }
}
