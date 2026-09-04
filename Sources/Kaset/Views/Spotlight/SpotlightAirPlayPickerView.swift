import AVKit
import SwiftUI

/// Wireless AirPlay audio output target selection view for Spotlight mode.
struct SpotlightAirPlayPickerView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var availableRoutes: [AirPlayRoute] = [
        AirPlayRoute(id: "system", name: "MacBook Pro Speakers", isCurrent: true, type: .builtIn),
        AirPlayRoute(id: "homepod_living", name: "Living Room HomePod", isCurrent: false, type: .homePod),
        AirPlayRoute(id: "airplay_tv", name: "Apple TV 4K", isCurrent: false, type: .appleTV),
    ]

    struct AirPlayRoute: Identifiable {
        let id: String
        let name: String
        var isCurrent: Bool
        let type: RouteType

        enum RouteType {
            case builtIn
            case homePod
            case appleTV
            case bluetooth

            var iconName: String {
                switch self {
                case .builtIn: "laptopcomputer"
                case .homePod: "homepod.fill"
                case .appleTV: "appletv.fill"
                case .bluetooth: "headphones"
                }
            }
        }
    }

    var body: some View {
        VStack(spacing: 20) {
            HStack {
                Text("Audio Output Target")
                    .font(.headline)
                Spacer()
                Button(action: { self.dismiss() }, label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                })
                .buttonStyle(.plain)
            }
            .padding([.top, .horizontal], 20)

            List(self.$availableRoutes) { $route in
                HStack(spacing: 12) {
                    Image(systemName: route.type.iconName)
                        .font(.title3)
                        .foregroundStyle(route.isCurrent ? Color.accentColor : Color.secondary)
                        .frame(width: 24)

                    Text(route.name)
                        .font(.body)
                        .foregroundStyle(route.isCurrent ? .primary : .secondary)

                    Spacer()

                    if route.isCurrent {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.body)
                            .foregroundStyle(Color.accentColor)
                    }
                }
                .padding(.vertical, 6)
                .contentShape(Rectangle())
                .onTapGesture {
                    for i in self.availableRoutes.indices {
                        self.availableRoutes[i].isCurrent = (self.availableRoutes[i].id == route.id)
                    }
                }
            }
            .listStyle(.sidebar)

            HStack {
                Spacer()
                Button("Done") {
                    self.dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding([.bottom, .horizontal], 20)
        }
        .frame(width: 380, height: 320)
    }
}
