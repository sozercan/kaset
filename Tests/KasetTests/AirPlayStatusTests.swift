import JavaScriptCore
import Testing
@testable import Kaset

// MARK: - AirPlayStatusTests

@Suite("AirPlay connection reporting", .tags(.service))
@MainActor
struct AirPlayStatusTests {
    @Test("A fresh document reports disconnected even without an earlier picker request")
    func disconnectedDocumentPublishesInitialState() throws {
        let context = try Self.makeContext()

        #expect(Self.connectionStates(in: context) == [false])
        #expect(context.exception == nil)
    }

    @Test("A document with no media clears a previous native connection indicator")
    func missingInitialMediaPublishesDisconnected() throws {
        let context = try Self.makeContext(setup: "video = null;")

        #expect(Self.connectionStates(in: context) == [false])
        #expect(context.exception == nil)
    }

    @Test("Connection state is reported before the page is ready", arguments: [
        "playerBar = null;",
        "document.readyState = 'loading';",
    ])
    func loadingPagePublishesInitialState(setup: String) throws {
        let context = try Self.makeContext(setup: setup)

        #expect(Self.connectionStates(in: context) == [false])
        #expect(context.exception == nil)
    }

    @Test("Existing wireless playback is reported without opening the picker")
    func connectedDocumentPublishesInitialState() throws {
        let context = try Self.makeContext(setup: "video.webkitCurrentPlaybackTargetIsWireless = true;")

        #expect(Self.connectionStates(in: context) == [true])
        #expect(context.exception == nil)
    }

    @Test("Repeated wireless events and DOM mutations publish only connection changes")
    func repeatedConnectionReportsAreDeduplicated() throws {
        let context = try Self.makeContext()
        context.evaluateScript("""
        dispatch('webkitcurrentplaybacktargetiswirelesschanged');
        notifyMediaMutation();
        video.webkitCurrentPlaybackTargetIsWireless = true;
        dispatch('webkitcurrentplaybacktargetiswirelesschanged');
        dispatch('webkitcurrentplaybacktargetiswirelesschanged');
        notifyMediaMutation();
        video.webkitCurrentPlaybackTargetIsWireless = false;
        dispatch('webkitcurrentplaybacktargetiswirelesschanged');
        dispatch('webkitcurrentplaybacktargetiswirelesschanged');
        """)

        #expect(Self.connectionStates(in: context) == [false, true, false])
        #expect(context.exception == nil)
    }

    @Test("Replacement and removal report the active element's actual connection")
    func mediaReplacementAndRemovalClearConnection() throws {
        for replacement in [
            "video = Object.assign({}, video, { webkitCurrentPlaybackTargetIsWireless: false, __kasetListenersAttached: false });",
            "video = null;",
        ] {
            let context = try Self.makeContext(setup: "video.webkitCurrentPlaybackTargetIsWireless = true;")
            context.evaluateScript("\(replacement) notifyMediaMutation();")

            #expect(Self.connectionStates(in: context) == [true, false])
            #expect(context.exception == nil)
        }
    }

    @Test("A late disconnect from detached media cannot overwrite the replacement's connection")
    func detachedMediaCannotChangeConnection() throws {
        let context = try Self.makeContext()
        context.evaluateScript("""
        const detached = video;
        const detachedListener = listeners.webkitcurrentplaybacktargetiswirelesschanged[0];
        video = Object.assign({}, video, {
            webkitCurrentPlaybackTargetIsWireless: true,
            __kasetListenersAttached: false
        });
        notifyMediaMutation();
        detached.webkitCurrentPlaybackTargetIsWireless = false;
        detachedListener({ currentTarget: detached });
        """)

        #expect(Self.connectionStates(in: context) == [false, true])
        #expect(context.exception == nil)
    }

    @Test("Changing the source on the same wireless element does not report a disconnect")
    func sameElementTrackChangePreservesConnection() throws {
        let context = try Self.makeContext(setup: "video.webkitCurrentPlaybackTargetIsWireless = true;")
        context.evaluateScript("""
        video.currentSrc = 'https://media.example/next';
        video.currentTime = 0;
        currentDataVideoId = 'next';
        dispatch('loadedmetadata');
        dispatch('playing');
        notifyMediaMutation();
        """)

        #expect(Self.connectionStates(in: context) == [true])
        #expect(context.exception == nil)
    }

    private static func makeContext(setup: String = "") throws -> JSContext {
        try MusicPlaybackObserverTestContext.make(setup: """
        var mediaMutationListeners = [];
        MutationObserver = function(callback) {
            this.observe = function(target) {
                if (target === document.body) mediaMutationListeners.push(callback);
            };
            this.disconnect = function() {};
        };
        function notifyMediaMutation() {
            mediaMutationListeners.slice().forEach(callback => callback([]));
        }
        \(setup)
        """)
    }

    private static func connectionStates(in context: JSContext) -> [Bool] {
        context.evaluateScript("messages.filter(message => message.type === 'AIRPLAY_STATUS').map(message => message.isConnected)")?.toArray() as? [Bool] ?? []
    }
}
