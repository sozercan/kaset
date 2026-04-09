#!/usr/bin/env python3

from __future__ import annotations

import json
import os
import subprocess
import sys
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


ISSUE_TITLE = os.environ.get("UI_TEST_ISSUE_TITLE", "CI: Full UI Suite failing on main")
ISSUE_MARKER = os.environ.get("UI_TEST_ISSUE_MARKER", "<!-- kaset-ci-full-ui-suite -->")
ARTIFACT_NAME = os.environ.get("UI_TEST_ARTIFACT_NAME", "macOS-UITestResults")
BUILD_OUTCOME = os.environ.get("UI_BUILD_OUTCOME", "")
INSTALL_OUTCOME = os.environ.get("UI_INSTALL_OUTCOME", "")
TEST_OUTCOME = os.environ.get("UI_TEST_OUTCOME", "")
XCRESULT_PATH = os.environ.get("UI_XCRESULT_PATH", "").strip()


def require_env(name: str) -> str:
    value = os.environ.get(name, "").strip()
    if not value:
        raise SystemExit(f"{name} is required")
    return value


REPOSITORY = require_env("GITHUB_REPOSITORY")
GITHUB_SHA = require_env("GITHUB_SHA")
GITHUB_RUN_ID = require_env("GITHUB_RUN_ID")
GITHUB_SERVER_URL = os.environ.get("GITHUB_SERVER_URL", "https://github.com").rstrip("/")
GITHUB_RUN_NUMBER = os.environ.get("GITHUB_RUN_NUMBER", GITHUB_RUN_ID)
RUN_URL = f"{GITHUB_SERVER_URL}/{REPOSITORY}/actions/runs/{GITHUB_RUN_ID}"
COMMIT_URL = f"{GITHUB_SERVER_URL}/{REPOSITORY}/commit/{GITHUB_SHA}"
SHORT_SHA = GITHUB_SHA[:7]
TIMESTAMP_UTC = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%S UTC")
TRACKER_BODY = f"""{ISSUE_MARKER}
This issue tracks failures of the full macOS UI suite on `main`.

The `Test Suite` workflow reuses this issue for each failing post-merge UI run
and closes it again after the suite recovers.
"""


@dataclass
class TrackerIssue:
    number: int
    state: str
    url: str


@dataclass
class XCResultDetails:
    environment: str | None
    total_tests: int | None
    passed_tests: int | None
    failed_tests: int | None
    skipped_tests: int | None
    failing_tests: list[str]


def run_command(args: list[str], stdin: str | None = None) -> str:
    completed = subprocess.run(
        args,
        input=stdin,
        capture_output=True,
        text=True,
        check=False,
    )
    if completed.returncode != 0:
        message = completed.stderr.strip() or completed.stdout.strip() or "command failed"
        command = " ".join(args)
        raise RuntimeError(f"{command}: {message}")
    return completed.stdout


def run_json(args: list[str]) -> Any:
    output = run_command(args)
    try:
        return json.loads(output)
    except json.JSONDecodeError as error:
        command = " ".join(args)
        raise RuntimeError(f"{command}: invalid JSON output ({error})") from error


def find_tracker_issue() -> TrackerIssue | None:
    issues = run_json([
        "gh",
        "issue",
        "list",
        "--repo",
        REPOSITORY,
        "--state",
        "all",
        "--limit",
        "100",
        "--search",
        f"\"{ISSUE_TITLE}\" in:title",
        "--json",
        "number,title,state,body,url",
    ])
    matches = [
        issue for issue in issues
        if issue.get("title") == ISSUE_TITLE and ISSUE_MARKER in (issue.get("body") or "")
    ]
    if not matches:
        return None

    newest = max(matches, key=lambda issue: int(issue["number"]))
    return TrackerIssue(
        number=int(newest["number"]),
        state=str(newest["state"]),
        url=str(newest["url"]),
    )


def create_tracker_issue() -> TrackerIssue:
    run_command([
        "gh",
        "issue",
        "create",
        "--repo",
        REPOSITORY,
        "--title",
        ISSUE_TITLE,
        "--body-file",
        "-",
    ], stdin=TRACKER_BODY)

    issue = find_tracker_issue()
    if issue is None:
        raise RuntimeError("created tracker issue but could not find it afterwards")
    return issue


def ensure_tracker_issue_open() -> TrackerIssue:
    issue = find_tracker_issue()
    if issue is None:
        issue = create_tracker_issue()

    if issue.state.upper() == "CLOSED":
        run_command([
            "gh",
            "issue",
            "reopen",
            str(issue.number),
            "--repo",
            REPOSITORY,
        ])
        issue = TrackerIssue(number=issue.number, state="OPEN", url=issue.url)

    return issue


def comment_on_issue(issue_number: int, body: str) -> None:
    run_command([
        "gh",
        "issue",
        "comment",
        str(issue_number),
        "--repo",
        REPOSITORY,
        "--body-file",
        "-",
    ], stdin=body)


def close_issue(issue_number: int) -> None:
    run_command([
        "gh",
        "issue",
        "close",
        str(issue_number),
        "--repo",
        REPOSITORY,
        "--reason",
        "completed",
    ])


def normalize_identifier(identifier: str) -> str:
    normalized = " ".join(identifier.split()).replace(" / ", "/").strip()
    if normalized.endswith("()"):
        normalized = normalized[:-2]
    if normalized and not normalized.startswith("KasetUITests/"):
        normalized = f"KasetUITests/{normalized}"
    return normalized


def collect_failed_tests(nodes: list[dict[str, Any]], path: tuple[str, ...] = ()) -> list[str]:
    failures: list[str] = []

    for node in nodes:
        node_type = str(node.get("nodeType") or "")
        name = str(node.get("name") or "").strip()
        next_path = path
        if node_type in {"UI test bundle", "Test Suite", "Test Case"} and name:
            next_path = (*path, name)

        if node_type == "Test Case" and str(node.get("result") or "") == "Failed":
            identifier = str(node.get("nodeIdentifier") or "/".join(next_path)).strip()
            normalized = normalize_identifier(identifier)
            if normalized:
                failures.append(normalized)

        children = node.get("children") or []
        if isinstance(children, list):
            failures.extend(collect_failed_tests(children, next_path))

    return failures


def extract_summary_failures(summary_failures: Any) -> list[str]:
    if isinstance(summary_failures, dict):
        summary_failures = [summary_failures]
    if not isinstance(summary_failures, list):
        return []

    identifiers: list[str] = []
    for failure in summary_failures:
        if not isinstance(failure, dict):
            continue
        value = (
            failure.get("testIdentifierString")
            or failure.get("testName")
            or failure.get("failureText")
            or ""
        )
        normalized = normalize_identifier(str(value))
        if normalized:
            identifiers.append(normalized)
    return identifiers


def deduplicate(values: list[str]) -> list[str]:
    ordered: list[str] = []
    seen: set[str] = set()
    for value in values:
        if value and value not in seen:
            seen.add(value)
            ordered.append(value)
    return ordered


def parse_xcresult_details() -> tuple[XCResultDetails | None, str | None]:
    if not XCRESULT_PATH:
        return None, "UI job failed before a .xcresult bundle was available."

    xcresult = Path(XCRESULT_PATH)
    if not xcresult.exists():
        return None, f"Expected .xcresult bundle was not found at {XCRESULT_PATH}."

    try:
        summary = run_json([
            "xcrun",
            "xcresulttool",
            "get",
            "test-results",
            "summary",
            "--path",
            str(xcresult),
            "--compact",
        ])
        tests = run_json([
            "xcrun",
            "xcresulttool",
            "get",
            "test-results",
            "tests",
            "--path",
            str(xcresult),
            "--compact",
        ])
    except RuntimeError as error:
        return None, f"Found a .xcresult bundle, but could not extract failure details: {error}"

    failing_tests = collect_failed_tests(tests.get("testNodes") or [])
    if not failing_tests:
        failing_tests = extract_summary_failures(summary.get("testFailures"))

    environment = summary.get("environmentDescription")
    if isinstance(environment, str):
        environment = " ".join(environment.split())
    else:
        environment = None

    details = XCResultDetails(
        environment=environment,
        total_tests=summary.get("totalTestCount"),
        passed_tests=summary.get("passedTests"),
        failed_tests=summary.get("failedTests"),
        skipped_tests=summary.get("skippedTests"),
        failing_tests=deduplicate(failing_tests),
    )
    return details, None


def failure_stage() -> str:
    outcomes = [
        (BUILD_OUTCOME, "build app bundle"),
        (INSTALL_OUTCOME, "install app"),
        (TEST_OUTCOME, "run UI tests"),
    ]
    for outcome, stage in outcomes:
        if outcome.lower() == "failure":
            return stage
    return "run UI tests"


def suite_repro_command() -> str:
    return """xcodebuild \\
  -project KasetUITests.xcodeproj \\
  -scheme KasetUITests \\
  -destination 'platform=macOS' \\
  test"""


def targeted_repro_commands(failing_tests: list[str]) -> list[str]:
    commands: list[str] = []
    for identifier in failing_tests[:3]:
        commands.append(f"""xcodebuild \\
  -project KasetUITests.xcodeproj \\
  -scheme KasetUITests \\
  -destination 'platform=macOS' \\
  -only-testing:{identifier} \\
  test""")
    return commands


def build_failure_comment() -> str:
    details, parse_note = parse_xcresult_details()
    lines = [
        "Full UI suite failed on `main`.",
        "",
        f"- Commit: [`{SHORT_SHA}`]({COMMIT_URL})",
        f"- Workflow run: [Test Suite #{GITHUB_RUN_NUMBER}]({RUN_URL})",
        f"- Date: {TIMESTAMP_UTC}",
        f"- Artifact: `{ARTIFACT_NAME}`",
    ]

    if details is not None:
        lines.extend([
            "",
            "Summary:",
            f"- Total tests: `{details.total_tests if details.total_tests is not None else 'unknown'}`",
            f"- Failed tests: `{details.failed_tests if details.failed_tests is not None else len(details.failing_tests)}`",
            f"- Passed tests: `{details.passed_tests if details.passed_tests is not None else 'unknown'}`",
            f"- Skipped tests: `{details.skipped_tests if details.skipped_tests is not None else 'unknown'}`",
        ])
        if details.environment:
            lines.append(f"- Environment: `{details.environment}`")

        if details.failing_tests:
            lines.extend(["", "Failing tests:"])
            preview = details.failing_tests[:10]
            lines.extend(f"- `{name}`" for name in preview)
            remaining = len(details.failing_tests) - len(preview)
            if remaining > 0:
                lines.append(f"- `{remaining}` additional failures not shown")
    else:
        lines.extend([
            "",
            "Failure details:",
            f"- Stage: `{failure_stage()}`",
        ])

    if parse_note:
        lines.extend([
            "",
            "Notes:",
            f"- {parse_note}",
            f"- Fallback stage: `{failure_stage()}`",
        ])

    lines.extend([
        "",
        "Local repro:",
        "```bash",
        suite_repro_command(),
        "```",
    ])

    if details is not None and details.failing_tests:
        lines.extend([
            "",
            "Targeted repro examples:",
            "```bash",
            "\n\n".join(targeted_repro_commands(details.failing_tests)),
            "```",
        ])

    return "\n".join(lines)


def build_recovery_comment() -> str:
    return "\n".join([
        "Full UI suite recovered on `main`.",
        "",
        f"- Commit: [`{SHORT_SHA}`]({COMMIT_URL})",
        f"- Workflow run: [Test Suite #{GITHUB_RUN_NUMBER}]({RUN_URL})",
        f"- Date: {TIMESTAMP_UTC}",
    ])


def handle_failure() -> None:
    issue = ensure_tracker_issue_open()
    comment_on_issue(issue.number, build_failure_comment())
    print(f"Updated tracker issue #{issue.number}: {issue.url}")


def handle_success() -> None:
    issue = find_tracker_issue()
    if issue is None or issue.state.upper() != "OPEN":
        print("No open tracker issue to close.")
        return

    comment_on_issue(issue.number, build_recovery_comment())
    close_issue(issue.number)
    print(f"Closed tracker issue #{issue.number}: {issue.url}")


def main() -> None:
    if len(sys.argv) != 2 or sys.argv[1] not in {"failure", "success"}:
        raise SystemExit("usage: ui_test_ci_issue_tracker.py [failure|success]")

    mode = sys.argv[1]
    if mode == "failure":
        handle_failure()
        return

    handle_success()


if __name__ == "__main__":
    main()
