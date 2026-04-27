import Foundation

public actor VoiceSessionCoordinator {
    private let source: any AudioSource
    private let provider: any TranscriptionProvider
    private let configuration: VoiceSessionConfiguration
    private var buffer: UtteranceBuffer
    private var frameTask: Task<Void, Never>?
    private var resultTask: Task<Void, Never>?
    private var eventsContinuation: AsyncStream<VoiceSessionEvent>.Continuation?
    private var pendingEvents: [VoiceSessionEvent] = []
    private var pendingEventsFinish = false
    private var metrics = VoiceSessionMetrics()
    private var providerReady = false
    private var stopRequested = false
    private var cancelRequested = false
    private var providerFinished = false
    private var terminalProviderResultReceived = false
    private var lifecycleState: LifecycleState = .idle
    private var nextBufferedFrameIndexToSend = 0
    private var isFlushingBufferedFrames = false
    private var flushWaiters: [CheckedContinuation<Void, Never>] = []
    private var lastFlushError: Error?

    private enum LifecycleState {
        case idle
        case startingSource
        case preparingProvider
        case recording
        case stopping
        case cancelled
        case finished
    }

    public init(
        source: any AudioSource,
        provider: any TranscriptionProvider,
        configuration: VoiceSessionConfiguration = VoiceSessionConfiguration()
    ) {
        self.source = source
        self.provider = provider
        self.configuration = configuration
        self.buffer = UtteranceBuffer(
            preRollFrameLimit: configuration.preRollFrameLimit,
            tailFrameLimit: configuration.tailFrameLimit
        )
    }

    public nonisolated func events() -> AsyncStream<VoiceSessionEvent> {
        AsyncStream { continuation in
            Task { await self.setEventsContinuation(continuation) }
        }
    }

    private func setEventsContinuation(_ continuation: AsyncStream<VoiceSessionEvent>.Continuation) {
        self.eventsContinuation = continuation
        flushPendingEvents()
    }

    public func start(config: TranscriptionProviderConfig) async throws {
        metrics = VoiceSessionMetrics()
        buffer = UtteranceBuffer(
            preRollFrameLimit: configuration.preRollFrameLimit,
            tailFrameLimit: configuration.tailFrameLimit
        )
        metrics.captureRequestedAtNanos = nowNanos()
        providerReady = false
        stopRequested = false
        cancelRequested = false
        providerFinished = false
        terminalProviderResultReceived = false
        lifecycleState = .startingSource
        nextBufferedFrameIndexToSend = 0
        isFlushingBufferedFrames = false
        flushWaiters.removeAll()
        lastFlushError = nil

        let initialPreRoll = buffer.beginUtterance()
        metrics.preRollFrameCount = initialPreRoll.count

        resultTask = Task { [provider] in
            for await result in provider.results() {
                await self.handleProviderResult(result)
            }
            guard !Task.isCancelled else { return }
            await self.handleProviderResultStreamEnded()
        }

        let frameStream = source.frames()
        frameTask = Task {
            for await frame in frameStream {
                if Task.isCancelled { break }
                await self.acceptLiveFrame(frame)
            }
        }

        do {
            try await source.start()
        } catch {
            var terminalBeforeStartFailure = terminalProviderResultReceived
            await source.stop()
            terminalBeforeStartFailure = terminalBeforeStartFailure || terminalProviderResultReceived
            await cleanupAfterStartFailure()
            terminalBeforeStartFailure = terminalBeforeStartFailure || terminalProviderResultReceived
            if terminalBeforeStartFailure {
                return
            }
            if cancelRequested {
                return
            }
            if stopRequested {
                await failBeforeProviderReady("Recording stopped before audio capture was ready.")
                return
            }
            lifecycleState = .finished
            throw error
        }

        if lifecycleState == .finished {
            await source.stop()
            return
        }

        if cancelRequested || lifecycleState == .cancelled {
            await stopSourceAndDrainFrames()
            return
        }

        if stopRequested {
            await failBeforeProviderReady("Recording stopped before audio capture was ready.")
            return
        }

        lifecycleState = .preparingProvider
        yieldEvent(.started(metrics))

        do {
            metrics.providerPrepareStartedAtNanos = nowNanos()
            try await provider.prepare(config: config)
        } catch {
            await stopSourceAndDrainFrames()
            resultTask?.cancel()
            resultTask = nil
            lifecycleState = .finished
            if cancelRequested || stopRequested {
                return
            }
            throw error
        }

        if lifecycleState == .finished {
            return
        }

        if cancelRequested || lifecycleState == .cancelled {
            return
        }

        metrics.providerReadyAtNanos = nowNanos()
        providerReady = true
        lifecycleState = stopRequested ? .stopping : .recording

        do {
            try await flushBufferedFrames()
        } catch {
            await failProvider(error)
            return
        }

        if stopRequested {
            buffer.requestEnd()
            if !buffer.closed {
                buffer.forceClose()
            }
            do {
                try await flushBufferedFrames()
            } catch {
                await failProvider(error)
                return
            }
            await finishProvider()
        }
    }

    private func acceptLiveFrame(_ frame: VoiceAudioFrame) async {
        guard lifecycleState != .finished, lifecycleState != .cancelled else { return }

        if metrics.firstFrameCapturedAtNanos == nil {
            metrics.firstFrameCapturedAtNanos = nowNanos()
        }

        guard buffer.accept(frame) else { return }
        metrics.lastFrameAcceptedAtNanos = frame.timestampNanos
        yieldEvent(.audioLevel(frame.audioLevel, metrics))

        do {
            if providerReady {
                try await flushBufferedFrames()
            }
        } catch {
            await failProvider(error, drainFrameTask: false)
        }
    }

    private func flushBufferedFrames() async throws {
        guard lifecycleState != .finished, lifecycleState != .cancelled else { return }
        guard providerReady else { return }

        if isFlushingBufferedFrames {
            await waitForCurrentFlush()
            if let lastFlushError {
                throw lastFlushError
            }
            return
        }

        isFlushingBufferedFrames = true
        lastFlushError = nil

        do {
            while nextBufferedFrameIndexToSend < buffer.snapshot().count {
                if cancelRequested || lifecycleState == .cancelled || lifecycleState == .finished {
                    finishCurrentFlush(error: nil)
                    return
                }

                let frames = buffer.snapshot()
                let frame = frames[nextBufferedFrameIndexToSend]
                nextBufferedFrameIndexToSend += 1
                try await send(frame)

                if lifecycleState == .finished {
                    finishCurrentFlush(error: nil)
                    return
                }
            }
            finishCurrentFlush(error: nil)
        } catch {
            finishCurrentFlush(error: error)
            throw error
        }
    }

    private func waitForCurrentFlush() async {
        await withCheckedContinuation { continuation in
            flushWaiters.append(continuation)
        }
    }

    private func finishCurrentFlush(error: Error?) {
        lastFlushError = error
        isFlushingBufferedFrames = false
        let waiters = flushWaiters
        flushWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    private func send(_ frame: VoiceAudioFrame) async throws {
        if metrics.firstFrameSentAtNanos == nil {
            metrics.firstFrameSentAtNanos = nowNanos()
        }

        try await provider.send(frame)
        metrics.lastFrameSentAtNanos = nowNanos()
        metrics.sentFrameCount += 1
        metrics.sentByteCount += frame.pcm16MonoData.count
    }

    public func stop(reason: VoiceSessionStopReason) async {
        metrics.logicalStopAtNanos = nowNanos()
        guard lifecycleState != .cancelled, lifecycleState != .finished else { return }
        stopRequested = true
        lifecycleState = .stopping
        await stopSourceAndDrainFrames()

        guard providerReady else { return }

        buffer.requestEnd()
        if !buffer.closed {
            buffer.forceClose()
        }

        do {
            try await flushBufferedFrames()
        } catch {
            await failProvider(error)
            return
        }

        await finishProvider()
    }

    private func stopSourceAndDrainFrames() async {
        await source.stop()

        if let frameTask {
            await frameTask.value
        }
        frameTask = nil
    }

    private func finishProvider() async {
        guard !providerFinished else { return }
        guard lifecycleState != .cancelled else { return }
        providerFinished = true

        do {
            metrics.finishSentAtNanos = nowNanos()
            try await provider.finish()
        } catch {
            await failProvider(error)
        }
    }

    public func cancel() async {
        guard lifecycleState != .cancelled, lifecycleState != .finished else { return }
        cancelRequested = true
        stopRequested = true
        lifecycleState = .cancelled
        terminalProviderResultReceived = true
        resultTask?.cancel()
        resultTask = nil
        frameTask?.cancel()
        await source.stop()
        if let frameTask {
            await frameTask.value
        }
        await provider.cancel()
        frameTask = nil
        providerReady = false
        yieldEvent(.cancelled(metrics), finish: true)
    }

    private func stopSourceWithoutDrainingFrames() async {
        frameTask?.cancel()
        await source.stop()
        frameTask = nil
    }

    private func cleanupAfterStartFailure() async {
        frameTask?.cancel()
        if let frameTask {
            await frameTask.value
        }
        resultTask?.cancel()
        frameTask = nil
        resultTask = nil
    }

    private func failBeforeProviderReady(_ message: String) async {
        guard lifecycleState != .finished, lifecycleState != .cancelled else { return }
        terminalProviderResultReceived = true
        lifecycleState = .finished
        resultTask?.cancel()
        resultTask = nil
        await stopSourceAndDrainFrames()
        await provider.cancel()
        yieldEvent(.failed(message, metrics), finish: true)
    }

    private func failProvider(_ error: Error, drainFrameTask: Bool = true) async {
        guard lifecycleState != .finished, lifecycleState != .cancelled else { return }
        terminalProviderResultReceived = true
        lifecycleState = .finished
        resultTask?.cancel()
        resultTask = nil
        if drainFrameTask {
            await stopSourceAndDrainFrames()
        } else {
            frameTask?.cancel()
            await source.stop()
            frameTask = nil
        }
        await provider.cancel()
        yieldEvent(.failed(error.localizedDescription, metrics), finish: true)
    }

    private func handleProviderResult(_ result: TranscriptionProviderResult) async {
        guard lifecycleState != .cancelled else { return }

        switch result {
        case .partial(let text):
            guard lifecycleState != .finished else { return }
            if metrics.firstPartialReceivedAtNanos == nil {
                metrics.firstPartialReceivedAtNanos = nowNanos()
            }
            yieldEvent(.partial(text, metrics))
        case .final(let text):
            guard lifecycleState != .finished else { return }
            terminalProviderResultReceived = true
            metrics.finalReceivedAtNanos = nowNanos()
            lifecycleState = .finished
            await stopSourceWithoutDrainingFrames()
            await provider.cancel()
            yieldEvent(.final(text, metrics), finish: true)
        case .failure(let message):
            guard lifecycleState != .finished else { return }
            terminalProviderResultReceived = true
            lifecycleState = .finished
            await stopSourceWithoutDrainingFrames()
            await provider.cancel()
            yieldEvent(.failed(message, metrics), finish: true)
        }
    }

    private func handleProviderResultStreamEnded() async {
        guard !terminalProviderResultReceived else { return }
        terminalProviderResultReceived = true
        lifecycleState = .finished
        await stopSourceWithoutDrainingFrames()
        await provider.cancel()
        yieldEvent(.failed("Transcription provider ended without a final result.", metrics), finish: true)
    }

    private func yieldEvent(_ event: VoiceSessionEvent, finish: Bool = false) {
        guard let eventsContinuation else {
            pendingEvents.append(event)
            pendingEventsFinish = pendingEventsFinish || finish
            return
        }

        eventsContinuation.yield(event)
        if finish {
            eventsContinuation.finish()
            self.eventsContinuation = nil
        }
    }

    private func flushPendingEvents() {
        guard let eventsContinuation else { return }

        for event in pendingEvents {
            eventsContinuation.yield(event)
        }
        pendingEvents.removeAll()

        if pendingEventsFinish {
            eventsContinuation.finish()
            pendingEventsFinish = false
            self.eventsContinuation = nil
        }
    }

    private func nowNanos() -> Int64 {
        Int64(DispatchTime.now().uptimeNanoseconds)
    }
}
