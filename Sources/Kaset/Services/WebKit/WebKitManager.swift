import Foundation
import os
import Security
import WebKit

@MainActor
@Observable
final class WebKitManager: NSObject, WebKitManagerProtocol {
    static let shared = WebKitManager(dataStore: .default(), restoresCookies: true, loadsExtensions: true)

    static func makeTestInstance(
        cookieArchiveStorage: CookieArchiveStorage = .inMemory()
    ) -> WebKitManager {
        WebKitManager(
            dataStore: .nonPersistent(),
            restoresCookies: false,
            loadsExtensions: false,
            cookieArchiveQueue: CookieArchiveWriteQueue(storage: cookieArchiveStorage)
        )
    }

    let dataStore: WKWebsiteDataStore

    let cookieArchiveQueue: CookieArchiveWriteQueue

    private(set) var cookiesDidChange: Date = .distantPast

    func recordCookieChange() {
        self.cookiesDidChange = Date()
    }

    var isRestoringCookies = false

    var isClearingAuthCookies = false

    let authCookieClearCoordinator = AuthCookieClearCoordinator()

    var cookieDebounceTask: Task<Void, Never>?

    var forcedCookieBackupTask: Task<Bool, Never>?

    var isPreparingLoginCookieBackup = false

    var activeLoginCookieBackupTransaction: CookieBackupTransaction?

    var loginCookieBackupSetupRequiresCleanup = false

    var forcedCookieBackupDirty = false

    var initialCookieRestoreTask: Task<CookieRestoreResult, Never>?

    var initialCookieRestoreResult: CookieRestoreResult = .ready

    var authCookieOperationFence = AuthCookieOperationFence()

    static let cookieDebounceInterval: Duration = .seconds(5)

    static let origin = "https://music.youtube.com"

    @MainActor
    let webExtensionController = WKWebExtensionController()

    nonisolated static let authCookieName = "__Secure-3PAPISID"

    nonisolated static let fallbackAuthCookieName = "SAPISID"

    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"

    let logger = DiagnosticsLogger.webKit

    private var extensionContexts: [String: WKWebExtensionContext] = [:]

    #if compiler(>=5.9)
        @ObservationIgnored
        @available(macOS 15.4, *)
        private lazy var webExtensionHost = KasetWebExtensionHost(
            controller: self.webExtensionController,
            logger: DiagnosticsLogger.extensions
        )
    #endif

    private init(
        dataStore: WKWebsiteDataStore,
        restoresCookies: Bool,
        loadsExtensions: Bool,
        cookieArchiveQueue: CookieArchiveWriteQueue = .shared
    ) {
        self.dataStore = dataStore
        self.cookieArchiveQueue = cookieArchiveQueue

        super.init()

        self.dataStore.httpCookieStore.add(self)

        if restoresCookies, !UITestConfig.isRunningUnitTests {
            self.startInitialCookieRestore()
        }

        self.logger.info("WebKitManager initialized with persistent data store")

        #if compiler(>=5.9)
            if #available(macOS 14.0, *) {
                self.webExtensionController.delegate = self
            }
        #endif

        if loadsExtensions {
            Task { await self.loadExtensions() }
        }
    }

    var isExtensionLoaded: Bool {
        #if compiler(>=5.9)
            if #available(macOS 14.0, *) {
                return !self.webExtensionController.extensionContexts.isEmpty
            }
        #endif
        return false
    }

    var loadedExtensionCount: Int {
        #if compiler(>=5.9)
            if #available(macOS 14.0, *) {
                return self.webExtensionController.extensionContexts.count
            }
        #endif
        return 0
    }

    var extensionVersion: String? {
        #if compiler(>=5.9)
            if #available(macOS 14.0, *) {
                return self.webExtensionController.extensionContexts.first?.webExtension.version
            }
        #endif
        return nil
    }

    func loadExtensions(using manager: ExtensionsManager = .shared) async {
        #if compiler(>=5.9)
            if #available(macOS 14.0, *) {
                let resolvedURLs = manager.resolvedURLs()
                guard !resolvedURLs.isEmpty else {
                    self.logger.info("No enabled extensions to load")
                    return
                }

                for (id, url) in resolvedURLs {
                    await self.loadSingleExtension(at: url, id: id, manager: manager)
                }

                self.logger.info("Loaded \(self.webExtensionController.extensionContexts.count) extension(s)")
            }
        #endif
    }

    @available(macOS 14.0, *)
    private func loadSingleExtension(at url: URL, id: String, manager: ExtensionsManager) async {
        do {
            let webExtension = try await WKWebExtension(resourceBaseURL: url)
            guard manager.allowsLoading(ExtensionPermissions(webExtension: webExtension), id: id) else {
                self.logger.warning("Extension requires permission review before loading: \(id)")
                return
            }
            let context = WKWebExtensionContext(for: webExtension)
            context.uniqueIdentifier = id

            self.extensionContexts[id] = context

            for permission in webExtension.requestedPermissions {
                context.setPermissionStatus(.grantedExplicitly, for: permission)
            }

            for matchPattern in webExtension.requestedPermissionMatchPatterns {
                context.setPermissionStatus(.grantedExplicitly, for: matchPattern)
            }

            if #available(macOS 15.4, *) {
                for matchPattern in Self.contentScriptMatchPatterns(from: webExtension.manifest) {
                    context.setPermissionStatus(.grantedExplicitly, for: matchPattern)
                }
            }

            try self.webExtensionController.load(context)
            if webExtension.hasBackgroundContent {
                try? await context.loadBackgroundContent()
            }
            self.logger.info("Loaded extension \(webExtension.displayName ?? url.lastPathComponent) (\(webExtension.version ?? "?")). Options: \(context.optionsPageURL?.absoluteString ?? "none")")
        } catch {
            self.logger.error("Failed to load extension at \(url.path): \(error.localizedDescription)")
        }
    }

    @available(macOS 15.4, *)
    static func contentScriptMatchPatterns(from manifest: [AnyHashable: Any]) -> [WKWebExtension.MatchPattern] {
        guard let contentScripts = manifest["content_scripts"] as? [[String: Any]] else {
            return []
        }

        var patterns: [WKWebExtension.MatchPattern] = []
        var seen = Set<String>()

        for contentScript in contentScripts {
            guard let matches = contentScript["matches"] as? [String] else { continue }
            for match in matches where seen.insert(match).inserted {
                guard let pattern = try? WKWebExtension.MatchPattern(string: match) else { continue }
                patterns.append(pattern)
            }
        }

        return patterns
    }

    func createWebViewConfiguration(websiteDataStore: WKWebsiteDataStore? = nil) -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = websiteDataStore ?? self.dataStore

        #if compiler(>=5.9)
            if #available(macOS 14.0, *) {
                configuration.webExtensionController = self.webExtensionController
            }
        #endif

        configuration.preferences.isElementFullscreenEnabled = true
        configuration.mediaTypesRequiringUserActionForPlayback = []

        configuration.allowsAirPlayForMediaPlayback = true

        return configuration
    }

    func registerExtensionHostWebView(_ webView: WKWebView, role: WebExtensionHostedWebViewRole) {
        #if compiler(>=5.9)
            if #available(macOS 15.4, *) {
                self.webExtensionHost.register(webView: webView, role: role)
            }
        #endif
    }

    func extensionHostWebViewWillNavigate(_ webView: WKWebView, to url: URL?) {
        #if compiler(>=5.9)
            if #available(macOS 15.4, *) {
                self.webExtensionHost.noteNavigationStarted(for: webView, pendingURL: url)
            }
        #endif
    }

    func extensionHostWebViewDidStartNavigation(_ webView: WKWebView) {
        #if compiler(>=5.9)
            if #available(macOS 15.4, *) {
                self.webExtensionHost.noteNavigationStarted(for: webView, pendingURL: nil)
            }
        #endif
    }

    func extensionHostWebViewDidBecomeActive(_ webView: WKWebView) {
        #if compiler(>=5.9)
            if #available(macOS 15.4, *) {
                self.webExtensionHost.noteBecameActive(webView: webView)
            }
        #endif
    }

    func unregisterExtensionHostWebView(role: WebExtensionHostedWebViewRole) {
        #if compiler(>=5.9)
            if #available(macOS 15.4, *) {
                self.webExtensionHost.unregister(role: role)
            }
        #endif
    }

    func extensionHostWebViewDidFinishNavigation(_ webView: WKWebView) {
        #if compiler(>=5.9)
            if #available(macOS 15.4, *) {
                self.webExtensionHost.noteNavigationFinished(for: webView)
            }
        #endif
    }

    func extensionHostWebViewDidFailNavigation(_ webView: WKWebView) {
        #if compiler(>=5.9)
            if #available(macOS 15.4, *) {
                self.webExtensionHost.noteNavigationFailed(for: webView)
            }
        #endif
    }

    func createSessionSwitchWebViewConfiguration() -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = self.dataStore
        configuration.userContentController.addUserScript(LoginPasskeySuppression.makeUserScript())
        return configuration
    }

    struct ExtensionPage: Identifiable {
        let id: String
        let url: URL
        let configuration: WKWebViewConfiguration
    }

    func extensionPage(forExtensionId id: String) -> ExtensionPage? {
        #if compiler(>=5.9)
            if #available(macOS 14.0, *) {
                guard let context = self.extensionContexts[id] else { return nil }
                guard let configuration = context.webViewConfiguration else { return nil }

                if let optionsURL = context.optionsPageURL {
                    return ExtensionPage(id: id, url: optionsURL, configuration: configuration)
                }

                guard let managedExt = ExtensionsManager.shared.extensions.first(where: { $0.id == id }),
                      let relativePath = managedExt.optionsPath ?? managedExt.popupPath,
                      let fallbackURL = Self.extensionResourceURL(relativePath: relativePath, baseURL: context.baseURL)
                else {
                    return nil
                }

                return ExtensionPage(id: id, url: fallbackURL, configuration: configuration)
            }
        #endif
        return nil
    }

    func optionsPageURL(forExtensionId id: String) -> URL? {
        self.extensionPage(forExtensionId: id)?.url
    }

    func optionsPageURL(forExtensionNamed name: String) -> URL? {
        #if compiler(>=5.9)
            if #available(macOS 14.0, *) {
                self.logger.info("Looking for options page for extension: \(name)")
                for context in self.webExtensionController.extensionContexts {
                    let displayName = context.webExtension.displayName ?? ""
                    self.logger.debug("Checking context: \(displayName)")
                    if displayName == name {
                        let url = context.optionsPageURL
                        self.logger.info("Found options page URL: \(url?.absoluteString ?? "nil")")
                        return url
                    }
                }
                self.logger.warning("No extension found with display name: \(name)")
            }
        #endif
        return nil
    }

    static func extensionResourceURL(relativePath: String, baseURL: URL) -> URL? {
        let trimmedPath = relativePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPath.isEmpty else { return nil }

        if let components = URLComponents(string: trimmedPath), components.scheme != nil || components.host != nil {
            return nil
        }

        let normalizedPath = trimmedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !normalizedPath.isEmpty else { return nil }

        let rootURL = baseURL.hasDirectoryPath ? baseURL : baseURL.appendingPathComponent("", isDirectory: true)
        return URL(string: normalizedPath, relativeTo: rootURL)?.absoluteURL
    }

    func getAllCookies() async -> [HTTPCookie] {
        await self.dataStore.httpCookieStore.allCookies()
    }

    func getCookies(for domain: String) async -> [HTTPCookie] {
        let allCookies = await getAllCookies()
        return Self.cookies(allCookies, matching: domain)
    }

    func cookieHeader(for domain: String) async -> String? {
        let cookies = await getCookies(for: domain)
        guard !cookies.isEmpty else { return nil }

        let headerFields = HTTPCookie.requestHeaderFields(with: cookies)
        return headerFields["Cookie"]
    }

    func getSAPISID() async -> String? {
        let cookies = await getCookies(for: "youtube.com")
        let allCookies = await getAllCookies()
        self.logger.debug("Checking for SAPISID - total cookies: \(allCookies.count), youtube.com cookies: \(cookies.count)")

        let secureCookie = cookies.first { $0.name == Self.authCookieName }
        let fallbackCookie = cookies.first { $0.name == Self.fallbackAuthCookieName }

        if let cookie = secureCookie ?? fallbackCookie {
            if let expiresDate = cookie.expiresDate {
                let formatter = DateFormatter()
                formatter.dateStyle = .short
                formatter.timeStyle = .short
                let expiresStr = formatter.string(from: expiresDate)
                let isExpired = expiresDate < Date()
                self.logger.debug("Found \(cookie.name) cookie, expires: \(expiresStr), expired: \(isExpired)")

                if isExpired {
                    self.logger.warning("Auth cookie has expired!")
                    return nil
                }
            } else if cookie.isSessionOnly {
                self.logger.debug("Found \(cookie.name) cookie (session-only, no expiration)")
            }
            return cookie.value
        }

        let cookieNames = cookies.map(\.name).joined(separator: ", ")
        self.logger.debug("No auth cookie found. Available cookies: \(cookieNames)")
        return nil
    }

    func hasAuthCookies() async -> Bool {
        let sapisid = await getSAPISID()
        return sapisid != nil
    }

    func logAuthCookies() async {
        let cookies = await getCookies(for: "youtube.com")
        let authCookieNames = ["SAPISID", "__Secure-3PAPISID", "SID", "HSID", "SSID", "APISID", "__Secure-1PAPISID"]

        self.logger.info("=== Auth Cookie Diagnostic ===")
        self.logger.info("Total youtube.com cookies: \(cookies.count)")

        for name in authCookieNames {
            if let cookie = cookies.first(where: { $0.name == name }) {
                let expiry: String
                if let date = cookie.expiresDate {
                    let formatter = DateFormatter()
                    formatter.dateStyle = .medium
                    formatter.timeStyle = .short
                    expiry = formatter.string(from: date)
                } else if cookie.isSessionOnly {
                    expiry = "session-only"
                } else {
                    expiry = "unknown"
                }
                self.logger.info("✓ \(name): expires \(expiry)")
            } else {
                self.logger.info("✗ \(name): not found")
            }
        }
        self.logger.info("==============================")
    }

    @discardableResult
    func clearAuthCookies() async -> Bool {
        await self.authCookieClearCoordinator.run(scope: .authenticationCookies) { [weak self] in
            guard let self else { return false }
            return await self.performAuthCookieClear()
        }
    }

    private func performAuthCookieClear() async -> Bool {
        self.logger.notice("Clearing WebKit auth cookies and the saved archive")
        self.isClearingAuthCookies = true
        defer { self.isClearingAuthCookies = false }

        await self.fenceAuthCookieOperationsAndInvalidateBackup()

        let didInvalidatePersistedCookies = await self.cookieArchiveQueue.invalidateAndDelete()

        let didClearLiveCookies = await self.deleteLiveLoginSessionCookies(allowsCookieStoreFallback: true)
        let didClear = didClearLiveCookies && didInvalidatePersistedCookies
        self.initialCookieRestoreResult = didClear ? .ready : .failed
        self.loginCookieBackupSetupRequiresCleanup = !didClear
        self.cookiesDidChange = Date()
        return didClear
    }

    func deleteLiveLoginSessionCookies(allowsCookieStoreFallback: Bool) async -> Bool {
        let result = await LiveAuthCookieStoreClearer.clear(
            allowsCookieStoreFallback: allowsCookieStoreFallback,
            operations: LiveAuthCookieStoreClearer.Operations(
                readCookies: {
                    await self.dataStore.httpCookieStore.allCookies()
                },
                deleteCookie: { cookie in
                    await self.dataStore.httpCookieStore.deleteCookie(cookie)
                },
                removeAllCookies: {
                    await self.dataStore.removeData(
                        ofTypes: [WKWebsiteDataTypeCookies],
                        modifiedSince: .distantPast
                    )
                }
            )
        )
        if result.usedCookieStoreFallback {
            self.logger.warning("Escalated authentication cleanup to the WebKit cookie data store")
        }
        if !result.didClear {
            self.logger.error("Could not clear live authentication cookies")
        }
        return result.didClear
    }

    @discardableResult
    func clearAllData() async -> Bool {
        await self.authCookieClearCoordinator.run(scope: .allWebsiteData) { [weak self] in
            guard let self else { return false }
            return await self.performAllWebsiteDataClear()
        }
    }

    private func performAllWebsiteDataClear() async -> Bool {
        let allTypes = WKWebsiteDataStore.allWebsiteDataTypes()
        let dateFrom = Date.distantPast

        self.logger.notice("Clearing all WebKit data and the saved archive")
        self.isClearingAuthCookies = true
        defer { self.isClearingAuthCookies = false }

        await self.fenceAuthCookieOperationsAndInvalidateBackup()
        await self.dataStore.removeData(ofTypes: allTypes, modifiedSince: dateFrom)

        let didInvalidatePersistedCookies = await self.cookieArchiveQueue.invalidateAndDelete()
        let remainingCookies = await self.dataStore.httpCookieStore.allCookies()
        let didClearLiveCookies = !remainingCookies.contains(where: KeychainCookieStorage.isLoginDomainCookie)
        let didClear = didInvalidatePersistedCookies && didClearLiveCookies
        self.initialCookieRestoreResult = didClear ? .ready : .failed
        self.loginCookieBackupSetupRequiresCleanup = !didClear
        if didClear {
            self.logger.info("WebKit data cleared successfully")
        } else {
            self.logger.error("WebKit data or durable cookie invalidation could not be cleared")
        }
        self.cookiesDidChange = Date()
        return didClear
    }

    private func fenceAuthCookieOperationsAndInvalidateBackup() async {
        self.authCookieOperationFence.invalidate()
        self.activeLoginCookieBackupTransaction = nil
        self.cookieDebounceTask?.cancel()
        self.cookieDebounceTask = nil

        let restoreTask = self.initialCookieRestoreTask
        let backupTask = self.forcedCookieBackupTask
        restoreTask?.cancel()
        backupTask?.cancel()

        _ = await self.cookieArchiveQueue.invalidateAndDelete()
        _ = await restoreTask?.value
        _ = await backupTask?.value
    }
}

#if compiler(>=5.9)
    @available(macOS 14.0, *)
    extension WebKitManager: WKWebExtensionControllerDelegate {
        func webExtensionController(_: WKWebExtensionController, promptForPermissions _: Set<WKWebExtension.Permission>, in _: (any WKWebExtensionTab)?, for _: WKWebExtensionContext) async -> (Set<WKWebExtension.Permission>, Date?) {
            ([], nil)
        }

        func webExtensionController(_: WKWebExtensionController, promptForPermissionMatchPatterns _: Set<WKWebExtension.MatchPattern>, in _: (any WKWebExtensionTab)?, for _: WKWebExtensionContext) async -> (Set<WKWebExtension.MatchPattern>, Date?) {
            ([], nil)
        }

        func webExtensionController(_: WKWebExtensionController, promptForPermissionToAccess _: Set<URL>, in _: (any WKWebExtensionTab)?, for _: WKWebExtensionContext) async -> (Set<URL>, Date?) {
            ([], nil)
        }

        @available(macOS 15.4, *)
        func webExtensionController(_: WKWebExtensionController, openWindowsFor _: WKWebExtensionContext) -> [any WKWebExtensionWindow] {
            self.webExtensionHost.openWindows
        }

        @available(macOS 15.4, *)
        func webExtensionController(_: WKWebExtensionController, focusedWindowFor _: WKWebExtensionContext) -> (any WKWebExtensionWindow)? {
            self.webExtensionHost.focusedWindow
        }
    }
#endif

enum SessionSwitchError: LocalizedError {
    case identityNotApplied(expectedBrandId: String?)
    case navigationFailed(underlying: String)
    case timedOut

    var errorDescription: String? {
        switch self {
        case .identityNotApplied:
            "The account session could not be switched. Please try again."
        case .navigationFailed:
            "Failed to load the account switch page."
        case .timedOut:
            "Switching accounts timed out. Please try again."
        }
    }
}

extension WebKitManager {
    func switchSessionIdentity(to signinURL: URL, expectedBrandId: String?) async throws {
        self.logger.info("Switching session identity (expecting \(expectedBrandId ?? "primary"))")
        guard AccountsListParser.isAllowedSigninURL(signinURL) else {
            throw SessionSwitchError.navigationFailed(underlying: "Refusing non-YouTube signin URL")
        }

        let configuration = self.createSessionSwitchWebViewConfiguration()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.customUserAgent = Self.userAgent

        let driver = SessionSwitchNavigationDriver()
        webView.navigationDelegate = driver

        defer {
            webView.navigationDelegate = nil
            webView.stopLoading()
        }

        try Task.checkCancellation()

        do {
            try await driver.load(signinURL, in: webView, timeout: .seconds(20))
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as SessionSwitchError {
            throw error
        } catch {
            throw SessionSwitchError.navigationFailed(underlying: error.localizedDescription)
        }

        for attempt in 0 ..< 5 {
            if let dataSyncId = try? await Self.readDataSyncId(from: webView),
               Self.dataSyncId(dataSyncId, matches: expectedBrandId)
            {
                self.logger.info("Session identity switch verified")
                return
            }
            if attempt < 4 {
                try await Task.sleep(for: .milliseconds(400))
            }
        }

        self.logger.error("Session identity switch could not be verified")
        throw SessionSwitchError.identityNotApplied(expectedBrandId: expectedBrandId)
    }

    private static func readDataSyncId(from webView: WKWebView) async throws -> String? {
        let script = """
        (function() {
            try {
                if (window.ytcfg && typeof window.ytcfg.get === 'function') {
                    return window.ytcfg.get('DATASYNC_ID') || '';
                }
                if (window.ytcfg && window.ytcfg.data_) {
                    return window.ytcfg.data_['DATASYNC_ID'] || '';
                }
            } catch (e) {}
            return '';
        })();
        """
        let result = try await webView.evaluateJavaScript(script)
        return result as? String
    }

    static func dataSyncId(_ dataSyncId: String, matches expectedBrandId: String?) -> Bool {
        let parts = dataSyncId.components(separatedBy: "||")
        guard parts.count == 2, !parts[0].isEmpty else {
            return false
        }
        let firstHalf = parts[0]
        let hasUserSessionSuffix = !parts[1].isEmpty
        let delegatedSessionId: String? = hasUserSessionSuffix ? firstHalf : nil
        if let expectedBrandId {
            return delegatedSessionId == expectedBrandId
        }
        return delegatedSessionId == nil
    }
}

@MainActor
private final class SessionSwitchNavigationDriver: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<Void, Error>?
    private var finished = false
    private var timeoutTask: Task<Void, Never>?

    func load(_ url: URL, in webView: WKWebView, timeout: Duration) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                self.continuation = continuation
                self.timeoutTask = Task { [weak self] in
                    try? await Task.sleep(for: timeout)
                    guard let self, !self.finished else { return }
                    self.complete(with: .failure(SessionSwitchError.timedOut))
                }
                webView.load(URLRequest(url: url))
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.complete(with: .failure(CancellationError()))
            }
        }
    }

    private func complete(with result: Result<Void, Error>) {
        guard !self.finished else { return }
        self.finished = true
        self.timeoutTask?.cancel()
        self.timeoutTask = nil
        let continuation = self.continuation
        self.continuation = nil
        continuation?.resume(with: result)
    }

    func webView(_: WKWebView, didFinish _: WKNavigation!) {
        self.complete(with: .success(()))
    }

    func webView(_: WKWebView, didFail _: WKNavigation!, withError error: Error) {
        self.complete(with: .failure(SessionSwitchError.navigationFailed(underlying: error.localizedDescription)))
    }

    func webView(_: WKWebView, didFailProvisionalNavigation _: WKNavigation!, withError error: Error) {
        self.complete(with: .failure(SessionSwitchError.navigationFailed(underlying: error.localizedDescription)))
    }
}
