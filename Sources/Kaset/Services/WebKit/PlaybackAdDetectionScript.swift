enum PlaybackAdDetectionScript {
    nonisolated static var detection: String {
        """
        function adPlayerAPIs() {
            const moviePlayer = document.getElementById('movie_player');
            const musicPlayer = document.querySelector('ytmusic-player');
            const musicAPI = musicPlayer && musicPlayer.playerApi;
            return [moviePlayer, musicAPI].filter(function(api, index, apis) {
                return api && apis.indexOf(api) === index;
            });
        }

        function hasAdPlayerSignal() {
            const moviePlayer = document.getElementById('movie_player');
            if (moviePlayer && moviePlayer.classList
                && (moviePlayer.classList.contains('ad-showing')
                    || moviePlayer.classList.contains('ad-interrupting'))) {
                return true;
            }
            for (const api of adPlayerAPIs()) {
                try {
                    if (typeof api.getPresentingPlayerType === 'function'
                        && api.getPresentingPlayerType(true) === 2) {
                        return true;
                    }
                } catch (e) {}
            }
            return false;
        }

        function isAdShowing() {
            const isAd = hasAdPlayerSignal();
            let contentVideoId = '';
            try {
                contentVideoId = new URL(window.location.href).searchParams.get('v') || '';
            } catch (e) {}

            let videoId = '';
            for (const api of adPlayerAPIs().reverse()) {
                try {
                    const data = typeof api.getVideoData === 'function' ? api.getVideoData() : null;
                    const id = data && (data.video_id || data.videoId);
                    if (typeof id === 'string' && id) {
                        videoId = id;
                        break;
                    }
                } catch (e) {}
            }
            if (isAd && contentVideoId && videoId && videoId !== contentVideoId) {
                window.__kasetAdVideoId = videoId;
            }
            const adVideoId = window.__kasetAdVideoId || '';
            const video = document.querySelector('#movie_player video') || document.querySelector('video');
            const boundVideoId = video && video.__kasetBoundVideoId;
            const awaitingContent = adVideoId !== ''
                && adVideoId !== contentVideoId
                && (videoId !== contentVideoId
                    || (!!boundVideoId && boundVideoId !== contentVideoId));
            if (!isAd && !awaitingContent) delete window.__kasetAdVideoId;
            return isAd || awaitingContent;
        }
        """
    }

    nonisolated static var observation: String {
        """
        function observeAdStateChanges(onChange) {
            const events = ['onAdStart', 'onAdEnd', 'onAdStateChange'];
            let observedPlayer = null;
            let classObserver = null;
            let observedAPIs = [];
            let apiRetryCount = 0;
            let apiRetryTimeoutId = null;
            let lastIsAd = isAdShowing();

            function reportChange() {
                const isAd = isAdShowing();
                if (isAd === lastIsAd) return;
                lastIsAd = isAd;
                onChange();
            }

            function reportAdEvent() {
                lastIsAd = isAdShowing();
                onChange();
            }

            return function refreshAdObserver() {
                const player = document.getElementById('movie_player');
                if (player !== observedPlayer) {
                    apiRetryCount = 0;
                    if (classObserver) classObserver.disconnect();
                    classObserver = null;
                    observedPlayer = player;
                    if (player && typeof MutationObserver === 'function') {
                        classObserver = new MutationObserver(reportChange);
                        classObserver.observe(player, {
                            attributes: true,
                            attributeFilter: ['class']
                        });
                    }
                }

                const candidates = adPlayerAPIs();
                const apis = candidates.filter(function(api) {
                    return typeof api.getPresentingPlayerType === 'function'
                        && typeof api.addEventListener === 'function';
                });
                for (const api of observedAPIs) {
                    if (apis.indexOf(api) !== -1) continue;
                    for (const event of events) {
                        try { api.removeEventListener(event, reportAdEvent); } catch (e) {}
                    }
                }
                for (const api of apis) {
                    if (observedAPIs.indexOf(api) !== -1) continue;
                    for (const event of events) {
                        try { api.addEventListener(event, reportAdEvent); } catch (e) {}
                    }
                }
                observedAPIs = apis;
                const musicPlayer = document.querySelector('ytmusic-player');
                const hasPendingMusicAPI = musicPlayer && !musicPlayer.playerApi;
                if (apis.length === candidates.length && !hasPendingMusicAPI) {
                    apiRetryCount = 0;
                    if (apiRetryTimeoutId !== null) clearTimeout(apiRetryTimeoutId);
                    apiRetryTimeoutId = null;
                } else if (apiRetryTimeoutId === null && apiRetryCount < 20) {
                    apiRetryCount += 1;
                    apiRetryTimeoutId = setTimeout(function() {
                        apiRetryTimeoutId = null;
                        refreshAdObserver();
                    }, 500);
                }
                reportChange();
            };
        }
        """
    }
}
