import XCTest
import LiuyuVoice
@testable import LiuyuLib

final class VoiceProviderFactoryTests: XCTestCase {
    private enum TestError: Error {
        case primaryFailed
    }

    func testWhisperMultipartUsesBatchProvider() {
        let provider = VoiceProviderFactory.makeProvider(
            params: Self.params(apiFormat: .whisperMultipart),
            language: nil
        )

        XCTAssertEqual(provider.mode, .batch)
    }

    func testChatCompletionsAudioUsesBatchProvider() {
        let provider = VoiceProviderFactory.makeProvider(
            params: Self.params(apiFormat: .chatCompletionsAudio),
            language: "en"
        )

        XCTAssertEqual(provider.mode, .batch)
    }

    func testGLMMultipartEventStreamUsesStreamingResponseProvider() {
        let provider = VoiceProviderFactory.makeProvider(
            params: Self.params(model: "glm-asr-2512", apiFormat: .glmMultipartEventStream),
            language: nil
        )

        XCTAssertEqual(provider.mode, .streamingResponse)
    }

    func testGLMRealtimeUsesStreamingProvider() {
        let provider = VoiceProviderFactory.makeProvider(
            params: Self.params(model: "glm-realtime-flash", apiFormat: .glmRealtime),
            language: nil
        )

        XCTAssertEqual(provider.mode, .streaming)
    }

    func testAlibabaRealtimeUsesStreamingProvider() {
        let provider = VoiceProviderFactory.makeProvider(
            params: Self.params(apiFormat: .alibabaRealtime),
            language: nil
        )

        XCTAssertEqual(provider.mode, .streaming)
    }

    func testIFlytekIATUsesStreamingProvider() {
        let provider = VoiceProviderFactory.makeProvider(
            params: Self.params(model: "iat-api-v2", apiFormat: .iflytekIAT),
            language: nil
        )

        XCTAssertEqual(provider.mode, .streaming)
    }

    func testTencentRealtimeWithoutFallbackUsesUnsupportedBatchProvider() {
        let provider = VoiceProviderFactory.makeProvider(
            params: Self.params(apiFormat: .tencentRealtime),
            language: nil
        )

        XCTAssertEqual(provider.mode, .batch)
    }

    func testTencentRealtimeWithoutFallbackDoesNotCallRESTTranscribe() async throws {
        let recorder = VoiceProviderAttemptRecorder()
        let provider = VoiceProviderFactory.makeProvider(
            params: Self.params(model: "tencent-realtime", apiFormat: .tencentRealtime),
            language: nil,
            restTranscribe: { data, config, apiFormat in
                await recorder.record(data: data, config: config, apiFormat: apiFormat)
                return "unexpected"
            }
        )

        do {
            try await provider.prepare(config: .init(
                apiKey: "tencent-key",
                endpoint: "https://tencent.example/realtime",
                model: "tencent-realtime"
            ))
            try await provider.finish()
        } catch {
            // unsupported provider path is expected
        }

        let attempts = await recorder.snapshot()
        XCTAssertEqual(attempts, [])
    }

    func testTencentRealtimeUsesRESTCapableFallbackWithoutCallingPrimary() async throws {
        let recorder = VoiceProviderAttemptRecorder()
        let provider = VoiceProviderFactory.makeProvider(
            params: Self.params(model: "tencent-realtime", apiFormat: .tencentRealtime),
            fallback: Self.params(model: "fallback-rest", apiFormat: .chatCompletionsAudio),
            language: "en",
            restTranscribe: { data, config, apiFormat in
                await recorder.record(data: data, config: config, apiFormat: apiFormat)
                return "fallback text"
            }
        )

        try await provider.prepare(config: .init(
            apiKey: "tencent-key",
            endpoint: "https://tencent.example/realtime",
            model: "tencent-realtime",
            language: "en"
        ))
        try await provider.send(Self.frame(sequence: 1))

        let results = provider.results()
        try await provider.finish()

        var finalText: String?
        for await result in results {
            if case .final(let text) = result {
                finalText = text
            }
        }

        let attempts = await recorder.snapshot()
        XCTAssertEqual(finalText, "fallback text")
        XCTAssertEqual(attempts.map(\.model), ["fallback-rest"])
        XCTAssertEqual(attempts.map(\.apiFormat), [.chatCompletionsAudio])
    }

    func testRESTProviderAttemptsFallbackWithSameAudioWhenPrimaryFails() async throws {
        let recorder = VoiceProviderAttemptRecorder()
        let provider = VoiceProviderFactory.makeProvider(
            params: Self.params(model: "primary", apiFormat: .whisperMultipart),
            fallback: Self.params(model: "fallback", apiFormat: .chatCompletionsAudio),
            language: "en",
            restTranscribe: { data, config, apiFormat in
                await recorder.record(data: data, config: config, apiFormat: apiFormat)
                if config.model == "primary" {
                    throw TestError.primaryFailed
                }
                return "fallback text"
            }
        )

        try await provider.prepare(config: .init(
            apiKey: "primary-key",
            endpoint: "https://primary.example/transcribe",
            model: "primary",
            language: "en"
        ))
        try await provider.send(Self.frame(sequence: 1))

        let results = provider.results()
        try await provider.finish()

        var finalText: String?
        for await result in results {
            if case .final(let text) = result {
                finalText = text
            }
        }

        let attempts = await recorder.snapshot()
        XCTAssertEqual(finalText, "fallback text")
        XCTAssertEqual(attempts.map(\.model), ["primary", "fallback"])
        XCTAssertEqual(attempts.map(\.apiFormat), [.whisperMultipart, .chatCompletionsAudio])
        XCTAssertEqual(attempts[0].data, attempts[1].data)
    }

    func testGLMEventStreamRESTProviderPassesEventStreamFormat() async throws {
        let recorder = VoiceProviderAttemptRecorder()
        let provider = VoiceProviderFactory.makeProvider(
            params: Self.params(model: "glm-asr-2512", apiFormat: .glmMultipartEventStream),
            language: "zh",
            restTranscribe: { data, config, apiFormat in
                await recorder.record(data: data, config: config, apiFormat: apiFormat)
                return "stream text"
            }
        )

        try await provider.prepare(config: .init(
            apiKey: "glm-key",
            endpoint: "https://open.bigmodel.cn/api/paas/v4/audio/transcriptions",
            model: "glm-asr-2512",
            language: "zh"
        ))
        try await provider.send(Self.frame(sequence: 1))

        let results = provider.results()
        try await provider.finish()

        var finalText: String?
        for await result in results {
            if case .final(let text) = result {
                finalText = text
            }
        }

        let attempts = await recorder.snapshot()
        XCTAssertEqual(finalText, "stream text")
        XCTAssertEqual(attempts.map(\.apiFormat), [.glmMultipartEventStream])
    }

    private static func params(model: String = "test-model", apiFormat: ApiFormat) -> VoiceProviderFactory.STTParams {
        (
            apiKey: "sk-test",
            endpoint: "https://example.com/v1/audio/transcriptions",
            model: model,
            apiFormat: apiFormat
        )
    }

    private static func frame(sequence: Int64) -> VoiceAudioFrame {
        VoiceAudioFrame(
            sequence: sequence,
            timestampNanos: sequence,
            format: .pcm16Mono16k,
            pcm16MonoData: Data([1, 2]),
            isPreRoll: false
        )
    }
}

private actor VoiceProviderAttemptRecorder {
    struct Attempt: Equatable {
        let data: Data
        let model: String
        let apiFormat: ApiFormat
    }

    private var attempts: [Attempt] = []

    func record(data: Data, config: TranscriptionProviderConfig, apiFormat: ApiFormat) {
        attempts.append(Attempt(data: data, model: config.model, apiFormat: apiFormat))
    }

    func snapshot() -> [Attempt] {
        attempts
    }
}
