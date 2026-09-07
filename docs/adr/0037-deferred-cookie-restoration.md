# ADR-0037: Deferred cookie restoration

## Status

Accepted

## Context

WebKit can retain a valid Google session when the native cookie archive is
missing. Archive storage or its restore policy can also be temporarily
unreadable. Treating these states as failed cleanup makes a storage retry erase
the session. Allowing backups during that delay can overwrite the retained
archive with an older live cookie jar.

## Decision

Startup restoration returns `ready`, `unavailable`, or `failed`.
`unavailable` preserves both stores and blocks authentication, login WebView
creation, and cookie backups. Retry joins one restoration task and reads the
policy and archive again. Only `failed` requires the existing cleanup flow.
Explicit sign-out still fences pending restoration and invalidates both stores.

An allowed policy with no archive preserves the live WebKit session. A denied
policy clears it. A readable archive remains authoritative, and invalid archive
contents retain the existing quarantine behavior.

A partial Google session without a primary YouTube authentication cookie can
start login. Its native archive baseline is empty, while rollback retains the
complete live Google and YouTube cookie jar captured before login.

The root task follows authentication state and owns account loading for startup,
sign-in, and recovery. Initializing or active-login tasks cannot continue into
playback cleanup. Cancelling an early sign-in resumes the status check; its
resolved state starts the task that performs cleanup and account loading. A
newly presented cleanup sheet captures the last login attempt's identity so
Retry retains ownership after cancellation releases the active attempt.

## Consequences

Temporary storage failures keep a recoverable session intact across repeated
sign-in attempts. Authentication stays unavailable until a storage read succeeds
or the user explicitly signs out. Observer and forced backups share the same
restoration gate so neither can replace an archive before that decision.
