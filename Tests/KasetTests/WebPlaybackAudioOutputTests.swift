import JavaScriptCore
import Testing
@testable import Kaset

@Suite("Music audio output continuity", .tags(.service))
@MainActor
struct WebPlaybackAudioOutputTests {
    @Test("A natural transition retains the same silent output through the next playing event")
    func naturalTransitionRetainsOutput() throws {
        let context = try Self.makeContext()
        context.evaluateScript("emit('play'); emit('playing'); video.ended = true; video.paused = true; emit('pause'); emit('ended');")
        #expect(context.evaluateScript("contexts.length").toInt32() == 1)
        #expect(context.evaluateScript("contexts[0].state").toString() == "running")

        context.evaluateScript("video.ended = false; emit('emptied'); video.paused = false; emit('play'); emit('playing'); runTimers();")

        #expect(context.evaluateScript("contexts.length").toInt32() == 1)
        #expect(context.evaluateScript("contexts[0].state").toString() == "running")
        #expect(context.evaluateScript("contexts[0].gain.gain.value").toDouble() == 0)
        #expect(context.exception == nil)
    }

    @Test("Pause and document suppression release output even at the end of a song")
    func explicitPauseReleasesOutput() throws {
        for action in [
            "video.paused = true; emit('pause');",
            "video.ended = true; window.__kasetPlaybackSuppressed = true; emit('pause');",
            "video.ended = true; video.paused = true; \(WebPlaybackDocumentGeneration.mediaSuppressionScript)",
            "video.ended = true; video.paused = true; \(SingletonPlayerWebView.seekAndPauseScript(to: 0))",
        ] {
            let context = try Self.makeContext()
            context.evaluateScript("emit('playing'); \(action)")

            #expect(context.evaluateScript("contexts[0].state").toString() == "closed")
            #expect(context.evaluateScript("contexts[0].source.stopped").toBool())
            #expect(context.evaluateScript("contexts[0].gain.disconnected").toBool())
            #expect(context.exception == nil)
        }
    }

    @Test("Deferred playback and blocked autoplay never open output")
    func deferredPlaybackDoesNotOpenOutput() throws {
        for flag in ["__kasetPlaybackSuppressed", "__kasetBlockAutoplay"] {
            let context = try Self.makeContext(setup: "window.\(flag) = true; window.__kasetAutoplayPending = true;")
            context.evaluateScript("emit('loadstart'); emit('play'); emit('playing');")

            #expect(context.evaluateScript("contexts.length").toInt32() == 0)
            #expect(context.exception == nil)
        }
    }

    @Test("An abandoned autoplay or finished queue releases its output after a bounded wait")
    func abandonedPlaybackReleasesOutput() throws {
        let startup = try Self.makeContext(setup: "window.__kasetAutoplayPending = true;")
        startup.evaluateScript("runTimers();")
        #expect(startup.evaluateScript("contexts[0].state").toString() == "closed")

        let ended = try Self.makeContext()
        ended.evaluateScript("emit('playing'); video.ended = true; emit('pause'); emit('ended'); runTimers();")
        #expect(ended.evaluateScript("contexts[0].state").toString() == "closed")
    }

    @Test("Page exit, playback errors, and wireless output release the local graph")
    func outputLifecycleReleasesGraph() throws {
        for action in [
            "windowListeners.pagehide();",
            "emit('error');",
            "video.webkitCurrentPlaybackTargetIsWireless = true; emit('webkitcurrentplaybacktargetiswirelesschanged');",
        ] {
            let context = try Self.makeContext()
            context.evaluateScript("emit('playing'); \(action)")
            #expect(context.evaluateScript("contexts[0].state").toString() == "closed")
            #expect(context.exception == nil)
        }
    }

    @Test("A late event from replaced media cannot release the active output")
    func replacedMediaDoesNotOwnOutput() throws {
        let context = try Self.makeContext()
        context.evaluateScript("""
        emit('playing');
        const replaced = video;
        video = { tagName: 'VIDEO', paused: false, ended: false, readyState: 4 };
        mediaMutation();
        documentListeners.pause.forEach(listener => listener({ target: replaced }));
        runTimers();
        """)
        #expect(context.evaluateScript("contexts[0].state").toString() == "running")
        #expect(context.exception == nil)
    }

    @Test("Removed media and a paused replacement release output without another media event")
    func missingOrPausedReplacementReleasesOutput() throws {
        for replacement in [
            "null",
            "{ tagName: 'VIDEO', paused: true, ended: false, readyState: 0 }",
        ] {
            let context = try Self.makeContext()
            context.evaluateScript("emit('playing'); video = \(replacement); mediaMutation(); runTimers();")

            #expect(context.evaluateScript("contexts.length").toInt32() == 1)
            #expect(context.evaluateScript("contexts[0].state").toString() == "closed")
            #expect(context.exception == nil)
        }
    }

    @Test("A replacement that starts before cleanup keeps the existing output")
    func replacementPlaybackCancelsCleanup() throws {
        let context = try Self.makeContext()
        context.evaluateScript("""
        emit('playing');
        video = { tagName: 'VIDEO', paused: true, ended: false, readyState: 0 };
        mediaMutation();
        video.paused = false;
        video.readyState = 4;
        emit('playing');
        runTimers();
        """)

        #expect(context.evaluateScript("contexts.length").toInt32() == 1)
        #expect(context.evaluateScript("contexts[0].state").toString() == "running")
        #expect(context.exception == nil)
    }

    @Test("An unavailable audio context leaves media playback untouched")
    func unavailableAudioContextDoesNotInterruptMedia() throws {
        let context = try Self.makeContext(setup: "window.AudioContext = function() { throw new Error('unavailable'); };")
        context.evaluateScript("emit('play'); emit('playing');")
        #expect(context.evaluateScript("video.paused").toBool() == false)
        #expect(context.evaluateScript("contexts.length").toInt32() == 0)
        #expect(context.exception == nil)
    }

    private static func makeContext(setup: String = "") throws -> JSContext {
        let context = try #require(JSContext())
        context.evaluateScript(Self.harness)
        context.evaluateScript(setup)
        context.evaluateScript(WebPlaybackAudioOutput.script)
        #expect(context.exception == nil)
        return context
    }

    private static let harness = """
    var window = this;
    var contexts = [];
    var timers = new Map();
    var nextTimer = 0;
    var documentListeners = {};
    var windowListeners = {};
    var mediaMutation;
    var MutationObserver = class {
        constructor(callback) { mediaMutation = callback; }
        observe() {}
        disconnect() {}
    };
    var video = {
        tagName: 'VIDEO', paused: false, ended: false, readyState: 4,
        pause() { this.paused = true; emit('pause'); }
    };
    var document = {
        querySelector: () => video,
        querySelectorAll: () => video ? [video] : [],
        addEventListener(name, listener) {
            (documentListeners[name] ||= []).push(listener);
        }
    };
    window.addEventListener = (name, listener) => { windowListeners[name] = listener; };
    function emit(name) {
        (documentListeners[name] || []).forEach(listener => listener({ target: video }));
    }
    function setTimeout(callback) { const id = ++nextTimer; timers.set(id, callback); return id; }
    function clearTimeout(id) { timers.delete(id); }
    function runTimers() {
        const pending = Array.from(timers.values());
        timers.clear();
        pending.forEach(callback => callback());
    }
    window.AudioContext = class {
        constructor() { this.state = 'suspended'; this.destination = {}; contexts.push(this); }
        createOscillator() {
            return this.source = {
                connect() {}, start() {}, disconnect() {},
                stop() { this.stopped = true; }
            };
        }
        createGain() {
            return this.gain = {
                gain: { value: 1 }, connect() {},
                disconnect() { this.disconnected = true; }
            };
        }
        resume() { this.state = 'running'; return { catch() {} }; }
        close() { this.state = 'closed'; return { catch() {} }; }
    };
    """
}
