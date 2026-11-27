import WebKit

enum LoginPasskeySuppression {
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

    @MainActor
    static func makeUserScript() -> WKUserScript {
        WKUserScript(
            source: self.scriptSource,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        )
    }
}
