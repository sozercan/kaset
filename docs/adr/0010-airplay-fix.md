# ADR-0010: Fix AirPlay for WebView-based playback

## Status

Implemented, with remaining recovery and compatibility limits documented below.

## Context

[Issue #42](https://github.com/sozercan/kaset/issues/42) reported that selecting an AirPlay device in the app left audio playing on the Mac. System-wide AirPlay worked.

Kaset plays DRM-protected media through `WKWebView`. The original `AVRoutePickerView` had no connection to that media, so selecting a device did not route WebKit playback. The first fix replaced the main player's control with `video.webkitShowPlaybackTargetPicker()`.

The original version of this ADR also claimed that every track change destroys the video element and that the picker's position follows the video's CSS bounds. Runtime traces and WebKit source inspection disproved both claims.

## Decision

Use WebKit's picker from both the main player and mini player, anchor it at the invoking button, and preserve the playback document during normal track changes and recoverable queue drift. Report connection state from the current media element.

### Track continuity

YouTube Music can change sources within the same document and video element. WebKit also retains a selected playback target and can assign it to eligible media clients. Element replacement alone therefore does not prove that the user must reconnect. See [WebKit's media-session manager](https://github.com/WebKit/WebKit/blob/6270255c36bd2919ef0eea13368231f488df509b/Source/WebCore/Modules/airplay/WebMediaSessionManager.mm#L268) and its [AirPlay autoplay regression test](https://github.com/WebKit/WebKit/blob/6270255c36bd2919ef0eea13368231f488df509b/LayoutTests/media/airplay-autoplay.html).

Kaset already uses YouTube Music's SPA router and native queue handoff. The investigation found three avoidable full-document reloads:

- Queue recovery requested `.forceFullPageWhenSameVideoId`, but `loadVideo` disabled the router even when the requested song differed from the tracked song. The strategy now forces a reload only when the IDs match. A different song uses the router when the current Music document is committed and still accepted.
- The three-second router fallback fired while the next media was still loading. The confirmation window is now 15 seconds. A missing or failed router still falls back immediately. Existing advertisement-aware deferral remains in effect.
- After consecutive Next commands, YouTube could briefly play the intended track and then switch to unexpected queue media. The native tracked ID already matched the intended target, so queue recovery forced a full reload. Queue recovery now uses `.preferRouterWhenSameVideoId` to reissue the intended target through the existing document, bypassing duplicate-play suppression. If a router attempt for that target is still pending, stale metadata leaves its confirmation deadline in control instead of starting another recovery.

Explicit full-page resynchronization, an uncommitted or lost document, and an unconfirmed router transition retain full-page recovery. Normal same-ID restarts continue to use the existing in-place restart path.

### Stalled AirPlay track changes

An accepted router command can fail before YouTube assigns the next media source. In the reproduced AirPlay transition, YouTube emitted player errors `5` and `150` for the requested track, then automatically played a different song from its own queue. Kaset kept showing the requested song until its 15-second fallback replaced the document and lost the route. The requested song played successfully when connected to AirPlay directly.

Both the source-error sequence and a competing native autoplay transition can leave the requested player unstarted (`-1`) with no loaded media. For navigation that starts on a wireless media element, Kaset retries the requested router command once if that state persists for one second. The delay lets normal loading and YouTube's error handlers settle before recovery interrupts its automatic skip. Buffering, paused, loaded, and advertisement media do not trigger recovery. The player states and error values are described in [YouTube's player API reference](https://developers.google.com/youtube/iframe_api_reference#Events).

Track identity and media readiness can update after the player-state event. A timer checks the pending target every 250 milliseconds and starts the settling window once all conditions match. Player-state changes also reset the window when loading resumes.

The retry requires the same playback occurrence, requested video ID, and unloaded media element. A rapid skip cancels the old retry and inherits its pending AirPlay handoff while WebKit's wireless flag is temporarily false. Media confirmation, page replacement, teardown, and leaving the page release that handoff. A late callback cannot cancel a newer retry. The original confirmation deadline still bounds a failed recovery.

### Picker position and window ownership

WebKit uses the document's [last native mouse position](https://github.com/WebKit/WebKit/blob/6270255c36bd2919ef0eea13368231f488df509b/Source/WebCore/dom/Document.cpp#L10297) to anchor the picker. Changing the video's CSS bounds does not set that position.

`AirPlayPickerAnchorView` resolves the invoking button's screen position. Before calling `webkitShowPlaybackTargetPicker()`, Kaset forwards a zero-click `mouseUp` event to the playback `WKWebView`, with no preceding mouse-down. This updates WebKit's anchor through public AppKit and WebKit APIs.

The event uses the playback window's content-view coordinates. WebKit supplies the [window's content view](https://github.com/WebKit/WebKit/blob/6270255c36bd2919ef0eea13368231f488df509b/Source/WebKit/UIProcess/mac/WebPageProxyMac.mm#L877) to its picker, but its [picker conversion treats window coordinates as view coordinates](https://github.com/WebKit/WebKit/blob/6270255c36bd2919ef0eea13368231f488df509b/Source/WebCore/platform/graphics/avfoundation/objc/AVRoutePickerViewTargetPicker.mm#L120). Converting the anchor compensates for flipped SwiftUI content views.

The mini player now calls the same WebKit picker instead of an unbound `AVRoutePickerView`. While the mini player is visible, it hosts the existing hidden playback WebView and the main window releases that host. Minimize and restore notifications update hosting separately from the mini player's open state, so an auxiliary mini player releases playback to the main window while minimized and takes it back when restored. The visible video window retains ownership when video mode is active. Moving the WebView between windows preserves its document and media element.

### Connection reporting

The observer publishes `webkitCurrentPlaybackTargetIsWireless` for the current `document.querySelector('video')`. It sends initial state, including false when media is absent, and updates on attachment, replacement, removal, and wireless-target events. Duplicate reports are suppressed, and late events from detached media are ignored.

An accepted document commit, WebView teardown, or loss of the current WebContent process clears the native connection indicator. The unused "AirPlay requested" state was removed because opening the picker does not establish a connection.

## Verification

Packaged runtime checks used an Apple TV receiver on macOS 27:

- The main and mini-player pickers appeared at their respective buttons and showed the selected receiver.
- Manual Next preserved AirPlay.
- Moving between the main and mini-player windows preserved the connection.
- An automatic track-end handoff encountered unexpected native queue media and recovered through the router. The next track played wirelessly with the same document generation, document ID, and video element. No full navigation occurred.
- A consecutive-Next reproduction first confirmed the intended track, then observed unexpected queue media. Before the follow-up fix, same-ID recovery replaced the document and left playback local until the picker reopened. With the fix, the same recovery used the router, confirmed the intended media in about 0.5 seconds, and restored wireless playback without opening the picker. Document generation, document ID, and video element were unchanged.
- Skipping from "Aslolan Aşktır" to "İncelikler" reproduced the source-error sequence and an unexpected YouTube queue song. An error-triggered prototype reissued the requested track inside the existing document. WebKit then reported wireless playback with matching player-response and Media Session metadata, through that song and the following natural transition to "Seyrüsefer". A later transition exposed the equivalent unstarted state without an error event.

The final state-based recovery has unit coverage, including delayed identity and readiness updates and a missing state callback. Its packaged receiver check remains pending. The prototype's receiver audio and display were not independently confirmed.

The repaired automatic recovery reached wireless playback about 1.3 seconds after router navigation began. This verifies the different-ID recovery fix. It does not establish a worst-case loading time or prove that every transition interrupted by the old three-second deadline will finish within 15 seconds.

Unit coverage exercises the production observer, current-versus-stale document resets, `loadVideo` routing and fallback, and picker event ordering and coordinates in flipped and unflipped AppKit content views. Queue-recovery coverage includes same-ID routing, duplicate-play suppression, pending-target confirmation and supersession, document loss, and the full-page timeout when media never confirms. Window-controller tests cover minimize/restore notifications in both mini-player modes, video-window ownership, and closing a minimized window.

The router script's tests exercise the measured unstarted state, its single retry, buffering and pause transitions, advertisements, rapid-skip supersession, playback-occurrence changes, confirmation cancellation, and late callbacks after media or document changes.

## Known limitations

- Full document, WebContent-process, or account-store recovery can lose the route. Receiver disappearance can also require the user to reopen the picker. Kaset has no supported API to silently choose a receiver.
- A router that accepts navigation but never confirms the target media, including after the single AirPlay recovery retry, waits 15 seconds before full-page recovery. Advertisement-aware deferral can extend that wait.
- Route retention does not guarantee gapless audio. WebKit may briefly report a local target while loading the next source before restoring the wireless route.
- Picker placement depends on WebKit's native event handling and coordinate conversion. Hardware verification covered an Apple TV on macOS 27. Other receivers and macOS versions still need runtime verification.
- Device-availability events remain unreliable in `WKWebView`. The button stays available when a track is selected, but opening the picker still requires a media element.

## References

- [Apple: Adding an AirPlay button to Safari media controls](https://developer.apple.com/documentation/webkitjs/adding_an_airplay_button_to_your_safari_media_controls)
- [Apple Developer Forums: AirPlay inside a webview](https://developer.apple.com/forums/thread/30179)
- [ADR-0001: WebView-based playback](0001-webview-playback.md)
