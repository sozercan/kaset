import Foundation
import Observation

@MainActor
@Observable
final class PodcastsAvailabilityService {
    enum Availability: Equatable {
        case unknown
        case available
        case unavailable
    }

    private(set) var availability: Availability = .unknown

    private var accountScope: AccountScope = .unconfigured
    private var generation = 0

    init() {}

    func activateAccount(_ accountId: String?) {
        let scope = AccountScope.account(Self.normalizedAccountId(accountId))
        guard self.accountScope != scope else { return }

        self.accountScope = scope
        self.generation += 1
    }

    @discardableResult
    func probe(
        for accountId: String?,
        using client: any YTMusicClientProtocol
    ) async -> Availability {
        let token = self.beginProbe(for: accountId)
        let label = token.accountId
        DiagnosticsLogger.api.info("Probing podcasts availability for account=\(label)")

        do {
            let sections = try await client.getPodcasts()
            guard self.shouldApplyProbeResult(token, outcome: "success") else {
                return self.availability
            }

            if sections.isEmpty {
                DiagnosticsLogger.api.info("Probe returned 0 sections; leaving availability=\(String(describing: self.availability))")
                return self.availability
            }
            self.availability = .available
            return .available
        } catch let YTMusicError.apiError(_, code) where code == 404 {
            guard self.shouldApplyProbeResult(token, outcome: "HTTP 404") else {
                return self.availability
            }

            DiagnosticsLogger.api.info("Probe returned HTTP 404; podcasts unavailable for account=\(label)")
            self.availability = .unavailable
            return .unavailable
        } catch is CancellationError {
            DiagnosticsLogger.api.debug("Probe cancelled for account=\(label)")
            return self.availability
        } catch {
            guard self.shouldApplyProbeResult(token, outcome: "inconclusive") else {
                return self.availability
            }

            DiagnosticsLogger.api.debug("Probe inconclusive for account=\(label): \(error.localizedDescription)")
            return self.availability
        }
    }

    func markUnavailable(for accountId: String?) {
        guard self.shouldApplyLazySignal(for: accountId, outcome: "unavailable") else { return }

        self.generation += 1
        self.availability = .unavailable
    }

    func markAvailable(for accountId: String?) {
        guard self.shouldApplyLazySignal(for: accountId, outcome: "available") else { return }

        self.generation += 1
        self.availability = .available
    }

    func reset() {
        self.accountScope = .loggedOut
        self.generation += 1
        self.availability = .unknown
    }

    private func beginProbe(for accountId: String?) -> ProbeToken {
        self.activateAccount(accountId)
        self.generation += 1
        return ProbeToken(
            accountId: Self.normalizedAccountId(accountId),
            generation: self.generation
        )
    }

    private func shouldApplyProbeResult(
        _ token: ProbeToken,
        outcome: String
    ) -> Bool {
        guard self.accountScope == .account(token.accountId),
              self.generation == token.generation
        else {
            DiagnosticsLogger.api.debug("Ignoring stale podcasts availability probe for account=\(token.accountId), outcome=\(outcome)")
            return false
        }
        return true
    }

    private func shouldApplyLazySignal(for accountId: String?, outcome: String) -> Bool {
        let normalizedAccountId = Self.normalizedAccountId(accountId)
        switch self.accountScope {
        case .unconfigured:
            self.accountScope = .account(normalizedAccountId)
            self.generation += 1
            return true
        case .loggedOut:
            DiagnosticsLogger.api.debug("Ignoring podcasts availability signal while logged out for account=\(normalizedAccountId), outcome=\(outcome)")
            return false
        case let .account(activeAccountId):
            guard activeAccountId == normalizedAccountId else {
                DiagnosticsLogger.api.debug("Ignoring stale podcasts availability signal for account=\(normalizedAccountId), outcome=\(outcome)")
                return false
            }
            return true
        }
    }

    private static func normalizedAccountId(_ accountId: String?) -> String {
        accountId ?? "primary"
    }
}

private extension PodcastsAvailabilityService {
    enum AccountScope: Equatable {
        case unconfigured
        case loggedOut
        case account(String)
    }

    struct ProbeToken: Equatable {
        let accountId: String
        let generation: Int
    }
}
