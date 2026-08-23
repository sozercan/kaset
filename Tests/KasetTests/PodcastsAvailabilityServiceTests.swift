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
        #expect(service.didResolveFirstProbe == false)
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
        #expect(service.didResolveFirstProbe == true)
    }

    @Test
    func probeWith404MarksUnavailable() async {
        let client = MockYTMusicClient()
        client.shouldThrowError = YTMusicError.apiError(message: "HTTP 404", code: 404)
        let service = PodcastsAvailabilityService()

        let result = await service.probe(for: "primary", using: client)

        #expect(result == .unavailable)
        #expect(service.availability == .unavailable)
        #expect(service.didResolveFirstProbe == true)
    }

    @Test
    func probeWithEmptySectionsLeavesAvailabilityUnchangedButResolvesGate() async {
        let client = MockYTMusicClient()
        client.podcastsSections = []
        let service = PodcastsAvailabilityService()

        let result = await service.probe(for: "primary", using: client)

        // Empty payload from a probe is not authoritative — leave the
        // state alone. The lazy path will confirm via user-initiated
        // load.
        #expect(result == .unknown)
        #expect(service.availability == .unknown)
        // But the gate releases so the UI doesn't hang.
        #expect(service.didResolveFirstProbe == true)
    }

    @Test
    func probeWith500LeavesAvailabilityUnchangedButResolvesGate() async {
        let client = MockYTMusicClient()
        client.shouldThrowError = YTMusicError.apiError(message: "HTTP 500", code: 500)
        let service = PodcastsAvailabilityService()

        let result = await service.probe(for: "primary", using: client)

        #expect(result == .unknown)
        #expect(service.availability == .unknown)
        #expect(service.didResolveFirstProbe == true)
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
        #expect(service.didResolveFirstProbe == true)

        let staleResult = await staleProbe.value
        #expect(staleResult == .available)
        #expect(service.availability == .available)
        #expect(service.didResolveFirstProbe == true)
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
        #expect(service.didResolveFirstProbe == false)

        let result = await probe.value
        #expect(result == .unknown)
        #expect(service.availability == .unknown)
        #expect(service.didResolveFirstProbe == false)
    }

    // MARK: - First-resolution gate

    @Test
    func probeForFirstResolutionFlipsGateOn404() async {
        let client = MockYTMusicClient()
        client.shouldThrowError = YTMusicError.apiError(message: "HTTP 404", code: 404)
        let service = PodcastsAvailabilityService()
        #expect(service.didResolveFirstProbe == false)

        await service.probeForFirstResolution(for: "primary", using: client)

        #expect(service.availability == .unavailable)
        #expect(service.didResolveFirstProbe == true)
    }

    @Test
    func probeForFirstResolutionFlipsGateOnSuccess() async {
        let client = MockYTMusicClient()
        client.podcastsSections = [
            PodcastSection(id: UUID().uuidString, title: "Top", items: []),
        ]
        let service = PodcastsAvailabilityService()

        await service.probeForFirstResolution(for: "primary", using: client)

        #expect(service.availability == .available)
        #expect(service.didResolveFirstProbe == true)
    }

    @Test
    func probeForFirstResolutionFlipsGateOnTimeoutAndProbeKeepsRunning() async {
        // Mock client that doesn't return until well after the timeout
        // and then yields a 404, so we can confirm both that the gate
        // releases via timeout and that the late 404 still demotes the
        // tab when it lands.
        let client = MockYTMusicClient()
        client.getPodcastsDelay = .milliseconds(500)
        client.shouldThrowError = YTMusicError.apiError(message: "HTTP 404", code: 404)
        let service = PodcastsAvailabilityService()

        await service.probeForFirstResolution(
            for: "primary",
            using: client,
            timeout: .milliseconds(50)
        )

        // Gate releases via timeout; state still unknown so sidebar fails open.
        #expect(service.didResolveFirstProbe == true)
        #expect(service.availability == .unknown)

        // The probe is still running in the background — wait for it
        // and confirm the eventual 404 demotes the tab.
        try? await Task.sleep(for: .milliseconds(700))
        #expect(service.availability == .unavailable)
    }

    // MARK: - Lazy signals

    @Test
    func markUnavailableUpdatesStateAndResolvesGate() {
        let service = PodcastsAvailabilityService()

        service.markUnavailable(for: "primary")

        #expect(service.availability == .unavailable)
        #expect(service.didResolveFirstProbe == true)
    }

    @Test
    func markAvailableUpdatesStateAndResolvesGate() {
        let service = PodcastsAvailabilityService()

        service.markAvailable(for: "primary")

        #expect(service.availability == .available)
        #expect(service.didResolveFirstProbe == true)
    }

    // MARK: - Reset

    @Test
    func resetClearsBothAvailabilityAndGate() {
        let service = PodcastsAvailabilityService()
        service.markUnavailable(for: "primary")
        #expect(service.availability == .unavailable)
        #expect(service.didResolveFirstProbe == true)

        service.reset()

        #expect(service.availability == .unknown)
        #expect(service.didResolveFirstProbe == false)
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
