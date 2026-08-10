import Testing
@testable import Kaset

@MainActor
struct NowPlayingBroadcasterTests {
    /// `notificationName` is a published cross-process contract: external now-playing
    /// surfaces (e.g. the boring.notch "Kaset" media source) listen for this exact
    /// string. Pin it so an accidental rename fails CI here instead of silently
    /// breaking those integrations.
    @Test("Broadcaster notification name matches the published contract")
    func notificationNameIsStableContract() {
        #expect(NowPlayingBroadcaster.notificationName == "com.sertacozercan.Kaset.playerInfo")
    }
}
