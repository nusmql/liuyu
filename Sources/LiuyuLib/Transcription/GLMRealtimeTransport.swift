import Foundation
import LiuyuVoice

public actor GLMRealtimeTransport: StreamingTranscriptionTransport {
    private nonisolated let adapter: GLMRealtimeAdapter

    public init(adapter: GLMRealtimeAdapter = GLMRealtimeAdapter()) {
        self.adapter = adapter
    }

    public func connect(config: TranscriptionProviderConfig) async throws {
        try await adapter.connect(config: TranscriptionConfig(
            apiKey: config.apiKey,
            endpoint: config.endpoint,
            model: config.model,
            language: config.language,
            timeout: 30
        ))
    }

    public func send(frames: [VoiceAudioFrame]) async throws {
        var data = Data()
        for frame in frames {
            data.append(frame.pcm16MonoData)
        }
        guard !data.isEmpty else { return }
        try await adapter.sendAudio(data, isFinal: false)
    }

    public func finish() async throws {
        try await adapter.sendAudio(Data(), isFinal: true)
    }

    public nonisolated func results() -> AsyncStream<TranscriptionProviderResult> {
        Self.mapAdapterResults(adapter.receiveResults())
    }

    public func cancel() async {
        await adapter.disconnect()
    }

    nonisolated static func mapAdapterResults(_ input: AsyncStream<TranscriptionResult>) -> AsyncStream<TranscriptionProviderResult> {
        AsyncStream { continuation in
            let task = Task {
                var lastNonEmptyText: String?

                for await result in input {
                    switch result {
                    case .partial(let text):
                        guard !text.isEmpty else { continue }
                        lastNonEmptyText = text
                        continuation.yield(.partial(text))
                    case .final(let text):
                        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmed.isEmpty {
                            lastNonEmptyText = trimmed
                            continuation.yield(.final(trimmed))
                        } else if let lastNonEmptyText {
                            continuation.yield(.final(lastNonEmptyText))
                        } else {
                            continuation.yield(.failure("No transcription result returned by GLM Realtime."))
                        }
                        continuation.finish()
                        return
                    case .error(let error):
                        continuation.yield(.failure(error.localizedDescription))
                        continuation.finish()
                        return
                    }
                }

                continuation.finish()
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }
}
