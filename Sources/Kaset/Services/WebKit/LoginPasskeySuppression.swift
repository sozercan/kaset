import WebKit

// MARK: - LoginPasskeySuppression

/// Hides WebAuthn passkey support from Google sign-in pages loaded in the
/// login and session-switch WebViews.
///
/// WKWebView exposes `window.PublicKeyCredential`, but without the restricted
/// `com.apple.developer.web-browser.public-key-credential` entitlement (granted
/// by Apple only to general-purpose browsers) the system rejects every passkey
/// ceremony before showing any UI. Google's sign-in page detects the API,
/// offers the passkey flow, and dead-ends on a "Something went wrong" error
/// instead of falling back to a password. Removing the API up front makes
/// Google treat the WebView like a browser without WebAuthn support and route
/// sign-in through flows that can actually succeed. See ADR-0033.
enum LoginPasskeySuppression {
    /// JavaScript that removes WebAuthn capability signals before page scripts run.
    ///
    /// Two layers, each independently guarded so a WebKit change can never
    /// break the sign-in page itself:
    /// 1. Undefines `window.PublicKeyCredential`, which well-behaved relying
    ///    parties (including Google) feature-detect before offering passkeys.
    /// 2. Rejects any `navigator.credentials.get/create` call that still asks
    ///    for a `publicKey` credential with `NotAllowedError`, the same error
    ///    the platform would eventually produce, but without the misleading
    ///    cross-device error screen.
    static let scriptSource = """
    (function () {
        "use strict";
        try {
            delete window.PublicKeyCredential;
            Object.defineProperty(window, "PublicKeyCredential", {
                value: undefined,
                writable: false,
                configurable: false,
            });
        } catch (error) {}
        try {
            var credentials = window.navigator && window.navigator.credentials;
            if (!credentials) {
                return;
            }
            var prototype = Object.getPrototypeOf(credentials);
            var wrap = function (original) {
                if (typeof original !== "function") {
                    return original;
                }
                return function (options) {
                    if (options && options.publicKey) {
                        return Promise.reject(new DOMException(
                            "Passkeys are not available in this app.",
                            "NotAllowedError"
                        ));
                    }
                    return original.apply(this, arguments);
                };
            };
            prototype.get = wrap(prototype.get);
            prototype.create = wrap(prototype.create);
        } catch (error) {}
    })();
    """

    /// Builds the user script for the login/session-switch configuration.
    ///
    /// Injected at document start so it runs before Google's capability
    /// detection, and into all frames because parts of the sign-in flow render
    /// in iframes.
    @MainActor
    static func makeUserScript() -> WKUserScript {
        WKUserScript(
            source: self.scriptSource,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        )
    }
}
