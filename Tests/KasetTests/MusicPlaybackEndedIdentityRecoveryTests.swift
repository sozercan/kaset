import Testing
@testable import Kaset

// MARK: - MusicPlaybackEndedIdentityRecoveryTests

@Suite(.tags(.service))
struct MusicPlaybackEndedIdentityRecoveryTests {
    @Test("Ended retry refreshes identity after metadata resolves")
    func endedRetryRefreshesResolvedIdentity() throws {
        let context = try MusicPlaybackObserverTestContext.make()
        context.evaluateScript(
            """
            messages = [];
            scheduledTimeouts = [];
            currentDataVideoId = '';
            window.location.href = 'https://music.youtube.com/';
            video.currentSrc = 'https://media.example/v2';
            video.currentTime = 0;
            dispatch('loadedmetadata');
            var endingGeneration = video.__kasetMediaGeneration;
            window.__kasetNativePlaybackGeneration = 41;
            video.paused = true;
            video.ended = true;
            dispatch('ended');
            var immediateEndedPayload = messages.filter(function(message) {
                return message.type === 'TRACK_ENDED';
            })[0];
            var immediateEndedVideoId = immediateEndedPayload.videoId;
            window.__kasetNativePlaybackGeneration = 42;
            currentDataVideoId = 'v2';
            titleElement.textContent = 'v2';
            dispatch('canplay');
            var endedRetryRan = runTimeout(16);
            dispatch('ended');
            """
        )

        #expect(context.evaluateScript("immediateEndedVideoId").toString().isEmpty)
        #expect(context.evaluateScript("video.__kasetBoundVideoId").toString() == "v2")
        #expect(context.evaluateScript("endedRetryRan").toBool() == true)
        #expect(context.evaluateScript(
            "video.__kasetEndedOccurrenceGeneration === endingGeneration"
        ).toBool() == true)
        #expect(context.evaluateScript("video.__kasetEndedReported").toBool() == true)
        #expect(context.evaluateScript(
            """
            messages.filter(function(message) { return message.type === 'TRACK_ENDED'; })
                .map(function(message) { return message.videoId; }).join('|')
            """
        ).toString() == "|v2")
        #expect(context.evaluateScript(
            """
            messages.filter(function(message) { return message.type === 'TRACK_ENDED'; })
                .slice(-1)[0].mediaGeneration === endingGeneration
            """
        ).toBool() == true)
        #expect(context.evaluateScript(
            """
            messages.filter(function(message) { return message.type === 'TRACK_ENDED'; })
                .slice(-1)[0].nativePlaybackGeneration
                === immediateEndedPayload.nativePlaybackGeneration
            """
        ).toBool() == true)
        #expect(context.evaluateScript(
            """
            messages.filter(function(message) { return message.type === 'TRACK_ENDED'; })
                .slice(-1)[0].mediaIdentityUncertain
            """
        ).toBool() == false)
        #expect(context.evaluateScript(
            "messages.filter(function(message) { return message.type === 'TRACK_ENDED'; }).length"
        ).toInt32() == 2)
    }

    @Test("Ended retry survives poll-based identity repair")
    func endedRetrySurvivesPollingIdentityRepair() throws {
        let context = try MusicPlaybackObserverTestContext.make()
        context.evaluateScript(
            """
            messages = [];
            scheduledTimeouts = [];
            fakeNow = 0;
            currentDataVideoId = '';
            window.location.href = 'https://music.youtube.com/';
            video.currentSrc = 'https://media.example/v2';
            video.currentTime = 0;
            dispatch('loadedmetadata');
            var endingGeneration = video.__kasetMediaGeneration;
            video.paused = true;
            video.ended = true;
            dispatch('ended');
            currentDataVideoId = 'v2';
            titleElement.textContent = 'v2';
            dispatch('waiting');
            var resolvedRetryRan = runTimeout(16);
            """
        )

        #expect(context.evaluateScript("resolvedRetryRan").toBool() == true)
        #expect(context.evaluateScript(
            "video.__kasetEndedOccurrenceGeneration === endingGeneration"
        ).toBool() == true)
        #expect(context.evaluateScript("video.__kasetMediaGeneration === endingGeneration").toBool() == true)
        #expect(context.evaluateScript("video.__kasetBoundVideoId").toString() == "v2")
        #expect(context.evaluateScript(
            """
            messages.filter(function(message) { return message.type === 'TRACK_ENDED'; })
                .map(function(message) { return message.videoId; }).join('|')
            """
        ).toString() == "|v2")
    }

    @Test("Ended retry survives media identity lag beyond one hundred milliseconds")
    func endedRetrySurvivesLongerIdentityLag() throws {
        let context = try MusicPlaybackObserverTestContext.make()
        context.evaluateScript(
            """
            messages = [];
            scheduledTimeouts = [];
            fakeNow = 0;
            currentDataVideoId = '';
            window.location.href = 'https://music.youtube.com/';
            video.currentSrc = 'https://media.example/v2';
            video.currentTime = 0;
            dispatch('loadedmetadata');
            var endingGeneration = video.__kasetMediaGeneration;
            window.__kasetNativePlaybackGeneration = 41;
            video.paused = true;
            video.ended = true;
            dispatch('ended');
            var immediateEndedPayload = messages.filter(function(message) {
                return message.type === 'TRACK_ENDED';
            })[0];
            var firstRetryRan = runTimeout(16);
            var secondRetryRan = runTimeout(100);
            window.__kasetNativePlaybackGeneration = 42;
            currentDataVideoId = 'v2';
            titleElement.textContent = 'v2';
            dispatch('canplay');
            var resolvedRetryRan = runTimeout(100);
            dispatch('ended');
            """
        )

        #expect(context.evaluateScript("firstRetryRan").toBool() == true)
        #expect(context.evaluateScript("secondRetryRan").toBool() == true)
        #expect(context.evaluateScript("resolvedRetryRan").toBool() == true)
        #expect(context.evaluateScript("fakeNow").toInt32() == 216)
        #expect(context.evaluateScript("video.__kasetBoundVideoId").toString() == "v2")
        #expect(context.evaluateScript(
            """
            messages.filter(function(message) { return message.type === 'TRACK_ENDED'; })
                .map(function(message) { return message.videoId; }).join('|')
            """
        ).toString() == "|v2")
        #expect(context.evaluateScript(
            """
            messages.filter(function(message) { return message.type === 'TRACK_ENDED'; })
                .slice(-1)[0].mediaGeneration === endingGeneration
            """
        ).toBool() == true)
        #expect(context.evaluateScript(
            """
            messages.filter(function(message) { return message.type === 'TRACK_ENDED'; })
                .slice(-1)[0].nativePlaybackGeneration
                === immediateEndedPayload.nativePlaybackGeneration
            """
        ).toBool() == true)
        #expect(context.evaluateScript("scheduledTimeouts.length").toInt32() == 0)
    }

    @Test("Ended identity deadline emits deterministic native fallback")
    func endedRetryEmitsIdentityDeadlineFallback() throws {
        let context = try MusicPlaybackObserverTestContext.make()
        context.evaluateScript(
            """
            messages = [];
            scheduledTimeouts = [];
            fakeNow = 0;
            currentDataVideoId = '';
            window.location.href = 'https://music.youtube.com/';
            video.currentSrc = 'https://media.example/v2';
            video.currentTime = 0;
            window.__kasetNativePlaybackGeneration = 41;
            dispatch('loadedmetadata');
            video.paused = true;
            video.ended = true;
            dispatch('ended');
            var immediateEndedPayload = messages.filter(function(message) {
                return message.type === 'TRACK_ENDED';
            })[0];
            var delayedRetry = scheduledTimeouts.splice(0, 1)[0];
            window.__kasetDocumentGeneration = 8;
            window.__kasetNativePlaybackGeneration = 42;
            fakeNow = 5001;
            delayedRetry.callback();
            dispatch('ended');
            var deadlinePayload = messages.filter(function(message) {
                return message.type === 'TRACK_ENDED_IDENTITY_DEADLINE';
            })[0];
            """
        )

        #expect(context.evaluateScript(
            "messages.filter(function(message) { return message.type === 'TRACK_ENDED'; }).length"
        ).toInt32() == 1)
        #expect(context.evaluateScript(
            "messages.filter(function(message) { return message.type === 'TRACK_ENDED_IDENTITY_DEADLINE'; }).length"
        ).toInt32() == 1)
        #expect(context.evaluateScript("deadlinePayload.videoId").toString().isEmpty)
        #expect(context.evaluateScript("deadlinePayload.mediaVideoId").toString().isEmpty)
        #expect(context.evaluateScript("deadlinePayload.mediaIdentityUncertain").toBool() == true)
        #expect(context.evaluateScript("deadlinePayload.identityDisposition").toString() == "deadlineFallback")
        for field in [
            "documentGeneration",
            "nativePlaybackGeneration",
            "eventIssuedAtMilliseconds",
            "observerEpoch",
            "documentID",
            "mediaGeneration",
            "isAd",
        ] {
            #expect(context.evaluateScript(
                "deadlinePayload.\(field) === immediateEndedPayload.\(field)"
            ).toBool() == true)
        }
        #expect(context.evaluateScript("scheduledTimeouts.length").toInt32() == 0)
    }
}
