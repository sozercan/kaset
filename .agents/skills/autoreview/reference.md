# Auto Review Reference

Details for cases the main `SKILL.md` flow doesn't cover. Read this when you need a
specific flag, a non-default reviewer setup, a non-macOS invocation, or one of the
edge cases below.

## Helper Locations

`<autoreview-helper>` in the examples below stands for whichever of these paths exists
in your environment. In this repo it is the repo-local one.

Repo-local (preferred in this checkout):

```bash
.agents/skills/autoreview/scripts/autoreview --help
```

`agent-scripts` checkout:

```bash
~/Projects/agent-scripts/skills/autoreview/scripts/autoreview --help
```

Global helper from `agent-scripts`:

```bash
~/.codex/skills/agent-scripts/autoreview/scripts/autoreview --help
```

On native Windows, invoke the repo-local extensionless Python helper through Python:

```powershell
python -I -X utf8 .agents\skills\autoreview\scripts\autoreview --help
```

From the root of an `agent-scripts` checkout, use its `skills\...` path instead:

```powershell
python -I -X utf8 skills\autoreview\scripts\autoreview --help
```

## Helper Behavior

The helper:

- chooses dirty local changes first
- accepts `--mode uncommitted` as an alias for `--mode local`
- otherwise uses current PR base if `gh pr view` works
- otherwise uses `origin/main` for non-main branches
- supports `--engine codex`, `claude`, `droid`, and `copilot`; default is `AUTOREVIEW_ENGINE` or `codex`
- resolves bare `git`, `gh`, reviewer, and PowerShell shell commands from absolute `PATH` entries only, never from the reviewed checkout; explicit relative `--*-bin` paths are refused
- use `--mode commit --commit <ref>` for already-committed work, especially clean `main` after landing
- should be left in `--mode auto` or forced to `--mode branch` for PR/branch work; do not force `--mode local` after committing
- writes the human report to stdout; progress and diagnostics may use stderr; writes persistent output files only with explicit `--output` or `--json-output` flags
- supports `--dry-run`, `--parallel-tests`, `--parallel-tests-shell`, `--prompt`, `--prompt-file`, `--dataset`, `--no-tools`, `--no-web-search`, and commit refs
- supports `--stream-engine-output` or `AUTOREVIEW_STREAM_ENGINE_OUTPUT=1` for live engine text while preserving structured validation; Codex and Claude hide tool/file event details, emit compact activity summaries, and report usage at turn completion
- supports opt-in review panels with `--panel` / `--reviewers`, plus per-engine `--model` and `--thinking`
- allows read-only tools and web search by default where the selected CLI supports them; runs reviewers from a sanitized temporary workspace containing the review prompt instead of the real checkout; forbids nested review in the prompt; Codex is run through `codex exec` with read-only sandbox and structured output
- prints `review still running: <engine> elapsed=<seconds>s pid=<pid>` to stderr at long-running intervals while waiting, unless streamed output or compact Codex activity has been visible recently
- prints `<label> clean: no accepted/actionable findings reported` when the validated report is clean, where `<label>` is `autoreview` for one reviewer and `autoreview panel` for a panel; the banner does not guarantee the final process exit status
- in normal review mode, exits nonzero for accepted/actionable findings or an overall incorrect verdict; review or validation failures and failed parallel tests also fail the process, except that `--allow-partial-panel` permits success when at least one usable reviewer report remains
- harness modes intentionally differ: `--expect-findings` treats findings as success and no findings as failure, while `--dry-run` exits successfully after target/configuration resolution without running a review

Tools are useful in review mode: read-only inspection and web search are on by default
so reviewers can check dependency contracts, upstream docs, and current behavior from
the sanitized review workspace rather than the real checkout.

## Optional Review Context

```bash
<autoreview-helper> --mode branch --base origin/main --prompt-file /tmp/review-notes.md --dataset /tmp/evidence.json
```

## Review Panels

Panels are opt-in. Use them when explicitly requested or when risk justifies the extra
spend. Run multiple reviewers against one frozen bundle:

```bash
<autoreview-helper> --reviewers codex,claude
```

`--panel` is shorthand for Codex plus Claude unless `--engine` changes the first reviewer:

```bash
<autoreview-helper> --panel
```

Set reviewer models and thinking/effort explicitly:

```bash
<autoreview-helper> --reviewers codex,claude --model codex=gpt-5.1 --thinking codex=high --model claude=sonnet --thinking claude=max
```

Inline syntax is also supported:

```bash
<autoreview-helper> --reviewers codex:gpt-5.1:high,claude:sonnet:max
```

Codex maps thinking to `model_reasoning_effort` and accepts `low`, `medium`, `high`, or
`xhigh`. Claude maps thinking to `--effort` and also accepts `max`. Engines without a
real thinking knob reject `--thinking`.

## Parallel Tests on Windows

The default `--parallel-tests` shell preserves the platform `cmd.exe` semantics used by
Python `shell=True`. Use `--parallel-tests-shell powershell` or
`--parallel-tests-shell pwsh` when the focused test command is PowerShell-specific.

## Smoke Harness

Repo-local thin shell wrappers over a shared Python implementation:

```bash
.agents/skills/autoreview/scripts/test-review-harness --fixture benign --engine codex
```

```powershell
& .\.agents\skills\autoreview\scripts\test-review-harness.ps1 -Fixture benign -Engine codex
```

From the root of an `agent-scripts` checkout, use its `skills/...` paths:

```bash
skills/autoreview/scripts/test-review-harness --fixture benign --engine codex
```

```powershell
& .\skills\autoreview\scripts\test-review-harness.ps1 -Fixture benign -Engine codex
```

## Security-Audit Suppression Changes

When a change touches security-audit suppression, verify accepted findings remain
auditable: suppressed findings stay in structured output, active output keeps an
unsuppressible suppression notice, and aggregate findings cannot hide unrelated active
risk.

## Regression Provenance

Keep roles separate: blamed code author, blamed PR author, PR merger/committer, current
PR author, and PR/date. If no blamed PR is traceable, use the blamed commit as the
provenance: commit SHA, date, and author username. Do not guess a merger or frame
missing PR metadata as a separate finding.

If the blamed PR was merged by `clawsweeper[bot]` or another automation, identify the
human trigger when practical. Check timeline/comments first; if rate-limited, use
gitcrawl/cache or public PR HTML. Look for maintainer commands such as
`@clawsweeper automerge`, `/landpr`, or labels/status comments that armed automerge.
Report `automerge triggered by @login`; if not found, say trigger unknown.

## Gitcrawl Recovery

If `gh`/Gitcrawl reports `database disk image is malformed`, run `gitcrawl doctor --json`
once to let the portable cache repair before retrying review; do not bypass the shim
unless repair fails and freshness requires live GitHub.

If Gitcrawl reports a portable manifest mismatch, source/runtime DB health error, or
stale portable-store checkout, run `gitcrawl doctor --json` and inspect
`source_db_health`, `runtime_db_health`, and `portable_store_status` before falling back
to live GitHub.
