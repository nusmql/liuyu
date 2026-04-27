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
        case .whisperMultipart, .chatCompletionsAudio:
            return makeRESTProvider(
                primary: params,
                fallback: fallback,
                language: language,
                restTranscribe: restTranscribe
            )
        case .tencentRealtime:
            guard let fallback, restApiFormat(for: fallback.apiFormat) != nil else {
                return UnsupportedTranscriptionProvider(
                    message: TranscriptionError.streamingNotSupported.localizedDescription
                )
            }

            Logger.warning("Tencent realtime STT is not supported yet, using REST fallback \(fallback.model)", category: .stt)
            return makeRESTProvider(
                primary: fallback,
                fallback: nil,
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
            guard let primaryApiFormat = restApiFormat(for: primary.apiFormat) else {
                throw TranscriptionError.streamingNotSupported
            }

            let primaryConfig = TranscriptionProviderConfig(
                apiKey: primary.apiKey,
                endpoint: primary.endpoint,
                model: primary.model,
                language: config.language ?? language
            )

            do {
                return try await restTranscribe(wavData, primaryConfig, primaryApiFormat)
            } catch {
                guard let fallback, let fallbackApiFormat = restApiFormat(for: fallback.apiFormat) else {
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
                    fallbackApiFormat
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

    private static func restApiFormat(for apiFormat: ApiFormat) -> ApiFormat? {
        switch apiFormat {
        case .whisperMultipart:
            return .whisperMultipart
        case .chatCompletionsAudio:
            return .chatCompletionsAudio
        case .alibabaRealtime, .tencentRealtime:
            return nil
        }
    }
}

private actor UnsupportedTranscriptionProvider: TranscriptionProvider {
    nonisolated let mode: TranscriptionMode = .batch
    private let message: String
    private var continuation: AsyncStream<TranscriptionProviderResult>.Continuation?
    private var pendingResults: [TranscriptionProviderResult] = []
    private var pendingFinish = false

    init(message: String) {
        self.message = message
    }

    func prepare(config: TranscriptionProviderConfig) async throws {
        yieldOrBuffer(.failure(message), finish: true)
        throw TranscriptionError.streamingNotSupported
    }

    func send(_ frame: VoiceAudioFrame) async throws {
        throw TranscriptionError.streamingNotSupported
    }

    func finish() async throws {
        throw TranscriptionError.streamingNotSupported
    }

    nonisolated func results() -> AsyncStream<TranscriptionProviderResult> {
        AsyncStream { continuation in
            Task { await self.setContinuation(continuation) }
        }
    }

    func cancel() async {
        continuation?.finish()
        continuation = nil
        pendingResults.removeAll(keepingCapacity: true)
        pendingFinish = false
    }

    private func setContinuation(_ continuation: AsyncStream<TranscriptionProviderResult>.Continuation) {
        self.continuation = continuation
        flushPendingResults()
    }

    private func yieldOrBuffer(_ result: TranscriptionProviderResult, finish: Bool) {
        guard let continuation else {
            pendingResults.append(result)
            pendingFinish = pendingFinish || finish
            return
        }

        continuation.yield(result)
        if finish {
            continuation.finish()
            self.continuation = nil
        }
    }

    private func flushPendingResults() {
        guard let continuation else { return }

        for result in pendingResults {
            continuation.yield(result)
        }
        pendingResults.removeAll()

        if pendingFinish {
            continuation.finish()
            pendingFinish = false
            self.continuation = nil
        }
    }
}
