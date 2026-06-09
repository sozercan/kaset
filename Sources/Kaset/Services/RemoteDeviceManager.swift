import Foundation
import Observation

struct RemoteDevice: Codable, Identifiable, Hashable {
    var id: String { self.deviceId }
    let deviceId: String
    let name: String
    let token: String
    let approvedAt: Date
    var lastActive: Date
}

struct PendingApproval: Codable, Identifiable, Hashable {
    var id: String { self.deviceId }
    let deviceId: String
    let name: String
    let requestedAt: Date
}

@Observable
@MainActor
final class RemoteDeviceManager {
    static let shared = RemoteDeviceManager()

    private enum Keys {
        static let approvedDevices = "kaset.remote.approvedDevices"
        static let pendingRequests = "kaset.remote.pendingRequests"
        static let globalPin = "kaset.remote.globalPin"
    }

    var approvedDevices: [RemoteDevice] = [] {
        didSet { self.saveApprovedDevices() }
    }

    var pendingRequests: [PendingApproval] = [] {
        didSet { self.savePendingRequests() }
    }

    var globalPin: String = "" {
        didSet {
            UserDefaults.standard.set(self.globalPin, forKey: Keys.globalPin)
        }
    }

    private init() {
        self.globalPin = UserDefaults.standard.string(forKey: Keys.globalPin) ?? Self.generateRandomPin()
        self.loadApprovedDevices()
        self.loadPendingRequests()
    }

    func requestApproval(deviceId: String, deviceName: String, pin: String) -> Bool {
        guard pin == self.globalPin else { return false }
        if self.approvedDevices.contains(where: { $0.deviceId == deviceId }) { return true }
        if !self.pendingRequests.contains(where: { $0.deviceId == deviceId }) {
            self.pendingRequests.append(PendingApproval(
                deviceId: deviceId,
                name: deviceName,
                requestedAt: Date()
            ))
        }
        return true
    }

    func approveDevice(deviceId: String) {
        guard let pending = self.pendingRequests.first(where: { $0.deviceId == deviceId }) else { return }
        self.pendingRequests.removeAll(where: { $0.deviceId == deviceId })
        self.approvedDevices.append(RemoteDevice(
            deviceId: deviceId,
            name: pending.name,
            token: UUID().uuidString.lowercased(),
            approvedAt: Date(),
            lastActive: Date()
        ))
    }

    func denyDevice(deviceId: String) {
        self.pendingRequests.removeAll(where: { $0.deviceId == deviceId })
    }

    func revokeDevice(deviceId: String) {
        self.approvedDevices.removeAll(where: { $0.deviceId == deviceId })
    }

    func isDeviceApproved(deviceId: String) -> Bool {
        self.approvedDevices.contains(where: { $0.deviceId == deviceId })
    }

    func deviceToken(deviceId: String) -> String {
        self.approvedDevices.first(where: { $0.deviceId == deviceId })?.token ?? ""
    }

    func updateDeviceActivity(deviceId: String) {
        if let idx = self.approvedDevices.firstIndex(where: { $0.deviceId == deviceId }) {
            var device = self.approvedDevices[idx]
            device.lastActive = Date()
            self.approvedDevices[idx] = device
        }
    }

    func clearAll() {
        self.approvedDevices = []
        self.pendingRequests = []
        self.globalPin = Self.generateRandomPin()
    }

    private static func generateRandomPin() -> String {
        String((0..<4).map { _ in "0123456789".randomElement()! })
    }

    private func saveApprovedDevices() {
        if let data = try? JSONEncoder().encode(self.approvedDevices) {
            UserDefaults.standard.set(data, forKey: Keys.approvedDevices)
        }
    }

    private func loadApprovedDevices() {
        if let data = UserDefaults.standard.data(forKey: Keys.approvedDevices),
           let devices = try? JSONDecoder().decode([RemoteDevice].self, from: data) {
            self.approvedDevices = devices
        }
    }

    private func savePendingRequests() {
        if let data = try? JSONEncoder().encode(self.pendingRequests) {
            UserDefaults.standard.set(data, forKey: Keys.pendingRequests)
        }
    }

    private func loadPendingRequests() {
        if let data = UserDefaults.standard.data(forKey: Keys.pendingRequests),
           let pending = try? JSONDecoder().decode([PendingApproval].self, from: data) {
            self.pendingRequests = pending
        }
    }
}
