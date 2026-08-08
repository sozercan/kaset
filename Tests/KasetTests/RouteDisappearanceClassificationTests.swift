import Foundation
import Testing
@testable import Kaset

/// A vanished audio route and a user pressing Pause arrive as the same remote command, so the
/// only thing separating them is a device disappearing just before the command was admitted.
///
/// Classification runs after an unbounded hop to the MainActor, so every case here is expressed
/// in terms of the instant the command was *admitted* — never the instant it is judged, and
/// never assuming the route stood still in between.
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
        // The command was already in flight when the route dropped, so the route cannot be
        // what prompted it.
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
        // Disconnect then reconnect quickly: there was somewhere to play by the time the
        // command arrived, so pausing then was deliberate.
        let events = [self.disappearance(at: 0), self.restoration(at: 200)]

        #expect(self.routeLossIndex(in: events, admittedAt: 250) == nil)
    }

    @Test("Output restored after the pause still leaves it route-driven")
    func restorationAfterTheCommandStillQualifies() {
        // The reconnect landed while the command was still queued for the MainActor. Judging by
        // the latest route state would misread this as a user pause and disable recovery.
        let events = [self.disappearance(at: 0), self.restoration(at: 160)]

        #expect(self.routeLossIndex(in: events, admittedAt: 60) == 0)
    }

    @Test("A later disconnect does not hide the one that explains a queued pause")
    func newerDisappearanceDoesNotShadowTheRelevantOne() {
        // Flapping Bluetooth can complete a whole disconnect/reconnect/disconnect cycle before
        // the first pause is drained. Keeping only the newest events would leave nothing that
        // predates the command, and a genuine route pause would read as the user's.
        let events = [
            self.disappearance(at: 0),
            self.restoration(at: 400),
            self.disappearance(at: 800),
        ]

        #expect(self.routeLossIndex(in: events, admittedAt: 60) == 0)
    }

    @Test("A disappearance already claimed cannot explain a second pause")
    func consumedDisappearanceDoesNotQualify() {
        // The system's own route-loss pause claims the disconnect. A user pause moments later
        // must keep its own meaning, or a future reconnect would resume against it.
        var events = [self.disappearance(at: 0)]
        events[0].isConsumed = true

        #expect(self.routeLossIndex(in: events, admittedAt: 60) == nil)
    }

    @Test("Route changes that never removed a device do not qualify")
    func changeWithoutDisappearanceDoesNotQualify() {
        // Plugging in a new output or switching by hand changes the default device without
        // taking one away.
        let events = [self.restoration(at: 0)]

        #expect(self.routeLossIndex(in: events, admittedAt: 60) == nil)
    }

    // MARK: - Route restoration

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
        // Flapping Bluetooth: reconnect then drop again before the delayed retry runs. Treating
        // any later event as a restoration would resume onto an output that is gone, and with
        // playback already paused there may be no second pause command to re-arm recovery.
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

    // MARK: - Helpers

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
