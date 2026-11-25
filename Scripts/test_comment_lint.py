from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

from comment_lint import comments


CHECKER = Path(__file__).with_name("comment_lint.py").resolve()


class CommentLexerTests(unittest.TestCase):
    def test_swift_nested_blocks_and_literals(self):
        source = (
            'let url = #"https://example.invalid/* literal */"#\n'
            'let script = """\n// literal\n"""\n'
            '/// Documentation\n'
            'let title = "é" /* outer\n /* nested */\n */ // tail\n'
        )
        found = comments("Example.swift", source)
        self.assertEqual([item.text for item in found], ["/// Documentation", "/* outer\n /* nested */\n */", "// tail"])
        for item in found:
            self.assertTrue(source.startswith(item.text, item.start))

    def test_required_headers_are_not_prose(self):
        self.assertEqual(comments("Package.swift", "// swift-tools-version: 6.2\n"), [])
        self.assertEqual(comments("script.sh", "#!/usr/bin/env bash\n"), [])
        self.assertEqual(len(comments("Example.swift", "// swift-tools-version: 6.2\n")), 1)
        self.assertEqual(len(comments("script.sh", "#!explanation\n")), 1)

    def test_non_swift_code_and_literal_delimiters(self):
        examples = {
            "worker.js": ('const url = `https://example.invalid`; const regex = /[/]/; // note\n', "// note"),
            "site.css": ('a::after {content: "/* literal */"} /* note */\n', "/* note */"),
            "site.html": ('<a title="<!-- literal -->">link</a><!-- note -->\n', "<!-- note -->"),
            "test.sh": ('cat <<\'EOF\'\n# literal\nEOF\necho "# literal" ${value#x} # note\n', "# note"),
            "build.yml": ('value: "one # two" # note\n', "# note"),
            "test.py": ('value = "# literal" # note\n', "# note"),
            "Localizable.strings": ('"url" = "https://example.invalid"; /* note */\n', "/* note */"),
            "test.scpt": ('set tag to "-- literal" -- note\n', "-- note"),
        }
        for path, (source, expected) in examples.items():
            with self.subTest(path=path):
                self.assertEqual([item.text for item in comments(path, source)], [expected])

    def test_heredoc_can_have_a_comment_on_the_opening_line(self):
        source = "cat <<'EOF' # opening note\n# literal\nEOF\n# closing note\n"
        self.assertEqual([item.text for item in comments("test.sh", source)], ["# opening note", "# closing note"])

    def test_apostrophe_in_unquoted_yaml_does_not_hide_comment(self):
        source = "title: It's yaml # note\nquoted: 'some # literal'\n"
        self.assertEqual([item.text for item in comments("test.yml", source)], ["# note"])

    def test_yaml_literal_blocks_are_data_not_comments(self):
        source = "- message: |- # note\n    # literal\n  value: >\n    # literal\n  tail: value # tail\n"
        self.assertEqual([item.text for item in comments("test.yml", source)], ["# note", "# tail"])

    def test_workflows_allow_exact_versions_for_sha_pins(self):
        sha = "a" * 40
        source = f"      - uses: owner/action@{sha} # v1.2.3\n        uses: owner/repo/path@{sha} # v2.0.0\n"
        for extension in ("yml", "yaml"):
            self.assertEqual(comments(f".github/workflows/test.{extension}", source), [])
        self.assertEqual(len(comments("outside.yml", source)), 2)

    def test_other_workflow_comments_are_counted(self):
        pin = f"owner/action@{'a' * 40}"
        examples = (
            (f"uses: {pin} # v1", "# v1"),
            (f"uses: {pin} # v1.2", "# v1.2"),
            (f"uses: {pin} # v01.2.3", "# v01.2.3"),
            (f"uses: {pin} # v1.2.3 workaround", "# v1.2.3 workaround"),
            ("uses: owner/action@v1.2.3 # v1.2.3", "# v1.2.3"),
            (f"name: {pin} # v1.2.3", "# v1.2.3"),
            ("# v1.2.3", "# v1.2.3"),
        )
        for source, expected in examples:
            with self.subTest(source=source):
                self.assertEqual([item.text for item in comments(".github/workflows/test.yml", source)], [expected])

    def test_ruby_recognizes_comments_without_a_space_and_document_blocks(self):
        source = 'pattern = /a#b/\nvalue = "é"# note\n=begin\nblock\n=end\n'
        found = comments("Cask.rb", source)
        self.assertEqual([item.text for item in found], ["# note", "=begin\nblock\n=end"])
        for item in found:
            self.assertTrue(source.startswith(item.text, item.start))

    def test_javascript_regex_after_control_statement_is_not_a_comment(self):
        source = (
            r"if (enabled && ready()) /https?:\/\//.test(url);" "\n"
            "const quotient = value.if() / a / b; // note\n"
        )
        self.assertEqual([item.text for item in comments("site.js", source)], ["// note"])

    def test_javascript_keyword_properties_can_be_division_operands(self):
        examples = (
            "const quotient = value.delete / divisor /* note */;\n",
            "const quotient = value?.delete / divisor /* note */;\n",
            "class Example { #delete; value() { return this.#delete / divisor /* note */; } }\n",
        )
        for source in examples:
            with self.subTest(source=source):
                self.assertEqual([item.text for item in comments("site.js", source)], ["/* note */"])

    def test_javascript_spread_does_not_behave_like_property_access(self):
        source = "const chars = [...typeof /[//]/]; // note\n"
        self.assertEqual([item.text for item in comments("site.js", source)], ["// note"])

    def test_shell_ansi_c_quoted_text_can_contain_hashes(self):
        source = r"value=$'don\'t # literal' # note" "\n"
        self.assertEqual([item.text for item in comments("test.sh", source)], ["# note"])


class CommentRatchetTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name)
        self.git("init", "-q")
        self.git("config", "user.name", "Comment Lint Test")
        self.git("config", "user.email", "test@example.invalid")
        self.git("config", "commit.gpgsign", "false")
        self.write("old.js", "// existing\n// removable\nconst value = 1;\n")
        self.git("add", ".")
        self.git("commit", "-qm", "Baseline")

    def write(self, path, text):
        (self.root / path).write_text(text, encoding="utf-8")

    def git(self, *arguments):
        subprocess.run(["git", *arguments], cwd=self.root, check=True, capture_output=True)

    def check(self, *arguments):
        return subprocess.run([sys.executable, CHECKER, *arguments], cwd=self.root, capture_output=True, text=True)

    def test_removals_and_reindent_pass(self):
        self.write("old.js", "    // existing\nconst value = 2;\n")
        self.assertEqual(self.check("--base", "HEAD").returncode, 0)

    def test_smaller_diff_cannot_trade_old_comments_for_new_ones(self):
        self.write("old.js", "const value = 2; // replacement\n")
        result = self.check("--base", "HEAD")
        self.assertEqual(result.returncode, 1)
        self.assertIn("old.js:1: error: new or edited comment", result.stdout)

    def test_duplicate_or_copied_comments_do_not_pass(self):
        self.write("old.js", "// existing\n// existing\nconst value = 1;\n")
        self.write("new.js", "// existing\n")
        result = self.check("--base", "HEAD")
        self.assertEqual(result.returncode, 1)
        self.assertIn("old.js:2:", result.stdout)
        self.assertIn("new.js:1:", result.stdout)

    def test_renames_keep_one_allowance(self):
        self.git("mv", "old.js", "renamed.js")
        self.assertEqual(self.check("--base", "HEAD").returncode, 0)

    def test_inventory_counts_only_lines_that_can_disappear(self):
        self.write("old.js", "/* note\n * note\n */\nconst value = 1; // inline\n/* part */ /* part */\n")
        result = self.check("--inventory")
        self.assertEqual(result.returncode, 0)
        self.assertIn("4 comments in 1 files; 4 removable lines and 1 lines that also contain code.", result.stdout)


if __name__ == "__main__":
    unittest.main()
