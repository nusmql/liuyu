import Foundation

public actor RESTTranscriptionProvider: TranscriptionProvider {
    public let mode: TranscriptionMode = .batch
    public let modeName: String
    private let transcribe: @Sendable (Data, TranscriptionProviderConfig) async throws -> String
    private var config: TranscriptionProviderConfig?
    private var frames: [VoiceAudioFrame] = []
    private var continuation: AsyncStream<TranscriptionProviderResult>.Continuation?
    private var pendingResults: [TranscriptionProviderResult] = []
    private var pendingFinish = false

    public init(
        modeName: String,
        transcribe: @escaping @Sendable (Data, TranscriptionProviderConfig) async throws -> String
    ) {
        self.modeName = modeName
        self.transcribe = transcribe
    }

    public func prepare(config: TranscriptionProviderConfig) async throws {
        self.config = config
        frames.removeAll(keepingCapacity: true)
        pendingResults.removeAll(keepingCapacity: true)
        pendingFinish = false
    }

    public func send(_ frame: VoiceAudioFrame) async throws {
        frames.append(frame)
    }

    public func finish() async throws {
        guard let config else {
            throw VoiceProviderError.notPrepared
        }

        let wavData = WAVEncoder.encodePCM16Mono(frames: frames)
        let text = try await transcribe(wavData, config)
        yieldOrBuffer(.final(text), finish: true)
    }

    public nonisolated func results() -> AsyncStream<TranscriptionProviderResult> {
        AsyncStream { continuation in
            Task { await self.setContinuation(continuation) }
        }
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

    public func cancel() async {
        continuation?.finish()
        continuation = nil
        frames.removeAll(keepingCapacity: true)
        pendingResults.removeAll(keepingCapacity: true)
        pendingFinish = false
    }
}

public enum VoiceProviderError: Error, LocalizedError, Sendable {
    case notPrepared

    public var errorDescription: String? {
        switch self {
        case .notPrepared:
            return "Transcription provider was not prepared."
        }
    }
}
