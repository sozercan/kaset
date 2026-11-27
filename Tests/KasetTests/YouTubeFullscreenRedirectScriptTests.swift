import Foundation
import JavaScriptCore
import Testing
@testable import Kaset

@Suite("YouTube full screen redirect script", .tags(.service))
@MainActor
struct YouTubeFullscreenRedirectScriptTests {
    @Test("Element full screen requests become a Kaset full screen toggle")
    func fullscreenRequestsPostToggle() throws {
        let context = try #require(JSContext())
        try self.evaluate(
            """
            var messages = [];
            var nativeCalls = 0;
            function Element() {}
            Element.prototype.requestFullscreen = function() { nativeCalls += 1; };
            Element.prototype.webkitRequestFullscreen = function() { nativeCalls += 1; };
            var window = {
                navigator: { userActivation: { isActive: true } },
                __kasetDocumentGeneration: 7,
                webkit: { messageHandlers: { youtubePlayer: {
                    postMessage: function(message) { messages.push(message); }
                } } }
            };
            """,
            in: context
        )
        try self.evaluate(YouTubeWatchWebView.fullscreenRedirectScript, in: context)
        try self.evaluate(
            """
            var player = new Element();
            var result = player.requestFullscreen();
            window.__kasetDocumentGeneration = 8;
            player.webkitRequestFullscreen();
            """,
            in: context
        )

        #expect(context.evaluateScript("nativeCalls").toInt32() == 0)
        #expect(context.evaluateScript("typeof result.then").toString() == "function")
        #expect(context.evaluateScript(
            "messages.map(function(m) { return m.type + ':' + m.documentGeneration; }).join(',')"
        ).toString() == "TOGGLE_FULLSCREEN:7,TOGGLE_FULLSCREEN:8")
    }

    @Test("Full screen requests without a user gesture are rejected without a toggle")
    func fullscreenRequestsRequireUserActivation() throws {
        let context = try #require(JSContext())
        try self.evaluate(
            """
            var messages = [];
            var rejection = null;
            function Element() {}
            Element.prototype.requestFullscreen = function() {};
            var window = {
                navigator: { userActivation: { isActive: false } },
                __kasetDocumentGeneration: 7,
                webkit: { messageHandlers: { youtubePlayer: {
                    postMessage: function(message) { messages.push(message); }
                } } }
            };
            """,
            in: context
        )
        try self.evaluate(YouTubeWatchWebView.fullscreenRedirectScript, in: context)
        try self.evaluate(
            """
            new Element().requestFullscreen().catch(function(error) { rejection = error.name; });
            """,
            in: context
        )

        #expect(context.evaluateScript("messages.length").toInt32() == 0)
        #expect(context.evaluateScript("rejection").toString() == "TypeError")
    }

    private func evaluate(_ script: String, in context: JSContext) throws {
        context.exception = nil
        _ = context.evaluateScript(script)
        if let exception = context.exception?.toString() {
            Issue.record("JavaScript exception: \(exception)")
            throw FullscreenRedirectScriptError.javaScriptException(exception)
        }
    }
}

private enum FullscreenRedirectScriptError: Error {
    case javaScriptException(String)
}
