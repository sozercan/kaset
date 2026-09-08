import Foundation
import Testing
@testable import Kaset

struct WebPlaybackNavigationMapTests {
    @Test("Expired cancellation cannot reject a new document navigation")
    func expiredCancellationDoesNotBlockReplacement() throws {
        var cancellations = WebPlaybackNavigationMap<NSObject, WebPlaybackCancelledNavigation>()
        weak var expiredNavigation: NSObject?
        do {
            let preload = NSObject()
            expiredNavigation = preload
            cancellations[preload] = WebPlaybackCancelledNavigation(generation: 1, shouldReportFailure: false)
        }

        #expect(expiredNavigation == nil)
        #expect(cancellations.values.isEmpty)

        let replacement = NSObject()
        #expect(cancellations[replacement] == nil)
        #expect(SingletonPlayerWebView.acceptsDocumentNavigationStart(
            isCancelled: cancellations[replacement] != nil,
            trackedGeneration: nil,
            candidateGeneration: 2,
            inFlightGeneration: 2,
            hasPendingGeneration: false
        ))

        var tracked = WebPlaybackNavigationMap<NSObject, WebPlaybackTrackedNavigation>()
        tracked[replacement] = WebPlaybackTrackedNavigation(generation: 2)
        tracked[replacement]?.didCommit = true
        let removed = tracked.removeValue(forKey: replacement)
        let finished = try #require(removed)
        #expect(finished.generation == 2)
        #expect(finished.didCommit)
    }

    @Test("Live cancelled navigation keeps ownership across a replacement")
    func lateCancelledCallbackStillRejected() {
        var cancellations = WebPlaybackNavigationMap<NSObject, WebPlaybackCancelledNavigation>()
        let cancelled = NSObject()
        let replacement = NSObject()
        cancellations[cancelled] = WebPlaybackCancelledNavigation(generation: 1, shouldReportFailure: true)
        cancellations[replacement] = WebPlaybackCancelledNavigation(generation: 2, shouldReportFailure: false)

        #expect(!SingletonPlayerWebView.acceptsDocumentNavigationStart(
            isCancelled: cancellations[cancelled] != nil,
            trackedGeneration: nil,
            candidateGeneration: 2,
            inFlightGeneration: 2,
            hasPendingGeneration: false
        ))
        let finishedCancellation = cancellations.removeValue(forKey: cancelled)
        #expect(finishedCancellation?.shouldReportFailure == true)
        #expect(cancellations[replacement]?.generation == 2)
        #expect(cancellations[cancelled] == nil)
    }

    @Test("Filtering and cancellation preserve only live navigation ownership")
    func cancellationTransfersLiveRecords() {
        var tracked = WebPlaybackNavigationMap<NSObject, WebPlaybackTrackedNavigation>()
        var cancellations = WebPlaybackNavigationMap<NSObject, WebPlaybackCancelledNavigation>()
        let old = NSObject()
        let current = NSObject()
        tracked[old] = WebPlaybackTrackedNavigation(generation: 1)
        tracked[current] = WebPlaybackTrackedNavigation(generation: 2)
        do {
            let expired = NSObject()
            tracked[expired] = WebPlaybackTrackedNavigation(generation: 1)
        }

        for (navigation, state) in tracked where state.generation == 1 {
            cancellations[navigation] = WebPlaybackCancelledNavigation(
                generation: state.generation,
                shouldReportFailure: false
            )
        }
        tracked = tracked.filter { $0.value.generation != 1 }

        #expect(cancellations.values.map(\.generation) == [1])
        #expect(cancellations[old]?.generation == 1)
        #expect(tracked.values.map(\.generation) == [2])
        #expect(tracked[current]?.generation == 2)
        cancellations.removeAll()
        #expect(cancellations[old] == nil)
    }

    @Test("New records release state belonging to deallocated navigations")
    func expiredRecordsArePrunedOnInsertion() {
        var records = WebPlaybackNavigationMap<NSObject, NSObject>()
        weak var expiredState: NSObject?
        do {
            let navigation = NSObject()
            let state = NSObject()
            expiredState = state
            records[navigation] = state
        }

        let current = NSObject()
        records[current] = NSObject()

        #expect(expiredState == nil)
        #expect(records.count == 1)
        #expect(records[current] != nil)
    }
}
