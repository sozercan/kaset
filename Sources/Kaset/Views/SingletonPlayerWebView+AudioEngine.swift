import Foundation
import WebKit

// MARK: - SingletonPlayerWebView Audio Engine

extension SingletonPlayerWebView {
    /// Injected at document start so `window.__kasetAudio` is available before any media elements load.
    static var audioEngineBootstrapScript: String {
        """
        (function() {
            if (window.__kasetAudio) return;

            class KasetAudioEngine {
                constructor() {
                    this.targetVolume = typeof window.__kasetTargetVolume === 'number'
                        ? Math.max(0.0, Math.min(1.0, window.__kasetTargetVolume))
                        : 1.0;
                    this.fadingEnabled = typeof window.__kasetFadingEnabled === 'boolean'
                        ? window.__kasetFadingEnabled
                        : true;
                    this.state = 'idle'; // 'idle' | 'fading_in' | 'fading_out'
                    this.fadeInterval = null;
                    this.isSettingVolume = false;
                    this.isEnforcingVolume = false;
                    this._resetVolumeSettingTimeout = null;
                }

                getVideo() {
                    return document.querySelector('video');
                }

                getMoviePlayer() {
                    return document.getElementById('movie_player');
                }

                getYtPlayer() {
                    return document.querySelector('ytmusic-player');
                }

                attachVideo(video) {
                    if (!video || video.__kasetEngineAttached) return;
                    video.__kasetEngineAttached = true;

                    // When a new song starts loading from network, prime volume to 0 so it never blasts before blooming
                    const primeZeroVolume = () => {
                        if (this.fadingEnabled && this.state !== 'fading_out') {
                            this.applyGain(0.0);
                        }
                    };

                    video.addEventListener('loadstart', primeZeroVolume);
                    video.addEventListener('loadedmetadata', primeZeroVolume);

                    video.addEventListener('play', () => {
                        if (window.__kasetPlaybackSuppressed) {
                            video.pause();
                        }
                    });

                    video.addEventListener('playing', () => {
                        if (window.__kasetPlaybackSuppressed) {
                            video.pause();
                            return;
                        }
                        if (this.fadingEnabled && this.targetVolume > 0 && this.state === 'idle' && !this.isSettingVolume) {
                            this.bloom(350);
                        }
                    });
                }

                setFadingEnabled(enabled) {
                    this.fadingEnabled = !!enabled;
                    window.__kasetFadingEnabled = this.fadingEnabled;
                }

                setTargetVolume(vol) {
                    const clamped = Math.max(0.0, Math.min(1.0, typeof vol === 'number' && Number.isFinite(vol) ? vol : 1.0));
                    this.targetVolume = clamped;
                    window.__kasetTargetVolume = clamped;

                    if (this.state === 'idle') {
                        this.applyGain(clamped);
                    }
                }

                applyGain(vol) {
                    const clamped = Math.max(0.0, Math.min(1.0, vol));
                    this.isSettingVolume = true;
                    window.__kasetIsSettingVolume = true;

                    const video = this.getVideo();
                    if (video) {
                        video.volume = clamped;
                    }

                    const ytVol = Math.round(clamped * 100);
                    const mp = this.getMoviePlayer();
                    if (mp && typeof mp.setVolume === 'function') {
                        mp.setVolume(ytVol);
                    }

                    const yp = this.getYtPlayer();
                    if (yp && yp.playerApi && typeof yp.playerApi.setVolume === 'function') {
                        yp.playerApi.setVolume(ytVol);
                    }

                    if (this.state === 'idle') {
                        if (this._resetVolumeSettingTimeout) {
                            clearTimeout(this._resetVolumeSettingTimeout);
                        }
                        this._resetVolumeSettingTimeout = setTimeout(() => {
                            this.isSettingVolume = false;
                            window.__kasetIsSettingVolume = false;
                            this._resetVolumeSettingTimeout = null;
                        }, 50);
                    }
                }

                cancelFade() {
                    if (this.fadeInterval) {
                        clearInterval(this.fadeInterval);
                        this.fadeInterval = null;
                        window.__kasetFadeInterval = null;
                    }
                    this.state = 'idle';
                    this.isSettingVolume = false;
                    window.__kasetIsSettingVolume = false;
                }

                enforceVolume() {
                    if (this.state !== 'idle' || this.isSettingVolume || this.isEnforcingVolume) {
                        return;
                    }
                    const video = this.getVideo();
                    if (!video) return;

                    const targetVol = this.targetVolume;
                    if (Math.abs(video.volume - targetVol) <= 0.01) return;

                    this.isEnforcingVolume = true;
                    this.applyGain(targetVol);
                    setTimeout(() => {
                        this.isEnforcingVolume = false;
                    }, 50);
                }

                resume(durationMs = 350) {
                    this.cancelFade();

                    window.__kasetAutoplayPending = true;
                    window.__kasetPlaybackSuppressed = false;
                    window.__kasetResumeAdOnly = false;
                    window.__kasetAutoplayAttempts = 0;
                    window.__kasetAutoplayRetryScheduled = false;

                    const video = this.getVideo();
                    const moviePlayer = this.getMoviePlayer();
                    const playBtn = document.querySelector('.play-pause-button.ytmusic-player-bar');

                    if (moviePlayer && typeof moviePlayer.playVideo === 'function') {
                        moviePlayer.playVideo();
                    } else if (playBtn && video && video.paused) {
                        playBtn.click();
                    }
                    if (video && video.paused) {
                        if (typeof window.__kasetAttemptAutoplayRecovery === 'function') {
                            window.__kasetAttemptAutoplayRecovery(video, playBtn);
                        } else {
                            video.play();
                        }
                    }

                    const target = this.targetVolume;

                    if (!this.fadingEnabled || durationMs <= 0) {
                        this.applyGain(target);
                        return 'resumed-instant';
                    }

                    this.state = 'fading_in';
                    this.isSettingVolume = true;
                    window.__kasetIsSettingVolume = true;

                    const currentVol = video ? video.volume : 0.0;
                    const startVol = (currentVol > 0.01 && currentVol < target) ? currentVol : 0.0;
                    this.applyGain(startVol);

                    const startTime = performance.now();
                    this.fadeInterval = setInterval(() => {
                        const elapsed = performance.now() - startTime;
                        const progress = Math.min(1.0, elapsed / durationMs);
                        const factor = Math.pow(progress, 2.2);
                        const currentGain = startVol + (this.targetVolume - startVol) * factor;
                        this.applyGain(currentGain);

                        if (progress >= 1.0) {
                            this.applyGain(this.targetVolume);
                            this.cancelFade();
                        }
                    }, 16);
                    window.__kasetFadeInterval = this.fadeInterval;
                    return 'fading-in';
                }

                pause(durationMs = 350, onComplete = null) {
                    this.cancelFade();

                    window.__kasetAutoplayPending = false;
                    window.__kasetPlaybackSuppressed = true;

                    const video = this.getVideo();
                    const moviePlayer = this.getMoviePlayer();

                    if (!video || video.paused) {
                        if (moviePlayer && typeof moviePlayer.pauseVideo === 'function') {
                            moviePlayer.pauseVideo();
                        }
                        if (typeof onComplete === 'function') onComplete();
                        return 'already-paused';
                    }

                    if (!this.fadingEnabled || durationMs <= 0) {
                        this.applyGain(0.0);
                        if (moviePlayer && typeof moviePlayer.pauseVideo === 'function') {
                            moviePlayer.pauseVideo();
                        }
                        video.pause();
                        const pauseBtn = document.querySelector('.play-pause-button.ytmusic-player-bar');
                        if (pauseBtn && !video.paused) pauseBtn.click();
                        if (typeof onComplete === 'function') onComplete();
                        return 'paused-instant';
                    }

                    this.state = 'fading_out';
                    this.isSettingVolume = true;
                    window.__kasetIsSettingVolume = true;

                    const startVol = video.volume > 0.0 ? video.volume : this.targetVolume;
                    const startTime = performance.now();

                    this.fadeInterval = setInterval(() => {
                        const elapsed = performance.now() - startTime;
                        const progress = Math.min(1.0, elapsed / durationMs);
                        const factor = Math.pow(Math.max(0.0, 1.0 - progress), 2.0);
                        this.applyGain(startVol * factor);

                        if (progress >= 1.0) {
                            this.applyGain(0.0);
                            if (moviePlayer && typeof moviePlayer.pauseVideo === 'function') {
                                moviePlayer.pauseVideo();
                            }
                            if (video) video.pause();
                            const pauseBtn = document.querySelector('.play-pause-button.ytmusic-player-bar');
                            if (pauseBtn && video && !video.paused) pauseBtn.click();

                            this.cancelFade();
                            if (typeof onComplete === 'function') onComplete();
                        }
                    }, 16);
                    window.__kasetFadeInterval = this.fadeInterval;
                    return 'fading-out';
                }

                skipWithFade(durationMs = 150, onAction = null) {
                    const video = this.getVideo();
                    if (!video || video.paused || !this.fadingEnabled || durationMs <= 0 || video.volume <= 0.01) {
                        this.cancelFade();
                        if (typeof onAction === 'function') onAction();
                        return 'skipped-instant';
                    }

                    this.cancelFade();
                    this.state = 'fading_out';
                    this.isSettingVolume = true;
                    window.__kasetIsSettingVolume = true;

                    const startVol = video.volume > 0.0 ? video.volume : this.targetVolume;
                    const startTime = performance.now();

                    this.fadeInterval = setInterval(() => {
                        const elapsed = performance.now() - startTime;
                        const progress = Math.min(1.0, elapsed / durationMs);
                        const factor = Math.pow(Math.max(0.0, 1.0 - progress), 2.0);
                        this.applyGain(startVol * factor);

                        if (progress >= 1.0) {
                            this.applyGain(0.0);
                            this.cancelFade();
                            if (typeof onAction === 'function') onAction();
                        }
                    }, 16);
                    window.__kasetFadeInterval = this.fadeInterval;
                    return 'fading-skip';
                }

                seekWithFade(durationMs = 300, onAction = null) {
                    const video = this.getVideo();
                    if (!video || video.paused || !this.fadingEnabled || durationMs <= 0) {
                        this.cancelFade();
                        if (typeof onAction === 'function') onAction();
                        return 'seeked-instant';
                    }

                    this.cancelFade();
                    this.state = 'fading_out';
                    this.isSettingVolume = true;
                    window.__kasetIsSettingVolume = true;

                    const originalVol = this.targetVolume;
                    const startVol = video.volume > 0.0 ? video.volume : originalVol;
                    const halfDuration = Math.max(80, Math.round(durationMs / 2));
                    const startTime = performance.now();

                    this.fadeInterval = setInterval(() => {
                        const elapsed = performance.now() - startTime;
                        const progress = Math.min(1.0, elapsed / halfDuration);
                        const factor = Math.pow(Math.max(0.0, 1.0 - progress), 2.0);
                        this.applyGain(startVol * factor);

                        if (progress >= 1.0) {
                            if (this.fadeInterval) {
                                clearInterval(this.fadeInterval);
                                this.fadeInterval = null;
                            }
                            this.applyGain(0.0);
                            if (typeof onAction === 'function') onAction();

                            // Seamlessly transition into fade-in without returning to idle
                            this.state = 'fading_in';
                            const rampStartTime = performance.now();

                            this.fadeInterval = setInterval(() => {
                                const rampElapsed = performance.now() - rampStartTime;
                                const rampProgress = Math.min(1.0, rampElapsed / halfDuration);
                                const rampFactor = Math.pow(rampProgress, 2.2);
                                this.applyGain(originalVol * rampFactor);

                                if (rampProgress >= 1.0) {
                                    this.applyGain(originalVol);
                                    this.cancelFade();
                                    this.enforceVolume();
                                }
                            }, 16);
                            window.__kasetFadeInterval = this.fadeInterval;
                        }
                    }, 16);
                    window.__kasetFadeInterval = this.fadeInterval;
                    return 'fading-seek';
                }

                bloom(durationMs = 350) {
                    if (this.state === 'fading_in' || this.state === 'fading_out') {
                        return;
                    }
                    const video = this.getVideo();
                    if (!video) return;

                    if (!this.fadingEnabled || durationMs <= 0) {
                        this.enforceVolume();
                        return;
                    }

                    const target = this.targetVolume;

                    this.cancelFade();
                    this.state = 'fading_in';
                    this.isSettingVolume = true;
                    window.__kasetIsSettingVolume = true;

                    const currentVol = video.volume;
                    const startVol = (currentVol > 0.01 && currentVol < target) ? currentVol : 0.0;
                    this.applyGain(startVol);

                    const startTime = performance.now();

                    this.fadeInterval = setInterval(() => {
                        const elapsed = performance.now() - startTime;
                        const progress = Math.min(1.0, elapsed / durationMs);
                        const factor = Math.pow(progress, 2.2);
                        this.applyGain(startVol + (this.targetVolume - startVol) * factor);

                        if (progress >= 1.0) {
                            this.applyGain(this.targetVolume);
                            this.cancelFade();
                            this.enforceVolume();
                        }
                    }, 16);
                    window.__kasetFadeInterval = this.fadeInterval;
                }

                fadeRamp(fromVol, toVol, durationMs, isLog, onComplete) {
                    this.cancelFade();
                    const from = Math.max(0.0, Math.min(1.0, fromVol));
                    const to = Math.max(0.0, Math.min(1.0, toVol));

                    if (durationMs <= 0) {
                        this.applyGain(to);
                        if (typeof onComplete === 'function') onComplete();
                        return;
                    }

                    this.state = to < from ? 'fading_out' : 'fading_in';
                    this.isSettingVolume = true;
                    window.__kasetIsSettingVolume = true;

                    this.applyGain(from);
                    const startTime = performance.now();

                    this.fadeInterval = setInterval(() => {
                        const elapsed = performance.now() - startTime;
                        const progress = Math.min(1.0, elapsed / durationMs);
                        const factor = isLog
                            ? (to < from ? Math.pow(Math.max(0.0, 1.0 - progress), 2.0) : Math.pow(progress, 2.2))
                            : progress;
                        const current = to < from ? from * factor : from + (to - from) * factor;
                        this.applyGain(current);

                        if (progress >= 1.0) {
                            this.applyGain(to);
                            this.cancelFade();
                            if (typeof onComplete === 'function') onComplete();

                            if (to === 0.0) {
                                const video = this.getVideo();
                                if (video && !video.paused && !window.__kasetPlaybackSuppressed) {
                                    this.bloom();
                                }
                            }
                        }
                    }, 16);
                    window.__kasetFadeInterval = this.fadeInterval;
                }
            }

            window.__kasetAudio = new KasetAudioEngine();

            // Eagerly find and attach to video element so we can catch the very first 'loadstart' / 'play' events
            const attachEagerly = () => {
                const video = document.querySelector('video');
                if (video) {
                    window.__kasetAudio.attachVideo(video);
                    return true;
                }
                return false;
            };
            if (!attachEagerly()) {
                const observer = new MutationObserver((mutations, obs) => {
                    if (attachEagerly()) {
                        // Keep observing in case YouTube replaces the video element during SPA navigation
                        const video = document.querySelector('video');
                        if (video) window.__kasetAudio.attachVideo(video);
                    }
                });
                observer.observe(document, { childList: true, subtree: true });
            }

            // Intercept keyboard shortcuts in the DOM so they trigger our audio fader.
            document.addEventListener('keydown', (e) => {
                const target = e.target;
                const isInput = target && (target.tagName === 'INPUT' || target.tagName === 'TEXTAREA' || target.isContentEditable);
                if (isInput) return;

                if (e.code === 'Space' || e.key === ' ' || e.code === 'KeyK') {
                    e.preventDefault();
                    e.stopPropagation();
                    const video = window.__kasetAudio.getVideo();
                    if (video && video.paused) {
                        window.__kasetAudio.resume(350);
                    } else if (video) {
                        window.__kasetAudio.pause(350);
                    }
                    return;
                }

                if (e.shiftKey && e.code === 'KeyN') {
                    e.preventDefault();
                    e.stopPropagation();
                    window.__kasetAudio.skipWithFade(150, () => {
                        const nextBtn = document.querySelector('.next-button.ytmusic-player-bar');
                        if (nextBtn) nextBtn.click();
                    });
                    return;
                }

                if (e.shiftKey && e.code === 'KeyP') {
                    e.preventDefault();
                    e.stopPropagation();
                    const video = window.__kasetAudio.getVideo();
                    if (video && video.currentTime > 3) {
                        window.__kasetAudio.seekWithFade(300, () => {
                            video.currentTime = 0;
                        });
                    } else {
                        window.__kasetAudio.skipWithFade(150, () => {
                            const prevBtn = document.querySelector('.previous-button.ytmusic-player-bar');
                            if (prevBtn) prevBtn.click();
                        });
                    }
                    return;
                }
            }, true);
        })();
        """
    }
}
