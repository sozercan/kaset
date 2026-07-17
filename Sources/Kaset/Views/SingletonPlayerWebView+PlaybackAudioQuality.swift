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
            function callIfFunction(target, name, args) {
                try {
                    if (target && typeof target[name] === 'function') {
                        target[name].apply(target, args);
                        return true;
                    }
                } catch (e) {}
                return false;
            }

            var lastAudioQualityStatsKey = '';
            var lastAudioQualityStatsTime = 0;
            var AUDIO_QUALITY_STATS_MIN_INTERVAL_MS = 30000;

            function safePrimitive(value) {
                if (value === null || typeof value === 'undefined') return null;

                var type = typeof value;
                if (type === 'string') {
                    return value.length > 160 ? value.substring(0, 160) : value;
                }
                if (type === 'number') {
                    return isFinite(value) ? value : null;
                }
                if (type === 'boolean') {
                    return value;
                }

                return null;
            }

            function safePrimitiveArray(value) {
                if (!value || !Array.isArray(value)) return null;

                var result = [];
                for (var i = 0; i < value.length && result.length < 12; i += 1) {
                    var safe = safePrimitive(value[i]);
                    if (safe !== null) {
                        result.push(safe);
                    }
                }

                return result.length > 0 ? result : null;
            }

            function readFunctionValue(target, names) {
                for (var i = 0; i < names.length; i += 1) {
                    var name = names[i];
                    try {
                        if (target && typeof target[name] === 'function') {
                            var value = target[name]();
                            if (value !== null && typeof value !== 'undefined') {
                                return {
                                    name: name,
                                    value: value
                                };
                            }
                        }
                    } catch (e) {}
                }

                return null;
            }

            function readObjectProperty(target, names) {
                for (var i = 0; i < names.length; i += 1) {
                    var name = names[i];
                    try {
                        if (target && target[name] !== null && typeof target[name] !== 'undefined') {
                            return {
                                name: name,
                                value: target[name]
                            };
                        }
                    } catch (e) {}
                }

                return null;
            }

            function isAllowedStatsKey(key) {
                if (!key || typeof key !== 'string') return false;

                var exact = {
                    afmt: true,
                    audioFormat: true,
                    audio_format: true,
                    audioCodec: true,
                    audioCodecs: true,
                    audioItag: true,
                    audioMimeType: true,
                    audioQuality: true,
                    audioBitrate: true,
                    bitrate: true,
                    codec: true,
                    codecs: true,
                    debug_audioFormat: true,
                    debug_audioQuality: true,
                    debug_playbackQuality: true,
                    itag: true,
                    mimeType: true,
                    quality: true
                };

                if (exact[key]) return true;

                var lower = key.toLowerCase();
                return lower.indexOf('audio') >= 0
                    && (
                        lower.indexOf('bitrate') >= 0
                        || lower.indexOf('codec') >= 0
                        || lower.indexOf('format') >= 0
                        || lower.indexOf('itag') >= 0
                        || lower.indexOf('mime') >= 0
                        || lower.indexOf('quality') >= 0
                    );
            }

            function sanitizedStatsForNerds(rawStats) {
                var stats = {};
                if (!rawStats || typeof rawStats !== 'object') return stats;

                try {
                    var keys = Object.keys(rawStats);
                    for (var i = 0; i < keys.length && Object.keys(stats).length < 12; i += 1) {
                        var key = keys[i];
                        if (!isAllowedStatsKey(key)) continue;

                        var value = rawStats[key];
                        var safe = safePrimitive(value);
                        if (safe !== null) {
                            stats[key] = safe;
                            continue;
                        }

                        var safeArray = safePrimitiveArray(value);
                        if (safeArray !== null) {
                            stats[key] = safeArray;
                        }
                    }
                } catch (e) {}

                return stats;
            }

            function audioQualityFromItag(itag) {
                switch (String(itag)) {
                case '139':
                case '249':
                case '250':
                    return 'AUDIO_QUALITY_LOW';
                case '140':
                case '251':
                    return 'AUDIO_QUALITY_MEDIUM';
                case '141':
                    return 'AUDIO_QUALITY_HIGH';
                default:
                    return null;
                }
            }

            function inferredAudioQualityFromPrimitive(value) {
                var text = String(value);
                var token = '';

                function observedQualityFromToken(candidate) {
                    if (candidate.length < 2 || candidate.length > 3) return null;

                    var quality = audioQualityFromItag(candidate);
                    if (!quality) return null;

                    return {
                        quality: quality,
                        itag: candidate
                    };
                }

                for (var i = 0; i <= text.length; i += 1) {
                    var character = i < text.length ? text.charAt(i) : '';
                    if (character >= '0' && character <= '9') {
                        token += character;
                        continue;
                    }

                    if (token.length > 0) {
                        var inferred = observedQualityFromToken(token);
                        if (inferred) return inferred;
                        token = '';
                    }
                }

                return null;
            }

            function inferredAudioQualityFromValue(value) {
                var safe = safePrimitive(value);
                if (safe !== null) {
                    return inferredAudioQualityFromPrimitive(safe);
                }

                var safeArray = safePrimitiveArray(value);
                if (safeArray !== null) {
                    for (var i = 0; i < safeArray.length; i += 1) {
                        var inferred = inferredAudioQualityFromPrimitive(safeArray[i]);
                        if (inferred) return inferred;
                    }
                }

                return null;
            }

            function inferredAudioQualityFromStats(stats) {
                var keys = [
                    'itag',
                    'audioItag',
                    'afmt',
                    'audioFormat',
                    'audio_format',
                    'debug_audioFormat',
                    'codec',
                    'codecs',
                    'audioCodec',
                    'audioCodecs'
                ];

                for (var i = 0; i < keys.length; i += 1) {
                    var key = keys[i];
                    if (!stats || stats[key] === null || typeof stats[key] === 'undefined') continue;

                    var inferred = inferredAudioQualityFromValue(stats[key]);
                    if (inferred) {
                        return {
                            quality: inferred.quality,
                            itag: inferred.itag,
                            source: 'statsForNerds.' + key + '.itag'
                        };
                    }
                }

                return null;
            }

            function applyToPlayerApi(playerApi, quality) {
                var applied = false;
                var audioQuality = youtubeAudioQualityValue(quality);
                applied = callIfFunction(playerApi, 'setAudioQuality', [audioQuality]) || applied;

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

                function addPlayer(target, source) {
                    if (target) {
                        players.push({
                            target: target,
                            source: source
                        });
                    }
                }

                try {
                    var ytmusicPlayer = document.querySelector('ytmusic-player');
                    if (ytmusicPlayer) {
                        addPlayer(ytmusicPlayer, 'ytmusic-player');
                        if (ytmusicPlayer.playerApi) {
                            addPlayer(ytmusicPlayer.playerApi, 'ytmusic-player.playerApi');
                        }
                    }
                } catch (e) {}

                try {
                    var moviePlayer = document.getElementById('movie_player');
                    if (moviePlayer) {
                        addPlayer(moviePlayer, 'movie_player');
                    }
                } catch (e) {}

                try {
                    if (window.yt && window.yt.player) {
                        addPlayer(window.yt.player, 'window.yt.player');
                    }
                } catch (e) {}

                return players;
            }

            function videoIdFromPlayers(players) {
                for (var i = 0; i < players.length; i += 1) {
                    var entry = players[i];
                    var dataResult = readFunctionValue(entry.target, ['getVideoData']);
                    if (!dataResult || !dataResult.value || typeof dataResult.value !== 'object') continue;

                    var videoId = safePrimitive(
                        dataResult.value.video_id
                        || dataResult.value.videoId
                        || dataResult.value.videoID
                    );
                    if (videoId) return videoId;
                }

                try {
                    if (window.location && window.location.href && typeof URL === 'function') {
                        var url = new URL(window.location.href);
                        return safePrimitive(url.searchParams.get('v')) || '';
                    }
                } catch (e) {}

                return '';
            }

            function collectAudioQualitySnapshot(quality, desired, applied, players) {
                var snapshot = {
                    type: 'PLAYBACK_AUDIO_QUALITY_STATS',
                    documentGeneration: window.__kasetDocumentGeneration,
                    preferred: quality,
                    desired: desired,
                    applied: !!applied,
                    observed: 'unknown',
                    source: 'unavailable',
                    videoId: videoIdFromPlayers(players),
                    available: [],
                    stats: {}
                };

                for (var i = 0; i < players.length; i += 1) {
                    var entry = players[i];

                    if (snapshot.observed === 'unknown') {
                        var observed = readFunctionValue(entry.target, [
                            'getAudioQuality',
                            'getPlaybackAudioQuality',
                            'getPreferredAudioQuality'
                        ]) || readObjectProperty(entry.target, [
                            'audioQuality',
                            'playbackAudioQuality',
                            'preferredAudioQuality'
                        ]);

                        if (observed) {
                            var safeObserved = safePrimitive(observed.value);
                            if (safeObserved !== null) {
                                snapshot.observed = safeObserved;
                                snapshot.source = entry.source + '.' + observed.name;
                            }
                        }
                    }

                    if (snapshot.available.length === 0) {
                        var available = readFunctionValue(entry.target, [
                            'getAvailableAudioQualityLevels',
                            'getAvailableAudioQualities',
                            'getAudioQualityLevels'
                        ]);

                        if (available) {
                            var safeAvailable = safePrimitiveArray(available.value);
                            if (safeAvailable !== null) {
                                snapshot.available = safeAvailable;
                            }
                        }
                    }

                    if (Object.keys(snapshot.stats).length === 0) {
                        var statsResult = readFunctionValue(entry.target, ['getStatsForNerds']);
                        if (statsResult) {
                            snapshot.stats = sanitizedStatsForNerds(statsResult.value);
                        }
                    }
                }

                if (snapshot.observed === 'unknown') {
                    var statsObserved = readObjectProperty(snapshot.stats, [
                        'audioQuality',
                        'debug_audioQuality',
                        'quality',
                        'debug_playbackQuality'
                    ]);
                    if (statsObserved) {
                        var safeStatsObserved = safePrimitive(statsObserved.value);
                        if (safeStatsObserved !== null) {
                            snapshot.observed = safeStatsObserved;
                            snapshot.source = 'statsForNerds.' + statsObserved.name;
                        }
                    }
                }

                if (snapshot.observed === 'unknown') {
                    var inferredStatsObserved = inferredAudioQualityFromStats(snapshot.stats);
                    if (inferredStatsObserved) {
                        snapshot.observed = inferredStatsObserved.quality;
                        snapshot.source = inferredStatsObserved.source;
                        snapshot.observedItag = inferredStatsObserved.itag;
                    }
                }

                return snapshot;
            }

            function postAudioQualityStats(snapshot) {
                try {
                    var handler = window.webkit
                        && window.webkit.messageHandlers
                        && window.webkit.messageHandlers.singletonPlayer;

                    if (!handler || typeof handler.postMessage !== 'function') return;

                    var now = (typeof Date !== 'undefined' && typeof Date.now === 'function')
                        ? Date.now()
                        : 0;
                    var statsKey = [
                        snapshot.preferred,
                        snapshot.desired,
                        snapshot.applied ? 'applied' : 'not-applied',
                        snapshot.observed,
                        snapshot.source,
                        snapshot.videoId,
                        JSON.stringify(snapshot.available || []),
                        JSON.stringify(snapshot.stats || {})
                    ].join('|');

                    if (
                        statsKey === lastAudioQualityStatsKey
                        && now - lastAudioQualityStatsTime < AUDIO_QUALITY_STATS_MIN_INTERVAL_MS
                    ) {
                        return;
                    }

                    handler.postMessage(snapshot);
                    lastAudioQualityStatsKey = statsKey;
                    lastAudioQualityStatsTime = now;
                } catch (e) {}
            }

            window.__kasetApplyPlaybackAudioQuality = function() {
                var quality = currentQuality();
                window.__kasetPlaybackAudioQuality = quality;

                var applied = false;
                var players = candidatePlayers();
                players.forEach(function(entry) {
                    applied = applyToPlayerApi(entry.target, quality) || applied;
                });

                postAudioQualityStats(
                    collectAudioQualitySnapshot(
                        quality,
                        youtubeAudioQualityValue(quality),
                        applied,
                        players
                    )
                );

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
