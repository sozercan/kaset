# ADR-0033: Suppress Passkey Detection in the Login WebView

## Status

Accepted

## Context

Kaset signs users in by loading `accounts.google.com` in a `WKWebView` and
capturing the resulting Google session cookies. When an account has passkeys,
Google's sign-in page offers passkey authentication, and that ceremony can
never succeed inside Kaset's WebView (issue #291):

- `WKWebView` exposes the WebAuthn API (`window.PublicKeyCredential`), and
  `PublicKeyCredential.getClientCapabilities()` even reports
  `hybridTransport: true`, so Google's page treats the WebView as a
  passkey-capable browser.
- However, the system authorizes passkey ceremonies only for apps that hold
  the restricted `com.apple.developer.web-browser.public-key-credential`
  entitlement, or for relying parties covered by the app's
  `webcredentials` Associated Domains. Every `navigator.credentials.get()`
  call from Kaset is rejected almost instantly with `NotAllowedError`, with
  no system UI and no Bluetooth activity.
- Google interprets that failure as a broken cross-device (hybrid) attempt
  and renders the "Something went wrong — check that Bluetooth is on and the
  devices are close together" error screen. The advice is unsatisfiable; the
  only escape is "Try another way" and a manual password entry.

Neither supported path to real in-WebView passkeys is available to Kaset:

- The browser entitlement is an Apple-managed capability granted after review
  only to apps that act as general-purpose web browsers (URL field, search,
  bookmarks), requested by the Account Holder of an organization developer
  account, and it must be authorized by an embedded provisioning profile.
  A YouTube Music client does not meet the criteria, and the profile
  requirement is incompatible with Kaset's ad-hoc and Apple Development
  signing fallbacks.
- Associated Domains would require Google to list Kaset's app identifier in
  the `google.com` AASA file, which will not happen.

Moving login to the system browser (or `ASWebAuthenticationSession`) does not
fit either: Kaset needs the Google session cookies to land in its own
`WKWebsiteDataStore`, an authentication session only returns a callback URL,
and importing cookies from another browser is both fragile (Google invalidates
sessions reused across client fingerprints) and indistinguishable from
credential-stealing behavior.

Shipping WKWebView apps in the same situation (for example the Nook browser
while awaiting the entitlement, and several Claude/Google wrapper apps)
converge on the same mitigation: hide WebAuthn from the sign-in page so the
site never offers a flow that cannot succeed.

## Decision

1. **Hide WebAuthn capability signals in the login and session-switch
   WebViews.** `WebKitManager.createSessionSwitchWebViewConfiguration()`
   attaches a `WKUserScript` (`LoginPasskeySuppression`), injected at document
   start into all frames, that undefines `window.PublicKeyCredential` and
   rejects `navigator.credentials.get`/`create` calls requesting a
   `publicKey` credential with `NotAllowedError`. Google's sign-in page
   feature-detects WebAuthn before offering passkeys, so it routes the
   account through password (and other non-WebAuthn) challenges instead of
   the dead-end hybrid flow.
2. **Scope the suppression to the authentication surface only.** The script
   is added solely to the configuration used by the login sheet and hidden
   account-switch navigations. Those WebViews load Google sign-in pages plus
   the youtube.com/music.youtube.com redirects that complete the flow, none
   of which need WebAuthn. Playback WebViews use different configurations
   and are unaffected.
3. **Keep the login sheet note, updated to describe the actual behavior**
   ("Passkey sign-in is not available in this window. Google will ask for
   your password or another sign-in method instead.") so users are not
   surprised when their passkey is not offered.

## Consequences

- Passkey-enabled Google accounts can sign in without hitting the
  unrecoverable "Something went wrong" screen; Google falls back to password
  sign-in on its own instead of requiring users to discover "Try another
  way".
- Passkeys still cannot be used to sign in to Kaset. That is a platform
  restriction, not a regression: the ceremony has never been able to succeed
  in the embedded WebView. If Apple ever offers a viable path (for example a
  less restrictive entitlement), the suppression script and this ADR should
  be revisited.
- Accounts restricted to passkey-only sign-in (for example by a Workspace
  policy that disallows passwords) still cannot log in, but they could not
  before either; with suppression Google at least presents its other
  verification options rather than the Bluetooth error loop.
- The suppression script depends on Google feature-detecting WebAuthn. If a
  page calls the API anyway, the second layer (rejecting `publicKey`
  requests promptly with `NotAllowedError`) fails the ceremony immediately
  and deterministically instead of leaving the outcome to the platform; the
  page may still render an error screen, but sign-in stays recoverable
  through its non-WebAuthn fallback.
- `LoginPasskeySuppressionTests` guards both directions: a plain WKWebView
  must still expose `PublicKeyCredential` (if WebKit changes this, the shim
  is obsolete), and the session-switch configuration must hide it and reject
  passkey requests.
