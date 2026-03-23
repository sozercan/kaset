import Foundation
import WebKit

// MARK: - AdBlockService

/// Blocks YouTube Music advertisements using deep API-response interception
/// and JavaScript injection.
///
/// ## Why URL blocking alone doesn't work
///
/// YouTube Music serves ads **inline** through its own API responses
/// (`ytInitialPlayerResponse`, `/youtubei/v1/player`, `/youtubei/v1/next`),
/// not via separate ad-serving domains.  The video ad streams come from the
/// same `googlevideo.com` endpoints as regular music.  URL-level blocking
/// cannot distinguish ad streams from music streams.
///
/// ## Strategy (4 layers)
///
/// 1. **`ytInitialPlayerResponse` interception + fetch/XHR patching** (`atDocumentStart`)
///    Intercepts the moment YouTube sets `ytInitialPlayerResponse` / `ytInitialData`
///    on `window` and strips all ad-related keys.  Also wraps `fetch()` and
///    `XMLHttpRequest` to strip ad data from subsequent SPA API calls.
///
/// 2. **CSS cosmetic hiding** (`atDocumentStart`)
///    Hides residual ad UI elements, premium upsell banners, popups.
///
/// 3. **Player API neuterisation + fallback ad-skipper** (`atDocumentEnd`)
///    Hooks into `playerApi` to make ad methods no-ops.  MutationObserver +
///    polling fallback instantly skips any ad that slips through.
///
/// 4. **Simplified WKContentRuleList** (network level)
///    Only blocks truly separate tracking / analytics domains.
@MainActor
final class AdBlockService {
    static let shared = AdBlockService()

    private let logger = DiagnosticsLogger.player
    private var contentRuleList: WKContentRuleList?
    private var isInitialized = false

    private init() {}

    // MARK: - Public API

    /// Compiles the content-blocking rule list once.  Call early (e.g. at app launch).
    func initialize() async {
        guard !self.isInitialized else { return }
        self.isInitialized = true

        self.logger.info("AdBlockService: compiling content-blocking rules …")

        do {
            let ruleList = try await WKContentRuleListStore.default()
                .compileContentRuleList(
                    forIdentifier: "kaset-adblocker-v2",
                    encodedContentRuleList: Self.contentBlockerRulesJSON
                )
            self.contentRuleList = ruleList
            self.logger.info("AdBlockService: content-blocking rules compiled ✓")
        } catch {
            self.logger.error("AdBlockService: failed to compile rules – \(error.localizedDescription)")
        }
    }

    /// Applies all ad-blocking layers to a `WKWebViewConfiguration` **before** the
    /// WebView is created.
    func configure(_ configuration: WKWebViewConfiguration) {
        let ucc = configuration.userContentController

        // 1. Network-level blocking (simplified – only tracking domains)
        if let ruleList = self.contentRuleList {
            ucc.add(ruleList)
        }

        // 2. API response interception (MUST be atDocumentStart, before YT scripts run)
        ucc.addUserScript(WKUserScript(
            source: Self.apiInterceptScript,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        ))

        // 3. CSS cosmetic hiding (atDocumentStart so elements are hidden instantly)
        ucc.addUserScript(WKUserScript(
            source: Self.cosmeticHidingCSS,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        ))

        // 4. Player API neuterisation + fallback skipper (atDocumentEnd, DOM must be ready)
        ucc.addUserScript(WKUserScript(
            source: Self.playerNeuterScript,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        ))
    }

    // MARK: - Layer 1: API Response Interception (atDocumentStart)

    private static let apiInterceptScript: String = """
    (function() {
        'use strict';

        // Ad-related keys to strip from YouTube API responses
        const AD_KEYS = [
            'playerAds',
            'adPlacements',
            'adSlots',
            'adBreakParams',
            'adBreakHeartbeatParams',
            'ads',
            'adParams',
            'adPlaybackElapsedMs',
            'instreamAdPlayerOverlayRenderer',
            'adLayoutLoggingData',
            'linearAdSequenceRenderer',
            'instreamAdContentRenderer',
        ];

        const TRACKING_KEYS_TO_NEUTER = [
            'enableServerFallbackOnError',
        ];

        function stripAds(obj) {
            if (!obj || typeof obj !== 'object') return obj;
            if (Array.isArray(obj)) {
                for (let i = 0; i < obj.length; i++) stripAds(obj[i]);
                return obj;
            }
            for (const key of AD_KEYS) {
                if (key in obj) delete obj[key];
            }
            if (obj.playbackTracking) {
                for (const key of TRACKING_KEYS_TO_NEUTER) {
                    delete obj.playbackTracking[key];
                }
            }
            if (obj.adPlacementConfig) delete obj.adPlacementConfig;
            for (const key of Object.keys(obj)) {
                const val = obj[key];
                if (val && typeof val === 'object') {
                    if (key === 'contents' && Array.isArray(val)) {
                        obj[key] = val.filter(item => {
                            const ks = Object.keys(item);
                            return !ks.some(k =>
                                k.toLowerCase().includes('adslot') ||
                                k.toLowerCase().includes('adbreak') ||
                                k === 'promotedSparklesWebRenderer' ||
                                k === 'adSlotRenderer'
                            );
                        });
                    }
                    stripAds(val);
                }
            }
            return obj;
        }

        // 1A: Intercept ytInitialPlayerResponse & ytInitialData
        function interceptGlobal(name) {
            let _value = window[name];
            try {
                Object.defineProperty(window, name, {
                    configurable: true,
                    get() { return _value; },
                    set(v) {
                        if (v && typeof v === 'object') stripAds(v);
                        _value = v;
                    }
                });
            } catch (e) {}
        }

        interceptGlobal('ytInitialPlayerResponse');
        interceptGlobal('ytInitialData');

        // 1B: Patch fetch() to strip ad data from API responses
        const YT_API_PATHS = [
            '/youtubei/v1/player',
            '/youtubei/v1/next',
            '/youtubei/v1/browse',
            '/youtubei/v1/music/get_queue',
        ];

        function isYTApi(url) {
            if (!url) return false;
            const s = typeof url === 'string' ? url : (url.url || url.toString());
            return YT_API_PATHS.some(p => s.includes(p));
        }

        const origFetch = window.fetch;
        window.fetch = async function(...args) {
            const resp = await origFetch.apply(this, args);
            const url = args[0];
            if (!isYTApi(typeof url === 'object' && url.url ? url.url : url)) return resp;
            try {
                const clone = resp.clone();
                const text = await clone.text();
                let json;
                try { json = JSON.parse(text); } catch { return resp; }
                stripAds(json);
                return new Response(JSON.stringify(json), {
                    status: resp.status,
                    statusText: resp.statusText,
                    headers: resp.headers,
                });
            } catch (e) { return resp; }
        };

        // 1C: Patch XMLHttpRequest
        const XHR = XMLHttpRequest.prototype;
        const origOpen = XHR.open;
        const origSend = XHR.send;

        XHR.open = function(method, url, ...rest) {
            this._kasetUrl = url;
            return origOpen.call(this, method, url, ...rest);
        };

        XHR.send = function(...args) {
            if (isYTApi(this._kasetUrl)) {
                this.addEventListener('readystatechange', function() {
                    if (this.readyState === 4 && this.status === 200) {
                        try {
                            const json = JSON.parse(this.responseText);
                            stripAds(json);
                            const cleaned = JSON.stringify(json);
                            Object.defineProperty(this, 'responseText', {
                                value: cleaned, writable: false, configurable: true,
                            });
                            Object.defineProperty(this, 'response', {
                                value: cleaned, writable: false, configurable: true,
                            });
                        } catch (e) {}
                    }
                });
            }
            return origSend.apply(this, args);
        };
    })();
    """

    // MARK: - Layer 2: CSS Cosmetic Hiding (atDocumentStart)

    private static let cosmeticHidingCSS: String = """
    (function() {
        'use strict';
        const style = document.createElement('style');
        style.textContent = `
            .ytp-ad-module,
            .ytp-ad-overlay-container,
            .ytp-ad-text-overlay,
            .ytp-ad-skip-button-container,
            .ytp-ad-player-overlay-layout,
            .ytp-ad-image-overlay,
            .ytp-ad-action-interstitial,
            .ytp-ad-feedback-dialog-container,
            .video-ads,
            #player-ads,
            #masthead-ad,
            .ad-container {
                display: none !important;
            }
            ytmusic-mealbar-promo-renderer,
            ytmusic-statement-banner-renderer,
            ytmusic-enforcement-message-renderer,
            ytmusic-enforcements-message-renderer,
            ytmusic-you-there-renderer,
            ytmusic-upsell-dialog-renderer,
            ytmusic-brand-button-renderer,
            tp-yt-paper-dialog:has(ytmusic-mealbar-promo-renderer),
            tp-yt-paper-dialog:has(ytmusic-enforcement-message-renderer),
            .ytmusic-popup-container:has(.ytmusic-mealbar-promo-renderer) {
                display: none !important;
            }
            .upgrade-button,
            ytmusic-pivot-bar-item-renderer[tab-id="SPunlimited"],
            a[href*="youtube.com/premium"] {
                display: none !important;
            }
        `;
        (document.head || document.documentElement).appendChild(style);
    })();
    """

    // MARK: - Layer 3: Player API Neuterisation + Fallback Skipper (atDocumentEnd)

    private static let playerNeuterScript: String = """
    (function() {
        'use strict';

        function neuterPlayerAPI() {
            const player = document.getElementById('movie_player');
            if (!player) return false;

            if (typeof player.getAdState === 'function') {
                player.getAdState = () => -1;
            }

            const adMethods = ['loadVideoByPlayerVars', 'cueVideoByPlayerVars', 'loadModule'];
            for (const method of adMethods) {
                if (typeof player[method] === 'function') {
                    const orig = player[method].bind(player);
                    player[method] = function(vars) {
                        if (vars && (vars.ad_type || vars.ad3_module || vars.ad_tag)) return;
                        return orig(vars);
                    };
                }
            }

            const ytPlayer = document.querySelector('ytmusic-player');
            if (ytPlayer && ytPlayer.playerApi) {
                if (typeof ytPlayer.playerApi.getAdState === 'function') {
                    ytPlayer.playerApi.getAdState = () => -1;
                }
            }
            return true;
        }

        function isAdPlaying() {
            const player = document.getElementById('movie_player') ||
                           document.querySelector('ytmusic-player');
            if (player && player.classList.contains('ad-showing')) return true;
            const adOverlay = document.querySelector('.ytp-ad-player-overlay-layout');
            if (adOverlay && adOverlay.offsetParent !== null) return true;
            const adModule = document.querySelector('.ytp-ad-module');
            if (adModule && adModule.children.length > 0) return true;
            return false;
        }

        function skipAdImmediately() {
            if (!isAdPlaying()) return;

            const video = document.querySelector('video');

            // Try skip buttons first
            const skipSels = [
                '.ytp-ad-skip-button',
                '.ytp-ad-skip-button-modern',
                '.ytp-skip-ad-button',
                'button.ytp-ad-skip-button',
                '.ytp-ad-skip-button-container button',
                '.videoAdUiSkipButton',
                '[id^="skip-button"] button',
            ];
            for (const sel of skipSels) {
                const btn = document.querySelector(sel);
                if (btn) { btn.click(); return; }
            }

            // Instantly jump to end
            if (video && video.duration && isFinite(video.duration) && video.duration > 0) {
                video.muted = true;
                video.currentTime = video.duration;
            }
        }

        function restoreAfterAd() {
            if (isAdPlaying()) return;
            const video = document.querySelector('video');
            if (video && video.muted) {
                video.muted = false;
                video.playbackRate = 1;
            }
        }

        function dismissOverlays() {
            const promoClose = document.querySelector(
                'ytmusic-mealbar-promo-renderer #dismiss-button, ' +
                'ytmusic-mealbar-promo-renderer .dismiss-button'
            );
            if (promoClose) promoClose.click();

            const stillListening = document.querySelector(
                'ytmusic-you-there-renderer button'
            );
            if (stillListening) stillListening.click();

            const popupDismiss = document.querySelector(
                'tp-yt-paper-dialog .dismiss-button, ' +
                'tp-yt-paper-dialog [slot="dismiss-button"]'
            );
            if (popupDismiss) popupDismiss.click();
        }

        function observePlayer() {
            const player = document.getElementById('movie_player') ||
                           document.querySelector('ytmusic-player');
            if (!player) { setTimeout(observePlayer, 500); return; }

            neuterPlayerAPI();

            const observer = new MutationObserver(() => {
                if (isAdPlaying()) skipAdImmediately();
                else restoreAfterAd();
            });

            observer.observe(player, {
                attributes: true,
                attributeFilter: ['class'],
                subtree: false,
            });

            const adModule = document.querySelector('.ytp-ad-module');
            if (adModule) {
                observer.observe(adModule, { childList: true, subtree: true });
            }
        }

        // Periodic fallback
        setInterval(() => {
            skipAdImmediately();
            restoreAfterAd();
            dismissOverlays();
        }, 500);

        // Re-neuterise periodically (YouTube may recreate the player)
        setInterval(neuterPlayerAPI, 3000);

        if (document.readyState === 'loading') {
            document.addEventListener('DOMContentLoaded', observePlayer);
        } else {
            observePlayer();
        }
    })();
    """

    // MARK: - Layer 4: Simplified WKContentRuleList (Network Level)

    private static let contentBlockerRulesJSON: String = {
        func blockRule(_ urlFilter: String) -> [String: Any] {
            [
                "trigger": ["url-filter": urlFilter],
                "action": ["type": "block"],
            ]
        }

        let rules: [[String: Any]] = [
            blockRule("googlesyndication\\.com"),
            blockRule("doubleclick\\.net"),
            blockRule("googleadservices\\.com"),
            blockRule("google-analytics\\.com"),
            blockRule("googletagmanager\\.com"),
            blockRule("googletagservices\\.com"),
            blockRule("adservice\\.google\\.com"),
            blockRule("pagead2\\.googlesyndication\\.com"),
            blockRule("securepubads\\.g\\.doubleclick\\.net"),
            blockRule("ad\\.youtube\\.com"),
            blockRule("ads\\.youtube\\.com"),
        ]

        guard let data = try? JSONSerialization.data(withJSONObject: rules),
              let json = String(data: data, encoding: .utf8)
        else {
            return """
            [{"trigger":{"url-filter":"googlesyndication\\\\.com"},"action":{"type":"block"}},\
            {"trigger":{"url-filter":"doubleclick\\\\.net"},"action":{"type":"block"}}]
            """
        }
        return json
    }()
}
