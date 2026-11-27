import Foundation
import Testing
@testable import Kaset

@Suite("Route disappearance classification", .tags(.service))
struct RouteDisappearanceClassificationTests {
    private let window = Duration.milliseconds(1500)
    private let base = ContinuousClock.now

    @Test("A pause admitted just after the output device vanished is route-driven")
    func pauseFollowingDisappearanceQualifies() {
        let events = [self.disappearance(at: 0)]

        #expect(self.routeLossIndex(in: events, admittedAt: 60) == 0)
    }

    @Test("A pause admitted before the device vanished is the user's")
    func pausePrecedingDisappearanceDoesNotQualify() {
        let events = [self.disappearance(at: 100)]

        #expect(self.routeLossIndex(in: events, admittedAt: 90) == nil)
    }

    @Test("A pause admitted long after the device vanished is the user's")
    func pauseOutsideWindowDoesNotQualify() {
        let events = [self.disappearance(at: 0)]

        #expect(self.routeLossIndex(in: events, admittedAt: 1600) == nil)
    }

    @Test("Output restored before the pause makes it the user's")
    func restorationBeforeTheCommandDoesNotQualify() {
        let events = [self.disappearance(at: 0), self.restoration(at: 200)]

        #expect(self.routeLossIndex(in: events, admittedAt: 250) == nil)
    }

    @Test("Output restored after the pause still leaves it route-driven")
    func restorationAfterTheCommandStillQualifies() {
        let events = [self.disappearance(at: 0), self.restoration(at: 160)]

        #expect(self.routeLossIndex(in: events, admittedAt: 60) == 0)
    }

    @Test("A later disconnect does not hide the one that explains a queued pause")
    func newerDisappearanceDoesNotShadowTheRelevantOne() {
        let events = [
            self.disappearance(at: 0),
            self.restoration(at: 400),
            self.disappearance(at: 800),
        ]

        #expect(self.routeLossIndex(in: events, admittedAt: 60) == 0)
    }

    @Test("A disappearance already claimed cannot explain a second pause")
    func consumedDisappearanceDoesNotQualify() {
        var events = [self.disappearance(at: 0)]
        events[0].isConsumed = true

        #expect(self.routeLossIndex(in: events, admittedAt: 60) == nil)
    }

    @Test("A claimed newer disappearance does not fall back to an older one")
    func consumedNewerDisappearanceDoesNotFallBack() {
        var events = [
            self.disappearance(at: 0),
            self.disappearance(at: 800),
        ]
        let systemPause = self.routeLossIndex(in: events, admittedAt: 860)
        #expect(systemPause == 1)
        if let systemPause {
            events[systemPause].isConsumed = true
        }

        #expect(self.routeLossIndex(in: events, admittedAt: 950) == nil)
    }

    @Test("Route changes that never removed a device do not qualify")
    func changeWithoutDisappearanceDoesNotQualify() {
        let events = [self.restoration(at: 0)]

        #expect(self.routeLossIndex(in: events, admittedAt: 60) == nil)
    }

    @Test("Output coming back after the pause counts as restored")
    func restorationAfterMarkerQualifies() {
        let events = [self.disappearance(at: 0), self.restoration(at: 400)]

        #expect(DefaultOutputDeviceMonitor.routeRestored(in: events, since: self.base + .milliseconds(60)))
    }

    @Test("Nothing after the pause is not a restoration")
    func noEventAfterMarkerDoesNotQualify() {
        let events = [self.disappearance(at: 0)]

        #expect(DefaultOutputDeviceMonitor.routeRestored(
            in: events,
            since: self.base + .milliseconds(60)
        ) == false)
    }

    @Test("A route lost again after coming back is not restored")
    func laterDisappearanceRevokesRestoration() {
        let events = [
            self.disappearance(at: 0),
            self.restoration(at: 400),
            self.disappearance(at: 800),
        ]

        #expect(DefaultOutputDeviceMonitor.routeRestored(
            in: events,
            since: self.base + .milliseconds(60)
        ) == false)
    }

    private func disappearance(at milliseconds: Int) -> RouteChangeEvent {
        RouteChangeEvent(at: self.base + .milliseconds(milliseconds), isDisappearance: true)
    }

    private func restoration(at milliseconds: Int) -> RouteChangeEvent {
        RouteChangeEvent(at: self.base + .milliseconds(milliseconds), isDisappearance: false)
    }

    private func routeLossIndex(in events: [RouteChangeEvent], admittedAt milliseconds: Int) -> Int? {
        DefaultOutputDeviceMonitor.routeLossIndex(
            in: events,
            admittedAt: self.base + .milliseconds(milliseconds),
            within: self.window
        )
    }
}
