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
        guard !parsed.suggestions.isEmpty
            || !bootstrap.suggestions.isEmpty
            || parsed.freeTextCommand != nil
            || bootstrap.hasFreeTextCommand
        else {
            throw YouTubeAskClientError.invalidResponse
        }
        guard let conversation = YouTubeAskConversation.materialized(
            from: bootstrap,
            parsed: parsed
        ) else {
            throw YouTubeAskClientError.invalidResponse
        }
        return conversation
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

    func continueAskConversation(
        _ conversation: YouTubeAskConversation,
        submitting userInputText: String,
        playerOffsetMilliseconds: Int64
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
        ), let submission = conversation.pendingFreeTextSubmission(matching: userInputText)
        else {
            throw CancellationError()
        }

        let bodyData: Data
        let clickTrackingContextData: Data
        let request: URLRequest
        do {
            bodyData = try YouTubeAskRequestBuilder.makeFreeTextBody(
                command: submission.command,
                clientMessageID: self.nextAskClientMessageID(),
                userInputText: submission.userInputText,
                playerOffsetMilliseconds: playerOffsetMilliseconds
            )
            clickTrackingContextData = try YouTubeAskRequestBuilder.makeFreeTextClickTrackingContext(
                command: submission.command
            )
            request = try self.makeAskRequest(
                endpoint: "get_panel",
                bodyData: bodyData,
                snapshot: snapshot,
                clickTrackingContextData: clickTrackingContextData
            )
            guard let finalBody = request.httpBody else {
                throw YouTubeAskClientError.invalidResponse
            }
            try YouTubeAskRequestBuilder.validateRequestBodySize(finalBody)
        } catch {
            throw YouTubeAskClientError.invalidResponse
        }
        guard self.consumeAskRevision(
            conversationID: conversation.id,
            revision: conversation.revision
        ) else {
            throw CancellationError()
        }

        let parsed = try await self.performAskPanelRequest(request: request, snapshot: snapshot)
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
        snapshot: AskRequestSnapshot,
        clickTrackingContextData: Data? = nil
    ) async throws -> YouTubeAskParsedConversation {
        try self.validateAskRequestSnapshot(snapshot)
        let request = try self.makeAskRequest(
            endpoint: "get_panel",
            bodyData: bodyData,
            snapshot: snapshot,
            clickTrackingContextData: clickTrackingContextData
        )
        return try await self.performAskPanelRequest(request: request, snapshot: snapshot)
    }

    private func performAskPanelRequest(
        request: URLRequest,
        snapshot: AskRequestSnapshot
    ) async throws -> YouTubeAskParsedConversation {
        try self.validateAskRequestSnapshot(snapshot)
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
            throw YTMusicError.authExpired
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
