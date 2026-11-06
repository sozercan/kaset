# Autoreview

This directory tracks the OpenClaw `autoreview` runtime with three narrow downstream behavior overrides.

## Upstream

- Repository: [`openclaw/agent-skills`](https://github.com/openclaw/agent-skills)
- Source snapshot: [`skills/autoreview` at commit `bae9b204f937991b45c3fd68d5c9dcafb23b9159`](https://github.com/openclaw/agent-skills/tree/bae9b204f937991b45c3fd68d5c9dcafb23b9159/skills/autoreview)
- Commit: [`bae9b204f937991b45c3fd68d5c9dcafb23b9159`](https://github.com/openclaw/agent-skills/commit/bae9b204f937991b45c3fd68d5c9dcafb23b9159)

The vendored runtime starts from that snapshot and carries only the behavior overrides below.
`AGENTS.md` records the downstream sync policy.

## Local differences

- Codex defaults to `gpt-6.1-sol` with `xhigh` reasoning instead of upstream's `high` reasoning.
- Claude defaults to `claude-opus-5-5` with `xhigh` reasoning instead of upstream's `claude-fable-5` default.
- Codex preserves `openai_base_url` from an external `CODEX_HOME/config.toml`, passes it through an internal OpenAI-compatible provider because isolated runs use `--ignore-user-config`, and disables WebSocket transport for that provider.
- `references/repository-entrypoint.md` is omitted; it is a template for repositories that consume the shared install, and this directory vendors the runtime.

No other runtime behavior is intentionally changed.

## Packaging

The upstream test suites, fixtures, and optional `scripts/test-review-harness*` live-provider smoke wrappers are omitted. `scripts/autoreview` does not depend on them. A small downstream test covers only the three local behavior overrides.

## Upstream license

OpenClaw's work is used under the MIT License:

```text
MIT License

Copyright (c) 2026 openclaw

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```
