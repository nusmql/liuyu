import XCTest
@testable import LiuyuVoice

final class VoiceSessionCoordinatorTests: XCTestCase {
    private enum EventCollectionError: Error {
        case timedOut
    }

    fileprivate enum PrepareFailure: Error {
        case failed
    }

    fileprivate enum FinishFailure: Error, LocalizedError {
        case failed

        var errorDescription: String? {
            "finish failed"
        }
    }

    fileprivate enum SourceStartFailure: Error {
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

    func testCoordinatorPreservesAllFramesCapturedDuringProviderPrepare() async throws {
        let frames = (1...5).map { makeFrame(sequence: Int64($0)) }
        let source = StartYieldingAudioSource(frames: frames)
        let provider = BlockingPrepareProvider()
        let coordinator = VoiceSessionCoordinator(
            source: source,
            provider: provider,
            configuration: VoiceSessionConfiguration(preRollFrameLimit: 2, tailFrameLimit: 0)
        )

        let startTask = Task {
            try await coordinator.start(config: .init(apiKey: "key", endpoint: "mock", model: "mock"))
        }

        try await provider.waitUntilPrepareStarted()
        let sentDuringPrepare = await provider.sentSequences()
        XCTAssertEqual(sentDuringPrepare, [])

        await provider.releasePrepare()
        try await startTask.value
        try await Self.waitForSentSequences([1, 2, 3, 4, 5], provider: provider)

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

    func testStopDuringSourceStartPreventsProviderPrepare() async throws {
        let source = BlockingStartAudioSource()
        let provider = StartAfterStopProvider()
        let coordinator = VoiceSessionCoordinator(
            source: source,
            provider: provider,
            configuration: VoiceSessionConfiguration(preRollFrameLimit: 0, tailFrameLimit: 0)
        )
        let events = coordinator.events()

        async let collectedEvents = Self.collectEvents(from: events)
        let startTask = Task {
            try await coordinator.start(config: .init(apiKey: "key", endpoint: "mock", model: "mock"))
        }

        try await source.waitUntilStartRequested()
        await coordinator.stop(reason: .userReleased)
        let stoppedDuringStart = await source.wasStopped()
        XCTAssertTrue(stoppedDuringStart)

        await source.releaseStart()
        try await startTask.value

        let prepareCalled = await provider.prepareWasCalled()
        let eventsResult = try await collectedEvents
        let failures = eventsResult.compactMap { event -> String? in
            guard case .failed(let message, _) = event else { return nil }
            return message
        }

        XCTAssertFalse(prepareCalled)
        XCTAssertEqual(failures, ["Recording stopped before audio capture was ready."])
    }

    func testStopDuringSourceStartStopsSourceAfterStartReturns() async throws {
        let source = BlockingStartAudioSource()
        let provider = StartAfterStopProvider()
        let coordinator = VoiceSessionCoordinator(
            source: source,
            provider: provider,
            configuration: VoiceSessionConfiguration(preRollFrameLimit: 0, tailFrameLimit: 0)
        )

        let startTask = Task {
            try await coordinator.start(config: .init(apiKey: "key", endpoint: "mock", model: "mock"))
        }

        try await source.waitUntilStartRequested()
        await coordinator.stop(reason: .userReleased)
        await source.releaseStart()
        try await startTask.value

        let stopCount = await source.stopCallCount()
        let isRunning = await source.isRunning()
        XCTAssertEqual(stopCount, 2)
        XCTAssertFalse(isRunning)
    }

    func testProviderFailureDuringSourceStartPreventsPrepareAfterStartReturns() async throws {
        let source = BlockingStartAudioSource()
        let provider = FailureEmittingProvider()
        let coordinator = VoiceSessionCoordinator(
            source: source,
            provider: provider,
            configuration: VoiceSessionConfiguration(preRollFrameLimit: 0, tailFrameLimit: 0)
        )
        let events = coordinator.events()

        async let collectedEvents = Self.collectEvents(from: events)
        let startTask = Task {
            try await coordinator.start(config: .init(apiKey: "key", endpoint: "mock", model: "mock"))
        }

        try await source.waitUntilStartRequested()
        try await provider.waitUntilResultsSubscribed()
        await provider.emitFailure("provider failed before source start completed")
        try await provider.waitUntilCancelled()
        await source.releaseStart()
        try await startTask.value

        let eventsResult = try await collectedEvents
        let failures = eventsResult.compactMap { event -> String? in
            guard case .failed(let message, _) = event else { return nil }
            return message
        }
        let prepareCalled = await provider.prepareWasCalled()

        XCTAssertEqual(failures, ["provider failed before source start completed"])
        XCTAssertFalse(prepareCalled)
    }

    func testProviderFailureDuringThrowingSourceStartPreservesTerminalFailure() async throws {
        let source = BlockingStartAudioSource(throwsOnStart: true)
        let provider = FailureEmittingProvider()
        let coordinator = VoiceSessionCoordinator(
            source: source,
            provider: provider,
            configuration: VoiceSessionConfiguration(preRollFrameLimit: 0, tailFrameLimit: 0)
        )
        let events = coordinator.events()

        async let collectedEvents = Self.collectEvents(from: events)
        let startTask = Task {
            try await coordinator.start(config: .init(apiKey: "key", endpoint: "mock", model: "mock"))
        }

        try await source.waitUntilStartRequested()
        try await provider.waitUntilResultsSubscribed()
        await provider.emitFailure("provider failed before source start threw")
        try await provider.waitUntilCancelled()
        await source.releaseStart()

        do {
            try await startTask.value
        } catch {
            XCTFail("Expected terminal provider failure to suppress source start error, got \(error)")
        }

        let eventsResult = try await collectedEvents
        let failures = eventsResult.compactMap { event -> String? in
            guard case .failed(let message, _) = event else { return nil }
            return message
        }
        let prepareCalled = await provider.prepareWasCalled()

        XCTAssertEqual(failures, ["provider failed before source start threw"])
        XCTAssertFalse(prepareCalled)
    }

    func testQueuedProviderFailureDuringThrowingSourceStartPreservesTerminalFailure() async throws {
        let source = BlockingStartAudioSource(throwsOnStart: true, suspendFirstStop: true)
        let provider = FailureEmittingProvider()
        let coordinator = VoiceSessionCoordinator(
            source: source,
            provider: provider,
            configuration: VoiceSessionConfiguration(preRollFrameLimit: 0, tailFrameLimit: 0)
        )
        let events = coordinator.events()

        async let collectedEvents = Self.collectEvents(from: events)
        let startTask = Task {
            try await coordinator.start(config: .init(apiKey: "key", endpoint: "mock", model: "mock"))
        }

        try await source.waitUntilStartRequested()
        try await provider.waitUntilResultsSubscribed()
        await source.releaseStart()
        try await source.waitUntilStopRequested()
        await provider.emitFailure("provider failed while source stop was suspended")
        try await provider.waitUntilCancelled()
        await source.releaseStop()

        do {
            try await startTask.value
        } catch {
            XCTFail("Expected queued terminal provider failure to suppress source start error, got \(error)")
        }

        let eventsResult = try await collectedEvents
        let failures = eventsResult.compactMap { event -> String? in
            guard case .failed(let message, _) = event else { return nil }
            return message
        }
        let prepareCalled = await provider.prepareWasCalled()

        XCTAssertEqual(failures, ["provider failed while source stop was suspended"])
        XCTAssertFalse(prepareCalled)
    }

    func testProviderResultEndDuringSourceStartPreventsPrepareAfterStartReturns() async throws {
        let source = BlockingStartAudioSource()
        let provider = EarlyEndingProvider()
        let coordinator = VoiceSessionCoordinator(
            source: source,
            provider: provider,
            configuration: VoiceSessionConfiguration(preRollFrameLimit: 0, tailFrameLimit: 0)
        )
        let events = coordinator.events()

        async let collectedEvents = Self.collectEvents(from: events)
        let startTask = Task {
            try await coordinator.start(config: .init(apiKey: "key", endpoint: "mock", model: "mock"))
        }

        try await source.waitUntilStartRequested()
        try await provider.waitUntilResultsSubscribed()
        await provider.endResults()
        try await provider.waitUntilCancelled()
        await source.releaseStart()
        try await startTask.value

        let eventsResult = try await collectedEvents
        let failures = eventsResult.compactMap { event -> String? in
            guard case .failed(let message, _) = event else { return nil }
            return message
        }
        let prepareCalled = await provider.prepareWasCalled()

        XCTAssertEqual(failures, ["Transcription provider ended without a final result."])
        XCTAssertFalse(prepareCalled)
    }

    func testProviderResultEndDuringThrowingSourceStartPreservesTerminalFailure() async throws {
        let source = BlockingStartAudioSource(throwsOnStart: true)
        let provider = EarlyEndingProvider()
        let coordinator = VoiceSessionCoordinator(
            source: source,
            provider: provider,
            configuration: VoiceSessionConfiguration(preRollFrameLimit: 0, tailFrameLimit: 0)
        )
        let events = coordinator.events()

        async let collectedEvents = Self.collectEvents(from: events)
        let startTask = Task {
            try await coordinator.start(config: .init(apiKey: "key", endpoint: "mock", model: "mock"))
        }

        try await source.waitUntilStartRequested()
        try await provider.waitUntilResultsSubscribed()
        await provider.endResults()
        try await provider.waitUntilCancelled()
        await source.releaseStart()

        do {
            try await startTask.value
        } catch {
            XCTFail("Expected terminal provider stream end to suppress source start error, got \(error)")
        }

        let eventsResult = try await collectedEvents
        let failures = eventsResult.compactMap { event -> String? in
            guard case .failed(let message, _) = event else { return nil }
            return message
        }
        let prepareCalled = await provider.prepareWasCalled()

        XCTAssertEqual(failures, ["Transcription provider ended without a final result."])
        XCTAssertFalse(prepareCalled)
    }

    func testQueuedProviderResultEndDuringThrowingSourceStartPreservesTerminalFailure() async throws {
        let source = BlockingStartAudioSource(throwsOnStart: true, suspendFirstStop: true)
        let provider = EarlyEndingProvider()
        let coordinator = VoiceSessionCoordinator(
            source: source,
            provider: provider,
            configuration: VoiceSessionConfiguration(preRollFrameLimit: 0, tailFrameLimit: 0)
        )
        let events = coordinator.events()

        async let collectedEvents = Self.collectEvents(from: events)
        let startTask = Task {
            try await coordinator.start(config: .init(apiKey: "key", endpoint: "mock", model: "mock"))
        }

        try await source.waitUntilStartRequested()
        try await provider.waitUntilResultsSubscribed()
        await source.releaseStart()
        try await source.waitUntilStopRequested()
        await provider.endResults()
        try await provider.waitUntilCancelled()
        await source.releaseStop()

        do {
            try await startTask.value
        } catch {
            XCTFail("Expected queued terminal provider stream end to suppress source start error, got \(error)")
        }

        let eventsResult = try await collectedEvents
        let failures = eventsResult.compactMap { event -> String? in
            guard case .failed(let message, _) = event else { return nil }
            return message
        }
        let prepareCalled = await provider.prepareWasCalled()

        XCTAssertEqual(failures, ["Transcription provider ended without a final result."])
        XCTAssertFalse(prepareCalled)
    }

    func testStopDuringStartFailureCleanupFinishesEventStream() async throws {
        let source = BlockingStartAudioSource(
            throwsOnStart: true,
            finishOnStopStartingAt: 2
        )
        let provider = StartAfterStopProvider()
        let coordinator = VoiceSessionCoordinator(
            source: source,
            provider: provider,
            configuration: VoiceSessionConfiguration(preRollFrameLimit: 0, tailFrameLimit: 0)
        )
        let events = coordinator.events()

        async let collectedEvents = Self.collectEvents(from: events)
        let startTask = Task {
            try await coordinator.start(config: .init(apiKey: "key", endpoint: "mock", model: "mock"))
        }

        try await source.waitUntilStartRequested()
        await source.releaseStart()
        try await source.waitUntilStopCallCount(1)

        let stopTask = Task {
            await coordinator.stop(reason: .userReleased)
        }
        try await source.waitUntilStopCallCount(2)

        try await startTask.value
        await stopTask.value

        let eventsResult = try await collectedEvents
        let failures = eventsResult.compactMap { event -> String? in
            guard case .failed(let message, _) = event else { return nil }
            return message
        }
        let prepareCalled = await provider.prepareWasCalled()

        XCTAssertEqual(failures, ["Recording stopped before audio capture was ready."])
        XCTAssertFalse(prepareCalled)
    }

    func testCancelDuringSourceStartStopsSourceAfterStartReturns() async throws {
        let source = BlockingStartAudioSource()
        let provider = StartAfterStopProvider()
        let coordinator = VoiceSessionCoordinator(
            source: source,
            provider: provider,
            configuration: VoiceSessionConfiguration(preRollFrameLimit: 0, tailFrameLimit: 0)
        )

        let startTask = Task {
            try await coordinator.start(config: .init(apiKey: "key", endpoint: "mock", model: "mock"))
        }

        try await source.waitUntilStartRequested()
        await coordinator.cancel()
        await source.releaseStart()
        try await startTask.value

        let stopCount = await source.stopCallCount()
        let isRunning = await source.isRunning()
        XCTAssertEqual(stopCount, 2)
        XCTAssertFalse(isRunning)
    }

    func testCancelDuringProviderPrepareDoesNotSendBufferedFrames() async throws {
        let source = StartYieldingAudioSource(frame: makeFrame(sequence: 1))
        let provider = BlockingPrepareProvider()
        let coordinator = VoiceSessionCoordinator(
            source: source,
            provider: provider,
            configuration: VoiceSessionConfiguration(preRollFrameLimit: 3, tailFrameLimit: 0)
        )
        let events = coordinator.events()

        async let collectedEvents = Self.collectEvents(from: events)
        let startTask = Task {
            try await coordinator.start(config: .init(apiKey: "key", endpoint: "mock", model: "mock"))
        }

        try await provider.waitUntilPrepareStarted()
        await coordinator.cancel()
        await provider.releasePrepare()
        try await startTask.value

        let sent = await provider.sentSequences()
        let eventsResult = try await collectedEvents
        let failures = eventsResult.compactMap { event -> String? in
            guard case .failed(let message, _) = event else { return nil }
            return message
        }
        let cancellations = eventsResult.compactMap { event -> VoiceSessionMetrics? in
            guard case .cancelled(let metrics) = event else { return nil }
            return metrics
        }

        XCTAssertEqual(sent, [])
        XCTAssertEqual(failures, [])
        XCTAssertEqual(cancellations.count, 1)
    }

    func testStopWaitsForInFlightFlushBeforeFinish() async throws {
        let source = StartYieldingAudioSource(frames: [
            makeFrame(sequence: 1),
            makeFrame(sequence: 2)
        ])
        let provider = BlockingSendProvider()
        let coordinator = VoiceSessionCoordinator(
            source: source,
            provider: provider,
            configuration: VoiceSessionConfiguration(preRollFrameLimit: 0, tailFrameLimit: 0)
        )

        let startTask = Task {
            try await coordinator.start(config: .init(apiKey: "key", endpoint: "mock", model: "mock"))
        }

        try await provider.waitUntilFirstSendStarted()
        let stopCompletion = AsyncFlag()
        let stopTask = Task {
            await coordinator.stop(reason: .userReleased)
            await stopCompletion.mark()
        }
        try await Task.sleep(for: .milliseconds(20))
        let stopCompletedBeforeFlush = await stopCompletion.isMarked()
        XCTAssertFalse(stopCompletedBeforeFlush)

        await provider.releaseFirstSend()
        try await startTask.value
        await stopTask.value

        let events = await provider.events()
        XCTAssertEqual(events, [
            "send:start:1",
            "send:end:1",
            "send:start:2",
            "send:end:2",
            "finish"
        ])
    }

    func testTerminalResultPreventsAdditionalBufferedFrameSends() async throws {
        let source = StartYieldingAudioSource(frames: [
            makeFrame(sequence: 1),
            makeFrame(sequence: 2)
        ])
        let provider = BlockingSendTerminalProvider()
        let coordinator = VoiceSessionCoordinator(
            source: source,
            provider: provider,
            configuration: VoiceSessionConfiguration(preRollFrameLimit: 0, tailFrameLimit: 0)
        )
        let events = coordinator.events()

        async let collectedEvents = Self.collectEvents(from: events)
        let startTask = Task {
            try await coordinator.start(config: .init(apiKey: "key", endpoint: "mock", model: "mock"))
        }

        try await provider.waitUntilFirstSendStarted()
        await provider.emitFinal("done")
        await provider.releaseFirstSend()
        try await startTask.value

        let eventsResult = try await collectedEvents
        let finalTexts = eventsResult.compactMap { event -> String? in
            guard case .final(let text, _) = event else { return nil }
            return text
        }
        let providerEvents = await provider.events()

        XCTAssertEqual(finalTexts, ["done"])
        XCTAssertTrue(providerEvents.contains("cancel"))
        XCTAssertFalse(providerEvents.contains("send:start:2"))
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

    func testProviderFailureStopsCapture() async throws {
        let source = IdleAudioSource()
        let provider = FailureEmittingProvider()
        let coordinator = VoiceSessionCoordinator(
            source: source,
            provider: provider,
            configuration: VoiceSessionConfiguration(preRollFrameLimit: 0, tailFrameLimit: 0)
        )
        let events = coordinator.events()

        async let collectedEvents = Self.collectEvents(from: events)
        try await coordinator.start(config: .init(apiKey: "key", endpoint: "mock", model: "mock"))
        try await provider.waitUntilResultsSubscribed()
        let isRunningBeforeFailure = await source.isRunning()
        XCTAssertTrue(isRunningBeforeFailure)

        await provider.emitFailure("provider failed")

        let eventsResult = try await collectedEvents
        let failures = eventsResult.compactMap { event -> String? in
            guard case .failed(let message, _) = event else { return nil }
            return message
        }

        XCTAssertEqual(failures, ["provider failed"])
        let isRunningAfterFailure = await source.isRunning()
        let stopCount = await source.stopCallCount()
        let providerCancelled = await provider.wasCancelled()
        XCTAssertFalse(isRunningAfterFailure)
        XCTAssertEqual(stopCount, 1)
        XCTAssertTrue(providerCancelled)
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

    func testFinishFailureCancelsProviderResultStream() async throws {
        let source = FakeAudioSource(frames: [
            makeFrame(sequence: 1)
        ])
        let provider = FinishFailingProvider()
        let coordinator = VoiceSessionCoordinator(
            source: source,
            provider: provider,
            configuration: VoiceSessionConfiguration(preRollFrameLimit: 0, tailFrameLimit: 0)
        )
        let events = coordinator.events()

        async let collectedEvents = Self.collectEvents(from: events)
        try await coordinator.start(config: .init(apiKey: "key", endpoint: "mock", model: "mock"))
        try await Self.waitForSentSequences([1], provider: provider)
        await coordinator.stop(reason: .userReleased)

        let eventsResult = try await collectedEvents
        let failures = eventsResult.compactMap { event -> String? in
            guard case .failed(let message, _) = event else { return nil }
            return message
        }
        let providerCancelled = await provider.wasCancelled()

        XCTAssertEqual(failures, ["finish failed"])
        XCTAssertTrue(providerCancelled)
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

    private static func waitForSentSequences(
        _ expectedSequences: [Int64],
        provider: FinishFailingProvider,
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

private actor AsyncFlag {
    private var marked = false

    func mark() {
        marked = true
    }

    func isMarked() -> Bool {
        marked
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
    private let framesToYield: [VoiceAudioFrame]
    private var continuation: AsyncStream<VoiceAudioFrame>.Continuation?
    private var started = false

    init(frame: VoiceAudioFrame) {
        self.framesToYield = [frame]
    }

    init(frames: [VoiceAudioFrame]) {
        self.framesToYield = frames
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
        for frame in framesToYield {
            continuation?.yield(frame)
        }
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

private actor BlockingStartAudioSource: AudioSource {
    private let throwsOnStart: Bool
    private let suspendFirstStop: Bool
    private let finishOnStopStartingAt: Int
    private var continuation: AsyncStream<VoiceAudioFrame>.Continuation?
    private var startRequested = false
    private var stopped = false
    private var running = false
    private var stopCount = 0
    private var startRequestedContinuation: CheckedContinuation<Void, Never>?
    private var releaseStartContinuation: CheckedContinuation<Void, Never>?
    private var stopRequestedContinuation: CheckedContinuation<Void, Never>?
    private var releaseStopContinuation: CheckedContinuation<Void, Never>?
    private var stopCountWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    init(
        throwsOnStart: Bool = false,
        suspendFirstStop: Bool = false,
        finishOnStopStartingAt: Int = 1
    ) {
        self.throwsOnStart = throwsOnStart
        self.suspendFirstStop = suspendFirstStop
        self.finishOnStopStartingAt = finishOnStopStartingAt
    }

    nonisolated func frames() -> AsyncStream<VoiceAudioFrame> {
        AsyncStream { continuation in
            Task { await self.setContinuation(continuation) }
        }
    }

    func start() async throws {
        startRequested = true
        startRequestedContinuation?.resume()
        startRequestedContinuation = nil

        await withCheckedContinuation { continuation in
            releaseStartContinuation = continuation
        }
        if throwsOnStart {
            throw VoiceSessionCoordinatorTests.SourceStartFailure.failed
        }
        running = true
    }

    func stop() async {
        stopped = true
        running = false
        stopCount += 1
        resumeStopCountWaiters()
        let shouldSuspend = suspendFirstStop && stopCount == 1
        if stopCount >= finishOnStopStartingAt {
            continuation?.finish()
            continuation = nil
        }
        if shouldSuspend {
            stopRequestedContinuation?.resume()
            stopRequestedContinuation = nil
            await withCheckedContinuation { continuation in
                releaseStopContinuation = continuation
            }
        }
    }

    func waitUntilStartRequested() async throws {
        if startRequested { return }
        await withCheckedContinuation { continuation in
            startRequestedContinuation = continuation
        }
    }

    func releaseStart() {
        releaseStartContinuation?.resume()
        releaseStartContinuation = nil
    }

    func waitUntilStopRequested() async throws {
        if stopCount > 0 { return }
        await withCheckedContinuation { continuation in
            stopRequestedContinuation = continuation
        }
    }

    func releaseStop() {
        releaseStopContinuation?.resume()
        releaseStopContinuation = nil
    }

    func waitUntilStopCallCount(_ expectedCount: Int) async throws {
        if stopCount >= expectedCount { return }
        await withCheckedContinuation { continuation in
            stopCountWaiters.append((expectedCount, continuation))
        }
    }

    func wasStopped() -> Bool {
        stopped
    }

    func isRunning() -> Bool {
        running
    }

    func stopCallCount() -> Int {
        stopCount
    }

    private func setContinuation(_ continuation: AsyncStream<VoiceAudioFrame>.Continuation) {
        self.continuation = continuation
    }

    private func resumeStopCountWaiters() {
        var remaining: [(Int, CheckedContinuation<Void, Never>)] = []
        for waiter in stopCountWaiters {
            if stopCount >= waiter.0 {
                waiter.1.resume()
            } else {
                remaining.append(waiter)
            }
        }
        stopCountWaiters = remaining
    }
}

private actor IdleAudioSource: AudioSource {
    private var continuation: AsyncStream<VoiceAudioFrame>.Continuation?
    private var running = false
    private var stopCount = 0

    nonisolated func frames() -> AsyncStream<VoiceAudioFrame> {
        AsyncStream { continuation in
            Task { await self.setContinuation(continuation) }
        }
    }

    func start() async throws {
        running = true
    }

    func stop() async {
        running = false
        stopCount += 1
        continuation?.finish()
        continuation = nil
    }

    func isRunning() -> Bool {
        running
    }

    func stopCallCount() -> Int {
        stopCount
    }

    private func setContinuation(_ continuation: AsyncStream<VoiceAudioFrame>.Continuation) {
        self.continuation = continuation
    }
}

private actor BlockingSendProvider: TranscriptionProvider {
    nonisolated let mode: TranscriptionMode = .streaming
    private var recordedEvents: [String] = []
    private var firstSendStarted = false
    private var firstSendStartedContinuation: CheckedContinuation<Void, Never>?
    private var releaseFirstSendContinuation: CheckedContinuation<Void, Never>?

    func prepare(config: TranscriptionProviderConfig) async throws {}

    func send(_ frame: VoiceAudioFrame) async throws {
        recordedEvents.append("send:start:\(frame.sequence)")
        if frame.sequence == 1 {
            firstSendStarted = true
            firstSendStartedContinuation?.resume()
            firstSendStartedContinuation = nil
            await withCheckedContinuation { continuation in
                releaseFirstSendContinuation = continuation
            }
        }
        recordedEvents.append("send:end:\(frame.sequence)")
    }

    func finish() async throws {
        recordedEvents.append("finish")
    }

    nonisolated func results() -> AsyncStream<TranscriptionProviderResult> {
        AsyncStream { _ in }
    }

    func cancel() async {}

    func waitUntilFirstSendStarted() async throws {
        if firstSendStarted { return }
        await withCheckedContinuation { continuation in
            firstSendStartedContinuation = continuation
        }
    }

    func releaseFirstSend() {
        releaseFirstSendContinuation?.resume()
        releaseFirstSendContinuation = nil
    }

    func events() -> [String] {
        recordedEvents
    }
}

private actor BlockingSendTerminalProvider: TranscriptionProvider {
    nonisolated let mode: TranscriptionMode = .streaming
    private var continuation: AsyncStream<TranscriptionProviderResult>.Continuation?
    private var recordedEvents: [String] = []
    private var firstSendStarted = false
    private var firstSendStartedContinuation: CheckedContinuation<Void, Never>?
    private var releaseFirstSendContinuation: CheckedContinuation<Void, Never>?

    func prepare(config: TranscriptionProviderConfig) async throws {}

    func send(_ frame: VoiceAudioFrame) async throws {
        recordedEvents.append("send:start:\(frame.sequence)")
        if frame.sequence == 1 {
            firstSendStarted = true
            firstSendStartedContinuation?.resume()
            firstSendStartedContinuation = nil
            await withCheckedContinuation { continuation in
                releaseFirstSendContinuation = continuation
            }
        }
        recordedEvents.append("send:end:\(frame.sequence)")
    }

    func finish() async throws {
        recordedEvents.append("finish")
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

    func waitUntilFirstSendStarted() async throws {
        if firstSendStarted { return }
        await withCheckedContinuation { continuation in
            firstSendStartedContinuation = continuation
        }
    }

    func emitFinal(_ text: String) {
        recordedEvents.append("final:\(text)")
        continuation?.yield(.final(text))
    }

    func releaseFirstSend() {
        releaseFirstSendContinuation?.resume()
        releaseFirstSendContinuation = nil
    }

    func events() -> [String] {
        recordedEvents
    }

    private func setContinuation(_ continuation: AsyncStream<TranscriptionProviderResult>.Continuation) {
        self.continuation = continuation
    }
}

private actor StartAfterStopProvider: TranscriptionProvider {
    nonisolated let mode: TranscriptionMode = .streaming
    private var prepareCalled = false
    private var continuation: AsyncStream<TranscriptionProviderResult>.Continuation?

    func prepare(config: TranscriptionProviderConfig) async throws {
        prepareCalled = true
    }

    func send(_ frame: VoiceAudioFrame) async throws {}

    func finish() async throws {
        continuation?.yield(.final("unexpected"))
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

    func prepareWasCalled() -> Bool {
        prepareCalled
    }

    private func setContinuation(_ continuation: AsyncStream<TranscriptionProviderResult>.Continuation) {
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

private actor FailureEmittingProvider: TranscriptionProvider {
    nonisolated let mode: TranscriptionMode = .streaming
    private var continuation: AsyncStream<TranscriptionProviderResult>.Continuation?
    private var resultsSubscribed = false
    private var resultsSubscribedContinuation: CheckedContinuation<Void, Never>?
    private var prepareCalled = false
    private var cancelled = false
    private var cancelledContinuation: CheckedContinuation<Void, Never>?

    func prepare(config: TranscriptionProviderConfig) async throws {
        prepareCalled = true
    }

    func send(_ frame: VoiceAudioFrame) async throws {}

    func finish() async throws {}

    nonisolated func results() -> AsyncStream<TranscriptionProviderResult> {
        AsyncStream { continuation in
            Task { await self.setContinuation(continuation) }
        }
    }

    func cancel() async {
        cancelled = true
        cancelledContinuation?.resume()
        cancelledContinuation = nil
        continuation?.finish()
        continuation = nil
    }

    func emitFailure(_ message: String) {
        continuation?.yield(.failure(message))
        continuation?.finish()
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

    func prepareWasCalled() -> Bool {
        prepareCalled
    }

    func wasCancelled() -> Bool {
        cancelled
    }

    func waitUntilCancelled() async throws {
        if cancelled { return }
        await withCheckedContinuation { continuation in
            cancelledContinuation = continuation
        }
    }
}

private actor EarlyEndingProvider: TranscriptionProvider {
    nonisolated let mode: TranscriptionMode = .streaming
    private var continuation: AsyncStream<TranscriptionProviderResult>.Continuation?
    private var resultsSubscribed = false
    private var resultsSubscribedContinuation: CheckedContinuation<Void, Never>?
    private var prepareCalled = false
    private var cancelled = false
    private var cancelledContinuation: CheckedContinuation<Void, Never>?

    func prepare(config: TranscriptionProviderConfig) async throws {
        prepareCalled = true
    }

    func send(_ frame: VoiceAudioFrame) async throws {}

    func finish() async throws {}

    nonisolated func results() -> AsyncStream<TranscriptionProviderResult> {
        AsyncStream { continuation in
            Task { await self.setContinuation(continuation) }
        }
    }

    func cancel() async {
        cancelled = true
        cancelledContinuation?.resume()
        cancelledContinuation = nil
        continuation?.finish()
        continuation = nil
    }

    func endResults() {
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

    func prepareWasCalled() -> Bool {
        prepareCalled
    }

    func waitUntilCancelled() async throws {
        if cancelled { return }
        await withCheckedContinuation { continuation in
            cancelledContinuation = continuation
        }
    }
}

private actor FinishFailingProvider: TranscriptionProvider {
    nonisolated let mode: TranscriptionMode = .streaming
    private var sent: [Int64] = []
    private var cancelled = false
    private var continuation: AsyncStream<TranscriptionProviderResult>.Continuation?

    func prepare(config: TranscriptionProviderConfig) async throws {}

    func send(_ frame: VoiceAudioFrame) async throws {
        sent.append(frame.sequence)
    }

    func finish() async throws {
        throw VoiceSessionCoordinatorTests.FinishFailure.failed
    }

    nonisolated func results() -> AsyncStream<TranscriptionProviderResult> {
        AsyncStream { continuation in
            Task { await self.setContinuation(continuation) }
        }
    }

    func cancel() async {
        cancelled = true
        continuation?.finish()
        continuation = nil
    }

    func sentSequences() -> [Int64] {
        sent
    }

    func wasCancelled() -> Bool {
        cancelled
    }

    private func setContinuation(_ continuation: AsyncStream<TranscriptionProviderResult>.Continuation) {
        self.continuation = continuation
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
