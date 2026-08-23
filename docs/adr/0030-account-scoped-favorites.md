# ADR-0030: Account-Scoped Favorites Persistence

## Status

Accepted

## Context

Kaset Favorites are local pins, not a YouTube Music API resource. The original
implementation stored every user's pins in one `favorites.json` file, so
favorites could appear under a different Google user, primary account, brand
account, or signed-out session.

Scoping only by `UserAccount.id` is insufficient because every primary Google
account uses the literal ID `primary`. Authentication and account discovery are
also asynchronous: account-list responses, WebView identity pins, and manual
account switches can finish after a reauthentication boundary unless their
provenance is checked. Finally, a valid account-list response can omit the
Google email that is normally used to recognize a returning owner.

The persistence design must therefore:

- separate parent Google users as well as their primary and brand identities;
- never expose raw email, cookies, tokens, or session identifiers in filenames;
- keep signed-out state distinct from the primary account;
- support email-less responses without reusing an unverified previous owner;
- migrate old and provisional files without making a failed migration
  unrecoverable;
- reject asynchronous commits whose authentication generation is stale; and
- avoid production filesystem writes from unit or UI tests.

## Decision

Favorites use an opaque, local ownership model:

1. `AccountService` assigns each parent Google user a local owner UUID.
2. The authenticated SAPISID value and normalized Google email are separately
   hashed and stored only as aliases to that UUID. Raw authentication material
   and email are never persisted or used in filenames or logs. A credential-only
   owner remains provisional: it has no active favorites scope, cannot mutate,
   and cannot claim legacy files until an email alias corroborates ownership.
   A stored auth alias becomes active only after a matching email corroborates
   it in the current authentication generation; later partial responses in that
   generation may omit email. A newly observed email cannot
   replace or extend an already-bound owner's aliases without independent
   corroboration; conflicting or unclaimed changed emails are not persisted.
3. Each primary or brand identity gets a deterministic scope derived from the
   owner UUID and the selected YouTube account ID.
4. Across launches, the auth fingerprint restores a candidate owner mapping,
   but activation still waits for matching email corroboration in the current
   authentication generation because Google can reuse one SAPISID across
   multi-login identities. After that corroboration, later partial responses
   in the same generation may omit email. If a later email alias resolves to a
   different known owner, migration uses prepare → commit → bind → finalize phases. Baseline
   and staged files keep retries authoritative until every target is durable
   and the alias registry has committed. The same registry persists pending
   finalization records so interrupted source/claim cleanup resumes on launch.
5. Signed-out state has no active scope. Guest Mode uses a separate guest scope
   and restores the last signed-in scope on exit. Account selection keeps Guest
   Mode published while a narrowly scoped account-list refresh uses the preserved
   signed-in session for switch/rollback tokens. Guest Mode exits only after the
   WebKit identity switch commits; failed or superseded switches leave it active.
6. Favorite mutation UI and manager methods remain unavailable until an active
   scope exists.
7. `AuthService.accountIdentityGeneration` advances at logout, session expiry,
   and every explicit login completion, even when Google reuses the same cookie
   value across multi-login identities. Login
   restoration and sign-out are single-flight and mutually serialized. API
   requests capture the generation that built their auth headers, so stale
   responses cannot expire or publish data into a newer authenticated identity.
8. `AccountService` snapshots that generation across account fetches, restored
   session pins, manual switches, and rollback work. Stale operations cannot
   commit account state, verified identity, selection, or favorites scope.
   Explicit sign-out establishes a synchronous mutation fence before its first
   suspension, and both sign-out and reauthentication drain retained WebKit
   session mutations before cookies are cleared or sampled. The login WebView is
   not created until that reauthentication barrier establishes its cookie baseline.
9. The opaque owner registry is written to `UserDefaults` and to an atomic
   backup manifest beside the favorites files. The manifest is authoritative on
   recovery and heals a missing or corrupt preferences copy. Unit and UI tests
   keep `FavoritesManager.shared` in memory; persistence tests use an isolated
   temporary directory.

Legacy `favorites.json` data migrates into the first resolved signed-in opaque
scope, while every `favorites-<accountId>.json` file for the verified account
list is claimed for its corresponding opaque scope even when it is not selected.
When a target already exists, migration
atomically renames the globally discoverable legacy file to a destination-bound
claim before modifying the target; retries and owner reconciliation can resume
only for that claimed scope. Scope writes are atomic, pending debounced writes
are flushed before switches, pending snapshots are materialized before legacy
migration retries, and merge preparation leaves source files and claims intact
until the new owner binding is committed.
If a scope file cannot be read or decoded, mutation controls remain disabled so
the unreadable file cannot be overwritten from an empty fallback snapshot.

## Consequences

- Different Google users and brand identities no longer share local favorites.
- Logout and reauthentication cannot erase or reactivate another user's pins.
- Email-less sessions after a new authentication boundary remain fail-closed
  until ownership is corroborated in that generation. Returning email-bound
  sessions then keep using their hashed auth alias for later partial responses.
  Email reconciliation is retryable and crash-tolerant.
- Account lifecycle code carries an additional authentication-generation
  invariant that must be checked by future asynchronous account commits.
- The owner alias registry adds redundant local metadata in `UserDefaults` and
  an Application Support manifest, but stores no raw email or authentication
  material.
- Old provisional source files or destination-bound legacy claims can remain
  after a cleanup failure; this is safe because canonical targets are durable,
  claims cannot be consumed by another account scope, and cleanup is idempotent.
