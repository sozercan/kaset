import CoreAudio
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

    @Test("A repeated notification for the fallback output before the pause leaves it route-driven")
    func fallbackNotificationBeforeTheCommandStillQualifies() {
        let events = [self.disappearance(at: 0), self.restoration(at: 20, to: Self.speakers)]

        #expect(self.routeLossIndex(in: events, admittedAt: 60) == 0)
    }

    @Test("Route changes that never removed a device do not qualify")
    func changeWithoutDisappearanceDoesNotQualify() {
        let events = [self.restoration(at: 0)]

        #expect(self.routeLossIndex(in: events, admittedAt: 60) == nil)
    }

    @Test("The lost device coming back after the pause counts as restored")
    func restorationAfterMarkerQualifies() {
        let events = [self.disappearance(at: 0), self.restoration(at: 400)]

        #expect(self.routeRestored(in: events, since: 60))
    }

    @Test("Nothing after the pause is not a restoration")
    func noEventAfterMarkerDoesNotQualify() {
        let events = [self.disappearance(at: 0)]

        #expect(self.routeRestored(in: events, since: 60) == false)
    }

    @Test("A route lost again after coming back is not restored")
    func laterDisappearanceRevokesRestoration() {
        let events = [
            self.disappearance(at: 0),
            self.restoration(at: 400),
            self.disappearance(at: 800),
        ]

        #expect(self.routeRestored(in: events, since: 60) == false)
    }

    @Test("Switching to a different device after the pause is not a restoration")
    func switchToDifferentDeviceDoesNotQualify() {
        let events = [
            self.disappearance(at: 0),
            self.restoration(at: 400, to: Self.usbDevice),
        ]

        #expect(self.routeRestored(in: events, since: 60) == false)
    }

    @Test("A repeated notification for the fallback output is not a restoration")
    func repeatedFallbackNotificationDoesNotQualify() {
        let events = [
            self.disappearance(at: 0),
            self.restoration(at: 200, to: Self.speakers),
        ]

        #expect(self.routeRestored(in: events, since: 60) == false)
    }

    @Test("The lost device becoming the default as the fallback disappears counts as restored")
    func lostDeviceReturningThroughFallbackDisappearanceQualifies() {
        let events = [
            self.disappearance(at: 0),
            RouteChangeEvent(
                at: self.base + .milliseconds(400),
                isDisappearance: true,
                lostDevice: Self.speakers,
                defaultDevice: Self.headphones
            ),
        ]

        #expect(self.routeRestored(in: events, since: 60))
    }

    @Test("Without a known lost device nothing counts as restored")
    func unknownLostDeviceDoesNotQualify() {
        let events = [self.disappearance(at: 0), self.restoration(at: 400)]

        #expect(DefaultOutputDeviceMonitor.routeRestored(
            in: events,
            since: self.base + .milliseconds(60),
            lostDevice: nil
        ) == false)
    }

    @Test("The record resumes only when the device the claimed pause lost comes back")
    func recordRestoresOnlyTheLostDevice() {
        let record = RouteChangeRecord()
        var defaultDevice: AudioDeviceID = 1
        let identities: [AudioDeviceID: String] = [1: Self.headphones, 2: Self.speakers, 3: Self.usbDevice]
        let identity: (AudioDeviceID) -> String = { identities[$0] ?? "unknown" }
        var usable: Set<AudioDeviceID> = [1, 2, 3]
        let change: (Int) -> Void = { milliseconds in
            record.recordChange(
                at: self.base + .milliseconds(milliseconds),
                currentDefaultDeviceID: { defaultDevice },
                isDeviceUsable: { usable.contains($0) },
                deviceIdentity: identity
            )
        }
        record.prime(defaultDeviceID: defaultDevice, deviceIdentity: identity)

        usable.remove(1)
        defaultDevice = 2
        change(0)
        let pauseAt = self.base + .milliseconds(60)
        #expect(record.claimRouteLoss(admittedAt: pauseAt, within: self.window))
        #expect(record.routeRestored(since: pauseAt) == false)

        change(200)
        #expect(record.routeRestored(since: pauseAt) == false)

        defaultDevice = 3
        change(400)
        #expect(record.routeRestored(since: pauseAt) == false)

        usable.insert(1)
        defaultDevice = 1
        change(800)
        #expect(record.routeRestored(since: pauseAt))
    }

    @Test("The record does not resume a pause it never attributed to a route loss")
    func recordIgnoresUnclaimedInstant() {
        let record = RouteChangeRecord()
        var defaultDevice: AudioDeviceID = 1
        let identity: (AudioDeviceID) -> String = { "uid:\($0)" }
        var usable: Set<AudioDeviceID> = [1, 2]
        let change: (Int) -> Void = { milliseconds in
            record.recordChange(
                at: self.base + .milliseconds(milliseconds),
                currentDefaultDeviceID: { defaultDevice },
                isDeviceUsable: { usable.contains($0) },
                deviceIdentity: identity
            )
        }
        record.prime(defaultDeviceID: defaultDevice, deviceIdentity: identity)

        usable.remove(1)
        defaultDevice = 2
        change(0)
        usable.insert(1)
        defaultDevice = 1
        change(400)

        #expect(record.routeRestored(since: self.base + .milliseconds(60)) == false)
    }

    private static let headphones = "uid:headphones"
    private static let speakers = "uid:speakers"
    private static let usbDevice = "uid:usb"

    private func disappearance(at milliseconds: Int) -> RouteChangeEvent {
        RouteChangeEvent(
            at: self.base + .milliseconds(milliseconds),
            isDisappearance: true,
            lostDevice: Self.headphones,
            defaultDevice: Self.speakers
        )
    }

    private func restoration(at milliseconds: Int, to device: String = Self.headphones) -> RouteChangeEvent {
        RouteChangeEvent(
            at: self.base + .milliseconds(milliseconds),
            isDisappearance: false,
            defaultDevice: device
        )
    }

    private func routeRestored(in events: [RouteChangeEvent], since milliseconds: Int) -> Bool {
        DefaultOutputDeviceMonitor.routeRestored(
            in: events,
            since: self.base + .milliseconds(milliseconds),
            lostDevice: Self.headphones
        )
    }

    private func routeLossIndex(in events: [RouteChangeEvent], admittedAt milliseconds: Int) -> Int? {
        DefaultOutputDeviceMonitor.routeLossIndex(
            in: events,
            admittedAt: self.base + .milliseconds(milliseconds),
            within: self.window
        )
    }
}
