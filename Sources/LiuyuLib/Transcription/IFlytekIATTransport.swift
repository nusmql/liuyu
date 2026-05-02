import Foundation
import LiuyuVoice

public actor IFlytekIATTransport: StreamingTranscriptionTransport {
    private nonisolated let adapter: IFlytekIATAdapter
    private var pendingPCM = Data()
    private let chunkSize = 1_280

    public init(adapter: IFlytekIATAdapter = IFlytekIATAdapter()) {
        self.adapter = adapter
    }

    public func connect(config: TranscriptionProviderConfig) async throws {
        pendingPCM.removeAll(keepingCapacity: true)
        try await adapter.connect(config: TranscriptionConfig(
            apiKey: config.apiKey,
            endpoint: config.endpoint,
            model: config.model,
            language: config.language,
            timeout: 30
        ))
    }

    public func send(frames: [VoiceAudioFrame]) async throws {
        for frame in frames {
            pendingPCM.append(frame.pcm16MonoData)
        }

        while pendingPCM.count >= chunkSize {
            let chunk = pendingPCM.prefix(chunkSize)
            pendingPCM.removeFirst(chunkSize)
            try await adapter.sendAudio(Data(chunk), isFinal: false)
        }
    }

    public func finish() async throws {
        if !pendingPCM.isEmpty {
            try await adapter.sendAudio(pendingPCM, isFinal: false)
            pendingPCM.removeAll(keepingCapacity: true)
        }
        try await adapter.sendAudio(Data(), isFinal: true)
    }

    public nonisolated func results() -> AsyncStream<TranscriptionProviderResult> {
        GLMRealtimeTransport.mapAdapterResults(adapter.receiveResults())
    }

    public func cancel() async {
        pendingPCM.removeAll(keepingCapacity: true)
        await adapter.disconnect()
    }
}
