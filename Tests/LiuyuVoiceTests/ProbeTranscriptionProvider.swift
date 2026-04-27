import Foundation
@testable import LiuyuVoice

actor ProbeTranscriptionProvider: TranscriptionProvider {
    nonisolated let mode: TranscriptionMode = .streaming

    private let finalText: String
    private var continuation: AsyncStream<TranscriptionProviderResult>.Continuation?
    private var sentFrames: [VoiceAudioFrame] = []
    private var recordedEvents: [String] = []
    private var sentFrameCountWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    init(finalText: String = "probe result") {
        self.finalText = finalText
    }

    func prepare(config: TranscriptionProviderConfig) async throws {
        recordedEvents.append("prepare")
    }

    func send(_ frame: VoiceAudioFrame) async throws {
        sentFrames.append(frame)
        recordedEvents.append("send:\(frame.sequence)")
        resumeSentFrameCountWaiters()
    }

    func finish() async throws {
        recordedEvents.append("finish")
        continuation?.yield(.final(finalText))
        continuation?.finish()
        continuation = nil
    }

    nonisolated func results() -> AsyncStream<TranscriptionProviderResult> {
        AsyncStream { continuation in
            Task { await self.setContinuation(continuation) }
        }
    }

    func cancel() async {
        recordedEvents.append("cancel")
        continuation?.finish()
        continuation = nil
    }

    func waitUntilSentFrameCount(_ expectedCount: Int) async throws {
        if sentFrames.count >= expectedCount { return }
        await withCheckedContinuation { continuation in
            sentFrameCountWaiters.append((expectedCount, continuation))
        }
    }

    func snapshot() -> ProbeTranscriptionSnapshot {
        ProbeTranscriptionSnapshot(sentFrames: sentFrames, events: recordedEvents)
    }

    private func setContinuation(_ continuation: AsyncStream<TranscriptionProviderResult>.Continuation) {
        self.continuation = continuation
    }

    private func resumeSentFrameCountWaiters() {
        var remaining: [(Int, CheckedContinuation<Void, Never>)] = []
        for waiter in sentFrameCountWaiters {
            if sentFrames.count >= waiter.0 {
                waiter.1.resume()
            } else {
                remaining.append(waiter)
            }
        }
        sentFrameCountWaiters = remaining
    }
}

struct ProbeTranscriptionSnapshot: Sendable, Equatable {
    let sentFrames: [VoiceAudioFrame]
    let events: [String]

    var concatenatedPCM: Data {
        sentFrames.reduce(Data()) { partial, frame in
            var data = partial
            data.append(frame.pcm16MonoData)
            return data
        }
    }
}
