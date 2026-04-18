# ADR-0014: 6-Band Equalizer via Core Audio Process Tap

## Status

Implemented

## Context

Users requested an equalizer comparable to Spotify's mobile EQ — six bands, presets, audible effect. Kaset's audio path makes this non-trivial:

1. **DRM-protected playback in WKWebView**: per [ADR-0001](0001-webview-playback.md) the app delegates audio decode/playback to a hidden `WKWebView` so YouTube Music's Widevine DRM is honoured.
2. **No Web Audio API access**: `AudioContext.createMediaElementSource()` returns a silent stub for DRM-protected `<video>` elements, so JavaScript-side EQ is impossible.
3. **No `AVAudioEngine` insertion point**: the audio is decoded by WebKit, never exposed to AVFoundation as an `AVPlayerItem`. There is no `audioMix` to attach.
4. **Multi-process architecture**: WebKit moved media decode into the **`com.apple.WebKit.GPU`** XPC subprocess on macOS Sonoma+. The Kaset main process never touches the audio samples.

Earlier sessions (recorded in the project memory) confirmed:
- A `CATap` on `selfPID` captures silence — the main process emits no audio.
- An `AVAudioEngine.inputNode` rebound to an aggregate device fails with `kAudioUnitErr_FailedInitialization` (-10875). `AVAudioEngine`'s input node is fixed to its construction-time device.
- A ring-buffer-backed `AVAudioSourceNode` reproducer reliably introduces an "underwater sound" artifact, presumably from clock drift between the tap-driven write side and the output-driven read side.

## Decision

Build the equalizer on **macOS 14.2+ Core Audio Process Tap** plus a **single duplex `AUHAL`** unit, with all DSP implemented in-app.

### Audio path

```
WebKit GPU process  ──tap──▶  Aggregate device  ──AUHAL bus 1──▶  Render callback
                              (output device =                      ▶ Biquad x6
                               main subdevice,                      ▶ Preamp + soft limiter
                               drift-comp on tap)                   ▶ Wet/dry crossfade
                                                  ◀──AUHAL bus 0──  ──▶  Speakers
```

Single clock domain (the aggregate device clock-masters off the system default output), single `AUHAL` running both directions, no ring buffer.

### Process discovery

`ProcessTapHelper` enumerates Core Audio's process-object list via `kAudioHardwarePropertyProcessObjectList`, filters to `com.apple.WebKit.GPU` / `com.apple.WebKit.WebContent`, and prefers entries whose parent PID matches Kaset. Tapping happens with `CATapMuteBehavior.mutedWhenTapped` so WebKit's direct output is silenced and only the EQ-processed render reaches the speakers.

### DSP

`BiquadFilter` is a hand-rolled RBJ-cookbook biquad in Transposed Direct Form II:
- **Topology**: low-shelf @ 60 Hz, peaking @ 150 / 400 / 1 k / 2.4 k Hz, high-shelf @ 15 kHz — matches the standard six-band EQ frequency layout.
- **Coefficient slewing**: per-sample one-pole interpolation toward target coefficients (~5 ms time constant) prevents zipper noise on slider sweeps.
- **Headroom**: `EQSettings.autoTrimDB` attenuates by half the peak band gain so boosts don't immediately clip; a tanh soft limiter at 0.9 catches whatever transients still exceed full scale.
- **Bypass crossfade**: render callback always runs the filter chain and then mixes wet vs. dry by a slewed factor — toggling the EQ never clicks and re-enable doesn't trigger filter-warm-up transients.

### Why not `AVAudioUnitEQ` or `AVAudioEngine`?

- `AVAudioEngine.inputNode` cannot be rebound to an aggregate device at runtime (`kAudioUnitErr_FailedInitialization`).
- `AVAudioUnitEQ` only accepts peaking filters via the standard `parametric` mode and isn't callable outside an `AVAudioEngine`. Implementing biquads directly gives us the shelf topology and parameter slewing in ~250 lines.

### Why `AUHAL` duplex over two separate `AUHAL`s?

Two `AUHAL`s on different devices (one input on aggregate, one output on default) was the prior session's path and produced "underwater sound" — the read/write clocks drift independently. A single duplex `AUHAL` bound to an aggregate that already includes the output device shares one clock domain, so the input and output cycles are inherently locked.

## Required system surface

- `Info.plist`: `NSAudioCaptureUsageDescription` (TCC prompt for the process tap).
- `Kaset.entitlements`: `com.apple.security.device.audio-input` (sandbox capability for audio capture in the presence of `app-sandbox`).
- macOS 14.2+ runtime check inside `ProcessTapHelper.start()`.

## Consequences

- New code lives under `Sources/Kaset/Models/` (`EQSettings`, `EQBand`, `EQPreset`), `Sources/Kaset/Services/Audio/` (`EqualizerService`, `EqualizerAudioEngine`, `ProcessTapHelper`, `BiquadFilter`), and `Sources/Kaset/Views/EqualizerSettingsView.swift`.
- **Permission UX is intent-preserving.** `EQSettings.isEnabled` is the user's intent and persists across launches. The actual engine state is shown separately via the status row (Active / Waiting for playback / Permission needed / Engine error). When TCC permission for *Screen & System Audio Recording* is missing the toggle auto-disables and the status row offers a deep-link to the right System Settings pane; otherwise a transient launch-time tap failure (no playback yet) leaves the toggle on so the engine spins up automatically when playback starts.
- **No additional latency** in the audio path — duplex `AUHAL` renders input and output in the same cycle.
- **Other macOS apps' audio is unaffected** — the tap targets only Kaset's WebKit subprocess.
- **WebKit subprocess restarts** invalidate the tap. The user must toggle the EQ off and on to refresh; we don't currently observe XPC lifecycle to do this automatically.

## Future work

- **Loudness normalisation**: Spotify-style per-track LUFS analysis would reclaim ~6 dB of headroom and substantially reduce limiter engagement on hot masters. Larger scope — requires sliding-window RMS/K-weighting analysis and track-change integration with `PlayerService`.
- **Look-ahead / oversampled limiter**: a 2× upsampled limiter would reduce alias products at extreme settings. Marginal perceptual gain.
- **Process-tap auto-refresh**: subscribe to WebKit XPC restart notifications (or poll `kAudioHardwarePropertyProcessObjectList`) and rebuild the tap when the underlying PID changes.

## References

- WWDC23 — *Capturing system audio with Core Audio taps*
- RBJ Audio EQ Cookbook
- ADR-0001 — WebView-based playback rationale (why we can't intercept audio earlier in the pipeline)
