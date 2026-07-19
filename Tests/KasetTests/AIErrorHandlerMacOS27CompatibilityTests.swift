import Foundation
import FoundationModels
import Testing
@testable import Kaset

#if compiler(>=6.4)
    private enum ExpectedAIError: Equatable {
        case contextWindowExceeded
        case decodingFailure
        case contentBlocked
        case cancelled
        case notAvailable
        case modelNotReady
        case sessionBusy
        case timedOut
        case unknown
    }

    @available(macOS 27.0, *)
    private func mappedError(_ error: any Error) -> ExpectedAIError {
        switch AIErrorHandler.handle(error) {
        case .contextWindowExceeded:
            .contextWindowExceeded
        case .decodingFailure:
            .decodingFailure
        case .contentBlocked:
            .contentBlocked
        case .cancelled:
            .cancelled
        case .notAvailable:
            .notAvailable
        case .modelNotReady:
            .modelNotReady
        case .sessionBusy:
            .sessionBusy
        case .timedOut:
            .timedOut
        case .unknown:
            .unknown
        }
    }

    @Suite(.tags(.api))
    struct AIErrorHandlerMacOS27CompatibilityTests {
        @Test("Maps macOS 27 language model errors")
        func mapsLanguageModelErrors() {
            guard #available(macOS 27.0, *) else { return }

            #expect(mappedError(LanguageModelError.contextSizeExceeded(.init(
                contextSize: 4096,
                tokenCount: 5000,
                debugDescription: "test"
            ))) == .contextWindowExceeded)
            #expect(mappedError(LanguageModelError.rateLimited(.init(
                resetDate: nil,
                debugDescription: "test"
            ))) == .sessionBusy)
            #expect(mappedError(LanguageModelError.guardrailViolation(.init(
                debugDescription: "test"
            ))) == .contentBlocked)
            #expect(mappedError(LanguageModelError.refusal(.init(
                explanation: "test",
                debugDescription: "test"
            ))) == .contentBlocked)
            #expect(mappedError(LanguageModelError.unsupportedLanguageOrLocale(.init(
                languageCode: .english,
                debugDescription: "test"
            ))) == .notAvailable)
            #expect(mappedError(LanguageModelError.timeout(.init(
                debugDescription: "test"
            ))) == .timedOut)
        }

        @Test("Maps macOS 27 parsing errors")
        func mapsParsingError() {
            guard #available(macOS 27.0, *) else { return }

            let error = GeneratedContent.ParsingError(
                rawContent: "{}",
                debugDescription: "test"
            )

            #expect(mappedError(error) == .decodingFailure)
        }

        @Test("Maps macOS 27 session errors")
        func mapsSessionErrors() {
            guard #available(macOS 27.0, *) else { return }

            #expect(mappedError(LanguageModelSession.Error.concurrentRequests) == .sessionBusy)
            #expect(mappedError(LanguageModelSession.Error.transcriptMutationWhileResponding) == .unknown)
        }

        @Test("Maps macOS 27 model asset errors")
        func mapsAssetsUnavailable() {
            guard #available(macOS 27.0, *) else { return }

            let error = SystemLanguageModel.Error.assetsUnavailable(.init(debugDescription: "test"))

            #expect(mappedError(error) == .notAvailable)
        }

        @Test("Keeps unsupported macOS 27 features as unknown errors")
        func keepsUnsupportedFeaturesUnknown() {
            guard #available(macOS 27.0, *) else { return }

            #expect(mappedError(LanguageModelError.unsupportedCapability(.init(
                capability: .vision,
                debugDescription: "test"
            ))) == .unknown)
            #expect(mappedError(LanguageModelError.unsupportedTranscriptContent(.init(
                unsupportedContent: [],
                debugDescription: "test"
            ))) == .unknown)
            #expect(mappedError(LanguageModelError.unsupportedGenerationGuide(.init(
                schemaName: "TestSchema",
                debugDescription: "test"
            ))) == .unknown)
        }
    }
#endif
