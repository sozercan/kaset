import Foundation
import Network
import Testing
@testable import Kaset

/// Tests for NetworkMonitor.
@Suite("NetworkMonitor", .tags(.service))
@MainActor
struct NetworkMonitorTests {
    @Test("Shared instance exists")
    func sharedInstanceExists() {
        let monitor = NetworkMonitor.shared
        #expect(monitor !== nil)
    }

    @Test("Initial state defaults to connected")
    func initialStateDefaults() {
        let monitor = NetworkMonitor.shared
        // By default, isConnected should be true (optimistic default)
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
        // When connected, statusDescription should include the interface type
        if monitor.isConnected {
            #expect(!monitor.statusDescription.isEmpty)
            #expect(monitor.statusDescription != "No internet connection")
        }
    }

    @Test("Status description when disconnected shows no internet")
    func statusDescriptionFormat() {
        // This test verifies the format of the status description
        // The actual state depends on the real network, so we just verify the format
        let monitor = NetworkMonitor.shared
        let description = monitor.statusDescription

        // Description should not be empty
        #expect(!description.isEmpty)

        // If not connected, it should be the disconnect message
        if !monitor.isConnected {
            #expect(description == "No internet connection")
        }
    }

    @Test("Interface type is Sendable")
    func interfaceTypeIsSendable() {
        // Verify InterfaceType conforms to Sendable by using it across concurrency domains
        let interfaceType: NetworkMonitor.InterfaceType = .wifi
        Task.detached {
            // This compiles only if InterfaceType is Sendable
            _ = interfaceType.description
        }
    }

    @Test("Expensive connection flag is available")
    func expensiveConnectionFlag() {
        let monitor = NetworkMonitor.shared
        // Just verify the property is accessible (actual value depends on real network)
        _ = monitor.isExpensive
    }

    @Test("Constrained connection flag is available")
    func constrainedConnectionFlag() {
        let monitor = NetworkMonitor.shared
        // Just verify the property is accessible (actual value depends on real network)
        _ = monitor.isConstrained
    }
}
