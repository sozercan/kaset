import Testing
@testable import Kaset

@Suite("Mock YouTube Music client", .serialized, .timeLimit(.minutes(1)))
@MainActor
struct MockYTMusicClientTests {
    @Test("Reset releases suspended history requests")
    func resetReleasesSuspendedHistoryRequests() async {
        let client = MockYTMusicClient()
        client.shouldWaitForGetHistoryResponse = true
        var didComplete = false
        let request = Task { @MainActor in
            _ = try? await client.getHistory()
            didComplete = true
        }

        while client.getHistoryCallCount == 0 {
            await Task.yield()
        }

        client.reset()

        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(1)
        while !didComplete, clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }

        let resetReleasedRequest = didComplete
        if !resetReleasedRequest {
            client.resumeNextGetHistoryResponse()
        }
        await request.value

        #expect(resetReleasedRequest)
    }
}
