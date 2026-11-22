# ADR-0043: Preserve Website Feedback and Download Fallbacks

## Status

Accepted

## Decision

Keep a live status region for the website's copy buttons. Their accessible names tell screen reader users what will be copied, but those names hide the temporary visual “Copied” text from assistive technology. The status region announces a successful copy without changing the accessible name or moving focus.

Keep the GitHub releases link in the page markup. The release lookup enhances it with a version and a direct DMG URL when available. If JavaScript is unavailable, the lookup fails, or the release has no DMG asset, the original link still takes users to the release page.
