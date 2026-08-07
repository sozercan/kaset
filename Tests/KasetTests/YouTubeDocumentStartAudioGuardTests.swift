import JavaScriptCore
import Testing
import WebKit
@testable import Kaset

@Suite("YouTube document-start audio guard", .tags(.service))
@MainActor
struct YouTubeDocumentStartAudioGuardTests {
    @Test("A muted document cannot become audible before the observer attaches")
    func mutedDocumentGatesFirstPlay() throws {
        let context = try #require(JSContext())
        context.evaluateScript(Self.mediaHarness)
        context.evaluateScript(YouTubeWatchWebView.pageBootstrapScript(
            targetVolume: 0,
            documentGeneration: 1
        ))
        context.evaluateScript("video = new HTMLMediaElement(); video.play();")

        #expect(context.evaluateScript("audibleStartCount").toInt32() == 0)
        #expect(context.evaluateScript("video.volume").toDouble() == 0)
        #expect(context.evaluateScript("video.muted").toBool())
    }

    @Test("Native autoplay capture is muted before the document-end observer exists")
    func mutedDocumentGatesNativeAutoplay() throws {
        let context = try #require(JSContext())
        context.evaluateScript(Self.mediaHarness)
        context.evaluateScript(YouTubeWatchWebView.pageBootstrapScript(
            targetVolume: 0,
            documentGeneration: 1
        ))
        context.evaluateScript("video = new HTMLMediaElement(); documentListeners.play({ target: video });")

        #expect(context.evaluateScript("video.volume").toDouble() == 0)
        #expect(context.evaluateScript("video.muted").toBool())
    }

    @Test("Replacement media is muted as soon as it is inserted")
    func mutedDocumentGatesReplacementMedia() throws {
        let context = try #require(JSContext())
        context.evaluateScript(Self.mediaHarness)
        context.evaluateScript(YouTubeWatchWebView.pageBootstrapScript(
            targetVolume: 0,
            documentGeneration: 1
        ))
        context.evaluateScript("video = new HTMLMediaElement(); mutationCallback([{ addedNodes: [video] }]);")

        #expect(context.evaluateScript("video.volume").toDouble() == 0)
        #expect(context.evaluateScript("video.muted").toBool())
    }

    @Test("YouTube cannot restore an audible persisted volume while Kaset is muted")
    func mutedDocumentReassertsVolumeAfterReset() throws {
        let context = try #require(JSContext())
        context.evaluateScript(Self.mediaHarness)
        context.evaluateScript(YouTubeWatchWebView.pageBootstrapScript(
            targetVolume: 0,
            documentGeneration: 1
        ))
        context.evaluateScript(
            "video = new HTMLMediaElement(); video.play(); video.volume = 0.73; video.muted = false; documentListeners.volumechange({ target: video });"
        )

        #expect(context.evaluateScript("video.volume").toDouble() == 0)
        #expect(context.evaluateScript("video.muted").toBool())
    }

    @Test("Persisted volume restoration cannot become audible before volumechange dispatch")
    func mutedDocumentBlocksSynchronousVolumeRestoration() throws {
        for restorationScript in [
            "video.volume = 0.73; video.muted = false;",
            "video.muted = false; video.volume = 0.73;",
        ] {
            let context = try #require(JSContext())
            context.evaluateScript(Self.mediaHarness)
            context.evaluateScript(YouTubeWatchWebView.pageBootstrapScript(
                targetVolume: 0,
                documentGeneration: 1
            ))
            context.evaluateScript(
                "video = new HTMLMediaElement(); video.play(); audibleStateTransitionCount = 0; \(restorationScript)"
            )

            #expect(context.evaluateScript("queuedVolumeChangeTargets.length").toInt32() > 0)
            #expect(context.evaluateScript("audibleStateTransitionCount").toInt32() == 0)
            #expect(context.evaluateScript("video.volume").toDouble() == 0)
            #expect(context.evaluateScript("video.muted").toBool())
        }
    }

    @Test("An audible target is applied before unmuting first play")
    func audibleDocumentAppliesTargetBeforePlay() throws {
        let context = try #require(JSContext())
        context.evaluateScript(Self.mediaHarness)
        context.evaluateScript(YouTubeWatchWebView.pageBootstrapScript(
            targetVolume: 0.4,
            documentGeneration: 1
        ))
        context.evaluateScript("video = new HTMLMediaElement(); video.muted = true; video.play();")

        #expect(abs(context.evaluateScript("volumeAtPlay").toDouble() - 0.4) < 0.001)
        #expect(!context.evaluateScript("mutedAtPlay").toBool())
    }

    @Test("An audible target rejects persisted volume and mute writes synchronously")
    func audibleDocumentBlocksPersistedStateRestoration() throws {
        for restorationScript in [
            "video.volume = 0.91; video.muted = true;",
            "video.muted = true; video.volume = 0.91;",
        ] {
            let context = try #require(JSContext())
            context.evaluateScript(Self.mediaHarness)
            context.evaluateScript(YouTubeWatchWebView.pageBootstrapScript(
                targetVolume: 0.4,
                documentGeneration: 1
            ))
            context.evaluateScript(
                "video = new HTMLMediaElement(); video.play(); \(restorationScript)"
            )

            #expect(abs(context.evaluateScript("video.volume").toDouble() - 0.4) < 0.001)
            #expect(!context.evaluateScript("video.muted").toBool())
        }
    }

    @Test("The document-start guard synchronizes the YouTube player API")
    func audioGuardSynchronizesPlayerAPI() throws {
        let context = try #require(JSContext())
        context.evaluateScript(Self.mediaHarness)
        context.evaluateScript(
            """
            moviePlayer = {
                volume: 73,
                muted: false,
                getVolume: function() { return this.volume; },
                setVolume: function(value) { this.volume = value; },
                isMuted: function() { return this.muted; },
                mute: function() { this.muted = true; },
                unMute: function() { this.muted = false; }
            };
            """
        )
        context.evaluateScript(YouTubeWatchWebView.pageBootstrapScript(
            targetVolume: 0,
            documentGeneration: 1
        ))

        #expect(context.evaluateScript("moviePlayer.volume").toInt32() == 0)
        #expect(context.evaluateScript("moviePlayer.muted").toBool())
    }

    @Test("A native volume change reuses the document-start guard")
    func updatedTargetReusesAudioGuard() throws {
        let context = try #require(JSContext())
        context.evaluateScript(Self.mediaHarness)
        context.evaluateScript(YouTubeWatchWebView.pageBootstrapScript(
            targetVolume: 0,
            documentGeneration: 1
        ))
        context.evaluateScript(
            "video = new HTMLMediaElement(); video.play(); window.__kasetTargetVolume = 0.4; window.__kasetApplyTargetVolumeToAllMedia = function() { window.__kasetApplyTargetVolume(video); }; window.__kasetApplyTargetVolumeToAllMedia();"
        )

        #expect(abs(context.evaluateScript("video.volume").toDouble() - 0.4) < 0.001)
        #expect(!context.evaluateScript("video.muted").toBool())
    }

    @Test("The audio guard is installed at document start")
    func audioGuardUsesDocumentStartInjection() throws {
        let contentController = WKUserContentController()
        YouTubeWatchWebView.shared.installUserScripts(
            on: contentController,
            targetVolume: 0,
            documentGeneration: 1
        )

        let bootstrap = try #require(contentController.userScripts.first)
        #expect(bootstrap.injectionTime == .atDocumentStart)
        #expect(bootstrap.isForMainFrameOnly)
        #expect(bootstrap.source.contains("__kasetApplyTargetVolume"))
        #expect(bootstrap.source.contains("HTMLMediaElement"))
    }

    private static let mediaHarness = """
    var audibleStartCount = 0;
    var volumeAtPlay = null;
    var mutedAtPlay = null;
    var audibleStateTransitionCount = 0;
    var queuedVolumeChangeTargets = [];
    var documentListeners = {};
    var moviePlayer = null;

    function HTMLMediaElement() {
        this._volume = 0.73;
        this._muted = false;
        this.paused = true;
        this.readyState = 0;
    }
    function recordMediaState(media) {
        if (!media.paused && !media.muted && media.volume > 0) {
            audibleStateTransitionCount += 1;
        }
    }
    Object.defineProperty(HTMLMediaElement.prototype, 'volume', {
        configurable: true,
        get: function() { return this._volume; },
        set: function(value) {
            this._volume = value;
            recordMediaState(this);
            queuedVolumeChangeTargets.push(this);
        }
    });
    Object.defineProperty(HTMLMediaElement.prototype, 'muted', {
        configurable: true,
        get: function() { return this._muted; },
        set: function(value) {
            this._muted = value;
            recordMediaState(this);
            queuedVolumeChangeTargets.push(this);
        }
    });
    HTMLMediaElement.prototype.play = function() {
        volumeAtPlay = this.volume;
        mutedAtPlay = this.muted;
        if (!this.muted && this.volume > 0) { audibleStartCount += 1; }
        this.paused = false;
        return true;
    };

    var document = {
        documentElement: {},
        addEventListener: function(name, listener) { documentListeners[name] = listener; },
        querySelectorAll: function() { return []; },
        getElementById: function(id) { return id === 'movie_player' ? moviePlayer : null; }
    };
    var mutationCallback = null;
    function MutationObserver(callback) {
        mutationCallback = callback;
        this.observe = function() {};
        this.disconnect = function() {};
    }

    var window = globalThis;
    window.location = { search: '', hash: '' };
    window.webkit = {
        messageHandlers: {
            youtubePlayer: { postMessage: function() {} }
        }
    };
    """
}
