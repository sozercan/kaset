import JavaScriptCore
@testable import Kaset

// MARK: - MusicPlaybackObserverTestContext

enum MusicPlaybackObserverTestContext {
    static func make() -> JSContext {
        let context = JSContext()!
        context.evaluateScript(
            """
            var messages = [];
            var listeners = {};
            function addListener(name, callback) {
                if (!listeners[name]) listeners[name] = [];
                listeners[name].push(callback);
            }
            function dispatch(name) {
                (listeners[name] || []).forEach(function(callback) { callback({ currentTarget: video }); });
            }
            var scheduledTimeouts = [];
            function setTimeout(callback, delay) { scheduledTimeouts.push({ callback: callback, delay: delay }); return scheduledTimeouts.length; }
            function runTimeout(delay) {
                for (var index = 0; index < scheduledTimeouts.length; index += 1) {
                    if (scheduledTimeouts[index].delay !== delay) continue;
                    scheduledTimeouts.splice(index, 1)[0].callback();
                    return true;
                }
                return false;
            }
            function clearTimeout() {}
            function setInterval() { return 1; }
            function clearInterval() {}
            function MutationObserver() { this.observe = function() {}; }

            var currentDataVideoId = 'v1';
            var currentDataArtist = 'Artist';
            var video = {
                paused: false,
                ended: false,
                currentSrc: 'https://media.example/v1',
                src: '',
                currentTime: 179,
                duration: 180,
                readyState: 4,
                volume: 1,
                webkitCurrentPlaybackTargetIsWireless: false,
                addEventListener: addListener,
                pause: function() { this.paused = true; },
                play: function() { this.paused = false; }
            };
            var player = {
                playerApi: {
                    getVideoData: function() {
                        return {
                            video_id: currentDataVideoId,
                            title: currentDataVideoId,
                            author: currentDataArtist
                        };
                    },
                    setVolume: function() {}
                }
            };
            var moviePlayer = {
                classList: { contains: function() { return false; } },
                getVideoData: function() { return { video_id: currentDataVideoId }; },
                setVolume: function() {}
            };
            var playerBar = {};
            var progressBar = {
                getAttribute: function(name) { return name === 'value' ? '179' : '180'; }
            };
            var titleElement = { textContent: 'v1' };
            var artistElement = { textContent: 'Artist' };
            var document = {
                readyState: 'complete',
                body: {},
                addEventListener: function() {},
                getElementById: function(id) { return id === 'movie_player' ? moviePlayer : null; },
                querySelectorAll: function() { return []; },
                querySelector: function(selector) {
                    if (selector === 'video') return video;
                    if (selector === 'ytmusic-player') return player;
                    if (selector === 'ytmusic-player-bar') return playerBar;
                    if (selector === '#progress-bar') return progressBar;
                    if (selector === '.ytmusic-player-bar.title') return titleElement;
                    if (selector === '.ytmusic-player-bar.byline') return artistElement;
                    return null;
                }
            };
            var window = globalThis;
            window.location = { href: 'https://music.youtube.com/watch?v=v1' };
            window.__kasetDocumentGeneration = 7;
            window.__kasetTargetVolume = 1;
            window.__kasetAutoplayPending = false;
            window.__kasetPlaybackSuppressed = false;
            window.webkit = {
                messageHandlers: {
                    singletonPlayer: {
                        postMessage: function(message) { messages.push(message); }
                    }
                }
            };
            """
        )
        context.evaluateScript(SingletonPlayerWebView.observerScript)
        return context
    }
}
