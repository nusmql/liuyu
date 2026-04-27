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

        resultTask = Task { [provider] in
            for await result in provider.results() {
                await self.handleProviderResult(result)
            }
        }

        do {
            try await provider.prepare(config: config)
        } catch {
            resultTask?.cancel()
            resultTask = nil
            throw error
        }
        metrics.providerReadyAtNanos = nowNanos()

        let preRoll = buffer.beginUtterance()
        metrics.preRollFrameCount = preRoll.count
        for frame in preRoll {
            try await send(frame)
        }

        frameTask = Task { [source] in
            for await frame in source.frames() {
                if Task.isCancelled { break }
                await self.acceptLiveFrame(frame)
            }
        }

        try await source.start()
        yieldEvent(.started(metrics))
    }

    private func acceptLiveFrame(_ frame: VoiceAudioFrame) async {
        if metrics.firstFrameCapturedAtNanos == nil {
            metrics.firstFrameCapturedAtNanos = nowNanos()
        }

        guard buffer.accept(frame) else { return }
        metrics.lastFrameAcceptedAtNanos = frame.timestampNanos

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
        buffer.requestEnd()
        await source.stop()

        if let frameTask {
            await frameTask.value
        }
        frameTask = nil
        if !buffer.closed {
            buffer.forceClose()
        }

        do {
            metrics.finishSentAtNanos = nowNanos()
            try await provider.finish()
        } catch {
            yieldEvent(.failed(error.localizedDescription, metrics), finish: true)
        }
    }

    public func cancel() async {
        await source.stop()
        await provider.cancel()
        frameTask?.cancel()
        resultTask?.cancel()
        frameTask = nil
        resultTask = nil
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
            metrics.finalReceivedAtNanos = nowNanos()
            yieldEvent(.final(text, metrics), finish: true)
        case .failure(let message):
            yieldEvent(.failed(message, metrics), finish: true)
        }
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
