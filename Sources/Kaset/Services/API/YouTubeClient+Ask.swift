import Foundation
import YouTubeAskCore

extension YouTubeClient {
    func loadAskConversation(
        from bootstrap: YouTubeAskBootstrap
    ) async throws -> YouTubeAskConversation {
        let snapshot = try await self.makeAskRequestSnapshot(videoID: bootstrap.videoID)
        guard bootstrap.isBound(
            toVideoID: snapshot.videoID,
            authenticationGeneration: snapshot.authenticationGeneration,
            accountBinding: snapshot.accountBinding,
            clientGeneration: snapshot.clientGeneration
        ) else {
            throw CancellationError()
        }

        if !bootstrap.requiresPanelMaterialization {
            return YouTubeAskConversation.direct(from: bootstrap)
        }

        guard let command = bootstrap.materializationCommand else {
            throw YouTubeAskClientError.invalidResponse
        }
        guard self.consumeAskBootstrap(conversationID: bootstrap.conversationID) else {
            throw CancellationError()
        }
        let bodyData = YouTubeAskRequestBuilder.makePanelBootstrapBody(command: command)
        let parsed = try await self.performAskPanelRequest(
            bodyData: bodyData,
            snapshot: snapshot
        )
        guard !parsed.suggestions.isEmpty else {
            throw YouTubeAskClientError.invalidResponse
        }
        return YouTubeAskConversation.materialized(
            from: bootstrap,
            parsed: parsed
        )
    }

    func continueAskConversation(
        _ conversation: YouTubeAskConversation,
        selecting suggestionID: YouTubeAskSuggestion.ID
    ) async throws -> YouTubeAskConversation {
        guard let videoID = conversation.boundVideoID else {
            throw CancellationError()
        }
        let snapshot = try await self.makeAskRequestSnapshot(videoID: videoID)
        guard conversation.isBound(
            toVideoID: snapshot.videoID,
            authenticationGeneration: snapshot.authenticationGeneration,
            accountBinding: snapshot.accountBinding,
            clientGeneration: snapshot.clientGeneration
        ), let command = conversation.command(for: suggestionID)
        else {
            throw CancellationError()
        }
        guard self.consumeAskRevision(
            conversationID: conversation.id,
            revision: conversation.revision
        ) else {
            throw CancellationError()
        }

        let bodyData: Data
        do {
            bodyData = try YouTubeAskRequestBuilder.makeDirectChipBody(
                command: command,
                clientMessageID: self.nextAskClientMessageID()
            )
        } catch {
            throw YouTubeAskClientError.invalidResponse
        }
        let parsed = try await self.performAskPanelRequest(
            bodyData: bodyData,
            snapshot: snapshot
        )
        guard !parsed.messages.isEmpty,
              let nextConversation = YouTubeAskConversation.continued(
                  from: conversation,
                  parsed: parsed
              )
        else {
            throw YouTubeAskClientError.invalidResponse
        }
        return nextConversation
    }

    private func performAskPanelRequest(
        bodyData: Data,
        snapshot: AskRequestSnapshot
    ) async throws -> YouTubeAskParsedConversation {
        try self.validateAskRequestSnapshot(snapshot)
        let request = try self.makeAskRequest(
            endpoint: "get_panel",
            bodyData: bodyData,
            snapshot: snapshot
        )

        let response: YouTubeAskHTTPResponse
        do {
            response = try await self.askTransport.send(request)
        } catch is CancellationError {
            throw CancellationError()
        } catch YouTubeAskTransportError.responseTooLarge {
            throw YouTubeAskClientError.responseTooLarge
        } catch YouTubeAskTransportError.invalidResponse {
            throw YouTubeAskClientError.invalidResponse
        } catch {
            throw YouTubeAskClientError.unavailable
        }
        try self.validateAskRequestSnapshot(snapshot)

        switch response.statusCode {
        case 200 ... 299:
            break
        case 401, 403:
            // Match YouTubeClient's established InnerTube auth handling: both
            // statuses expire the matching identity generation, never a newer
            // session that signed in while this request was in flight.
            self.handleAskAuthenticationFailure(snapshot: snapshot)
            throw YouTubeAskClientError.authenticationRequired
        case 429:
            throw YouTubeAskClientError.rateLimited
        default:
            throw YouTubeAskClientError.unavailable
        }

        let parsed: YouTubeAskParsedConversation
        do {
            parsed = try await Task.detached(priority: .userInitiated) {
                let envelope = try YouTubeAskWireDecoder.decode(response.data)
                return try YouTubeAskParser.parseConversation(from: envelope)
            }.value
        } catch is CancellationError {
            throw CancellationError()
        } catch YouTubeAskCoreError.responseTooLarge {
            throw YouTubeAskClientError.responseTooLarge
        } catch {
            throw YouTubeAskClientError.invalidResponse
        }

        try self.validateAskRequestSnapshot(snapshot)
        return parsed
    }
}
