import Foundation
import Testing
@testable import Kaset

// MARK: - PodcastsAvailabilityServiceTests

@Suite(.serialized, .tags(.service))
@MainActor
struct PodcastsAvailabilityServiceTests {
    // MARK: - Initial state

    @Test
    func initialAvailabilityIsUnknown() {
        let service = PodcastsAvailabilityService()
        #expect(service.availability == .unknown)
    }

    // MARK: - Probe outcomes

    @Test
    func probeWithNonEmptySectionsMarksAvailable() async {
        let client = MockYTMusicClient()
        client.podcastsSections = [
            PodcastSection(id: UUID().uuidString, title: "Top Shows", items: []),
        ]
        let service = PodcastsAvailabilityService()

        let result = await service.probe(for: "primary", using: client)

        #expect(result == .available)
        #expect(service.availability == .available)
    }

    @Test
    func probeWith404MarksUnavailable() async {
        let client = MockYTMusicClient()
        client.shouldThrowError = YTMusicError.apiError(message: "HTTP 404", code: 404)
        let service = PodcastsAvailabilityService()

        let result = await service.probe(for: "primary", using: client)

        #expect(result == .unavailable)
        #expect(service.availability == .unavailable)
    }

    @Test
    func probeWithEmptySectionsLeavesAvailabilityUnchanged() async {
        let client = MockYTMusicClient()
        client.podcastsSections = []
        let service = PodcastsAvailabilityService()

        let result = await service.probe(for: "primary", using: client)

        // Empty payload from a probe is not authoritative — leave the
        // state alone. The lazy path will confirm via user-initiated
        // load.
        #expect(result == .unknown)
        #expect(service.availability == .unknown)
    }

    @Test
    func probeWith500LeavesAvailabilityUnchanged() async {
        let client = MockYTMusicClient()
        client.shouldThrowError = YTMusicError.apiError(message: "HTTP 500", code: 500)
        let service = PodcastsAvailabilityService()

        let result = await service.probe(for: "primary", using: client)

        #expect(result == .unknown)
        #expect(service.availability == .unknown)
    }

    @Test
    func probeWithNetworkErrorLeavesKnownGoodStateAlone() async {
        let client = MockYTMusicClient()
        client.shouldThrowError = YTMusicError.networkError(underlying: URLError(.timedOut))
        let service = PodcastsAvailabilityService()
        service.markAvailable(for: "primary")

        let result = await service.probe(for: "primary", using: client)

        // Transient failures must not flip a known-good state.
        #expect(result == .available)
        #expect(service.availability == .available)
    }

    // MARK: - Account/session invalidation

    @Test
    func late404ProbeDoesNotOverrideNewerAccountAvailability() async {
        let service = PodcastsAvailabilityService()

        let staleClient = MockYTMusicClient()
        staleClient.getPodcastsDelay = .milliseconds(150)
        staleClient.shouldThrowError = YTMusicError.apiError(message: "HTTP 404", code: 404)
        let staleProbeStarted = AsyncSignal()
        staleClient.onGetPodcasts = { staleProbeStarted.signal() }

        let staleProbe = Task { @MainActor in
            await service.probe(for: "account-a", using: staleClient)
        }
        await staleProbeStarted.wait()

        let currentClient = MockYTMusicClient()
        currentClient.podcastsSections = [
            PodcastSection(id: UUID().uuidString, title: "Available Shows", items: []),
        ]

        let currentResult = await service.probe(for: "account-b", using: currentClient)
        #expect(currentResult == .available)
        #expect(service.availability == .available)

        let staleResult = await staleProbe.value
        #expect(staleResult == .available)
        #expect(service.availability == .available)
    }

    @Test
    func resetInvalidatesLateProbeCompletion() async {
        let service = PodcastsAvailabilityService()
        let client = MockYTMusicClient()
        client.getPodcastsDelay = .milliseconds(150)
        client.shouldThrowError = YTMusicError.apiError(message: "HTTP 404", code: 404)
        let probeStarted = AsyncSignal()
        client.onGetPodcasts = { probeStarted.signal() }

        let probe = Task { @MainActor in
            await service.probe(for: "primary", using: client)
        }
        await probeStarted.wait()

        service.reset()
        #expect(service.availability == .unknown)

        let result = await probe.value
        #expect(result == .unknown)
        #expect(service.availability == .unknown)
    }

    // MARK: - Lazy signals

    @Test
    func markUnavailableUpdatesState() {
        let service = PodcastsAvailabilityService()

        service.markUnavailable(for: "primary")

        #expect(service.availability == .unavailable)
    }

    @Test
    func markAvailableUpdatesState() {
        let service = PodcastsAvailabilityService()

        service.markAvailable(for: "primary")

        #expect(service.availability == .available)
    }

    // MARK: - Reset

    @Test
    func resetClearsAvailability() {
        let service = PodcastsAvailabilityService()
        service.markUnavailable(for: "primary")
        #expect(service.availability == .unavailable)

        service.reset()

        #expect(service.availability == .unknown)
    }
}

// MARK: - AsyncSignal

@MainActor
private final class AsyncSignal {
    private var isSignalled = false
    private var continuation: CheckedContinuation<Void, Never>?

    func signal() {
        guard !self.isSignalled else { return }
        self.isSignalled = true
        self.continuation?.resume()
        self.continuation = nil
    }

    func wait() async {
        if self.isSignalled {
            return
        }

        await withCheckedContinuation { continuation in
            if self.isSignalled {
                continuation.resume()
            } else {
                self.continuation = continuation
            }
        }
    }
}
