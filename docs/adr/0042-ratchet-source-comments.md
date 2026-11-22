# ADR-0042: Ratchet Source Comments

## Status

Accepted

## Context

Kaset already has thousands of source comments. Deleting all of them at once risks losing constraints that aren't apparent from the code. A count cap would also let a patch trade one deleted comment for an unrelated new one.

## Decision

Ban new prose comments and prohibit edits to legacy ones. Keep the code readable through its names and structure. Delete tautologies and stale comments, track implementation debt as issues, and preserve durable decisions in ADRs. Allow required interpreter and package headers; don't add new linter-suppression comments.

CI compares each changed file's comment text and multiplicity against the PR base (or the previous main-branch commit on push). Deletions and indentation changes pass; adding a comment, duplicating it, or replacing it fails even if the total falls. A Git-detected rename inherits the original file's comments. There is no checked-in allowance to update.

SwiftFormat's `markTypes` rule stays disabled so formatting doesn't reintroduce section comments. CI pins SwiftFormat because an unpinned upgrade can apply formatting rules that this checkout has not adopted; the ratchet uses the same pinned tokenizer.

## Consequences

The inventory covers checked-in Swift, web source, scripts, and comment-bearing configuration formats. The local Python checker uses SwiftFormat for Swift, the standard tokenizers for Python and Ruby, and lightweight lexical matching for the other formats. Documentation, vendored autoreview code, Xcode's generated project annotations, and code stored inside strings, heredocs, or YAML block scalars are outside the automated gate. Audit embedded code manually when touching it.

A mixed code/comment line doesn't count toward the number of source lines that can disappear. Removing prose may also add ADR or issue text, so the source-line savings are not net repository shrinkage.
