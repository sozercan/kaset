// MARK: - Playback Audio Quality Scripts

extension SingletonPlayerWebView {
    static func playbackAudioQualityBootstrapScript(
        quality: SettingsManager.PlaybackAudioQuality
    ) -> String {
        """
        (function() {
            try {
                localStorage.setItem('kasetPlaybackAudioQuality', '\(quality.rawValue)');
            } catch (e) {}
            window.__kasetPlaybackAudioQuality = '\(quality.rawValue)';
        })();
        """
    }

    static func playbackAudioQualitySyncScript(
        quality: SettingsManager.PlaybackAudioQuality
    ) -> String {
        """
        (function() {
            try {
                localStorage.setItem('kasetPlaybackAudioQuality', '\(quality.rawValue)');
            } catch (e) {}
            window.__kasetPlaybackAudioQuality = '\(quality.rawValue)';
            if (typeof window.__kasetApplyPlaybackAudioQuality === 'function') {
                window.__kasetApplyPlaybackAudioQuality();
            }
        })();
        """
    }

    static var playbackAudioQualityOverrideScript: String {
        """
        (function() {
            function normalizedQuality(value) {
                switch (value) {
                case 'low':
                case 'normal':
                case 'high':
                case 'auto':
                    return value;
                default:
                    return 'auto';
                }
            }

            function currentQuality() {
                if (typeof window.__kasetPlaybackAudioQuality === 'string') {
                    return normalizedQuality(window.__kasetPlaybackAudioQuality);
                }

                try {
                    return normalizedQuality(localStorage.getItem('kasetPlaybackAudioQuality'));
                } catch (e) {
                    return 'auto';
                }
            }

            function youtubeAudioQualityValue(quality) {
                switch (quality) {
                case 'low':
                    return 'AUDIO_QUALITY_LOW';
                case 'normal':
                    return 'AUDIO_QUALITY_MEDIUM';
                case 'high':
                    return 'AUDIO_QUALITY_HIGH';
                case 'auto':
                default:
                    return 'AUDIO_QUALITY_AUTO';
                }
            }

            function youtubePlaybackQualityValue(quality) {
                switch (quality) {
                case 'low':
                    return 'small';
                case 'normal':
                    return 'medium';
                case 'high':
                    return 'hd720';
                case 'auto':
                default:
                    return 'auto';
                }
            }

            function callIfFunction(target, name, args) {
                try {
                    if (target && typeof target[name] === 'function') {
                        target[name].apply(target, args);
                        return true;
                    }
                } catch (e) {}
                return false;
            }

            function applyToPlayerApi(playerApi, quality) {
                var applied = false;
                var audioQuality = youtubeAudioQualityValue(quality);
                var playbackQuality = youtubePlaybackQualityValue(quality);

                applied = callIfFunction(playerApi, 'setAudioQuality', [audioQuality]) || applied;
                applied = callIfFunction(playerApi, 'setPlaybackQuality', [playbackQuality]) || applied;

                if (quality === 'auto') {
                    applied = callIfFunction(playerApi, 'setPlaybackQualityRange', []) || applied;
                } else {
                    applied = callIfFunction(
                        playerApi,
                        'setPlaybackQualityRange',
                        [playbackQuality, playbackQuality]
                    ) || applied;
                }

                try {
                    if (playerApi && typeof playerApi.setOption === 'function') {
                        [
                            ['audio', 'quality', audioQuality],
                            ['audio', 'audioQuality', audioQuality],
                            ['player', 'audioQuality', audioQuality],
                            ['player', 'audio_quality', audioQuality],
                            ['playback', 'audioQuality', audioQuality],
                            ['playback', 'audio_quality', audioQuality]
                        ].forEach(function(args) {
                            try {
                                playerApi.setOption(args[0], args[1], args[2]);
                                applied = true;
                            } catch (e) {}
                        });
                    }
                } catch (e) {}

                return applied;
            }

            function candidatePlayers() {
                var players = [];

                try {
                    var ytmusicPlayer = document.querySelector('ytmusic-player');
                    if (ytmusicPlayer) {
                        players.push(ytmusicPlayer);
                        if (ytmusicPlayer.playerApi) {
                            players.push(ytmusicPlayer.playerApi);
                        }
                    }
                } catch (e) {}

                try {
                    var moviePlayer = document.getElementById('movie_player');
                    if (moviePlayer) {
                        players.push(moviePlayer);
                    }
                } catch (e) {}

                try {
                    if (window.yt && window.yt.player) {
                        players.push(window.yt.player);
                    }
                } catch (e) {}

                return players;
            }

            window.__kasetApplyPlaybackAudioQuality = function() {
                var quality = currentQuality();
                window.__kasetPlaybackAudioQuality = quality;

                var applied = false;
                candidatePlayers().forEach(function(player) {
                    applied = applyToPlayerApi(player, quality) || applied;
                });

                return applied;
            };

            var applyScheduled = false;

            function applyNow() {
                applyScheduled = false;
                try {
                    window.__kasetApplyPlaybackAudioQuality();
                } catch (e) {}
            }

            function scheduleApply() {
                if (applyScheduled) {
                    return;
                }

                applyScheduled = true;

                try {
                    if (typeof requestAnimationFrame === 'function') {
                        requestAnimationFrame(applyNow);
                    } else if (typeof setTimeout === 'function') {
                        setTimeout(applyNow, 0);
                    } else {
                        applyNow();
                    }
                } catch (e) {
                    applyNow();
                }
            }

            applyNow();

            function attachVideoListeners() {
                var v = document.querySelector('video');
                if (!v || v.__kasetAudioQualityAttached) return;
                v.__kasetAudioQualityAttached = true;
                ['loadedmetadata', 'loadeddata', 'canplay', 'playing', 'emptied']
                    .forEach(function(eventName) {
                        v.addEventListener(eventName, scheduleApply);
                    });
            }

            attachVideoListeners();

            try {
                new MutationObserver(function() {
                    attachVideoListeners();
                    scheduleApply();
                }).observe(document.documentElement, { childList: true, subtree: true });
            } catch (e) {}
        })();
        """
    }
}
