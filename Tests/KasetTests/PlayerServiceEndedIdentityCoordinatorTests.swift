import Foundation
import JavaScriptCore
import Testing
@testable import Kaset

extension PlayerServiceWebQueueSyncTests {
    @Test(
        "An uncertain ended event leaves its occurrence available for the resolved retry",
        arguments: [false, true]
    )
    func uncertainEndedRetryContinuesPendingHandoff(repairThroughPolling: Bool) async throws {
        try await self.withEndedIdentityCoordinator { coordinator, context, documentGeneration in
            let pendingGeneration = self.playerService.pendingNativeQueueAdvanceGeneration
            let uncertain = try Self.endedIdentityPayload(in: context)
            #expect((uncertain["videoId"] as? String)?.isEmpty == true)
            #expect(uncertain["mediaIdentityUncertain"] as? Bool == true)
            let occurrence = try MusicPlaybackOccurrence.web(
                documentGeneration: documentGeneration,
                mediaGeneration: #require(WebPlaybackDocumentGeneration.decode(uncertain["mediaGeneration"])),
                nativeGeneration: #require(WebPlaybackDocumentGeneration.decode(uncertain["nativePlaybackGeneration"]))
            )
            #expect(self.playerService.acceptsWebMusicPlaybackOccurrence(occurrence))

            coordinator.enqueueTrackEndedForTesting(body: uncertain, documentGeneration: documentGeneration)
            await coordinator.awaitPlaybackBridgeDrainForTesting()

            #expect(self.playerService.currentIndex == 0)
            #expect(self.playerService.pendingNativeQueueAdvanceVideoId == "v2")
            #expect(self.playerService.acceptsWebMusicPlaybackOccurrence(occurrence))

            context.evaluateScript(
                """
                currentDataVideoId = 'v2';
                titleElement.textContent = 'v2';
                dispatch('\(repairThroughPolling ? "waiting" : "canplay")');
                var resolvedRetryRan = runTimeout(16);
                """
            )
            #expect(context.evaluateScript("resolvedRetryRan").toBool() == true)
            let resolved = try Self.endedIdentityPayload(in: context)
            #expect(resolved["videoId"] as? String == "v2")
            #expect(resolved["mediaIdentityUncertain"] as? Bool == false)
            #expect(resolved["observerEpoch"] as? NSNumber == uncertain["observerEpoch"] as? NSNumber)
            #expect(resolved["mediaGeneration"] as? NSNumber == uncertain["mediaGeneration"] as? NSNumber)

            coordinator.enqueueTrackEndedForTesting(body: resolved, documentGeneration: documentGeneration)
            coordinator.enqueueTrackEndedForTesting(body: resolved, documentGeneration: documentGeneration)
            await coordinator.awaitPlaybackBridgeDrainForTesting()

            #expect(self.playerService.currentIndex == 2)
            #expect(self.playerService.currentTrack?.videoId == "v3")
            #expect(self.playerService.pendingNativeQueueAdvanceVideoId == nil)
            #expect(!self.playerService.acceptsWebMusicPlaybackOccurrence(occurrence))
            let navigationGeneration = self.playerService.playbackNavigationGeneration
            await self.playerService.handleNativeQueueAdvanceTimeout(generation: pendingGeneration)
            #expect(self.playerService.currentTrack?.videoId == "v3")
            #expect(self.playerService.playbackNavigationGeneration == navigationGeneration)
        }
    }

    @Test("The same-generation identity deadline resolves a pending handoff once")
    func uncertainEndedDeadlineResolvesPendingHandoff() async throws {
        try await self.withEndedIdentityCoordinator { coordinator, context, documentGeneration in
            let pendingGeneration = self.playerService.pendingNativeQueueAdvanceGeneration
            let uncertain = try Self.endedIdentityPayload(in: context)
            coordinator.enqueueTrackEndedForTesting(body: uncertain, documentGeneration: documentGeneration)
            await coordinator.awaitPlaybackBridgeDrainForTesting()
            #expect(self.playerService.currentIndex == 0)
            #expect(self.playerService.pendingNativeQueueAdvanceVideoId == "v2")

            context.evaluateScript(
                """
                var retryIndex = scheduledTimeouts.findIndex(function(timeout) { return timeout.delay === 16; });
                var deadlineRetry = scheduledTimeouts.splice(retryIndex, 1)[0];
                fakeNow = 5001;
                deadlineRetry.callback();
                """
            )
            let deadline = try Self.endedIdentityPayload(in: context, type: "TRACK_ENDED_IDENTITY_DEADLINE")
            #expect((deadline["videoId"] as? String)?.isEmpty == true)
            #expect(deadline["mediaIdentityUncertain"] as? Bool == true)
            #expect(deadline["observerEpoch"] as? NSNumber == uncertain["observerEpoch"] as? NSNumber)
            #expect(deadline["mediaGeneration"] as? NSNumber == uncertain["mediaGeneration"] as? NSNumber)
            coordinator.enqueueTrackEndedForTesting(body: deadline, documentGeneration: documentGeneration)
            coordinator.enqueueTrackEndedForTesting(body: deadline, documentGeneration: documentGeneration)
            await coordinator.awaitPlaybackBridgeDrainForTesting()

            #expect(self.playerService.currentIndex == 1)
            #expect(self.playerService.currentTrack?.videoId == "v2")
            #expect(self.playerService.pendingNativeQueueAdvanceVideoId == nil)
            #expect(self.playerService.state == .loading)
            let navigationGeneration = self.playerService.playbackNavigationGeneration
            await self.playerService.handleNativeQueueAdvanceTimeout(generation: pendingGeneration)
            #expect(self.playerService.playbackNavigationGeneration == navigationGeneration)
        }
    }

    @Test("Legacy ended events without the uncertainty flag retain fallback behavior", arguments: [false, true])
    func legacyEndedWithoutUncertaintyFlagStillAdvances(hasVideoId: Bool) async throws {
        try await self.withEndedIdentityCoordinator(preparePendingHandoff: false) { coordinator, context, documentGeneration in
            context.evaluateScript(
                """
                video.currentTime = 180;
                video.paused = true;
                video.ended = true;
                dispatch('ended');
                """
            )
            var legacy = try Self.endedIdentityPayload(in: context)
            legacy.removeValue(forKey: "mediaIdentityUncertain")
            if !hasVideoId {
                legacy.removeValue(forKey: "videoId")
            }
            coordinator.enqueueTrackEndedForTesting(body: legacy, documentGeneration: documentGeneration)
            coordinator.enqueueTrackEndedForTesting(body: legacy, documentGeneration: documentGeneration)
            await coordinator.awaitPlaybackBridgeDrainForTesting()

            #expect(self.playerService.currentIndex == 1)
            #expect(self.playerService.currentTrack?.videoId == "v2")
            #expect(self.playerService.pendingNativeQueueAdvanceVideoId == nil)
        }
    }

    private func withEndedIdentityCoordinator(
        preparePendingHandoff: Bool = true,
        _ operation: @MainActor (
            SingletonPlayerWebView.Coordinator,
            JSContext,
            UInt64
        ) async throws -> Void
    ) async throws {
        let songs = [
            Song(id: "1", title: "Song 1", artists: [], duration: 180, videoId: "v1"),
            Song(id: "2", title: "Song 2", artists: [], duration: 1, videoId: "v2"),
            Song(id: "3", title: "Song 3", artists: [], duration: 220, videoId: "v3"),
        ]
        await self.playerService.playQueue(songs, startingAt: 0)
        self.playerService.state = .playing
        let singleton = SingletonPlayerWebView.shared
        let previousCoordinator = singleton.coordinator
        let previousWebVideoId = singleton.currentVideoId
        let coordinator = SingletonPlayerWebView.Coordinator(playerService: self.playerService)
        singleton.coordinator = coordinator
        singleton.currentVideoId = "v1"
        defer {
            coordinator.cancelPlaybackBridgeTasks()
            self.playerService.clearPendingNativeQueueAdvance()
            self.playerService.clearQueueNavigationRecovery()
            if singleton.coordinator === coordinator {
                singleton.coordinator = previousCoordinator
            }
            singleton.currentVideoId = previousWebVideoId
        }

        let documentGeneration = singleton.documentGeneration.currentGeneration
        let nativeGeneration = self.playerService.currentNativeMusicPlaybackGeneration
        let context = try MusicPlaybackObserverTestContext.make()
        context.evaluateScript(
            """
            window.__kasetDocumentGeneration = \(documentGeneration);
            window.__kasetNativePlaybackGeneration = \(nativeGeneration);
            messages = [];
            video.currentTime = 30;
            dispatch('waiting');
            """
        )
        let sourceState = try #require(context.evaluateScript(
            "messages.filter(function(message) { return message.type === 'STATE_UPDATE'; }).slice(-1)[0]"
        ).toDictionary() as? [String: Any])
        coordinator.enqueueStateUpdateForTesting(
            body: sourceState,
            observedVideoId: "v1",
            documentGeneration: documentGeneration
        )
        await coordinator.awaitPlaybackBridgeDrainForTesting()
        #expect(self.playerService.currentMusicPlaybackOccurrence?.documentGeneration == documentGeneration)
        guard preparePendingHandoff else {
            try await operation(coordinator, context, documentGeneration)
            return
        }
        self.playerService.injectedWebQueueVideoId = "v2"
        context.evaluateScript(
            """
            messages = [];
            video.currentTime = 180;
            video.paused = true;
            video.ended = true;
            dispatch('ended');
            """
        )
        let sourceEnded = try Self.endedIdentityPayload(in: context)
        coordinator.enqueueTrackEndedForTesting(body: sourceEnded, documentGeneration: documentGeneration)
        await coordinator.awaitPlaybackBridgeDrainForTesting()
        try #require(self.playerService.pendingNativeQueueAdvanceVideoId == "v2")

        context.evaluateScript(
            """
            messages = [];
            scheduledTimeouts = [];
            currentDataVideoId = '';
            window.location.href = 'https://music.youtube.com/';
            video.currentSrc = 'https://media.example/v2';
            video.currentTime = 0;
            video.duration = 1;
            video.paused = false;
            video.ended = false;
            dispatch('loadedmetadata');
            video.currentTime = 1;
            video.paused = true;
            video.ended = true;
            dispatch('ended');
            """
        )
        try #require(context.exception == nil)
        try await operation(coordinator, context, documentGeneration)
    }

    private static func endedIdentityPayload(in context: JSContext, type: String = "TRACK_ENDED") throws -> [String: Any] {
        let payload = context.evaluateScript(
            "messages.filter(function(message) { return message.type === '\(type)'; }).slice(-1)[0]"
        )
        try #require(context.exception == nil)
        return try #require(payload?.toDictionary() as? [String: Any])
    }
}
