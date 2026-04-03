# Task Planning: Phases with Exit Criteria

For any non-trivial task, **plan in phases with testable exit criteria** before writing code. This ensures incremental progress and early detection of issues.

> ⚠️ **Never implement without an approved plan** — Planning and execution are separate phases. Do not write production code until the plan has been reviewed. When working in plan mode, always include **"don't implement yet"** as a guard. The human will say when to start.

> 🔁 **Follow the repo default loop in `AGENTS.md`** — Local verification is CLI-first: `swift build`, targeted `swift test --skip KasetUITests`, then `swiftlint --strict && swiftformat .`. Use Xcode/`xcodebuild` only for UI/runtime debugging, scheme-specific investigation, or CI parity.

## Phase Structure

Every task should be broken into phases. Each phase must have:
1. **Clear deliverable** — What artifact or change is produced
2. **Testable exit criteria** — How to verify the phase is complete
3. **Rollback point** — The phase should leave the codebase in a working state

## Standard Phases

### Phase 1: Research & Understanding

> 📝 **Write research findings to a persistent file** — Don't just summarize verbally. Write a structured research document (in the session workspace, not the repo) with findings about affected files, existing patterns, edge cases, and dependencies. This is the review surface — if the research is wrong, the plan will be wrong.

| Deliverable | Exit Criteria |
|-------------|---------------|
| Written research artifact | Findings documented in a persistent file |
| Identify affected files and dependencies | List all files to modify/create |
| Understand existing patterns | Can explain how similar features work |
| Read relevant docs | Confirmed patterns in `docs/` apply |

**Exit gate**: Can articulate the implementation plan without ambiguity.

### Phase 2: Interface Design
| Deliverable | Exit Criteria |
|-------------|---------------|
| Define new types/protocols | Type signatures compile |
| Plan public API surface | No breaking changes to existing callers (or changes identified) |

**Exit gate**: `swift build` succeeds with stub implementations.

### Phase 3: Core Implementation

> 🔄 **Continuously verify the build** — Run `swift build` throughout implementation, not just at the end. Catch type errors and regressions early, not after 15 minutes of changes.

> 📋 **Track progress in the plan** — Mark tasks and phases as completed as you go. The human should be able to glance at the plan at any point and see exactly where things stand.

| Deliverable | Exit Criteria |
|-------------|---------------|
| Implement business logic | Unit tests pass for new code |
| Handle error cases | Error paths have test coverage |
| Add logging | `DiagnosticsLogger` calls in place |
| Performance verified | Anti-pattern checklist passed, perf tests added if applicable |

**Exit gate**: Targeted `swift test --skip KasetUITests --filter ...` passes for the new code path.

### Phase 4: Quality Assurance
| Deliverable | Exit Criteria |
|-------------|---------------|
| Linting passes | `swiftlint --strict` reports 0 errors |
| Formatting applied | `swiftformat .` makes no changes |
| Full default test suite passes | `swift test --skip KasetUITests` succeeds |

**Exit gate**: `swift build`, `swift test --skip KasetUITests`, `swiftlint --strict`, and `swiftformat .` pass locally.

## Example: Adding a New Service

```
Phase 1: Research
├── Write findings to session workspace
├── Exit: Understand YTMusicClient pattern, confirm no existing solution

Phase 2: Interface
├── Create NewService.swift with protocol + stub
├── Exit: `swift build` passes

Phase 3: Implementation
├── Implement methods, add error handling
├── Create NewServiceTests.swift
├── Run `swift build` after each major change
├── Exit: `swift test --skip KasetUITests --filter NewServiceTests` passes

Phase 4: QA
├── Run `swift build`
├── Run `swift test --skip KasetUITests`
├── Run `swiftlint --strict && swiftformat .`
├── Exit: Default local CLI loop passes
```

## Implementation Discipline

- **Reference existing code for consistency** — When building features similar to existing ones, explicitly find and match existing implementations. A new detail view should match the patterns in existing detail views. A new parser should follow the structure in `Sources/Kaset/Services/API/Parsers/`. Point to the reference file and replicate its patterns rather than designing from scratch.
- **Revert and re-scope on wrong direction** — If implementation goes wrong, don't try to incrementally patch a bad approach. Revert git changes and narrow the scope. A clean restart with tighter scope almost always produces better results than fixing a broken chain of changes.
- **Protect existing interfaces** — Do not change public function signatures, protocols, or model types unless the plan explicitly calls for it. When in doubt, make the new code adapt to existing interfaces, not the other way around.

## Checkpoint Communication

After each phase, briefly report:
- ✅ What was completed
- 🧪 Test/verification results
- ➡️ Next phase plan

This keeps the human informed and provides natural points to course-correct.
