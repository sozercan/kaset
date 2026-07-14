import Foundation
import Testing
@testable import Kaset

@Suite("Web playback document generation")
struct WebPlaybackDocumentGenerationTests {
    @Test("JavaScript string literals escape untrusted video identifiers")
    func javascriptLiteralEscaping() {
        let literal = WebPlaybackDocumentGeneration.javaScriptStringLiteral("x';alert(1)//")

        #expect(literal.hasPrefix("\""))
        #expect(literal.hasSuffix("\""))
        #expect(!literal.hasPrefix("'"))
        #expect(WebPlaybackDocumentGeneration.javaScriptStringLiteral(nil) == "null")
    }

    @Test("Suppression script keeps an invalidated document from restarting media")
    func mediaSuppressionScriptIsPersistent() {
        let script = WebPlaybackDocumentGeneration.mediaSuppressionScript

        #expect(script.contains("window.__kasetPlaybackSuppressed = true"))
        #expect(script.contains("document.addEventListener('play'"))
        #expect(script.contains("}, true);"))
        #expect(script.contains("media.pause()"))
    }

    @Test("Retryable WebKit cancellation errors do not terminally fail navigation")
    func retryableCancellationClassification() {
        let cancelled = NSError(
            domain: NSURLErrorDomain,
            code: URLError.cancelled.rawValue
        )
        let policyChange = NSError(domain: "WebKitErrorDomain", code: 102)
        let offline = NSError(domain: NSURLErrorDomain, code: URLError.notConnectedToInternet.rawValue)

        #expect(WebPlaybackNavigationFailure.isRetryableCancellation(cancelled))
        #expect(WebPlaybackNavigationFailure.isRetryableCancellation(policyChange))
        #expect(!WebPlaybackNavigationFailure.isRetryableCancellation(offline))
    }

    @Test("Tracked navigation retains one-shot bootstrap seek across redirects")
    func trackedNavigationRetainsSeek() {
        let navigation = WebPlaybackTrackedNavigation(generation: 42, pendingSeek: 12.5)

        #expect(navigation.generation == 42)
        #expect(navigation.pendingSeek == 12.5)
        #expect(!navigation.didCommit)
        #expect(!navigation.didActivatePlaybackOrigin)
    }

    @Test("Pending and provisional navigation suppress the outgoing document until commit")
    func navigationSuppressesOutgoingDocumentUntilCommit() {
        var generation = WebPlaybackDocumentGeneration()

        #expect(generation.accepts(rawGeneration: 0))

        let next = generation.beginNavigation()
        #expect(next == 1)
        #expect(generation.pendingGeneration == next)
        #expect(generation.userScriptGeneration == next)
        #expect(!generation.accepts(rawGeneration: 0))
        #expect(!generation.acceptsUserCommand(
            generation: 0,
            issuedAtMilliseconds: nil,
            navigationStartedAtMilliseconds: 100
        ))
        #expect(!generation.acceptsUserCommand(
            generation: 0,
            issuedAtMilliseconds: 99,
            navigationStartedAtMilliseconds: 100
        ))
        #expect(generation.acceptsUserCommand(
            generation: 0,
            issuedAtMilliseconds: 100,
            navigationStartedAtMilliseconds: 100
        ))
        #expect(!generation.accepts(rawGeneration: next))

        let didStart = generation.startNavigation(next)
        #expect(didStart)
        #expect(generation.currentGeneration == 0)
        #expect(generation.inFlightGeneration == next)
        #expect(generation.userScriptGeneration == next)
        #expect(!generation.accepts(rawGeneration: 0))
        #expect(generation.acceptsUserCommand(
            generation: 0,
            issuedAtMilliseconds: 101,
            navigationStartedAtMilliseconds: 100
        ))
        #expect(!generation.accepts(rawGeneration: next))

        let didCommit = generation.commitNavigation(next)
        #expect(didCommit)
        #expect(generation.currentGeneration == next)
        #expect(generation.inFlightGeneration == nil)
        #expect(generation.accepts(rawGeneration: next))
        #expect(!generation.acceptsUserCommand(
            generation: 0,
            issuedAtMilliseconds: 101,
            navigationStartedAtMilliseconds: 100
        ))
        #expect(!generation.accepts(rawGeneration: 0))
    }

    @Test("Current media-key commands are accepted when no navigation is active")
    func currentUserCommandAcceptedWithoutNavigation() {
        let generation = WebPlaybackDocumentGeneration()

        #expect(generation.acceptsUserCommand(
            generation: 0,
            issuedAtMilliseconds: nil,
            navigationStartedAtMilliseconds: nil
        ))
    }

    @Test("Superseded navigation cannot start over the newer request")
    func supersededNavigationCannotStart() {
        var generation = WebPlaybackDocumentGeneration()

        let first = generation.beginNavigation()
        let second = generation.beginNavigation()

        let startedFirst = generation.startNavigation(first)
        #expect(!startedFirst)
        #expect(generation.pendingGeneration == second)
        let startedSecond = generation.startNavigation(second)
        #expect(startedSecond)
        #expect(generation.inFlightGeneration == second)
    }

    @Test("Cancelling a pre-navigation request restores the committed document")
    func cancellingPendingNavigationRestoresCommittedDocument() {
        var generation = WebPlaybackDocumentGeneration()
        let first = generation.beginNavigation()
        let didStartFirst = generation.startNavigation(first)
        let didCommitFirst = generation.commitNavigation(first)
        #expect(didStartFirst)
        #expect(didCommitFirst)

        _ = generation.beginNavigation()
        #expect(!generation.accepts(rawGeneration: first))

        generation.cancelPendingNavigation()

        #expect(generation.pendingGeneration == nil)
        #expect(generation.accepts(rawGeneration: first))
    }

    @Test("Cancelling a provisional navigation restores the committed document")
    func cancellingInFlightNavigationRestoresCommittedDocument() {
        var generation = WebPlaybackDocumentGeneration()
        let first = generation.beginNavigation()
        let didStartFirst = generation.startNavigation(first)
        let didCommitFirst = generation.commitNavigation(first)
        #expect(didStartFirst)
        #expect(didCommitFirst)

        let second = generation.beginNavigation()
        let didStartSecond = generation.startNavigation(second)
        #expect(didStartSecond)
        #expect(!generation.accepts(rawGeneration: first))
        #expect(!generation.accepts(rawGeneration: second))

        let didCancel = generation.cancelInFlightNavigation(second)
        #expect(didCancel)
        #expect(generation.inFlightGeneration == nil)
        #expect(generation.currentGeneration == first)
        #expect(generation.accepts(rawGeneration: first))
    }

    @Test("An earlier commit is recorded while a newer request remains pending")
    func commitWhileNewerRequestIsPending() {
        var generation = WebPlaybackDocumentGeneration()
        let first = generation.beginNavigation()
        let didStartFirst = generation.startNavigation(first)
        #expect(didStartFirst)

        let second = generation.beginNavigation()
        let didCommitFirst = generation.commitNavigation(first)
        #expect(didCommitFirst)

        #expect(generation.currentGeneration == first)
        #expect(generation.pendingGeneration == second)
        #expect(!generation.accepts(rawGeneration: first))
        #expect(generation.userScriptGeneration == second)
    }

    @Test("A committed document cannot finish after a newer selection begins")
    func staleCommittedDocumentCannotFinish() {
        var generation = WebPlaybackDocumentGeneration()
        let first = generation.beginNavigation()
        let didStartFirst = generation.startNavigation(first)
        let didCommitFirst = generation.commitNavigation(first)
        #expect(didStartFirst)
        #expect(didCommitFirst)
        #expect(generation.canFinishNavigation(first))

        let second = generation.beginNavigation()
        #expect(!generation.canFinishNavigation(first))
        let didStartSecond = generation.startNavigation(second)
        #expect(didStartSecond)
        #expect(!generation.canFinishNavigation(first))
        let didCommitSecond = generation.commitNavigation(second)
        #expect(didCommitSecond)
        #expect(!generation.canFinishNavigation(first))
        #expect(generation.canFinishNavigation(second))
    }

    @Test("An earlier commit is recorded while a newer navigation is in flight")
    func commitWhileNewerNavigationIsInFlight() {
        var generation = WebPlaybackDocumentGeneration()
        let first = generation.beginNavigation()
        let didStartFirst = generation.startNavigation(first)
        #expect(didStartFirst)

        let second = generation.beginNavigation()
        let didStartSecond = generation.startNavigation(second)
        #expect(didStartSecond)

        let didCommitFirst = generation.commitNavigation(first)
        #expect(didCommitFirst)
        #expect(generation.currentGeneration == first)
        #expect(generation.inFlightGeneration == second)
        #expect(!generation.accepts(rawGeneration: first))

        let didCommitSecond = generation.commitNavigation(second)
        #expect(didCommitSecond)
        #expect(generation.currentGeneration == second)
        #expect(generation.inFlightGeneration == nil)
        #expect(generation.accepts(rawGeneration: second))
    }

    @Test("Invalidation rejects every document that existed before teardown")
    func invalidationRejectsExistingDocuments() {
        var generation = WebPlaybackDocumentGeneration()
        let first = generation.beginNavigation()
        let didStartFirst = generation.startNavigation(first)
        let didCommitFirst = generation.commitNavigation(first)
        #expect(didStartFirst)
        #expect(didCommitFirst)

        generation.invalidate()

        #expect(generation.currentGeneration > first)
        #expect(!generation.accepts(rawGeneration: first))
        #expect(generation.accepts(rawGeneration: generation.currentGeneration))
    }

    @Test("Malformed or unrelated URL query values do not decode a document generation")
    func malformedURLQueryValuesDoNotDecode() throws {
        let unrelated = try #require(URL(string: "https://example.test/watch?other=42"))
        let malformed = try #require(URL(string: "https://example.test/watch?kasetDocumentGeneration=nope"))

        #expect(WebPlaybackDocumentGeneration.generation(from: unrelated) == nil)
        #expect(WebPlaybackDocumentGeneration.generation(from: malformed) == nil)
        #expect(WebPlaybackDocumentGeneration.generation(from: nil) == nil)
        let fragment = try #require(URL(
            string: "https://example.test/watch#kasetDocumentGeneration=42"
        ))
        #expect(WebPlaybackDocumentGeneration.generation(from: fragment) == 42)
    }

    @Test("A query-dropping redirect remains associated through mainDocumentURL")
    func redirectedRequestKeepsGenerationAssociation() throws {
        let original = try #require(URL(
            string: "https://example.test/watch?v=video&kasetDocumentGeneration=42"
        ))
        let redirect = try #require(URL(string: "https://consent.example.test/continue"))
        var request = URLRequest(url: redirect)
        request.mainDocumentURL = original

        #expect(WebPlaybackDocumentGeneration.request(request, belongsTo: 42))
        #expect(!WebPlaybackDocumentGeneration.request(request, belongsTo: 41))

        var unrelated = URLRequest(url: redirect)
        unrelated.mainDocumentURL = try #require(URL(
            string: "https://example.test/watch?v=old&kasetDocumentGeneration=41"
        ))
        #expect(!WebPlaybackDocumentGeneration.request(unrelated, belongsTo: 42))
    }

    @Test("Conflicting request and main-document generations are rejected")
    func conflictingRequestGenerationsAreRejected() throws {
        let current = try #require(URL(
            string: "https://music.youtube.com/watch?v=current&kasetDocumentGeneration=42"
        ))
        let stale = try #require(URL(
            string: "https://consent.youtube.com/m?kasetDocumentGeneration=41"
        ))
        var request = URLRequest(url: stale)
        request.mainDocumentURL = current

        #expect(!WebPlaybackDocumentGeneration.request(request, belongsTo: 41))
        #expect(!WebPlaybackDocumentGeneration.request(request, belongsTo: 42))
        #expect(!WebPlaybackDocumentGeneration.requestBelongsToNavigationChain(
            request,
            currentURL: current,
            generation: 42,
            playbackHost: "music.youtube.com"
        ))
    }

    @Test("Tokenless allowed-host continuation cannot borrow a newer generation")
    func tokenlessContinuationCannotBorrowNewerGeneration() throws {
        let staleCurrent = try #require(URL(
            string: "https://music.youtube.com/watch?v=old&kasetDocumentGeneration=41"
        ))
        let tokenlessConsent = try URLRequest(url: #require(URL(
            string: "https://consent.youtube.com/m"
        )))

        #expect(!WebPlaybackDocumentGeneration.requestBelongsToNavigationChain(
            tokenlessConsent,
            currentURL: staleCurrent,
            generation: 42,
            playbackHost: "music.youtube.com"
        ))
    }

    @Test("Tokenless continuation requires a committed same-generation intermediary")
    func tokenlessContinuationRequiresCommittedIntermediary() throws {
        var documentGeneration = WebPlaybackDocumentGeneration()
        let generation = documentGeneration.beginNavigation()
        let didStart = documentGeneration.startNavigation(generation)
        #expect(didStart)

        let consent = try #require(URL(string: "https://consent.youtube.com/m"))
        let returnRequest = try URLRequest(url: #require(URL(
            string: "https://music.youtube.com/watch?v=video"
        )))

        #expect(!WebPlaybackDocumentGeneration.requestBelongsToNavigationChain(
            returnRequest,
            currentURL: consent,
            generation: generation,
            playbackHost: "music.youtube.com",
            committedIntermediaryGeneration: documentGeneration.committedIntermediaryGeneration
        ))
        let didCommitIntermediary = documentGeneration.commitIntermediaryNavigation(generation)
        #expect(didCommitIntermediary)
        #expect(WebPlaybackDocumentGeneration.requestBelongsToNavigationChain(
            returnRequest,
            currentURL: consent,
            generation: generation,
            playbackHost: "music.youtube.com",
            committedIntermediaryGeneration: documentGeneration.committedIntermediaryGeneration
        ))

        _ = documentGeneration.beginNavigation()
        #expect(documentGeneration.committedIntermediaryGeneration == nil)
        #expect(!WebPlaybackDocumentGeneration.requestBelongsToNavigationChain(
            returnRequest,
            currentURL: consent,
            generation: generation + 1,
            playbackHost: "music.youtube.com",
            committedIntermediaryGeneration: documentGeneration.committedIntermediaryGeneration
        ))
    }

    @Test("Playback navigation only trusts the expected HTTPS origin")
    func playbackNavigationRequiresExpectedOrigin() throws {
        let expected = try #require(URL(string: "https://music.youtube.com/watch?v=video"))
        let wrongHost = try #require(URL(string: "https://consent.youtube.com/continue"))
        let wrongScheme = try #require(URL(string: "http://music.youtube.com/watch?v=video"))

        #expect(WebPlaybackDocumentGeneration.isExpectedPlaybackURL(
            expected,
            host: "music.youtube.com"
        ))
        #expect(!WebPlaybackDocumentGeneration.isExpectedPlaybackURL(
            wrongHost,
            host: "music.youtube.com"
        ))
        #expect(!WebPlaybackDocumentGeneration.isExpectedPlaybackURL(
            wrongScheme,
            host: "music.youtube.com"
        ))
        #expect(!WebPlaybackDocumentGeneration.isExpectedPlaybackURL(
            nil,
            host: "music.youtube.com"
        ))
    }

    @Test("Fragment-only navigation is distinguished from a document-changing URL")
    func fragmentOnlyNavigationDetection() throws {
        let current = try #require(URL(string: "https://example.test/watch?v=video#one"))
        let fragmentChange = try #require(URL(string: "https://example.test/watch?v=video#two"))
        let queryChange = try #require(URL(string: "https://example.test/watch?v=other#two"))

        #expect(WebPlaybackDocumentGeneration.isFragmentOnlyNavigation(
            from: current,
            to: fragmentChange
        ))
        #expect(!WebPlaybackDocumentGeneration.isFragmentOnlyNavigation(
            from: current,
            to: queryChange
        ))
        #expect(!WebPlaybackDocumentGeneration.isFragmentOnlyNavigation(
            from: current,
            to: current
        ))
    }

    @Test("Internal blank navigations are recognized")
    func internalBlankNavigationDetection() throws {
        #expect(WebPlaybackDocumentGeneration.isInternalBlankNavigation(nil))
        #expect(try WebPlaybackDocumentGeneration.isInternalBlankNavigation(
            #require(URL(string: "about:blank"))
        ))
        #expect(try WebPlaybackDocumentGeneration.isInternalBlankNavigation(
            #require(URL(string: "data:text/html,"))
        ))
        #expect(try !WebPlaybackDocumentGeneration.isInternalBlankNavigation(
            #require(URL(string: "https://example.test"))
        ))
    }

    @Test("Only an explicitly owned blank URL is accepted")
    func internalBlankNavigationRequiresOwnership() throws {
        var documentGeneration = WebPlaybackDocumentGeneration()
        let blankGeneration = documentGeneration.beginBlankNavigation()
        let ownedBlank = try #require(WebPlaybackDocumentGeneration.blankURL(
            generation: blankGeneration
        ))
        let ownedData = try #require(URL(
            string: "data:text/html,%3Chtml%3E%3C/html%3E#kasetBlankGeneration=\(blankGeneration)"
        ))
        let unownedBlank = try #require(URL(string: "about:blank"))

        #expect(documentGeneration.ownsBlankNavigation(ownedBlank))
        #expect(documentGeneration.ownsBlankNavigation(ownedData))
        #expect(try documentGeneration.ownsBlankNavigation(#require(URL(
            string: "about:blank%23kasetBlankGeneration=\(blankGeneration)"
        ))))
        #expect(try documentGeneration.ownsBlankNavigation(#require(URL(
            string: "data:text/html,%3Chtml%3E%3C/html%3E%23kasetBlankGeneration=\(blankGeneration)"
        ))))
        #expect(!documentGeneration.ownsBlankNavigation(unownedBlank))

        let ownedResponse = URLResponse(
            url: ownedBlank,
            mimeType: "text/html",
            expectedContentLength: 0,
            textEncodingName: "utf-8"
        )
        #expect(WebPlaybackDocumentGeneration.acceptsMainFrameResponse(
            ownedResponse,
            expectedHost: "music.youtube.com",
            expectedVideoID: nil,
            allowsInternalBlank: documentGeneration.ownsBlankNavigation(ownedBlank)
        ))
        let ownedDataResponse = URLResponse(
            url: ownedData,
            mimeType: "text/html",
            expectedContentLength: 0,
            textEncodingName: "utf-8"
        )
        #expect(WebPlaybackDocumentGeneration.acceptsMainFrameResponse(
            ownedDataResponse,
            expectedHost: "music.youtube.com",
            expectedVideoID: nil,
            allowsInternalBlank: documentGeneration.ownsBlankNavigation(ownedData)
        ))

        _ = documentGeneration.beginNavigation()
        #expect(!documentGeneration.ownsBlankNavigation(ownedBlank))
    }

    @Test("Main-frame response validation allows playback and trusted consent origins")
    func mainFrameResponseValidation() throws {
        #expect(try WebPlaybackDocumentGeneration.acceptsMainFrameResponse(
            #require(URL(string: "https://music.youtube.com/watch")),
            expectedHost: "music.youtube.com"
        ))
        #expect(try WebPlaybackDocumentGeneration.acceptsMainFrameResponse(
            #require(URL(string: "https://consent.youtube.com/")),
            expectedHost: "music.youtube.com"
        ))
        #expect(try !WebPlaybackDocumentGeneration.acceptsMainFrameResponse(
            #require(URL(string: "http://music.youtube.com/watch")),
            expectedHost: "music.youtube.com"
        ))
        #expect(try !WebPlaybackDocumentGeneration.acceptsMainFrameResponse(
            #require(URL(string: "about:blank")),
            expectedHost: "music.youtube.com"
        ))
        #expect(try !WebPlaybackDocumentGeneration.acceptsMainFrameResponse(
            #require(URL(string: "data:text/html,")),
            expectedHost: "music.youtube.com"
        ))
    }

    @Test("Playback response requires 2xx status and the expected watch identity")
    func playbackResponseRequiresSuccessAndExpectedIdentity() throws {
        var documentGeneration = WebPlaybackDocumentGeneration()
        let generation = documentGeneration.beginNavigation()
        let didStart = documentGeneration.startNavigation(generation)
        #expect(didStart)
        let expectedURL = try #require(URL(
            string: "https://music.youtube.com/watch?v=video&kasetDocumentGeneration=\(generation)"
        ))
        let wrongVideoURL = try #require(URL(
            string: "https://music.youtube.com/watch?v=other&kasetDocumentGeneration=\(generation)"
        ))
        let consentURL = try #require(URL(string: "https://consent.youtube.com/m"))

        let success = try #require(HTTPURLResponse(
            url: expectedURL,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        ))
        let serverError = try #require(HTTPURLResponse(
            url: expectedURL,
            statusCode: 503,
            httpVersion: nil,
            headerFields: nil
        ))
        let wrongVideo = try #require(HTTPURLResponse(
            url: wrongVideoURL,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        ))
        let consent = try #require(HTTPURLResponse(
            url: consentURL,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        ))

        #expect(WebPlaybackDocumentGeneration.acceptsMainFrameResponse(
            success,
            expectedHost: "music.youtube.com",
            expectedVideoID: "video",
            allowsInternalBlank: false
        ))
        #expect(!WebPlaybackDocumentGeneration.acceptsMainFrameResponse(
            serverError,
            expectedHost: "music.youtube.com",
            expectedVideoID: "video",
            allowsInternalBlank: false
        ))
        #expect(!WebPlaybackDocumentGeneration.acceptsMainFrameResponse(
            wrongVideo,
            expectedHost: "music.youtube.com",
            expectedVideoID: "video",
            allowsInternalBlank: false
        ))
        #expect(WebPlaybackDocumentGeneration.acceptsMainFrameResponse(
            consent,
            expectedHost: "music.youtube.com",
            expectedVideoID: "video",
            allowsInternalBlank: false
        ))

        let didRecordResponse = documentGeneration.recordSuccessfulPlaybackResponse(
            url: expectedURL,
            host: "music.youtube.com",
            videoID: "video"
        )
        #expect(didRecordResponse)
        let didCommitWrongVideo = documentGeneration.commitNavigation(
            generation,
            expectedVideoID: "other"
        )
        #expect(!didCommitWrongVideo)
        let didCommitExpectedVideo = documentGeneration.commitNavigation(
            generation,
            expectedVideoID: "video"
        )
        #expect(didCommitExpectedVideo)
    }

    @Test("Trusted consent continuations remain in the same navigation generation")
    func trustedRedirectContinuation() throws {
        let original = try #require(URL(
            string: "https://music.youtube.com/watch?v=x&kasetDocumentGeneration=42"
        ))
        let consent = try #require(URL(string: "https://consent.youtube.com/m"))
        var redirectRequest = URLRequest(url: consent)
        redirectRequest.mainDocumentURL = original
        #expect(WebPlaybackDocumentGeneration.requestBelongsToNavigationChain(
            redirectRequest,
            currentURL: original,
            generation: 42,
            playbackHost: "music.youtube.com"
        ))

        let returnRequest = try URLRequest(url: #require(URL(string: "https://music.youtube.com/watch?v=x")))
        #expect(WebPlaybackDocumentGeneration.requestBelongsToNavigationChain(
            returnRequest,
            currentURL: consent,
            generation: 42,
            playbackHost: "music.youtube.com",
            committedIntermediaryGeneration: 42
        ))

        let untrusted = try URLRequest(url: #require(URL(string: "https://example.test/")))
        #expect(!WebPlaybackDocumentGeneration.requestBelongsToNavigationChain(
            untrusted,
            currentURL: consent,
            generation: 42,
            playbackHost: "music.youtube.com"
        ))

        let rebound = try #require(WebPlaybackDocumentGeneration.requestByBindingGeneration(
            returnRequest,
            generation: 42
        ))
        #expect(WebPlaybackDocumentGeneration.generation(from: rebound.url) == 42)
    }

    @Test("Bridge generation decoding rejects malformed values")
    func bridgeGenerationDecoding() {
        let generation = WebPlaybackDocumentGeneration()

        #expect(generation.accepts(rawGeneration: NSNumber(value: 0)))
        #expect(generation.accepts(rawGeneration: 0))
        #expect(!generation.accepts(rawGeneration: -1))
        #expect(!generation.accepts(rawGeneration: 0.5))
        #expect(!generation.accepts(rawGeneration: "0"))
        #expect(!generation.accepts(rawGeneration: true))
        #expect(!generation.accepts(rawGeneration: Double(UInt64.max)))
        #expect(!generation.accepts(rawGeneration: nil))
    }
}
