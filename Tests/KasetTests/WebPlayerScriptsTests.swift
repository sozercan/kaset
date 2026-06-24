import Testing
import WebKit
@testable import Kaset

// MARK: - WebPlayerScriptsTests

/// Locks the output of the shared playback-script builders so the music and
/// YouTube paths that compose from them cannot silently drift. See ADR-0024.
@Suite("WebPlayerScripts", .tags(.service))
@MainActor
struct WebPlayerScriptsTests {
    // MARK: - Volume

    @Test("clampVolume keeps in-range values and clamps out-of-range/non-finite")
    func clampVolume() {
        #expect(WebPlayerScripts.clampVolume(0.5) == 0.5)
        #expect(WebPlayerScripts.clampVolume(0) == 0)
        #expect(WebPlayerScripts.clampVolume(1) == 1)
        #expect(WebPlayerScripts.clampVolume(2.0) == 1.0)
        #expect(WebPlayerScripts.clampVolume(-1) == 0.0)
        #expect(WebPlayerScripts.clampVolume(.nan) == 1.0)
        #expect(WebPlayerScripts.clampVolume(.infinity) == 1.0)
    }

    @Test("targetVolumeBootstrap emits a clamped assignment to __kasetTargetVolume")
    func targetVolumeBootstrap() {
        #expect(WebPlayerScripts.targetVolumeBootstrap(0.25)
            == "window.__kasetTargetVolume = 0.25;")
        // Whole numbers render with a trailing .0 — both observer scripts read
        // this verbatim, and existing contract tests assert "1.0"/"0.0".
        #expect(WebPlayerScripts.targetVolumeBootstrap(2.0)
            == "window.__kasetTargetVolume = 1.0;")
        #expect(WebPlayerScripts.targetVolumeBootstrap(-1)
            == "window.__kasetTargetVolume = 0.0;")
    }

    // MARK: - Video element accessor

    @Test("VideoElement accessor JS matches each origin's DOM")
    func videoElementAccessor() {
        #expect(WebPlayerScripts.VideoElement.ytMusic.accessorJS
            == "document.querySelector('video')")
        #expect(WebPlayerScripts.VideoElement.youTube.accessorJS
            == "document.querySelector('#movie_player video') || document.querySelector('video')")
    }

    // MARK: - Command builders (golden output)

    @Test("play builder targets the element and guards on paused")
    func playBuilder() {
        let expected = """
        (function() {
            const video = document.querySelector('#movie_player video') || document.querySelector('video');
            if (video && video.paused) { video.play(); }
        })();
        """
        #expect(WebPlayerScripts.play(.youTube) == expected)
    }

    @Test("pause builder targets the element and guards on playing")
    func pauseBuilder() {
        let expected = """
        (function() {
            const video = document.querySelector('video');
            if (video && !video.paused) { video.pause(); }
        })();
        """
        #expect(WebPlayerScripts.pause(.ytMusic) == expected)
    }

    @Test("seek builder writes currentTime with the requested time")
    func seekBuilder() {
        let expected = """
        (function() {
            const video = document.querySelector('video');
            if (video) { video.currentTime = 42.0; }
        })();
        """
        #expect(WebPlayerScripts.seek(to: 42.0, element: .ytMusic) == expected)
    }

    // MARK: - Reparenting

    @Test("reparent moves the web view under the container and fills it")
    func reparentMovesAndFills() {
        let webView = WKWebView(frame: .zero)
        let first = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 60))
        let second = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 120))

        webView.reparent(into: first)
        #expect(webView.superview === first)
        #expect(webView.frame == first.bounds)
        #expect(webView.autoresizingMask == [.width, .height])

        webView.reparent(into: second)
        #expect(webView.superview === second)
        #expect(webView.frame == second.bounds)

        // Idempotent: reparenting into the current container is a no-op.
        webView.reparent(into: second)
        #expect(webView.superview === second)
    }
}
