import Testing
@testable import Kaset

@Suite(.serialized, .tags(.service))
@MainActor
struct PlaybackAudioQualityStatsLoggingTests {
    @Test("Audio quality stats log message keeps only native-allowlisted stats")
    func audioQualityStatsLogMessageSanitizesUntrustedBridgePayload() {
        let body: [String: Any] = [
            "preferred": "high",
            "desired": "AUDIO_QUALITY_HIGH",
            "applied": true,
            "observed": "AUDIO_QUALITY_MEDIUM",
            "source": "stats",
            "available": [
                "AUDIO_QUALITY_HIGH",
                ["mock": "mock-token"],
                Double.infinity,
                true,
            ],
            "stats": [
                "audioBitrate": "256kbps",
                "audioCodec": [
                    "opus",
                    ["mock": "mock-token"],
                    251,
                    false,
                    Double.nan,
                ],
                "audioSecret": "mock-token",
                "debug_audioQuality": "AUDIO_QUALITY_HIGH",
                "trackingCookie": "mock-cookie",
                "unrelated": ["mock": "mock-token"],
            ],
        ]

        let message = SingletonPlayerWebView.Coordinator.audioQualityStatsLogMessage(
            body: body,
            observedVideoId: "video-id"
        )

        #expect(message.contains("available=[\"AUDIO_QUALITY_HIGH\",true]"))
        #expect(message.contains("\"audioBitrate\":\"256kbps\""))
        #expect(message.contains("\"audioCodec\":[\"opus\",251,false]"))
        #expect(message.contains("\"debug_audioQuality\":\"AUDIO_QUALITY_HIGH\""))
        #expect(!message.contains("trackingCookie"))
        #expect(!message.contains("audioSecret"))
        #expect(!message.contains("unrelated"))
        #expect(!message.contains("mock-token"))
        #expect(!message.contains("mock-cookie"))
        #expect(!message.contains("Infinity"))
        #expect(!message.contains("NaN"))
    }
}
