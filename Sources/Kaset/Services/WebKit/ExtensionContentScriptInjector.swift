import Foundation
import WebKit

// MARK: - ExtensionContentScriptInjector

/// Injects user-installed WebExtension `content_scripts` and stylesheets into
/// Kaset's playback WebViews.
///
/// Kaset's player WebViews are long-lived surfaces that load a single origin
/// each (`music.youtube.com` for the music player, `www.youtube.com` for the
/// video player). Apple's `WKWebExtensionController` content-script injection
/// relies on a full browser tab/window model that is not exercised by these
/// dedicated WebViews on current macOS releases, so content scripts do not run
/// through the controller. To make extensions actually affect playback, we read
/// each enabled extension's `content_scripts` from disk and add them as
/// `WKUserScript`s to the WebView's `WKUserContentController` — the mechanism
/// WebKit reliably supports for manually managed WebViews.
@MainActor
enum ExtensionContentScriptInjector {

    /// The origin a given hosted WebView role loads.
    private static func originHost(for role: WebExtensionHostedWebViewRole) -> String {
        switch role {
        case .musicPlayer:
            "music.youtube.com"
        case .youtubeWatch:
            "www.youtube.com"
        }
    }

    /// Builds the on-disk URL for an enabled managed extension.
    private static func resourceURL(for ext: ManagedExtension) -> URL? {
        guard let base = ExtensionsManager.shared.managedExtensionsDirectoryURL else { return nil }
        return base.appendingPathComponent(ext.relativePath, isDirectory: true)
    }

    /// Returns `WKUserScript`s for every enabled extension whose content scripts
    /// target the given WebView role. Each script is wrapped so it only runs on
    /// pages matching the extension's `matches` globs.
    static func userScripts(for role: WebExtensionHostedWebViewRole) -> [WKUserScript] {
        var result: [WKUserScript] = []
        let host = Self.originHost(for: role)

        for ext in ExtensionsManager.shared.extensions where ext.isEnabled {
            guard let base = Self.resourceURL(for: ext),
                  let manifest = Self.loadManifest(in: base),
                  let contentScripts = manifest["content_scripts"] as? [[String: Any]]
            else { continue }

            for entry in contentScripts {
                guard let matches = entry["matches"] as? [String],
                      Self.matchesTargetHost(matches, host: host) else { continue }

                let runAt = (entry["run_at"] as? String) ?? "document_idle"
                let injectionTime: WKUserScriptInjectionTime = switch runAt {
                case "document_start":
                    .atDocumentStart
                default:
                    .atDocumentEnd
                }

                guard let jsFiles = entry["js"] as? [String] else { continue }

                for file in jsFiles {
                    let fileURL = base.appendingPathComponent(file)
                    guard let source = try? String(contentsOf: fileURL, encoding: .utf8) else { continue }
                    let wrapped = Self.wrap(source: source, matches: matches)
                    result.append(WKUserScript(
                        source: wrapped,
                        injectionTime: injectionTime,
                        forMainFrameOnly: true
                    ))
                }
            }
        }

        return result
    }

    /// Returns `WKUserScript`s that inject each extension's stylesheet content as
    /// a `<style>` element, scoped to the WebView role's origin.
    static func styleSheets(for role: WebExtensionHostedWebViewRole) -> [WKUserScript] {
        var result: [WKUserScript] = []
        let host = Self.originHost(for: role)

        for ext in ExtensionsManager.shared.extensions where ext.isEnabled {
            guard let base = Self.resourceURL(for: ext),
                  let manifest = Self.loadManifest(in: base),
                  let contentScripts = manifest["content_scripts"] as? [[String: Any]]
            else { continue }

            for entry in contentScripts {
                guard let matches = entry["matches"] as? [String],
                      Self.matchesTargetHost(matches, host: host),
                      let cssFiles = entry["css"] as? [String]
                else { continue }

                for file in cssFiles {
                    let fileURL = base.appendingPathComponent(file)
                    guard let css = try? String(contentsOf: fileURL, encoding: .utf8) else { continue }
                    // JSON-encode so arbitrary CSS (quotes, newlines) is safe to
                    // embed inside a JavaScript string literal.
                    let encodedCSS = (try? JSONSerialization.data(withJSONObject: [css]))
                        .flatMap { String(data: $0, encoding: .utf8) }
                        .map { String($0.dropFirst().dropLast()) } // strip the surrounding [ ]
                        ?? "\(css)"
                    let regex = Self.cssMatchRegex(for: matches)
                    let source = """
                    (function(){
                      if (!location.href.match(/\(regex)/)) return;
                      var s = document.createElement('style');
                      s.textContent = "\(encodedCSS)";
                      (document.head || document.documentElement).appendChild(s);
                    })();
                    """
                    result.append(WKUserScript(
                        source: source,
                        injectionTime: .atDocumentEnd,
                        forMainFrameOnly: true
                    ))
                }
            }
        }

        return result
    }

    // MARK: - Helpers

    private static func loadManifest(in base: URL) -> [String: Any]? {
        let url = base.appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: url),
              let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return manifest
    }

    /// Whether any of the manifest match globs targets the given host. A glob
    /// such as `https://music.youtube.com/*` or `*://*.youtube.com/*` matches
    /// when its host (ignoring leading wildcards) is contained in `host`.
    /// `<all_urls>` always matches.
    private static func matchesTargetHost(_ matches: [String], host: String) -> Bool {
        matches.contains { Self.matchTargetsHost($0, host: host) }
    }

    private static func matchTargetsHost(_ match: String, host: String) -> Bool {
        if match == "<all_urls>" { return true }

        // Strip scheme and path, keep host portion.
        var remainder = match
        if let schemeEnd = remainder.firstIndex(of: ":") {
            remainder = String(remainder[remainder.index(after: schemeEnd)...])
        }
        remainder = remainder.replacingOccurrences(of: "//", with: "")
        // Drop path component.
        if let slash = remainder.firstIndex(of: "/") {
            remainder = String(remainder[..<slash])
        }
        remainder = remainder.trimmingCharacters(in: .whitespaces)
        if remainder.isEmpty { return true }
        // Handle leading wildcard host like `*.youtube.com`.
        if remainder.hasPrefix("*.") {
            let suffix = String(remainder.dropFirst(2))
            return host == suffix || host.hasSuffix("." + suffix) || host.hasSuffix(suffix)
        }
        return remainder == host || remainder == "*"
    }

    /// Wraps extension JS so it only executes on pages whose URL matches one of
    /// the manifest match globs. Keeps multiple extensions isolated and avoids
    /// running a music-extension script on the wrong surface.
    private static func wrap(source: String, matches: [String]) -> String {
        let regex = Self.cssMatchRegex(for: matches)
        return """
        (function(){
          if (!location.href.match(/\(regex)/)) return;
          \(source)
        })();
        """
    }

    /// Builds a JS regex source string from manifest match globs.
    private static func cssMatchRegex(for matches: [String]) -> String {
        let alternatives = matches.compactMap { Self.globToRegex($0) }
        if alternatives.isEmpty { return "$.^" } // never matches
        return alternatives.joined(separator: "|")
    }

    /// Converts a single MV3 match pattern to a JS regex source string.
    private static func globToRegex(_ pattern: String) -> String? {
        if pattern == "<all_urls>" { return ".*" }

        // Scheme
        var p = pattern
        var scheme = "https?"
        if p.hasPrefix("*://") {
            p = String(p.dropFirst(4))
        } else if let range = p.range(of: "://") {
            scheme = String(p[..<range.lowerBound])
            p = String(p[range.upperBound...])
            scheme = scheme == "*" ? "https?" : NSRegularExpression.escapedPattern(for: scheme)
        }
        // Host + path
        guard let slashIndex = p.firstIndex(of: "/") else { return nil }
        var host = String(p[..<slashIndex])
        let path = String(p[slashIndex...])

        if host == "*" {
            host = "[^/]+"
        } else if host.hasPrefix("*.") {
            host = "(?:[^/]+\\.)?" + NSRegularExpression.escapedPattern(for: String(host.dropFirst(2)))
        } else {
            host = NSRegularExpression.escapedPattern(for: host)
        }

        let pathRegex = path
            .replacingOccurrences(of: ".", with: "\\.")
            .replacingOccurrences(of: "*", with: ".*")

        return "^(?:\(scheme)://)\(host)\(pathRegex)$"
    }
}
