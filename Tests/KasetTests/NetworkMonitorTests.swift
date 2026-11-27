import Foundation
import Network
import Testing
@testable import Kaset

@Suite(.tags(.service))
@MainActor
struct NetworkMonitorTests {
    @Test("Isolated monitor starts connected and updates status transitions deterministically")
    func isolatedMonitorTransitions() {
        let monitor = NetworkMonitor()
        #expect(monitor.isConnected == true)
        #expect(monitor.statusDescription == "Unknown")

        monitor.applyPathState(isConnected: true, isExpensive: true, isConstrained: true, interfaceType: .cellular)
        #expect(monitor.isConnected == true)
        #expect(monitor.isExpensive == true)
        #expect(monitor.isConstrained == true)
        #expect(monitor.statusDescription == "Cellular (expensive) (low data mode)")

        monitor.applyPathState(isConnected: false, isExpensive: false, isConstrained: false, interfaceType: .unknown)
        #expect(monitor.isConnected == false)
        #expect(monitor.statusDescription == "No internet connection")
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
        let monitor = NetworkMonitor(isConnected: true, interfaceType: .wifi)
        #expect(monitor.statusDescription == "Wi-Fi")
    }

    @Test("Status description when disconnected shows no internet")
    func statusDescriptionFormat() {
        let monitor = NetworkMonitor(isConnected: false, interfaceType: .unknown)
        #expect(monitor.statusDescription == "No internet connection")
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
        let monitor = NetworkMonitor(isExpensive: true)
        #expect(monitor.isExpensive == true)
    }

    @Test("Constrained connection flag is available")
    func constrainedConnectionFlag() {
        let monitor = NetworkMonitor(isConstrained: true)
        #expect(monitor.isConstrained == true)
    }
}
