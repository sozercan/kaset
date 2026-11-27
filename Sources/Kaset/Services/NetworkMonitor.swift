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

    private let monitor: NWPathMonitor?
    private let queue: DispatchQueue?
    private let logger = DiagnosticsLogger.network

    private init() {
        let pathMonitor = NWPathMonitor()
        let monitorQueue = DispatchQueue(label: "com.kaset.networkMonitor", qos: .utility)
        self.monitor = pathMonitor
        self.queue = monitorQueue
        self.startMonitoring(pathMonitor: pathMonitor, queue: monitorQueue)
    }

    init(
        isConnected: Bool = true,
        isExpensive: Bool = false,
        isConstrained: Bool = false,
        interfaceType: InterfaceType = .unknown
    ) {
        self.monitor = nil
        self.queue = nil
        self.isConnected = isConnected
        self.isExpensive = isExpensive
        self.isConstrained = isConstrained
        self.interfaceType = interfaceType
    }

    deinit {
        self.monitor?.cancel()
    }

    private func startMonitoring(pathMonitor: NWPathMonitor, queue: DispatchQueue) {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor [weak self] in
                self?.updatePath(path)
            }
        }
        pathMonitor.start(queue: queue)
        self.logger.info("Network monitoring started")
    }

    func applyPathState(
        isConnected: Bool,
        isExpensive: Bool,
        isConstrained: Bool,
        interfaceType: InterfaceType
    ) {
        let wasConnected = self.isConnected
        self.isConnected = isConnected
        self.isExpensive = isExpensive
        self.isConstrained = isConstrained
        self.interfaceType = interfaceType

        if wasConnected != self.isConnected {
            if self.isConnected {
                self.logger.info("Network connected: \(self.statusDescription)")
            } else {
                self.logger.warning("Network disconnected")
            }
        }
    }

    private func updatePath(_ path: NWPath) {
        self.applyPathState(
            isConnected: path.status == .satisfied,
            isExpensive: path.isExpensive,
            isConstrained: path.isConstrained,
            interfaceType: Self.mapInterfaceType(path)
        )
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
