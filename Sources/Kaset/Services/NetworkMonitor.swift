import Foundation
import Network
import Observation

// MARK: - NetworkMonitor

/// Monitors network connectivity using NWPathMonitor.
/// Uses system callbacks for real-time updates (no polling needed).
/// Note: NWPathMonitor requires DispatchQueue - no async/await API available from Apple.
@MainActor
@Observable
final class NetworkMonitor {
    /// Shared singleton instance.
    static let shared = NetworkMonitor()

    /// Whether the network is currently available.
    private(set) var isConnected: Bool = true

    /// Whether the connection is expensive (cellular/hotspot).
    private(set) var isExpensive: Bool = false

    /// Whether the connection is constrained (low data mode).
    private(set) var isConstrained: Bool = false

    /// The current network interface type.
    private(set) var interfaceType: InterfaceType = .unknown

    /// Human-readable description of the current connection status.
    var statusDescription: String {
        if !self.isConnected {
            return "No internet connection"
        }
        var description = self.interfaceType.description
        if self.isExpensive {
            description += " (expensive)"
        }
        if self.isConstrained {
            description += " (low data mode)"
        }
        return description
    }

    /// Network interface types.
    enum InterfaceType: Sendable {
        case wifi
        case cellular
        case wiredEthernet
        case loopback
        case other
        case unknown

        var description: String {
            switch self {
            case .wifi: "Wi-Fi"
            case .cellular: "Cellular"
            case .wiredEthernet: "Ethernet"
            case .loopback: "Loopback"
            case .other: "Other"
            case .unknown: "Unknown"
            }
        }
    }

    /// NWPathMonitor is Sendable and immutable, so no isolation annotation needed.
    private let monitor: NWPathMonitor
    private let queue: DispatchQueue
    private let logger = DiagnosticsLogger.network

    private init() {
        self.monitor = NWPathMonitor()
        self.queue = DispatchQueue(label: "com.kaset.networkMonitor", qos: .utility)
        self.startMonitoring()
    }

    deinit {
        self.monitor.cancel()
    }

    /// Starts monitoring network changes.
    private func startMonitoring() {
        self.monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor [weak self] in
                self?.updatePath(path)
            }
        }
        self.monitor.start(queue: self.queue)
        self.logger.info("Network monitoring started")
    }

    /// Updates state based on the new network path.
    private func updatePath(_ path: NWPath) {
        let wasConnected = self.isConnected
        self.isConnected = path.status == .satisfied
        self.isExpensive = path.isExpensive
        self.isConstrained = path.isConstrained
        self.interfaceType = Self.mapInterfaceType(path)

        // Log connectivity changes
        if wasConnected != self.isConnected {
            if self.isConnected {
                self.logger.info("Network connected: \(self.statusDescription)")
            } else {
                self.logger.warning("Network disconnected")
            }
        }
    }

    /// Maps NWPath interface to our InterfaceType.
    private static func mapInterfaceType(_ path: NWPath) -> InterfaceType {
        if path.usesInterfaceType(.wifi) {
            return .wifi
        } else if path.usesInterfaceType(.cellular) {
            return .cellular
        } else if path.usesInterfaceType(.wiredEthernet) {
            return .wiredEthernet
        } else if path.usesInterfaceType(.loopback) {
            return .loopback
        } else if path.usesInterfaceType(.other) {
            return .other
        }
        return .unknown
    }
}
