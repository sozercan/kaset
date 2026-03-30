# Dev Loop Packaging

Use this skill when you need a fresh `.app` bundle, a fast build-package-relaunch loop, or a packaged runtime repro instead of a compile-only check.

## Default Loop

- Prefer `swift build` for the fastest compile verification.
- Prefer `swift test --skip KasetUITests` for the default non-UI test pass.
- Escalate to packaging only when you need a runnable app bundle, login/WebView/runtime inspection, or bundle verification.

## Common Commands

```bash
swift build
Scripts/build-app.sh
Scripts/compile_and_run.sh
Scripts/compile_and_run.sh --test
Scripts/compile_and_run.sh --lint
Scripts/compile_and_run.sh --wait
```

## What The Scripts Do

- `Scripts/build-app.sh` builds the app and assembles `.build/app/Kaset.app`.
- `Scripts/compile_and_run.sh` kills existing Kaset processes, optionally runs tests and linting, packages the app, relaunches it, and checks that it stays running.
- `Scripts/compile_and_run.sh --test` runs the SwiftPM test target before packaging; it does not invoke the separate Xcode UI-test project.
- `Scripts/build-app.sh` can also build for custom architectures via `ARCHES`.

## Landmarks

- `Scripts/build-app.sh`
- `Scripts/compile_and_run.sh`
- `.build/app/Kaset.app`
