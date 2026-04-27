import Foundation
import LiuyuVoice

enum VoiceProviderFactory {
    typealias STTParams = (apiKey: String, endpoint: String, model: String, apiFormat: ApiFormat)
    typealias RESTTranscribe = @Sendable (Data, TranscriptionProviderConfig, ApiFormat) async throws -> String

    static func makeProvider(
        params: STTParams,
        fallback: STTParams? = nil,
        language: String?,
        restTranscribe: @escaping RESTTranscribe = transcribeWithService
    ) -> any TranscriptionProvider {
        switch params.apiFormat {
        case .alibabaRealtime:
            return StreamingTranscriptionProvider(
                transport: AlibabaRealtimeTransport(),
                chunkFrameLimit: 5
            )
        case .whisperMultipart, .chatCompletionsAudio, .tencentRealtime:
            return makeRESTProvider(
                primary: params,
                fallback: fallback,
                language: language,
                restTranscribe: restTranscribe
            )
        }
    }

    private static func makeRESTProvider(
        primary: STTParams,
        fallback: STTParams?,
        language: String?,
        restTranscribe: @escaping RESTTranscribe
    ) -> RESTTranscriptionProvider {
        RESTTranscriptionProvider(modeName: "rest") { wavData, config in
            do {
                return try await restTranscribe(wavData, config, restApiFormat(for: primary.apiFormat))
            } catch {
                guard let fallback, fallback.apiFormat != .alibabaRealtime else {
                    throw error
                }

                Logger.warning("Primary voice REST transcription failed, trying fallback \(fallback.model)", category: .stt)
                let fallbackConfig = TranscriptionProviderConfig(
                    apiKey: fallback.apiKey,
                    endpoint: fallback.endpoint,
                    model: fallback.model,
                    language: config.language ?? language
                )
                return try await restTranscribe(
                    wavData,
                    fallbackConfig,
                    restApiFormat(for: fallback.apiFormat)
                )
            }
        }
    }

    private static func transcribeWithService(
        wavData: Data,
        config: TranscriptionProviderConfig,
        apiFormat: ApiFormat
    ) async throws -> String {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("liuyu_voice_\(UUID().uuidString).wav")
        try wavData.write(to: tempURL, options: .atomic)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let service = TranscriptionService(
            apiKey: config.apiKey,
            endpoint: config.endpoint,
            model: config.model,
            language: config.language,
            apiFormat: apiFormat
        )
        return try await service.transcribe(audioFileURL: tempURL)
    }

    private static func restApiFormat(for apiFormat: ApiFormat) -> ApiFormat {
        switch apiFormat {
        case .whisperMultipart:
            return .whisperMultipart
        case .chatCompletionsAudio:
            return .chatCompletionsAudio
        case .alibabaRealtime, .tencentRealtime:
            return .whisperMultipart
        }
    }
}
