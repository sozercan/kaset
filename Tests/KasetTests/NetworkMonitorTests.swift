import Foundation
import Network
import Testing
@testable import Kaset

@Suite(.tags(.service))
@MainActor
struct NetworkMonitorTests {
    @Test("Shared instance is stable")
    func sharedInstanceIsStable() {
        let first = NetworkMonitor.shared
        let second = NetworkMonitor.shared

        #expect(first === second)
        #expect(!first.statusDescription.isEmpty)
    }

    @Test("Initial state defaults to connected")
    func initialStateDefaults() {
        let monitor = NetworkMonitor.shared
        #expect(monitor.isConnected == true)
    }

    @Test("Interface type has description")
    func interfaceTypeDescriptions() {
        #expect(NetworkMonitor.InterfaceType.wifi.description == "Wi-Fi")
        #expect(NetworkMonitor.InterfaceType.cellular.description == "Cellular")
        #expect(NetworkMonitor.InterfaceType.wiredEthernet.description == "Ethernet")
        #expect(NetworkMonitor.InterfaceType.loopback.description == "Loopback")
        #expect(NetworkMonitor.InterfaceType.other.description == "Other")
        #expect(NetworkMonitor.InterfaceType.unknown.description == "Unknown")
    }

    @Test("Status description when connected shows interface type")
    func statusDescriptionWhenConnected() {
        let monitor = NetworkMonitor.shared
        if monitor.isConnected {
            #expect(!monitor.statusDescription.isEmpty)
            #expect(monitor.statusDescription != "No internet connection")
        }
    }

    @Test("Status description when disconnected shows no internet")
    func statusDescriptionFormat() {
        let monitor = NetworkMonitor.shared
        let description = monitor.statusDescription

        #expect(!description.isEmpty)

        if !monitor.isConnected {
            #expect(description == "No internet connection")
        }
    }

    @Test("Interface type is Sendable")
    func interfaceTypeIsSendable() {
        let interfaceType: NetworkMonitor.InterfaceType = .wifi
        Task.detached {
            _ = interfaceType.description
        }
    }

    @Test("Expensive connection flag is available")
    func expensiveConnectionFlag() {
        let monitor = NetworkMonitor.shared
        _ = monitor.isExpensive
    }

    @Test("Constrained connection flag is available")
    func constrainedConnectionFlag() {
        let monitor = NetworkMonitor.shared
        _ = monitor.isConstrained
    }
}
