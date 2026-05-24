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

    /// Whether the network is currently available and not cut off by offline mode.
    var isConnected: Bool {
        if SettingsManager.shared.offlineModeEnabled {
            return false
        }
        return self.realIsConnected
    }

    /// Internal actual physical connection status.
    private(set) var realIsConnected: Bool = true

    /// Whether the connection is expensive (cellular/hotspot).
    private(set) var isExpensive: Bool = false

    /// Whether the connection is constrained (low data mode).
    private(set) var isConstrained: Bool = false

    /// The current network interface type.
    private(set) var interfaceType: InterfaceType = .unknown

    /// Whether offline mode was automatically enabled by a system network drop.
    private var isOfflineModeSystemInitiated: Bool = false

    /// Clears the system-initiated offline mode flag when the user manually goes online.
    func clearSystemInitiatedOffline() {
        self.isOfflineModeSystemInitiated = false
    }

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
    enum InterfaceType {
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
        let isPhysicallyConnected = path.status == .satisfied
        let wasConnected = self.realIsConnected
        self.realIsConnected = isPhysicallyConnected
        self.isExpensive = path.isExpensive
        self.isConstrained = path.isConstrained
        self.interfaceType = Self.mapInterfaceType(path)

        // Log and handle connectivity changes
        if wasConnected != isPhysicallyConnected {
            if isPhysicallyConnected {
                self.logger.info("Network connected: \(self.statusDescription)")

                // If offline mode was system-initiated, turn it off automatically now that we have internet back
                if self.isOfflineModeSystemInitiated {
                    self.logger.info("System connected back to internet; automatically disabling offline mode")
                    SettingsManager.shared.offlineModeEnabled = false
                    self.isOfflineModeSystemInitiated = false
                }
            } else {
                self.logger.warning("Network disconnected")

                // If the app is not already in offline mode, enable it automatically
                if !SettingsManager.shared.offlineModeEnabled {
                    self.logger.info("System disconnected from internet; automatically enabling offline mode")
                    self.isOfflineModeSystemInitiated = true
                    SettingsManager.shared.offlineModeEnabled = true
                }
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
