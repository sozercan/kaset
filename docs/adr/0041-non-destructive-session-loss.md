# ADR-0041: Non-destructive session loss

## Status

Accepted

## Context

Signed-in users were repeatedly signed out of both release and debug builds.
Several paths turned a recoverable gap in the WebKit cookie jar into a durable
sign-out. A durable sign-out writes the invalidation tombstone and deletes the
archive. The next launch then sees a denied restore policy and clears the live
login cookies too (ADR-0037).

- The cookie observer treated any snapshot without a primary YouTube cookie as
  a sign-out. A partial session, another process clearing the shared jar, or a
  brief gap during a cookie update was enough.
- Every reauthentication prompt cleared the archive and live cookies before the
  login transaction captured a rollback baseline. Any `sessionExpired()` call
  opens that prompt, including one from a parser change or a stray 401/403.
  Cancelling it could not restore the previous session.
- Packaged debug builds used the release bundle identifier. Both builds shared
  one sandbox container and one WebKit cookie jar while keeping separate
  archives. Each launch replaced the jar with that build's archive, and release
  cleanup deleted the debug archive.

## Decision

The cookie observer never invalidates the archive. A snapshot without a primary
session keeps the last archive and logs a notice. Explicit sign-out and
failed-login cleanup remain the only paths that invalidate it.

Reauthentication begins the login transaction first, then clears only live
login-session cookies within it. The archive is not touched. This clear never
escalates to removing every WebKit cookie. If it fails, the attempt rolls back.
Cancelling restores the captured cookies, archive, and restore policy. A
completed login replaces them as before.

A login that starts without a live primary session rolls back to the persisted
archive. ADR-0037 rolled it back to an empty baseline, which deleted the archive.

`Scripts/build-app.sh debug` packages `com.sertacozercan.Kaset.debug` with
matching Sparkle mach-lookup exceptions. API Explorer reads the debug
container's `cookies.dat` first.

Each destructive or session-replacing step logs at notice level.

## Consequences

A session that really ended keeps its archive until the user signs in again or
signs out. Startup restores the dead cookies, and the first authenticated
request prompts for reauthentication.

Killing the app during a login attempt still leaves restoration denied. That
transaction state lives only in memory.

Packaged debug builds start with an empty container, so the developer signs in
once per build identity. They still share the login Keychain with release
builds.
