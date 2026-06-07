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

    def test_keeps_call_expression_secret_assignments(self) -> None:
        output = autoreview.redact_review_text("let password = getPassword()")
        multiline_assignment = "let pass" "word = getPassword()\nnext line"
        multiline_output = autoreview.redact_review_text(multiline_assignment)

        self.assertEqual("let password = getPassword()", output)
        self.assertIn("next line", multiline_output)

    def test_rejects_call_expression_secret_literal_arguments(self) -> None:
        assignment = "let pass" 'word = getPassword("actual-secret-123")'
        fallback_assignment = "let pass" 'word = getPassword() || "actual-secret-123"'
        template_assignment = "let pass" "word = getPassword(`actual-secret-123`)"
        bare_argument_assignment = "let pass" "word = getPassword(actual-secret-123)"
        secret_identifier_call = "let to" "ken = actualSecret123()"
        prefixed_secret_identifier_call = "let to" "ken = getActualSecret123()"
        with self.assertRaises(SystemExit):
            autoreview.redact_review_text(assignment)
        with self.assertRaises(SystemExit):
            autoreview.redact_review_text(fallback_assignment)
        with self.assertRaises(SystemExit):
            autoreview.redact_review_text(template_assignment)
        with self.assertRaises(SystemExit):
            autoreview.redact_review_text(bare_argument_assignment)
        with self.assertRaises(SystemExit):
            autoreview.redact_review_text(secret_identifier_call)
        with self.assertRaises(SystemExit):
            autoreview.redact_review_text(prefixed_secret_identifier_call)

    def test_redacts_colon_style_quoted_secret_values_with_spaces(self) -> None:
        output = autoreview.redact_review_text('password: "mock secret phrase value"\n{"api_key": "mock api key value"}')

        self.assertIn("[REDACTED_FIELD_SECRET]", output)
        self.assertNotIn("mock secret phrase value", output)
        self.assertNotIn("mock api key value", output)
        self.assertNotIn("phrase value", output)

    def test_redacts_short_unquoted_secret_fields(self) -> None:
        output = autoreview.redact_review_text('password: abc123\n{"api_key": x9}')

        self.assertEqual("[REDACTED_FIELD_SECRET]\n{[REDACTED_FIELD_SECRET]}", output)
        self.assertNotIn("abc123", output)
        self.assertNotIn("x9", output)

    def test_keeps_common_short_secret_field_literals(self) -> None:
        text = "password: false\ntoken: null\napiKey: test\nsecret: 2"

        output = autoreview.redact_review_text(text)

        self.assertEqual(text, output)

    def test_keeps_code_references_with_secret_like_property_names(self) -> None:
        output = autoreview.redact_review_text("return { password: user.passwordHash, apiKey: config.apiKey };")

        self.assertEqual("return { password: user.passwordHash, apiKey: config.apiKey };", output)

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

    def test_redacts_quoted_cookie_assignments(self) -> None:
        output = autoreview.redact_review_text(
            'SID="abcdef1234567890"\n'
            'redact_review_text(\'Cookie: SID="fedcba0987654321"\'); check(\'important change\')'
        )

        self.assertIn("[REDACTED_COOKIE]", output)
        self.assertIn("Cookie: [REDACTED_COOKIE_HEADER]", output)
        self.assertIn("); check('important change')", output)
        self.assertNotIn("abcdef1234567890", output)
        self.assertNotIn("fedcba0987654321", output)

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

    def test_safe_diff_omits_extensionless_secret_paths(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            repo = Path(temp)
            run(["git", "init"], repo)
            secret_path = repo / "secrets"
            secret_path.write_text("prod: opaque-credential-value\n")
            run(["git", "add", "secrets"], repo)

            output = autoreview.safe_diff(repo, ["--cached"], ["--patch"])

        self.assertIn("[1 sensitive changed path omitted from review bundle]", output)
        self.assertNotIn("secrets", output)
        self.assertNotIn("opaque-credential-value", output)

    def test_safe_diff_includes_non_ascii_paths(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            repo = Path(temp)
            run(["git", "init"], repo)
            path = repo / "é.txt"
            path.write_text("unicode-content\n")
            run(["git", "add", "é.txt"], repo)

            output = autoreview.safe_diff(repo, ["--cached"], ["--patch"])

        self.assertIn("unicode-content", output)

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

    def test_claude_file_tools_are_scoped_to_workspace(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            workspace = Path(temp)
            args = type("Args", (), {
                "claude_allowed_tools": "Read,Grep,Glob,WebSearch",
                "web_search": True,
            })()

            output = autoreview.claude_allowed_tools(args, workspace)

        self.assertIn("Read(./**)", output)
        self.assertIn("Grep(./**)", output)
        self.assertIn("Glob(./**)", output)
        self.assertIn("WebSearch", output)
        self.assertNotIn("Read,", output)

    def test_claude_file_tools_reject_out_of_workspace_scope(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            workspace = Path(temp)
            absolute_args = type("Args", (), {
                "claude_allowed_tools": "Read(//Users/**),WebSearch",
                "web_search": True,
            })()

            with self.assertRaises(SystemExit):
                autoreview.claude_allowed_tools(absolute_args, workspace)

    def test_claude_file_tools_allow_project_root_relative_scope(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            workspace = Path(temp)
            args = type("Args", (), {
                "claude_allowed_tools": "Read(/src/**),Glob(/docs/**),WebSearch",
                "web_search": True,
            })()

            output = autoreview.claude_allowed_tools(args, workspace)

        self.assertIn("Read(/src/**)", output)
        self.assertIn("Glob(/docs/**)", output)
        self.assertIn("WebSearch", output)

    def test_claude_file_tools_reject_placeholder_scope(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            workspace = Path(temp)
            args = type("Args", (), {
                "claude_allowed_tools": "Read([LOCAL_PATH]),WebSearch",
                "web_search": True,
            })()

            with self.assertRaises(SystemExit):
                autoreview.claude_allowed_tools(args, workspace)

            args = type("Args", (), {
                "claude_allowed_tools": "Read(/[LOCAL_PATH]),WebSearch",
                "web_search": True,
            })()

            with self.assertRaises(SystemExit):
                autoreview.claude_allowed_tools(args, workspace)


if __name__ == "__main__":
    unittest.main()
