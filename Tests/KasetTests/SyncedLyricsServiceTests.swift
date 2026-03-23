import Testing
@testable import Kaset

@Suite("SyncedLyricsService")
final class SyncedLyricsServiceTests {
    
    @Test("Service initializes without error")
    func testServiceInitialization() {
        let service = SyncedLyricsService.shared
        #expect(service != nil)
    }
}

