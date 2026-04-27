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
    private var providerFinished = false
    private var terminalProviderResultReceived = false

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
        metrics.captureRequestedAtNanos = nowNanos()
        metrics.providerPrepareStartedAtNanos = nowNanos()
        providerReady = false
        stopRequested = false
        providerFinished = false
        terminalProviderResultReceived = false

        resultTask = Task { [provider] in
            for await result in provider.results() {
                await self.handleProviderResult(result)
            }
            guard !Task.isCancelled else { return }
            self.handleProviderResultStreamEnded()
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
            frameTask?.cancel()
            if let frameTask {
                await frameTask.value
            }
            resultTask?.cancel()
            frameTask = nil
            resultTask = nil
            throw error
        }
        yieldEvent(.started(metrics))

        do {
            try await provider.prepare(config: config)
        } catch {
            await stopSourceAndDrainFrames()
            resultTask?.cancel()
            resultTask = nil
            throw error
        }
        metrics.providerReadyAtNanos = nowNanos()
        providerReady = true

        let preRoll = buffer.beginUtterance()
        metrics.preRollFrameCount = preRoll.count
        for frame in preRoll {
            try await send(frame)
        }

        if stopRequested {
            buffer.requestEnd()
            if !buffer.closed {
                buffer.forceClose()
            }
            await finishProvider()
        }
    }

    private func acceptLiveFrame(_ frame: VoiceAudioFrame) async {
        if metrics.firstFrameCapturedAtNanos == nil {
            metrics.firstFrameCapturedAtNanos = nowNanos()
        }

        guard buffer.accept(frame) else { return }
        metrics.lastFrameAcceptedAtNanos = frame.timestampNanos
        yieldEvent(.audioLevel(frame.audioLevel, metrics))

        guard providerReady else { return }

        do {
            try await send(frame)
        } catch {
            yieldEvent(.failed(error.localizedDescription, metrics), finish: true)
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
        stopRequested = true
        await stopSourceAndDrainFrames()

        guard providerReady else { return }

        buffer.requestEnd()
        if !buffer.closed {
            buffer.forceClose()
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
        providerFinished = true

        do {
            metrics.finishSentAtNanos = nowNanos()
            try await provider.finish()
        } catch {
            terminalProviderResultReceived = true
            yieldEvent(.failed(error.localizedDescription, metrics), finish: true)
        }
    }

    public func cancel() async {
        terminalProviderResultReceived = true
        resultTask?.cancel()
        resultTask = nil
        frameTask?.cancel()
        await source.stop()
        await provider.cancel()
        frameTask = nil
        providerReady = false
        yieldEvent(.cancelled(metrics), finish: true)
    }

    private func handleProviderResult(_ result: TranscriptionProviderResult) async {
        switch result {
        case .partial(let text):
            if metrics.firstPartialReceivedAtNanos == nil {
                metrics.firstPartialReceivedAtNanos = nowNanos()
            }
            yieldEvent(.partial(text, metrics))
        case .final(let text):
            terminalProviderResultReceived = true
            metrics.finalReceivedAtNanos = nowNanos()
            yieldEvent(.final(text, metrics), finish: true)
        case .failure(let message):
            terminalProviderResultReceived = true
            yieldEvent(.failed(message, metrics), finish: true)
        }
    }

    private func handleProviderResultStreamEnded() {
        guard !terminalProviderResultReceived else { return }
        terminalProviderResultReceived = true
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
        Int64(Date().timeIntervalSince1970 * 1_000_000_000)
    }
}
