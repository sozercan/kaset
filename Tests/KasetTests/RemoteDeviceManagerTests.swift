import Testing
import Foundation
@testable import Kaset

@Suite(.serialized)
@MainActor
struct RemoteDeviceManagerTests {
    @Test("Manages device approval flow and persists correctly")
    func managesDeviceFlow() {
        let manager = RemoteDeviceManager.shared
        manager.clearAll()
        manager.globalPin = "4321"

        // Verify request with wrong PIN
        #expect(!manager.requestApproval(deviceId: "dev-1", deviceName: "Test Phone", pin: "0000"))
        #expect(manager.pendingRequests.isEmpty)

        // Verify request with correct PIN
        #expect(manager.requestApproval(deviceId: "dev-1", deviceName: "Test Phone", pin: "4321"))
        #expect(manager.pendingRequests.count == 1)
        #expect(!manager.isDeviceApproved(deviceId: "dev-1"))

        // Approve device
        manager.approveDevice(deviceId: "dev-1")
        #expect(manager.pendingRequests.isEmpty)
        #expect(manager.isDeviceApproved(deviceId: "dev-1"))
        #expect(!manager.deviceToken(deviceId: "dev-1").isEmpty)

        // Revoke device
        manager.revokeDevice(deviceId: "dev-1")
        #expect(!manager.isDeviceApproved(deviceId: "dev-1"))
    }
}
