/// Ad signals shared by the YouTube and YouTube Music playback bridges.
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
                    // Player type 2 is ad media. Passing true also includes
                    // server-stitched segments when supported by the player.
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
            // Match the bridges' metadata preference: Music API, then movie player.
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
            // Ad-end signals can precede the return of content media. Share the
            // known creative ID with end-event and recovery-seek scripts too.
            const adVideoId = window.__kasetAdVideoId || '';
            const video = document.querySelector('#movie_player video') || document.querySelector('video');
            const boundVideoId = video && video.__kasetBoundVideoId;
            // Metadata can return before the physical content occurrence does.
            const isAdCreative = adVideoId !== ''
                && adVideoId !== contentVideoId
                && (!videoId || videoId === adVideoId || boundVideoId === adVideoId);
            if (!isAd && !isAdCreative) delete window.__kasetAdVideoId;
            return isAd || isAdCreative;
        }
        """
    }

    /// Returns a refresh hook for the bridges' existing player-attachment paths.
    /// Watches only the player class and ad events; it adds no polling timer.
    nonisolated static var observation: String {
        """
        function observeAdStateChanges(onChange) {
            const events = ['onAdStart', 'onAdEnd', 'onAdStateChange'];
            let observedPlayer = null;
            let classObserver = null;
            let observedAPIs = [];
            let lastIsAd = isAdShowing();

            function reportChange() {
                const isAd = isAdShowing();
                if (isAd === lastIsAd) return;
                lastIsAd = isAd;
                onChange();
            }

            function reportAdEvent() {
                // Media events can report an ad between observer callbacks.
                // Always sample explicit ad events so an end is not lost.
                lastIsAd = isAdShowing();
                onChange();
            }

            return function refreshAdObserver() {
                const player = document.getElementById('movie_player');
                if (player !== observedPlayer) {
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

                const apis = adPlayerAPIs().filter(function(api) {
                    // A bare player div already has DOM addEventListener.
                    // Wait for YouTube's API before subscribing to player events.
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
                reportChange();
            };
        }
        """
    }
}
