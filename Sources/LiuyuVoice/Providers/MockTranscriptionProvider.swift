import Foundation

public struct MockTranscriptionProviderSnapshot: Sendable, Equatable {
    public let sentSequences: [Int64]
    public let finished: Bool
    public let lastSendOrder: Int?
    public let finishOrder: Int?
}

public actor MockTranscriptionProvider: TranscriptionProvider {
    public nonisolated let mode: TranscriptionMode
    private let finalText: String
    private var sentSequences: [Int64] = []
    private var finished = false
    private var order = 0
    private var lastSendOrder: Int?
    private var finishOrder: Int?
    private var continuation: AsyncStream<TranscriptionProviderResult>.Continuation?
    private var pendingResults: [TranscriptionProviderResult] = []
    private var pendingFinish = false

    public init(mode: TranscriptionMode = .streaming, finalText: String) {
        self.mode = mode
        self.finalText = finalText
    }

    public func prepare(config: TranscriptionProviderConfig) async throws {}

    public func send(_ frame: VoiceAudioFrame) async throws {
        order += 1
        lastSendOrder = order
        sentSequences.append(frame.sequence)
    }

    public func finish() async throws {
        order += 1
        finishOrder = order
        finished = true
        yieldOrBuffer(.final(finalText), finish: true)
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
        pendingResults.removeAll()
        pendingFinish = false
    }

    public func snapshot() -> MockTranscriptionProviderSnapshot {
        MockTranscriptionProviderSnapshot(
            sentSequences: sentSequences,
            finished: finished,
            lastSendOrder: lastSendOrder,
            finishOrder: finishOrder
        )
    }
}
