import XCTest
@testable import LiuyuVoice

final class VoiceSessionCoordinatorTests: XCTestCase {
    private enum EventCollectionError: Error {
        case timedOut
    }

    fileprivate enum PrepareFailure: Error {
        case failed
    }

    func testStartCancelsResultTaskWhenPrepareFails() async throws {
        let source = FakeAudioSource(frames: [])
        let provider = PrepareFailingProvider()
        let coordinator = VoiceSessionCoordinator(source: source, provider: provider)

        do {
            try await coordinator.start(config: .init(apiKey: "key", endpoint: "mock", model: "mock"))
            XCTFail("Expected prepare failure")
        } catch PrepareFailure.failed {
            // expected
        }

        try await Self.waitForResultStreamTermination(provider: provider)
    }

    func testCoordinatorStartsCaptureAndBuffersFramesBeforeProviderPrepareCompletes() async throws {
        let source = StartYieldingAudioSource(frame: makeFrame(sequence: 1))
        let provider = BlockingPrepareProvider()
        let coordinator = VoiceSessionCoordinator(
            source: source,
            provider: provider,
            configuration: VoiceSessionConfiguration(preRollFrameLimit: 3, tailFrameLimit: 0)
        )

        let startTask = Task {
            try await coordinator.start(config: .init(apiKey: "key", endpoint: "mock", model: "mock"))
        }

        try await provider.waitUntilPrepareStarted()
        let sourceStartedDuringPrepare = await source.hasStarted()
        let sentDuringPrepare = await provider.sentSequences()
        XCTAssertTrue(sourceStartedDuringPrepare)
        XCTAssertEqual(sentDuringPrepare, [])

        await provider.releasePrepare()
        try await startTask.value
        try await Self.waitForSentSequences([1], provider: provider)

        await coordinator.cancel()
    }

    func testStopBeforePrepareCompletesFlushesBufferedFramesBeforeFinish() async throws {
        let source = StartYieldingAudioSource(frame: makeFrame(sequence: 1))
        let provider = BlockingPrepareProvider()
        let coordinator = VoiceSessionCoordinator(
            source: source,
            provider: provider,
            configuration: VoiceSessionConfiguration(preRollFrameLimit: 3, tailFrameLimit: 0)
        )

        let startTask = Task {
            try await coordinator.start(config: .init(apiKey: "key", endpoint: "mock", model: "mock"))
        }

        try await provider.waitUntilPrepareStarted()
        await coordinator.stop(reason: .userReleased)
        await provider.releasePrepare()
        try await startTask.value

        try await Self.waitForProviderEvents(["send:1", "finish"], provider: provider)
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

    func testCoordinatorEmitsAudioLevelForAcceptedLiveFrames() async throws {
        let source = FakeAudioSource(frames: [
            makeFrame(sequence: 1, audioLevel: 0.6)
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
        try await Self.waitForSentFrameCount(1, provider: provider)
        await coordinator.stop(reason: .userReleased)

        let audioLevels = try await collectedEvents.compactMap { event -> Float? in
            guard case .audioLevel(let level, _) = event else { return nil }
            return level
        }
        XCTAssertEqual(audioLevels, [0.6])
    }

    func testCoordinatorFailsWhenProviderResultsEndWithoutTerminalEvent() async throws {
        let source = FakeAudioSource(frames: [
            makeFrame(sequence: 1)
        ])
        let provider = SilentFinishingProvider()
        let coordinator = VoiceSessionCoordinator(
            source: source,
            provider: provider,
            configuration: VoiceSessionConfiguration(preRollFrameLimit: 0, tailFrameLimit: 0)
        )
        let events = coordinator.events()

        async let collectedEvents = Self.collectEvents(from: events)
        try await coordinator.start(config: .init(apiKey: "key", endpoint: "mock", model: "mock"))
        try await provider.waitUntilResultsSubscribed()
        await coordinator.stop(reason: .userReleased)

        let failures = try await collectedEvents.compactMap { event -> String? in
            guard case .failed(let message, _) = event else { return nil }
            return message
        }
        XCTAssertEqual(failures, ["Transcription provider ended without a final result."])
    }

    func testCoordinatorCancelDoesNotEmitProviderEndedFailure() async throws {
        let source = FakeAudioSource(frames: [])
        let provider = CancelEmittingProvider()
        let coordinator = VoiceSessionCoordinator(
            source: source,
            provider: provider,
            configuration: VoiceSessionConfiguration(preRollFrameLimit: 0, tailFrameLimit: 0)
        )
        let events = coordinator.events()

        async let collectedEvents = Self.collectEvents(from: events)
        try await coordinator.start(config: .init(apiKey: "key", endpoint: "mock", model: "mock"))
        try await provider.waitUntilResultsSubscribed()
        await coordinator.cancel()

        let eventsResult = try await collectedEvents
        let failures = eventsResult.compactMap { event -> String? in
            guard case .failed(let message, _) = event else { return nil }
            return message
        }
        let cancellations = eventsResult.compactMap { event -> VoiceSessionMetrics? in
            guard case .cancelled(let metrics) = event else { return nil }
            return metrics
        }

        XCTAssertEqual(failures, [])
        XCTAssertEqual(cancellations.count, 1)
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

    private static func waitForSentSequences(
        _ expectedSequences: [Int64],
        provider: BlockingPrepareProvider,
        attempts: Int = 100
    ) async throws {
        for _ in 0..<attempts {
            let sequences = await provider.sentSequences()
            if sequences == expectedSequences {
                return
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw EventCollectionError.timedOut
    }

    private static func waitForProviderEvents(
        _ expectedEvents: [String],
        provider: BlockingPrepareProvider,
        attempts: Int = 100
    ) async throws {
        for _ in 0..<attempts {
            let events = await provider.events()
            if events == expectedEvents {
                return
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        let events = await provider.events()
        XCTFail("Expected provider events \(expectedEvents), got \(events)")
        throw EventCollectionError.timedOut
    }

    private func makeFrame(sequence: Int64, audioLevel: Float = 0) -> VoiceAudioFrame {
        VoiceAudioFrame(
            sequence: sequence,
            timestampNanos: sequence,
            format: .pcm16Mono16k,
            pcm16MonoData: Data([1, 2]),
            isPreRoll: false,
            audioLevel: audioLevel
        )
    }
}

private actor PrepareFailingProvider: TranscriptionProvider {
    nonisolated let mode: TranscriptionMode = .streaming
    private var resultStreamTerminated = false

    func prepare(config: TranscriptionProviderConfig) async throws {
        throw VoiceSessionCoordinatorTests.PrepareFailure.failed
    }

    func send(_ frame: VoiceAudioFrame) async throws {}

    func finish() async throws {}

    nonisolated func results() -> AsyncStream<TranscriptionProviderResult> {
        AsyncStream { continuation in
            continuation.onTermination = { _ in
                Task { await self.markResultStreamTerminated() }
            }
        }
    }

    func cancel() async {}

    func markResultStreamTerminated() {
        resultStreamTerminated = true
    }

    func hasTerminatedResultStream() -> Bool {
        resultStreamTerminated
    }
}

private actor BlockingPrepareProvider: TranscriptionProvider {
    nonisolated let mode: TranscriptionMode = .streaming
    private var prepareStarted = false
    private var prepareStartedContinuation: CheckedContinuation<Void, Never>?
    private var releasePrepareContinuation: CheckedContinuation<Void, Never>?
    private var sent: [Int64] = []
    private var recordedEvents: [String] = []

    func prepare(config: TranscriptionProviderConfig) async throws {
        prepareStarted = true
        prepareStartedContinuation?.resume()
        prepareStartedContinuation = nil

        await withCheckedContinuation { continuation in
            releasePrepareContinuation = continuation
        }
    }

    func send(_ frame: VoiceAudioFrame) async throws {
        sent.append(frame.sequence)
        recordedEvents.append("send:\(frame.sequence)")
    }

    func finish() async throws {
        recordedEvents.append("finish")
    }

    nonisolated func results() -> AsyncStream<TranscriptionProviderResult> {
        AsyncStream { _ in }
    }

    func cancel() async {}

    func waitUntilPrepareStarted() async throws {
        if prepareStarted { return }
        await withCheckedContinuation { continuation in
            prepareStartedContinuation = continuation
        }
    }

    func releasePrepare() {
        releasePrepareContinuation?.resume()
        releasePrepareContinuation = nil
    }

    func sentSequences() -> [Int64] {
        sent
    }

    func events() -> [String] {
        recordedEvents
    }
}

private actor StartYieldingAudioSource: AudioSource {
    private let frame: VoiceAudioFrame
    private var continuation: AsyncStream<VoiceAudioFrame>.Continuation?
    private var started = false

    init(frame: VoiceAudioFrame) {
        self.frame = frame
    }

    nonisolated func frames() -> AsyncStream<VoiceAudioFrame> {
        AsyncStream { continuation in
            Task { await self.setContinuation(continuation) }
        }
    }

    func start() async throws {
        started = true
        for _ in 0..<100 where continuation == nil {
            try? await Task.sleep(for: .milliseconds(1))
        }
        continuation?.yield(frame)
    }

    func stop() async {
        continuation?.finish()
        continuation = nil
    }

    func hasStarted() -> Bool {
        started
    }

    private func setContinuation(_ continuation: AsyncStream<VoiceAudioFrame>.Continuation) {
        self.continuation = continuation
    }
}

private actor SilentFinishingProvider: TranscriptionProvider {
    nonisolated let mode: TranscriptionMode = .streaming
    private var continuation: AsyncStream<TranscriptionProviderResult>.Continuation?
    private var resultsSubscribed = false
    private var resultsSubscribedContinuation: CheckedContinuation<Void, Never>?

    func prepare(config: TranscriptionProviderConfig) async throws {}

    func send(_ frame: VoiceAudioFrame) async throws {}

    func finish() async throws {
        continuation?.finish()
    }

    nonisolated func results() -> AsyncStream<TranscriptionProviderResult> {
        AsyncStream { continuation in
            Task { await self.setContinuation(continuation) }
        }
    }

    func cancel() async {
        continuation?.finish()
        continuation = nil
    }

    private func setContinuation(_ continuation: AsyncStream<TranscriptionProviderResult>.Continuation) {
        self.continuation = continuation
        resultsSubscribed = true
        resultsSubscribedContinuation?.resume()
        resultsSubscribedContinuation = nil
    }

    func waitUntilResultsSubscribed() async throws {
        if resultsSubscribed { return }
        await withCheckedContinuation { continuation in
            resultsSubscribedContinuation = continuation
        }
    }
}

private actor CancelEmittingProvider: TranscriptionProvider {
    nonisolated let mode: TranscriptionMode = .streaming
    private var continuation: AsyncStream<TranscriptionProviderResult>.Continuation?
    private var resultsSubscribed = false
    private var resultsSubscribedContinuation: CheckedContinuation<Void, Never>?

    func prepare(config: TranscriptionProviderConfig) async throws {}

    func send(_ frame: VoiceAudioFrame) async throws {}

    func finish() async throws {}

    nonisolated func results() -> AsyncStream<TranscriptionProviderResult> {
        AsyncStream { continuation in
            Task { await self.setContinuation(continuation) }
        }
    }

    func cancel() async {
        continuation?.yield(.failure("provider cleanup failure during cancel"))
        continuation?.finish()
        continuation = nil
        try? await Task.sleep(for: .milliseconds(20))
    }

    private func setContinuation(_ continuation: AsyncStream<TranscriptionProviderResult>.Continuation) {
        self.continuation = continuation
        resultsSubscribed = true
        resultsSubscribedContinuation?.resume()
        resultsSubscribedContinuation = nil
    }

    func waitUntilResultsSubscribed() async throws {
        if resultsSubscribed { return }
        await withCheckedContinuation { continuation in
            resultsSubscribedContinuation = continuation
        }
    }
}

private extension VoiceSessionCoordinatorTests {
    static func waitForResultStreamTermination(
        provider: PrepareFailingProvider,
        attempts: Int = 100
    ) async throws {
        for _ in 0..<attempts {
            if await provider.hasTerminatedResultStream() {
                return
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw EventCollectionError.timedOut
    }
}
