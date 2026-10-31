---
name: dev-loop-packaging
description: Use when you need a fresh packaged `.app` bundle, a fast build-package-relaunch loop, or a packaged runtime repro for Kaset instead of a compile-only verification.
metadata:
  short-description: Package and relaunch Kaset
---

# Dev Loop Packaging

`swift build` and `swift test --skip KasetUITests` remain the fastest checks. Package only when you need a runnable app bundle, login/WebView/runtime inspection, or bundle verification.

## Common Commands

```bash
Scripts/build-app.sh
Scripts/compile_and_run.sh
Scripts/compile_and_run.sh --test
Scripts/compile_and_run.sh --lint
Scripts/compile_and_run.sh --wait
```

## What The Scripts Do

- `Scripts/build-app.sh` builds the app and assembles `.build/app/Kaset.app`. Set `ARCHES` to build for custom architectures.
- `Scripts/compile_and_run.sh` kills running Kaset processes, optionally runs tests and linting, packages a debug app by default, relaunches it, and checks that it stays running. Pass `--release` for a release build.
- `Scripts/compile_and_run.sh --test` runs the SwiftPM test target before packaging; it does not run the separate Xcode UI-test project.

## Landmarks

- `Scripts/build-app.sh`
- `Scripts/compile_and_run.sh`
- `.build/app/Kaset.app`
