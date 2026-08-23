import WebKit

if #available(macOS 14.0, *) {
    func inspectExtension() {
        let x = WKWebExtension.self
        let ctx = WKWebExtensionContext.self
    }
}
