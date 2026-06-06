#!/usr/bin/env python3
from __future__ import annotations

import subprocess
import tempfile
import unittest
from importlib.machinery import SourceFileLoader
from importlib.util import module_from_spec, spec_from_loader
from pathlib import Path


SCRIPT = Path(__file__).with_name("autoreview")
LOADER = SourceFileLoader("autoreview_helper", str(SCRIPT))
SPEC = spec_from_loader(LOADER.name, LOADER)
assert SPEC is not None
autoreview = module_from_spec(SPEC)
LOADER.exec_module(autoreview)


def run(args: list[str], cwd: Path) -> str:
    result = subprocess.run(args, cwd=cwd, check=True, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    return result.stdout


class AutoReviewHelperTests(unittest.TestCase):
    def test_redacts_quoted_secret_values_with_spaces(self) -> None:
        output = autoreview.redact_review_text('PASSWORD="mock secret phrase value"')

        self.assertIn("[REDACTED_ENV_SECRET]", output)
        self.assertNotIn("mock secret phrase value", output)
        self.assertNotIn("phrase value", output)

    def test_redacts_colon_style_quoted_secret_values_with_spaces(self) -> None:
        output = autoreview.redact_review_text('password: "mock secret phrase value"\n{"api_key": "mock api key value"}')

        self.assertIn("[REDACTED_FIELD_SECRET]", output)
        self.assertNotIn("mock secret phrase value", output)
        self.assertNotIn("mock api key value", output)
        self.assertNotIn("phrase value", output)

    def test_redacts_credential_urls_with_email_style_usernames(self) -> None:
        output = autoreview.redact_review_text(
            "DATABASE_URL=postgres://user@example.com:mock-password@db.example.test/app"
        )

        self.assertIn("[REDACTED_CREDENTIAL_URL]", output)
        self.assertNotIn("mock-password", output)
        self.assertNotIn("db.example.test", output)

    def test_redacts_oauth_fragment_urls(self) -> None:
        output = autoreview.redact_review_text("https://accounts.example.test/callback#code=mock-code-123456")

        self.assertEqual("[REDACTED_AUTH_URL]", output)

    def test_redacts_generic_session_cookies(self) -> None:
        output = autoreview.redact_review_text("SESSIONID=abcdef1234567890")

        self.assertEqual("[REDACTED_COOKIE]", output)

    def test_redacts_token_auth_schemes(self) -> None:
        output = autoreview.redact_review_text("Authorization: Token abcdefghijklmnop")

        self.assertIn("[REDACTED_AUTH_HEADER]", output)
        self.assertNotIn("abcdefghijklmnop", output)

    def test_keeps_benign_token_prose(self) -> None:
        output = autoreview.redact_review_text("token classification should stay reviewable")

        self.assertEqual("token classification should stay reviewable", output)

    def test_allows_documented_secret_placeholders(self) -> None:
        output = autoreview.redact_review_text(
            'password: "REDACTED"\napiKey: "mock-token"\ntoken: "test-cookie"\\nsecret=mock-token'
        )

        self.assertEqual(
            "[PLACEHOLDER_SECRET]\n[PLACEHOLDER_SECRET]\n[PLACEHOLDER_SECRET]\\n[PLACEHOLDER_SECRET]",
            output,
        )

    def test_deletion_hunks_use_new_file_anchor_not_old_span(self) -> None:
        patch = """diff --git a/file.txt b/file.txt
--- a/file.txt
+++ b/file.txt
@@ -10,3 +10,0 @@
-one
-two
-three
"""

        self.assertEqual({"file.txt": [(10, 10)]}, autoreview.parse_changed_line_ranges(patch))

    def test_local_bundle_hides_sensitive_untracked_filenames(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            repo = Path(temp)
            run(["git", "init"], repo)
            (repo / ".envrc").write_text("export PASSWORD=mock-secret-value\n")

            output = autoreview.local_bundle(repo)

        self.assertIn("[sensitive untracked file omitted]", output)
        self.assertNotIn(".envrc", output)
        self.assertNotIn("mock-secret-value", output)

    def test_safe_diff_omits_renames_from_sensitive_paths(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            repo = Path(temp)
            run(["git", "init"], repo)
            run(["git", "config", "user.email", "test@example.invalid"], repo)
            run(["git", "config", "user.name", "Test User"], repo)
            (repo / ".env").write_text("PASSWORD=mock-secret-value\n")
            run(["git", "add", ".env"], repo)
            run(["git", "commit", "-m", "add env"], repo)
            run(["git", "mv", ".env", "example.txt"], repo)

            output = autoreview.safe_diff(repo, ["--cached"], ["--patch", "--find-renames"])

        self.assertIn("[1 sensitive changed path omitted from review bundle]", output)
        self.assertNotIn(".env", output)
        self.assertNotIn("example.txt", output)
        self.assertNotIn("mock-secret-value", output)

    def test_safe_diff_omits_copies_from_sensitive_paths(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            repo = Path(temp)
            run(["git", "init"], repo)
            run(["git", "config", "user.email", "test@example.invalid"], repo)
            run(["git", "config", "user.name", "Test User"], repo)
            (repo / ".env").write_text("PASSWORD=mock-secret-value\n")
            run(["git", "add", ".env"], repo)
            run(["git", "commit", "-m", "add env"], repo)
            (repo / "example.txt").write_text((repo / ".env").read_text())
            run(["git", "add", "example.txt"], repo)

            output = autoreview.safe_diff(repo, ["--cached"], ["--patch", "--find-renames"])

        self.assertIn("[1 sensitive changed path omitted from review bundle]", output)
        self.assertNotIn(".env", output)
        self.assertNotIn("example.txt", output)
        self.assertNotIn("mock-secret-value", output)

    def test_safe_diff_omits_yaml_secret_paths(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            repo = Path(temp)
            run(["git", "init"], repo)
            secret_path = repo / "config" / "secrets.yml"
            secret_path.parent.mkdir()
            secret_path.write_text("prod: opaque-credential-value\n")
            run(["git", "add", "config/secrets.yml"], repo)

            output = autoreview.safe_diff(repo, ["--cached"], ["--patch"])

        self.assertIn("[1 sensitive changed path omitted from review bundle]", output)
        self.assertNotIn("config/secrets.yml", output)
        self.assertNotIn("opaque-credential-value", output)

    def test_safe_diff_treats_safe_paths_as_literal_pathspecs(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            repo = Path(temp)
            run(["git", "init"], repo)
            magic_path = repo / ":(glob)*"
            sensitive_path = repo / "token.txt"
            magic_path.write_text("safe-content\n")
            sensitive_path.write_text("opaque-sensitive-content\n")
            run(["git", "add", str(magic_path.name), str(sensitive_path.name)], repo)

            output = autoreview.safe_diff(repo, ["--cached"], ["--patch"])

        self.assertIn("[1 sensitive changed path omitted from review bundle]", output)
        self.assertIn("safe-content", output)
        self.assertNotIn("token.txt", output)
        self.assertNotIn("opaque-sensitive-content", output)

    def test_safe_show_includes_root_commit_paths(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            repo = Path(temp)
            run(["git", "init"], repo)
            run(["git", "config", "user.email", "test@example.invalid"], repo)
            run(["git", "config", "user.name", "Test User"], repo)
            (repo / "first.txt").write_text("root-commit-content\n")
            run(["git", "add", "first.txt"], repo)
            run(["git", "commit", "-m", "initial"], repo)
            commit = run(["git", "rev-parse", "HEAD"], repo).strip()

            output = autoreview.safe_show(repo, commit, ["--patch", "--format=fuller"])

        self.assertIn("first.txt", output)
        self.assertIn("root-commit-content", output)


if __name__ == "__main__":
    unittest.main()
