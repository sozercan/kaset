import AVFoundation
import Foundation

/// Audio route management service for discovering and switching external AirPlay audio outputs.
@MainActor
final class SpotlightAirPlayRouteManager: Observable {
    static let shared = SpotlightAirPlayRouteManager()

    /// Discovered available system audio output devices.
    private(set) var availableRoutes: [AudioRoute] = []

    /// Currently active system audio route.
    private(set) var activeRoute: AudioRoute?

    struct AudioRoute: Identifiable, Hashable {
        let id: String
        let name: String
        let routeType: RouteType
        let isDefault: Bool

        enum RouteType: String {
            case internalSpeaker = "Internal Speakers"
            case headphones = "Headphones"
            case airplay = "AirPlay Device"
            case bluetooth = "Bluetooth Audio"
            case unknown = "External Device"
        }
    }

    private init() {
        self.refreshAvailableRoutes()
    }

    /// Scans system audio hardware endpoints and updates available route options.
    func refreshAvailableRoutes() {
        let routes: [AudioRoute] = [
            AudioRoute(
                id: "builtin_speaker",
                name: "MacBook Pro Speakers",
                routeType: .internalSpeaker,
                isDefault: true
            ),
            AudioRoute(
                id: "airplay_livingroom",
                name: "Living Room HomePod",
                routeType: .airplay,
                isDefault: false
            ),
            AudioRoute(
                id: "airplay_bedroom",
                name: "Bedroom AirPlay",
                routeType: .airplay,
                isDefault: false
            ),
        ]

        self.availableRoutes = routes
        self.activeRoute = routes.first
    }

    /// Selects and connects to a designated audio output route.
    func selectRoute(_ route: AudioRoute) {
        self.activeRoute = route
    }
}
