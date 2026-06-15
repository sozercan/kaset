import Foundation
import Testing
@testable import Kaset

@Suite(.serialized)
@MainActor
struct RemoteDeviceManagerTests {
    @Test("Manages device approval flow and persists correctly")
    func managesDeviceFlow() {
        let manager = RemoteDeviceManager.shared
        manager.clearAll()
        manager.globalPin = "4321"

        // Verify request with wrong PIN fails direct login
        #expect(manager.verifyPinAndApprove(deviceId: "dev-1", deviceName: "Test Phone", pin: "0000") == nil)
        #expect(manager.pendingRequests.isEmpty)
        #expect(!manager.isDeviceApproved(deviceId: "dev-1"))

        // Verify request with correct PIN directly logs in and approves
        let token = manager.verifyPinAndApprove(deviceId: "dev-1", deviceName: "Test Phone", pin: "4321")
        #expect(token != nil)
        #expect(manager.isDeviceApproved(deviceId: "dev-1"))
        #expect(manager.deviceToken(deviceId: "dev-1") == token)
        #expect(manager.pendingRequests.isEmpty)

        // Revoke device
        manager.revokeDevice(deviceId: "dev-1")
        #expect(!manager.isDeviceApproved(deviceId: "dev-1"))

        // Verify request approval queueing (no PIN)
        manager.requestApproval(deviceId: "dev-2", deviceName: "Test Phone 2")
        #expect(manager.pendingRequests.count == 1)
        #expect(!manager.isDeviceApproved(deviceId: "dev-2"))

        // Approve device
        manager.approveDevice(deviceId: "dev-2")
        #expect(manager.pendingRequests.isEmpty)
        #expect(manager.isDeviceApproved(deviceId: "dev-2"))
        #expect(!manager.deviceToken(deviceId: "dev-2").isEmpty)
    }
}
