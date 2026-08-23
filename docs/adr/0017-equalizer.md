# ADR-0017: 6-Band Equalizer via Core Audio Process Tap

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

Build the equalizer on **macOS 14.2+ Core Audio Process Tap** plus an **`AudioDeviceIOProc`** registered directly on the aggregate device, with all DSP implemented in-app.

### Audio path

```
WebKit GPU process  ──tap──▶  Aggregate device  ──┐
                              (main sub-device =   │
                               default output,     ├─▶ AudioDeviceIOProc
                               drift-comp on tap)  │   ▶ Biquad x6
                                                   │   ▶ Preamp + envelope limiter
                                                   │   ▶ Wet/dry crossfade
                                                   └─▶  Speakers
```

Single clock domain (aggregate device clock-masters off the system default output); input and output buffers are delivered to the same I/O-proc callback, so there's no ring buffer and no cross-device drift.

### Process discovery

`ProcessTapHelper` enumerates Core Audio's process-object list via `kAudioHardwarePropertyProcessObjectList`, filters to `com.apple.WebKit.GPU` / `com.apple.WebKit.WebContent`, and prefers entries whose parent PID matches Kaset. Tapping happens with `CATapMuteBehavior.mutedWhenTapped` so WebKit's direct output is silenced and only the EQ-processed render reaches the speakers.

### DSP

`BiquadFilter` is a hand-rolled RBJ-cookbook biquad in Transposed Direct Form II:
- **Topology**: low-shelf @ 60 Hz, peaking @ 150 / 400 / 1 k / 2.4 k Hz, high-shelf @ 15 kHz — matches the standard six-band EQ frequency layout.
- **Coefficient slewing**: per-sample one-pole interpolation toward target coefficients (~5 ms time constant) prevents zipper noise on slider sweeps.
- **Headroom**: `EQSettings.autoTrimDB` attenuates by 0.25× the peak positive band gain so boosted presets keep most of their loudness while staying off the limiter.
- **Envelope-follower limiter**: stereo-linked peak follower with fast attack (~0.5 ms) and slower release (~150 ms), gain-slew smoothed. Produces no harmonic distortion, unlike a memoryless `tanh` saturator, so ±12 dB slider extremes stay transparent.
- **Bypass crossfade**: the I/O proc always runs the filter chain and then mixes wet vs. dry by a slewed factor — toggling the EQ never clicks and re-enable doesn't trigger filter-warm-up transients.

### Why not `AVAudioUnitEQ` or `AVAudioEngine`?

- `AVAudioEngine.inputNode` cannot be rebound to an aggregate device at runtime (`kAudioUnitErr_FailedInitialization`).
- `AVAudioUnitEQ` only accepts peaking filters via the standard `parametric` mode and isn't callable outside an `AVAudioEngine`. Implementing biquads directly gives us the shelf topology and parameter slewing in ~250 lines.

### Why HAL `AudioDeviceIOProc` over duplex `AUHAL`?

An earlier revision of this feature used a single duplex `AUHAL` (`kAudioUnitSubType_HALOutput`) calling `AudioUnitRender` on bus 1 from a bus-0 render callback. On macOS 26 that path returns `kAudioUnitErr_CannotDoInCurrentContext` (-10863) whenever the tap's sample rate differs from the aggregate's main sub-device (i.e. the system output) — a configuration Core Audio happily accepts but AUHAL can't render through. Registering an `AudioDeviceIOProc` directly on the aggregate bypasses AUHAL: HAL delivers input and output buffer lists in the same callback, resolves the sample-rate conversion internally, and never hits the bus-plumbing restriction.

## Required system surface

- `Info.plist`: `NSAudioCaptureUsageDescription` (TCC prompt for the process tap).
- `Kaset.entitlements`: `com.apple.security.device.audio-input` (sandbox capability for audio capture in the presence of `app-sandbox`).
- macOS 14.2+ runtime check inside `ProcessTapHelper.start()`.

## Consequences

- New code lives under `Sources/Kaset/Models/` (`EQSettings`, `EQBand`, `EQPreset`), `Sources/Kaset/Services/Audio/` (`EqualizerService`, `EqualizerAudioEngine`, `ProcessTapHelper`, `BiquadFilter`), and `Sources/Kaset/Views/EqualizerSettingsView.swift`.
- **Permission UX is intent-preserving.** `EQSettings.isEnabled` is the user's intent and persists across launches. The actual engine state is shown separately via the status row (Active / Waiting for playback / Permission needed / Engine error). When TCC permission for *Screen & System Audio Recording* is missing the toggle auto-disables and the status row offers a deep-link to the right System Settings pane; otherwise a transient launch-time tap failure (no playback yet) leaves the toggle on so the engine spins up automatically when playback starts.
- **No additional latency** in the audio path — the HAL I/O proc delivers input and output in the same callback.
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
