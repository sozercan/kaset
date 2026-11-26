import Foundation
import Network
import Observation

@MainActor
@Observable
final class NetworkMonitor {
    static let shared = NetworkMonitor()

    private(set) var isConnected: Bool = true

    private(set) var isExpensive: Bool = false

    private(set) var isConstrained: Bool = false

    private(set) var interfaceType: InterfaceType = .unknown

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

    private func startMonitoring() {
        self.monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor [weak self] in
                self?.updatePath(path)
            }
        }
        self.monitor.start(queue: self.queue)
        self.logger.info("Network monitoring started")
    }

    private func updatePath(_ path: NWPath) {
        let wasConnected = self.isConnected
        self.isConnected = path.status == .satisfied
        self.isExpensive = path.isExpensive
        self.isConstrained = path.isConstrained
        self.interfaceType = Self.mapInterfaceType(path)

        if wasConnected != self.isConnected {
            if self.isConnected {
                self.logger.info("Network connected: \(self.statusDescription)")
            } else {
                self.logger.warning("Network disconnected")
            }
        }
    }

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
