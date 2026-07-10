import JavaScriptCore
import Testing
@testable import Kaset

// MARK: - SingletonPlayerVideoModeScriptTests

@Suite(.serialized, .tags(.service))
@MainActor
struct SingletonPlayerVideoModeScriptTests {
    @Test("Video mode warmup is bounded and stops steady RAF scheduling")
    func videoModeWarmupIsBounded() throws {
        let context = try #require(self.makeContext())

        try self.evaluate(SingletonPlayerWebView.videoModeInjectionScriptForTesting, in: context)

        let initialActive = context.evaluateScript("window.__kasetVideoModeActive")?.toBool() ?? false
        let initialQueueCount = context.evaluateScript("rafQueue.length")?.toInt32() ?? -1
        #expect(initialActive)
        #expect(initialQueueCount == 1)

        try self.evaluate("drainAnimationFrames(100);", in: context)

        let remainingQueueCount = context.evaluateScript("rafQueue.length")?.toInt32() ?? -1
        let scheduledCount = context.evaluateScript("rafScheduledCount")?.toInt32() ?? -1
        let videoMarked = context.evaluateScript("video.classList.contains('kaset-visible')")?.toBool() ?? false
        let playerMarked = context.evaluateScript("player.classList.contains('kaset-visible')")?.toBool() ?? false

        #expect(remainingQueueCount == 0)
        #expect(scheduledCount == 30)
        #expect(videoMarked)
        #expect(playerMarked)
    }

    @Test("Video mode schedules only one event-driven enforcement frame")
    func eventDrivenEnforcementCoalescesFrames() throws {
        let context = try #require(self.makeContext())

        try self.evaluate(SingletonPlayerWebView.videoModeInjectionScriptForTesting, in: context)
        try self.evaluate("drainAnimationFrames(100);", in: context)
        let before = context.evaluateScript("rafScheduledCount")?.toInt32() ?? -1

        try self.evaluate("mutationCallbacks[0](); mutationCallbacks[0](); mutationCallbacks[1]();", in: context)

        let pendingAfterMutations = context.evaluateScript("rafQueue.length")?.toInt32() ?? -1
        #expect(pendingAfterMutations == 1)

        try self.evaluate("drainAnimationFrames(10);", in: context)

        let after = context.evaluateScript("rafScheduledCount")?.toInt32() ?? -1
        let pendingAfterDrain = context.evaluateScript("rafQueue.length")?.toInt32() ?? -1
        #expect(after == before + 1)
        #expect(pendingAfterDrain == 0)
    }

    @Test("Video mode event enforcement removes stale extra visibility markers")
    func eventEnforcementRemovesStaleExtraMarkers() throws {
        let context = try #require(self.makeContext())

        try self.evaluate(SingletonPlayerWebView.videoModeInjectionScriptForTesting, in: context)
        try self.evaluate("drainAnimationFrames(100);", in: context)
        try self.evaluate(
            """
            var stale = makeElement('stale', body);
            allElements.push(stale);
            stale.classList.add('kaset-visible');
            mutationCallbacks[0]();
            """,
            in: context
        )
        #expect(context.evaluateScript("rafQueue.length")?.toInt32() == 1)

        try self.evaluate("drainAnimationFrames(10);", in: context)

        let staleStillVisible = context.evaluateScript("stale.classList.contains('kaset-visible')")?.toBool() ?? true
        let videoMarked = context.evaluateScript("video.classList.contains('kaset-visible')")?.toBool() ?? false

        #expect(!staleStillVisible)
        #expect(videoMarked)
    }

    @Test("Video mode reinjection clears stale visibility markers")
    func reinjectionClearsStaleVisibilityMarkers() throws {
        let context = try #require(self.makeContext())

        try self.evaluate(SingletonPlayerWebView.videoModeInjectionScriptForTesting, in: context)
        try self.evaluate("drainAnimationFrames(100);", in: context)
        try self.evaluate(
            """
            var stale = makeElement('stale', body);
            allElements.push(stale);
            stale.classList.add('kaset-visible');
            """,
            in: context
        )
        #expect(context.evaluateScript("stale.classList.contains('kaset-visible')")?.toBool() ?? false)

        try self.evaluate(SingletonPlayerWebView.videoModeInjectionScriptForTesting, in: context)
        try self.evaluate("drainAnimationFrames(100);", in: context)

        let staleStillVisible = context.evaluateScript("stale.classList.contains('kaset-visible')")?.toBool() ?? true
        let videoMarked = context.evaluateScript("video.classList.contains('kaset-visible')")?.toBool() ?? false

        #expect(!staleStillVisible)
        #expect(videoMarked)
    }

    @Test("Video mode removal stops pending enforcement and clears markers")
    func removalStopsPendingEnforcement() throws {
        let context = try #require(self.makeContext())

        try self.evaluate(SingletonPlayerWebView.videoModeInjectionScriptForTesting, in: context)
        try self.evaluate(SingletonPlayerWebView.videoModeRemovalScriptForTesting, in: context)
        try self.evaluate("drainAnimationFrames(100);", in: context)

        let active = context.evaluateScript("window.__kasetVideoModeActive")?.toBool() ?? true
        let stateExists = context.evaluateScript("typeof window.__kasetVideoModeState !== 'undefined'")?.toBool() ?? true
        let pending = context.evaluateScript("rafQueue.length")?.toInt32() ?? -1
        let markedCount = context.evaluateScript("document.querySelectorAll('.kaset-visible').length")?.toInt32() ?? -1

        #expect(!active)
        #expect(!stateExists)
        #expect(pending == 0)
        #expect(markedCount == 0)
    }

    // swiftlint:disable function_body_length
    private func makeContext() -> JSContext? {
        guard let context = JSContext() else { return nil }
        context.exceptionHandler = { _, exception in
            Issue.record("JavaScript exception: \(exception?.toString() ?? "unknown")")
        }
        context.evaluateScript(
            """
            var console = { log: function() {} };
            var window = {
                listeners: {},
                addEventListener: function(name, handler) { this.listeners[name] = handler; },
                removeEventListener: function(name) { delete this.listeners[name]; }
            };

            function makeClassList(element) {
                return {
                    add: function(name) { element.classes[name] = true; },
                    remove: function(name) { delete element.classes[name]; },
                    contains: function(name) { return element.classes[name] === true; }
                };
            }

            function makeElement(name, parent) {
                var element = {
                    nodeName: name,
                    parentElement: parent || null,
                    children: [],
                    classes: {},
                    style: { setProperty: function() {} },
                    textContent: '',
                    id: '',
                    appendChild: function(child) {
                        child.parentElement = element;
                        element.children.push(child);
                        if (child.id) { elementsById[child.id] = child; }
                    },
                    remove: function() {
                        if (element.id) { delete elementsById[element.id]; }
                    },
                    querySelector: function(selector) {
                        if (selector === 'video') { return video; }
                        return null;
                    }
                };
                element.classList = makeClassList(element);
                return element;
            }

            var elementsById = {};
            var html = makeElement('html', null);
            var body = makeElement('body', html);
            var playerPage = makeElement('ytmusic-player-page', body);
            playerPage.videoMode = false;
            playerPage.onVideoModeChangedCount = 0;
            playerPage.onVideoModeChanged = function() { this.onVideoModeChangedCount += 1; };
            var player = makeElement('ytmusic-player', playerPage);
            var video = makeElement('video', player);
            var allElements = [html, body, playerPage, player, video];

            var document = {
                documentElement: html,
                body: body,
                head: { appendChild: function(element) { if (element.id) { elementsById[element.id] = element; } } },
                createElement: function(name) {
                    var element = makeElement(name, null);
                    allElements.push(element);
                    return element;
                },
                getElementById: function(id) { return elementsById[id] || null; },
                querySelector: function(selector) {
                    if (selector === 'video') { return video; }
                    if (selector === 'ytmusic-player-page') { return playerPage; }
                    return null;
                },
                querySelectorAll: function(selector) {
                    if (selector === '.kaset-visible') {
                        return allElements.filter(function(element) { return element.classList.contains('kaset-visible'); });
                    }
                    if (selector === 'video') { return [video]; }
                    return [];
                }
            };

            var mutationCallbacks = [];
            function MutationObserver(callback) { this.callback = callback; mutationCallbacks.push(callback); }
            MutationObserver.prototype.observe = function() {};
            MutationObserver.prototype.disconnect = function() {};

            function ResizeObserver(callback) { this.callback = callback; mutationCallbacks.push(callback); }
            ResizeObserver.prototype.observe = function() {};
            ResizeObserver.prototype.disconnect = function() {};

            var rafQueue = [];
            var rafScheduledCount = 0;
            var canceledRafs = {};
            function requestAnimationFrame(callback) {
                rafScheduledCount += 1;
                rafQueue.push({ id: rafScheduledCount, callback: callback });
                return rafScheduledCount;
            }
            function cancelAnimationFrame(id) { canceledRafs[id] = true; }
            function drainAnimationFrames(limit) {
                var ran = 0;
                while (rafQueue.length > 0 && ran < limit) {
                    var item = rafQueue.shift();
                    if (!canceledRafs[item.id]) { item.callback(); }
                    ran += 1;
                }
                return ran;
            }
            """
        )
        return context
    }

    // swiftlint:enable function_body_length

    private func evaluate(_ script: String, in context: JSContext) throws {
        context.exception = nil
        _ = context.evaluateScript(script)
        if let exception = context.exception?.toString() {
            Issue.record("JavaScript exception: \(exception)")
            throw TestScriptError.javaScriptException(exception)
        }
    }
}

// MARK: - TestScriptError

private enum TestScriptError: Error {
    case javaScriptException(String)
}
