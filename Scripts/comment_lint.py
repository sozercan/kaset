import argparse
from collections import Counter
from dataclasses import dataclass
import io
import json
from pathlib import Path
import re
import subprocess
import sys
import tokenize


DOUBLE = r'"(?:\\[\s\S]|[^"\\])*"'
SINGLE = r"'(?:\\[\s\S]|[^'\\])*'"
QUOTES = f"{DOUBLE}|{SINGLE}"
SLASHES = r"(?P<comment>/\*[\s\S]*?\*/|//[^\n]*)"
HASH = r"(?P<comment>(?<![^\s;|&()])\#[^\n]*)"
CONFIG_HASH = r"(?P<comment>(?<!\S)\#[^\n]*)"
CONFIG_QUOTES = rf"(?<![^\s=\[\]{{}}:,])(?:{QUOTES})"
YAML_BLOCK = re.compile(
    rf"^(?P<indent> *)(?:(?P<sequence>-[ \t]+)?(?:{QUOTES}|[^:#]+):[ \t]+|-[ \t]+)"
    r"[|>](?:[1-9][+-]?|[+-][1-9]?)?[ \t]*(?:#.*)?$"
)
ACTION_RELEASE_ANNOTATION = re.compile(
    r" *(?:- +)?uses: +[\w.-]+(?:/[\w.-]+)+@[0-9a-f]{40} +# v"
    r"(?:0|[1-9][0-9]*)(?:\.(?:0|[1-9][0-9]*)){2}[ \t]*"
)
JS_TOKENS = re.compile(
    rf"{QUOTES}|`(?:\\[\s\S]|[^`\\])*`|{SLASHES}|\#?[\w$]+|\.{{3}}|\?\.|=>|\+\+|--|\S"
)
JS_REGEX = re.compile(r"/(?![/*])(?:\\[^\n]|\[(?:\\[^\n]|[^\]\\\n])*\]|[^/\\\[\n])+/[a-z]*")
JS_CONDITIONS = {"if", "while", "for", "with"}
JS_REGEX_PREFIXES = {
    "(", "[", "{", "=", ",", ":", ";", "!", "&", "|", "?", "+", "-", "*", "%", "^", "~", "/", "=>", "...",
}
JS_REGEX_KEYWORDS = {"return", "throw", "case", "yield", "typeof", "void", "delete", "else", "do"}
HEREDOC = r"(?<!<)<<-?[ \t]*['\"]?(?P<delimiter>\w+)['\"]?(?P<tail>[^\n]*)\n[\s\S]*?^\t*(?P=delimiter)$"
RUBY_LEX = """
source = STDIN.read.force_encoding(Encoding::UTF_8)
lines = source.lines
offsets = [0]
lines.each { |line| offsets << offsets.last + line.length }
comment_kinds = [:on_comment, :on_embdoc_beg, :on_embdoc, :on_embdoc_end]
tokens = Ripper.lex(source).select { |_position, kind| comment_kinds.include?(kind) }
puts JSON.generate(tokens.map do |(line, column), kind, text|
  [offsets[line - 1] + lines[line - 1].byteslice(0, column).length, kind, text]
end)
"""

LEXERS = {
    "strings": re.compile(rf"{QUOTES}|{SLASHES}"),
    "css": re.compile(rf"{QUOTES}|(?P<comment>/\*[\s\S]*?\*/)"),
    "markup": re.compile(
        rf"<!\[CDATA\[[\s\S]*?\]\]>|(?P<comment><!--[\s\S]*?-->)|<(?:{QUOTES}|[^\"'<>])*>",
    ),
    "shell": re.compile(rf"{HEREDOC}|{DOUBLE}|\${SINGLE}|'[^']*'|\\[^\n]|{HASH}", re.MULTILINE),
    "hash": re.compile(rf"{QUOTES}|{HASH}"),
    "config": re.compile(rf"{CONFIG_QUOTES}|{CONFIG_HASH}"),
    "applescript": re.compile(rf"{DOUBLE}|(?P<comment>\(\*[\s\S]*?\*\)|--[^\n]*|\#[^\n]*)"),
}

LANGUAGES = {
    ".swift": "swift",
    ".js": "javascript",
    ".css": "css",
    ".html": "markup",
    ".xml": "markup",
    ".xcscheme": "markup",
    ".svg": "markup",
    ".sdef": "markup",
    ".plist": "markup",
    ".entitlements": "markup",
    ".strings": "strings",
    ".sh": "shell",
    ".env": "shell",
    ".rb": "ruby",
    ".yaml": "config",
    ".yml": "config",
    ".toml": "config",
    ".scpt": "applescript",
    ".py": "python",
}


@dataclass(frozen=True)
class Comment:
    start: int
    text: str

    @property
    def key(self):
        return tuple(line.strip() for line in self.text.split("\n"))


def swift_comments(source):
    if not source.strip():
        return
    tokens = json.loads(run("swiftformat", "--output-tokens", "--disable", "all", "--quiet", source=source))["tokens"]
    offset = 0
    start = None
    depth = 0
    for token in tokens:
        text = token["string"]
        end = offset + len(text)
        if token["type"] == "startOfScope" and text in {"//", "/*", "#!"}:
            if start is None:
                start = offset
            if text == "/*":
                depth += 1
        elif start is not None:
            if token["type"] == "endOfScope" and text == "*/":
                depth -= 1
                if depth == 0:
                    yield Comment(start, source[start:end])
                    start = None
            elif token["type"] == "linebreak" and depth == 0:
                yield Comment(start, source[start:offset])
                start = None
        offset = end
    if start is not None:
        yield Comment(start, source[start:offset])
    if offset != len(source):
        raise ValueError("SwiftFormat token lengths do not match the source")


def python_comments(source):
    offsets = [0]
    for line in source.split("\n"):
        offsets.append(offsets[-1] + len(line) + 1)
    for token in tokenize.generate_tokens(io.StringIO(source).readline):
        if token.type == tokenize.COMMENT:
            line, column = token.start
            yield Comment(offsets[line - 1] + column, token.string)


def ruby_comments(source):
    tokens = json.loads(run("ruby", "-rripper", "-rjson", "-e", RUBY_LEX, source=source))
    start = None
    for offset, kind, text in tokens:
        if kind == "on_comment":
            yield Comment(offset, text.rstrip("\n"))
        elif kind == "on_embdoc_beg":
            start = offset
        elif kind == "on_embdoc_end" and start is not None:
            yield Comment(start, source[start:offset + len(text)].rstrip("\n"))
            start = None


def javascript_comments(source):
    offset = 0
    allow_regex = True
    pending_condition = False
    previous = ""
    parentheses = []
    while match := JS_TOKENS.search(source, offset):
        offset = match.end()
        if match["comment"] is not None:
            yield Comment(match.start(), match["comment"])
            continue
        token = match[0]
        if token == "/" and allow_regex and (literal := JS_REGEX.match(source, match.start())):
            offset = literal.end()
            token = literal[0]
        if token == "(":
            parentheses.append(pending_condition)
        property_access = previous in {".", "?."}
        if token == ")" and parentheses:
            allow_regex = parentheses.pop()
        else:
            allow_regex = token in JS_REGEX_PREFIXES or (not property_access and token in JS_REGEX_KEYWORDS)
        pending_condition = not property_access and token in JS_CONDITIONS
        previous = token


def language(path):
    if path.startswith(".agents/skills/autoreview/"):
        return None
    if path in {".gitignore", ".swiftformat"}:
        return "hash"
    return LANGUAGES.get(Path(path).suffix)


def lexical_comments(kind, source):
    for match in LEXERS[kind].finditer(source):
        if match["comment"] is not None:
            yield Comment(match.start("comment"), match["comment"])
        elif kind == "shell" and match["tail"]:
            for comment in lexical_comments(kind, match["tail"]):
                yield Comment(match.start("tail") + comment.start, comment.text)


def mask_yaml_literal_blocks(source):
    lines = source.split("\n")
    block_indent = None
    for index, line in enumerate(lines):
        if block_indent is not None:
            if not line.strip() or len(line) - len(line.lstrip(" ")) > block_indent:
                lines[index] = " " * len(line)
                continue
            block_indent = None
        if match := YAML_BLOCK.fullmatch(line):
            block_indent = len(match["indent"]) + len(match["sequence"] or "")
    return "\n".join(lines)


def required_header(path, kind, comment):
    if comment.start:
        return False
    if path == "Package.swift" and comment.text.startswith("// swift-tools-version:"):
        return True
    is_script = kind in {"swift", "python", "ruby", "shell", "javascript"}
    return is_script and re.match(r"#![ \t]*/", comment.text) is not None


def action_release_annotation(source, comment):
    line_start = source.rfind("\n", 0, comment.start) + 1
    line_end = comment.start + len(comment.text)
    return ACTION_RELEASE_ANNOTATION.fullmatch(source, line_start, line_end) is not None


def comments(path, source):
    kind = language(path)
    if kind == "swift":
        found = swift_comments(source)
    elif kind == "python":
        found = python_comments(source)
    elif kind == "ruby":
        found = ruby_comments(source)
    elif kind == "javascript":
        found = javascript_comments(source)
    elif kind in LEXERS:
        scan_source = mask_yaml_literal_blocks(source) if path.endswith((".yaml", ".yml")) else source
        found = lexical_comments(kind, scan_source)
    else:
        return []

    workflow = path.endswith((".yaml", ".yml")) and Path(path).parent == Path(".github/workflows")
    return [
        comment for comment in found
        if not required_header(path, kind, comment) and not (workflow and action_release_annotation(source, comment))
    ]


def run(*arguments, source=None):
    result = subprocess.run(arguments, input=source, capture_output=True, encoding="utf-8")
    if result.returncode:
        raise ValueError(result.stderr.strip() or f"{' '.join(arguments)} failed")
    return result.stdout


def git(*arguments):
    return run("git", *arguments)


def working_source(path):
    file = Path(path)
    if file.is_file() and not file.is_symlink():
        return file.read_text(encoding="utf-8")
    return ""


def changed_files(base):
    entries = iter(git("diff", "--name-status", "--find-renames", "--diff-filter=AMRT", "-z", base, "--").split("\0")[:-1])
    for status in entries:
        path = next(entries)
        if status.startswith("R"):
            yield next(entries), path
        else:
            yield path, None if status == "A" else path
    for path in git("ls-files", "--others", "--exclude-standard", "-z").split("\0")[:-1]:
        yield path, None


def check(base):
    revision = git("rev-parse", "--verify", "--end-of-options", f"{base}^{{commit}}").strip()
    clean = True
    for path, previous_path in changed_files(revision):
        if language(path) is None:
            continue
        try:
            source = working_source(path)
            current = comments(path, source)
            if not current:
                continue
            previous = git("show", f"{revision}:{previous_path}") if previous_path else ""
            remaining = Counter(comment.key for comment in comments(previous_path or path, previous))
            for comment in current:
                if remaining[comment.key]:
                    remaining[comment.key] -= 1
                else:
                    line = source.count("\n", 0, comment.start) + 1
                    print(f"{path}:{line}: error: new or edited comment; use code, documentation, or an ADR instead")
                    clean = False
        except (ValueError, tokenize.TokenError) as error:
            raise ValueError(f"{path}: {error}") from error
    return clean


def inventory(list_comments, revision):
    totals = Counter()
    files = git("ls-tree", "-rz", "--name-only", revision) if revision else git("ls-files", "-co", "--exclude-standard", "-z")
    for path in sorted(set(files.split("\0"))):
        if language(path) is None:
            continue
        try:
            source = git("show", f"{revision}:{path}") if revision else working_source(path)
            found = comments(path, source)
        except (ValueError, tokenize.TokenError) as error:
            raise ValueError(f"{path}: {error}") from error
        if not found:
            continue
        remainder = source
        for comment in reversed(found):
            end = comment.start + len(comment.text)
            remainder = remainder[:comment.start] + "\n" * comment.text.count("\n") + remainder[end:]
        lines = set()
        for comment in found:
            first = source.count("\n", 0, comment.start) + 1
            last = first + comment.text.count("\n")
            lines.update(range(first, last + 1))
            if list_comments:
                print(f"{path}:{first}: {comment.text}")
        code_lines = remainder.split("\n")
        removable = sum(not code_lines[line - 1].strip() for line in lines)
        totals.update(files=1, comments=len(found), removable=removable, mixed=len(lines) - removable)
    print(f"{totals['comments']:,} comments in {totals['files']:,} files; "
          f"{totals['removable']:,} removable lines and {totals['mixed']:,} lines that also contain code.")


def main():
    parser = argparse.ArgumentParser(description="Ratchet source comments against Git, or inventory them.")
    action = parser.add_mutually_exclusive_group(required=True)
    action.add_argument("--base", help="Git revision to compare with the working tree")
    action.add_argument("--inventory", action="store_true", help="Count comments and removable lines")
    action.add_argument("--list", action="store_true", help="List comments with file and line locations")
    parser.add_argument("--revision", help="Read an inventory from this Git revision instead of the working tree")
    args = parser.parse_args()
    if args.revision and args.base:
        parser.error("--revision requires --inventory or --list")
    try:
        if args.base is not None:
            if not args.base:
                parser.error("--base must not be empty")
            return 0 if check(args.base) else 1
        revision = git("rev-parse", "--verify", "--end-of-options", f"{args.revision}^{{commit}}").strip() if args.revision else None
        inventory(args.list, revision)
        return 0
    except (ValueError, OSError) as error:
        print(f"comment-lint: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
