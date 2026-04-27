import XCTest
@testable import LiuyuVoice

final class VoiceSessionCoordinatorTests: XCTestCase {
    private enum EventCollectionError: Error {
        case timedOut
    }

    func testCoordinatorSendsAllBufferedFramesBeforeFinish() async throws {
        let frames = (1...5).map { makeFrame(sequence: Int64($0)) }
        let source = FakeAudioSource(frames: frames)
        let provider = MockTranscriptionProvider(finalText: "done")
        let coordinator = VoiceSessionCoordinator(
            source: source,
            provider: provider,
            configuration: VoiceSessionConfiguration(preRollFrameLimit: 2, tailFrameLimit: 1)
        )

        try await coordinator.start(config: .init(apiKey: "key", endpoint: "mock", model: "mock"))
        try await Self.waitForSentFrameCount(5, provider: provider)
        await coordinator.stop(reason: .userReleased)

        let snapshot = await provider.snapshot()
        XCTAssertEqual(snapshot.sentSequences, [1, 2, 3, 4, 5])
        XCTAssertTrue(snapshot.finished)
        XCTAssertLessThan(snapshot.lastSendOrder!, snapshot.finishOrder!)
    }

    func testCoordinatorEmitsFinalEventWithMetrics() async throws {
        let source = FakeAudioSource(frames: [
            makeFrame(sequence: 1),
            makeFrame(sequence: 2)
        ])
        let provider = MockTranscriptionProvider(finalText: "done")
        let coordinator = VoiceSessionCoordinator(
            source: source,
            provider: provider,
            configuration: VoiceSessionConfiguration(preRollFrameLimit: 0, tailFrameLimit: 0)
        )
        let events = coordinator.events()

        async let collectedEvents = Self.collectEvents(from: events)
        try await coordinator.start(config: .init(apiKey: "key", endpoint: "mock", model: "mock"))
        try await Self.waitForSentFrameCount(2, provider: provider)
        await coordinator.stop(reason: .userReleased)

        let eventsResult = try await collectedEvents
        let finalEvents = eventsResult.compactMap { event -> VoiceSessionMetrics? in
            guard case .final("done", let metrics) = event else { return nil }
            return metrics
        }

        XCTAssertEqual(finalEvents.count, 1)
        XCTAssertEqual(finalEvents[0].sentFrameCount, 2)
        XCTAssertEqual(finalEvents[0].sentByteCount, 4)
        XCTAssertNotNil(finalEvents[0].finishSentAtNanos)
        XCTAssertNotNil(finalEvents[0].finalReceivedAtNanos)
    }

    private static func collectEvents(
        from stream: AsyncStream<VoiceSessionEvent>,
        timeout: Duration = .seconds(1)
    ) async throws -> [VoiceSessionEvent] {
        try await withThrowingTaskGroup(of: [VoiceSessionEvent].self) { group in
            group.addTask {
                var events: [VoiceSessionEvent] = []
                for await event in stream {
                    events.append(event)
                }
                return events
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw EventCollectionError.timedOut
            }

            let events = try await group.next()!
            group.cancelAll()
            return events
        }
    }

    private static func waitForSentFrameCount(
        _ expectedCount: Int,
        provider: MockTranscriptionProvider,
        attempts: Int = 100
    ) async throws {
        for _ in 0..<attempts {
            let snapshot = await provider.snapshot()
            if snapshot.sentSequences.count >= expectedCount {
                return
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw EventCollectionError.timedOut
    }

    private func makeFrame(sequence: Int64) -> VoiceAudioFrame {
        VoiceAudioFrame(
            sequence: sequence,
            timestampNanos: sequence,
            format: .pcm16Mono16k,
            pcm16MonoData: Data([1, 2]),
            isPreRoll: false
        )
    }
}
