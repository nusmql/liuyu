// Sources/LiuyuLib/Edit/EditViewModel.swift
import AppKit
import Combine

public enum EditState: Equatable {
    case idle
    case recording(audioLevel: Float)
    case transcribing
    case editing  // LLM processing
}

enum StreamingPartialTextUpdate: Equatable {
    case keepExistingText
    case replaceText(String)
}

enum StreamingStopDecision: Equatable {
    case localNoSpeech
    case sendFinalToProvider
}

struct StreamingRESTFallbackParams {
    let apiKey: String
    let endpoint: String
    let model: String
    let apiFormat: ApiFormat
    let language: String?
}

private struct StreamingSessionKey: Equatable {
    let apiKey: String
    let endpoint: String
    let model: String
    let apiFormat: ApiFormat
    let language: String?
}

func editStateAfterRecordingStops(hasExistingText: Bool) -> EditState {
    .transcribing
}

func editStateAfterTranscriptionCompletes(hasExistingText: Bool) -> EditState {
    hasExistingText ? .editing : .idle
}

func streamingPartialTextUpdate(
    hadExistingTextAtRecordingStart: Bool,
    partialText: String
) -> StreamingPartialTextUpdate {
    hadExistingTextAtRecordingStart ? .keepExistingText : .replaceText(partialText)
}

func isLocalNoSpeech(peakAudioLevel: Float, threshold: Float) -> Bool {
    peakAudioLevel < threshold
}

func streamingStopDecision(peakAudioLevel: Float, threshold: Float) -> StreamingStopDecision {
    isLocalNoSpeech(peakAudioLevel: peakAudioLevel, threshold: threshold)
        ? .localNoSpeech
        : .sendFinalToProvider
}

func streamingRESTFallbackParams(
    apiKey: String,
    apiFormat: ApiFormat,
    language: String?
) -> StreamingRESTFallbackParams? {
    switch apiFormat {
    case .glmRealtime:
        return StreamingRESTFallbackParams(
            apiKey: apiKey,
            endpoint: "https://open.bigmodel.cn/api/paas/v4/audio/transcriptions",
            model: "glm-asr-2512",
            apiFormat: .whisperMultipart,
            language: language
        )
    case .whisperMultipart,
         .glmMultipartEventStream,
         .chatCompletionsAudio,
         .alibabaRealtime,
         .tencentRealtime,
         .iflytekIAT:
        return nil
    }
}

func isWebSocketStreamingFormat(_ apiFormat: ApiFormat) -> Bool {
    switch apiFormat {
    case .glmRealtime, .alibabaRealtime, .tencentRealtime, .iflytekIAT:
        return true
    case .whisperMultipart, .glmMultipartEventStream, .chatCompletionsAudio:
        return false
    }
}

func shouldConnectBeforeAudioCapture(_ apiFormat: ApiFormat) -> Bool {
    isWebSocketStreamingFormat(apiFormat)
}

func shouldQueueStreamingStartupStop(editState: EditState, hasStreamingStartup: Bool) -> Bool {
    editState == .idle && hasStreamingStartup
}

func pcm16DataFromWAV(_ wavData: Data) -> Data? {
    guard wavData.count >= 12,
          String(decoding: wavData[0..<4], as: UTF8.self) == "RIFF",
          String(decoding: wavData[8..<12], as: UTF8.self) == "WAVE" else {
        return nil
    }

    var offset = 12
    while offset + 8 <= wavData.count {
        let chunkID = String(decoding: wavData[offset..<offset + 4], as: UTF8.self)
        guard let chunkSize = littleEndianUInt32(in: wavData, at: offset + 4) else {
            return nil
        }

        let dataStart = offset + 8
        let dataEnd = dataStart + Int(chunkSize)
        guard dataEnd <= wavData.count else { return nil }

        if chunkID == "data" {
            return wavData.subdata(in: dataStart..<dataEnd)
        }

        offset = dataEnd + (Int(chunkSize) % 2)
    }

    return nil
}

func normalizedPCM16RMSAudioLevel(_ pcmData: Data) -> Float {
    guard pcmData.count >= 2 else { return 0 }

    var sampleCount = 0
    var squareSum = 0.0
    pcmData.withUnsafeBytes { rawBuffer in
        let bytes = rawBuffer.bindMemory(to: UInt8.self)
        var offset = 0
        while offset + 1 < bytes.count {
            let rawSample = UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
            let sample = Double(Int16(bitPattern: rawSample)) / 32768.0
            squareSum += sample * sample
            sampleCount += 1
            offset += 2
        }
    }

    guard sampleCount > 0 else { return 0 }
    let rms = sqrt(squareSum / Double(sampleCount))
    let db = 20 * log10(max(rms, 1e-6))
    return Float(max(0, min(1, (db + 50) / 50)))
}

func normalizedWAVAudioLevel(at url: URL) -> Float? {
    guard let wavData = try? Data(contentsOf: url),
          let pcmData = pcm16DataFromWAV(wavData) else {
        return nil
    }
    return normalizedPCM16RMSAudioLevel(pcmData)
}

private func littleEndianUInt32(in data: Data, at offset: Int) -> UInt32? {
    guard offset + 4 <= data.count else { return nil }
    return UInt32(data[offset])
        | (UInt32(data[offset + 1]) << 8)
        | (UInt32(data[offset + 2]) << 16)
        | (UInt32(data[offset + 3]) << 24)
}

@MainActor
public class EditViewModel: ObservableObject {
    @Published public var text: String = ""
    @Published public var editState: EditState = .idle
    @Published public var errorMessage: String?

    private let recordingController = RecordingController()
    private let providerStore = ProviderConfigStore()
    private var cancellables = Set<AnyCancellable>()
    private var recordingStartTime: Date?
    private var currentAudioURL: URL?
    private var recordingFailed = false
    private var textAtRecordingStart: String?
    private var recordingPeakAudioLevel: Float = 0

    private let minimumRecordingDuration: TimeInterval = 0.3
    private let localNoSpeechPeakThreshold: Float = 0.06
    private var e2eStartTime: Date?
    private var editTraceToken = UUID()
    private var editTraceStartTime: Date?
    private var editTraceLastTime: Date?

    // Streaming transcription support
    private var streamingSession: StreamingTranscriptionSession?
    private var streamingSessionKey: StreamingSessionKey?
    private var streamingTask: Task<Void, Never>?
    private var streamingPrewarmTask: Task<Void, Never>?
    private var streamingRESTFallbackTask: Task<Void, Never>?
    private var streamingRESTFallbackWinningToken: UUID?
    private var streamingStartupToken: UUID?
    private var pendingStreamingStopToken: UUID?

    // Silence timeout
    private var silenceCheckTimer: Timer?
    private var lastAudioActivity: Date?
    private var silenceTimeout: TimeInterval { TimeInterval(UserDefaults.standard.integer(forKey: "silenceTimeout")) }

    public var hasText: Bool { !text.isEmpty }

    public var micButtonLabel: String {
        // When no text, show global shortcut for new input
        // When has text, show edit window shortcut for modification
        let shortcut = hasText ? RecordedShortcut.loadEditRecordShortcut() : RecordedShortcut.loadFromDefaults()
        if hasText {
            return "Hold to Edit (or \(shortcut.displayString))"
        } else {
            return "Hold to Speak (or \(shortcut.displayString))"
        }
    }

    public var audioLevel: Float {
        if case .recording(let level) = editState { return level }
        return 0
    }

    public init() {
        recordingController.$audioLevel
            .receive(on: RunLoop.main)
            .sink { [weak self] level in
                guard let self, case .recording = self.editState else { return }
                self.recordingPeakAudioLevel = max(self.recordingPeakAudioLevel, level)
                self.editState = .recording(audioLevel: level)
                self.updateAudioActivity(level: level)
            }
            .store(in: &cancellables)

        // Pre-warm the audio engine so the first recording starts instantly
        // and the pre-roll buffer captures audio before the user clicks.
        // Delay gives CoreAudio HAL time to initialize after app/window launch.
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000) // 0.5s
            do {
                try self?.recordingController.warmUp()
            } catch {
                Logger.warning("Pre-warm failed (will retry on first recording): \(error.localizedDescription)", category: .audio)
            }
        }
        scheduleStreamingPrewarm(reason: "startup")
    }

    @discardableResult
    private func beginEditTrace(reason: String) -> UUID {
        let token = UUID()
        editTraceToken = token
        editTraceStartTime = Date()
        editTraceLastTime = editTraceStartTime
        Logger.info("[EDIT trace=\(traceID(token))] begin reason=\(reason) state=\(editState) textChars=\(text.count)", category: .app)
        return token
    }

    private func invalidateEditTrace(reason: String) {
        let oldToken = editTraceToken
        editTraceToken = UUID()
        Logger.info("[EDIT trace=\(traceID(oldToken))] invalidated reason=\(reason)", category: .app)
    }

    private func isCurrentTrace(_ token: UUID) -> Bool {
        token == editTraceToken
    }

    private func guardCurrentTrace(_ token: UUID, stage: String) -> Bool {
        guard isCurrentTrace(token) else {
            Logger.info("[EDIT trace=\(traceID(token))] stale result ignored stage=\(stage)", category: .app)
            return false
        }
        return true
    }

    private func trace(_ stage: String, token: UUID, category: Logger.Category = .app, details: String = "") {
        let now = Date()
        let total = editTraceStartTime.map { now.timeIntervalSince($0) } ?? 0
        let delta = editTraceLastTime.map { now.timeIntervalSince($0) } ?? 0
        editTraceLastTime = now
        let suffix = details.isEmpty ? "" : " \(details)"
        Logger.info(
            "[EDIT trace=\(traceID(token))] \(stage) delta=\(formatSeconds(delta)) total=\(formatSeconds(total))\(suffix)",
            category: category
        )
    }

    private func finishTrace(_ stage: String, token: UUID, category: Logger.Category = .app, details: String = "") {
        trace(stage, token: token, category: category, details: details)
        if isCurrentTrace(token) {
            editTraceStartTime = nil
            editTraceLastTime = nil
        }
    }

    private func traceID(_ token: UUID) -> String {
        String(token.uuidString.prefix(8))
    }

    private func formatSeconds(_ value: TimeInterval) -> String {
        "\(String(format: "%.3f", value))s"
    }

    private func formatOptionalLevel(_ value: Float?) -> String {
        guard let value else { return "none" }
        return String(format: "%.3f", value)
    }

    private func updateAudioActivity(level: Float) {
        let threshold: Float = 0.25
        if level > threshold {
            lastAudioActivity = Date()
        }
    }

    private func startSilenceDetection() {
        silenceCheckTimer?.invalidate()
        lastAudioActivity = Date()
        guard silenceTimeout > 0 else { return }
        silenceCheckTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.checkSilenceTimeout()
            }
        }
    }

    private func checkSilenceTimeout() {
        guard case .recording = editState,
              let lastActivity = lastAudioActivity,
              silenceTimeout > 0 else { return }

        let silenceDuration = Date().timeIntervalSince(lastActivity)
        if silenceDuration >= silenceTimeout {
            Logger.info("Silence timeout after \(String(format: "%.1f", silenceDuration))s", category: .audio)
            stopRecording()
        }
    }

    private func stopSilenceDetection() {
        silenceCheckTimer?.invalidate()
        silenceCheckTimer = nil
    }

    private func makeStreamingSessionKey(
        params: (apiKey: String, endpoint: String, model: String, apiFormat: ApiFormat)
    ) -> StreamingSessionKey {
        let language = UserDefaults.standard.string(forKey: "language") ?? "auto"
        return StreamingSessionKey(
            apiKey: params.apiKey,
            endpoint: params.endpoint,
            model: params.model,
            apiFormat: params.apiFormat,
            language: language == "auto" ? nil : language
        )
    }

    private func makeStreamingSession(
        params: (apiKey: String, endpoint: String, model: String, apiFormat: ApiFormat),
        key: StreamingSessionKey
    ) -> StreamingTranscriptionSession {
        let service = TranscriptionService(
            apiKey: params.apiKey,
            endpoint: params.endpoint,
            model: params.model,
            language: key.language,
            apiFormat: params.apiFormat
        )
        return service.createStreamingSession()
    }

    private func consumePendingStreamingStop(token: UUID, stage: String) -> Bool {
        guard pendingStreamingStopToken == token else { return false }
        pendingStreamingStopToken = nil
        trace(stage, token: token, details: "reason=pending-stop")
        return true
    }

    private func cancelStreamingStartupBeforeAudio(token: UUID) async {
        editState = .idle
        textAtRecordingStart = nil
        stopSilenceDetection()
        recordingController.clearStreamingState()
        finishTrace("streaming.done.cancelledBeforeAudio", token: token, details: "textChars=\(text.count)")
        await cleanupStreaming(stopAudio: true)
    }

    private func cancelStreamingPrewarm() {
        streamingPrewarmTask?.cancel()
        streamingPrewarmTask = nil
    }

    private func scheduleStreamingPrewarm(reason: String) {
        cancelStreamingPrewarm()
        streamingPrewarmTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            await self?.prewarmStreamingSessionIfNeeded(reason: reason)
        }
    }

    private func prewarmStreamingSessionIfNeeded(reason: String) async {
        guard editState == .idle else { return }

        let feature = providerStore.loadFeatureConfig()
        guard let stt = feature.sttPrimary,
              let params = providerStore.resolveSTT(stt),
              params.apiFormat == .glmRealtime else {
            return
        }

        let key = makeStreamingSessionKey(params: params)
        if let existingSession = streamingSession,
           streamingSessionKey == key,
           await existingSession.connected {
            Logger.info("[StreamingPrewarm] already connected reason=\(reason) model=\(params.model)", category: .stt)
            return
        }

        let session = makeStreamingSession(params: params, key: key)
        let start = Date()
        Logger.info("[StreamingPrewarm] connect.begin reason=\(reason) model=\(params.model)", category: .stt)
        do {
            try await session.connect()
            guard !Task.isCancelled, editState == .idle else {
                await session.disconnect()
                Logger.info("[StreamingPrewarm] discarded reason=\(reason) model=\(params.model)", category: .stt)
                return
            }

            if let existingSession = streamingSession {
                if streamingSessionKey == key, await existingSession.connected {
                    await session.disconnect()
                    Logger.info("[StreamingPrewarm] already connected reason=\(reason) model=\(params.model)", category: .stt)
                    return
                }

                guard streamingSessionKey == key else {
                    await session.disconnect()
                    Logger.info("[StreamingPrewarm] discarded reason=\(reason) model=\(params.model) existingSession=true", category: .stt)
                    return
                }

                await existingSession.disconnect()
            }

            streamingSession = session
            streamingSessionKey = key
            Logger.info(
                "[StreamingPrewarm] connect.done reason=\(reason) model=\(params.model) duration=\(formatSeconds(Date().timeIntervalSince(start)))",
                category: .stt
            )
        } catch {
            if Task.isCancelled {
                await session.disconnect()
                return
            }
            Logger.warning(
                "[StreamingPrewarm] connect.failed reason=\(reason) model=\(params.model) duration=\(formatSeconds(Date().timeIntervalSince(start))) error=\(error.localizedDescription)",
                category: .stt
            )
        }
    }

    private func recycleStreamingSessionAfterTerminal(reason: String, token: UUID) async {
        trace("streaming.session.recycle", token: token, category: .stt, details: "reason=\(reason)")
        await cleanupStreaming()
        scheduleStreamingPrewarm(reason: reason)
    }

    private func startStreamingRESTFallbackIfAvailable(audioURL: URL, token: UUID) {
        guard let sessionKey = streamingSessionKey,
              let fallback = streamingRESTFallbackParams(
                apiKey: sessionKey.apiKey,
                apiFormat: sessionKey.apiFormat,
                language: sessionKey.language
              ) else {
            return
        }

        streamingRESTFallbackTask?.cancel()
        streamingRESTFallbackTask = Task { [weak self] in
            guard let self else { return }
            await MainActor.run {
                self.trace(
                    "streaming.restFallback.begin",
                    token: token,
                    category: .stt,
                    details: "model=\(fallback.model) format=\(fallback.apiFormat.rawValue)"
                )
            }

            let start = Date()
            let service = TranscriptionService(
                apiKey: fallback.apiKey,
                endpoint: fallback.endpoint,
                model: fallback.model,
                language: fallback.language,
                apiFormat: fallback.apiFormat
            )

            do {
                let fallbackText = try await service.transcribe(audioFileURL: audioURL)
                guard !Task.isCancelled else { return }
                let duration = Date().timeIntervalSince(start)
                let applied = await self.applyStreamingRESTFallbackResult(
                    fallbackText,
                    token: token,
                    duration: duration
                )
                guard applied else { return }

                await MainActor.run {
                    self.streamingRESTFallbackTask = nil
                    self.invalidateEditTrace(reason: "rest-fallback-won")
                    self.streamingRESTFallbackWinningToken = nil
                }
                await self.cleanupStreaming(cancelRESTFallback: false)
                await MainActor.run {
                    self.scheduleStreamingPrewarm(reason: "after-rest-fallback")
                }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard self.guardCurrentTrace(token, stage: "streaming.restFallback.failed") else { return }
                    guard self.editState == .transcribing else { return }
                    self.trace(
                        "streaming.restFallback.failed",
                        token: token,
                        category: .stt,
                        details: "duration=\(self.formatSeconds(Date().timeIntervalSince(start))) error=\(error.localizedDescription)"
                    )
                    self.streamingRESTFallbackTask = nil
                }
            }
        }
    }

    private func applyStreamingRESTFallbackResult(
        _ fallbackText: String,
        token: UUID,
        duration: TimeInterval
    ) async -> Bool {
        guard guardCurrentTrace(token, stage: "streaming.restFallback.apply") else { return false }
        guard editState == .transcribing else {
            trace(
                "streaming.restFallback.ignored",
                token: token,
                category: .stt,
                details: "state=\(editState)"
            )
            return false
        }

        let trimmed = fallbackText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            trace(
                "streaming.restFallback.empty",
                token: token,
                category: .stt,
                details: "duration=\(formatSeconds(duration))"
            )
            return false
        }

        trace(
            "streaming.restFallback.api.done",
            token: token,
            category: .stt,
            details: "duration=\(formatSeconds(duration)) chars=\(trimmed.count)"
        )
        streamingRESTFallbackWinningToken = token

        if let originalText = textAtRecordingStart {
            text = originalText
            editState = editStateAfterTranscriptionCompletes(hasExistingText: true)
            trace(
                "ui.state.editing",
                token: token,
                category: .ui,
                details: "instructionChars=\(trimmed.count) textChars=\(text.count) source=restFallback"
            )
            let feature = providerStore.loadFeatureConfig()
            await editWithLLM(instruction: trimmed, feature: feature, token: token)
            textAtRecordingStart = nil
            finishTrace("streaming.restFallback.edit.done", token: token, details: "textChars=\(text.count)")
        } else {
            text = trimmed
            editState = .idle
            textAtRecordingStart = nil
            finishTrace("streaming.restFallback.done", token: token, details: "textChars=\(text.count)")
        }

        return true
    }

    // MARK: - Recording

    public func startRecording() {
        cancelStreamingPrewarm()
        streamingRESTFallbackTask?.cancel()
        streamingRESTFallbackTask = nil
        streamingRESTFallbackWinningToken = nil
        streamingStartupToken = nil
        pendingStreamingStopToken = nil

        // Fail-safe: reset any stuck state from previous errors
        let traceToken = beginEditTrace(reason: hasText ? "voice-edit-recording" : "new-dictation-recording")
        textAtRecordingStart = hasText ? text : nil
        recordingPeakAudioLevel = 0
        recordingFailed = false
        stopSilenceDetection()
        cleanupAudio()

        errorMessage = nil
        e2eStartTime = Date()
        trace("recording.start.requested", token: traceToken, details: "hasText=\(hasText)")

        // Check if we should use streaming transcription
        let feature = providerStore.loadFeatureConfig()
        trace("provider.config.loaded", token: traceToken, details: "sttPrimary=\(feature.sttPrimary != nil) llmPrimary=\(feature.llmPrimary != nil)")

        if let stt = feature.sttPrimary {
            if let params = providerStore.resolveSTT(stt) {
                trace("stt.resolved", token: traceToken, details: "model=\(params.model) format=\(params.apiFormat.rawValue)")
                if isWebSocketStreamingFormat(params.apiFormat) {
                    // Use streaming for WebSocket-based providers
                    streamingStartupToken = traceToken
                    Task {
                        await startStreamingRecording(params: params, token: traceToken)
                    }
                    return
                }
            } else {
                Logger.error("Failed to resolve STT for provider: \(stt.providerID)", category: .app)
            }
        }

        // Use traditional file-based recording for REST providers
        do {
            try recordingController.start()
            recordingStartTime = Date()
            editState = .recording(audioLevel: 0)
            startSilenceDetection()
            trace("recording.started.file", token: traceToken)
        } catch {
            recordingFailed = true
            errorMessage = error.localizedDescription
            editState = .idle  // Fail-safe: ensure state resets on error
            textAtRecordingStart = nil
            finishTrace("recording.start.failed", token: traceToken, details: "error=\(error.localizedDescription)")
        }
    }

    /// Start recording with real-time streaming transcription
    @MainActor
    private func startStreamingRecording(
        params: (apiKey: String, endpoint: String, model: String, apiFormat: ApiFormat),
        token: UUID
    ) async {
        guard guardCurrentTrace(token, stage: "streaming.start") else { return }
        streamingStartupToken = token
        defer {
            if streamingStartupToken == token {
                streamingStartupToken = nil
            }
        }
        trace("streaming.start", token: token, details: "model=\(params.model) format=\(params.apiFormat.rawValue)")

        let sessionKey = makeStreamingSessionKey(params: params)

        if let existingSession = streamingSession,
           streamingSessionKey == sessionKey,
           await existingSession.connected {
            trace("streaming.session.reuse", token: token, category: .stt, details: "model=\(params.model)")
        } else {
            if streamingSession != nil {
                trace("streaming.session.replace", token: token, category: .stt, details: "model=\(params.model)")
                await cleanupStreaming()
            }

            streamingSession = makeStreamingSession(params: params, key: sessionKey)
            streamingSessionKey = sessionKey
            trace("streaming.session.created", token: token, category: .stt, details: "model=\(params.model)")
        }

        do {
            let connectBeforeAudio = shouldConnectBeforeAudioCapture(params.apiFormat)
            func connectStreamingSession() async throws -> Bool {
                let wasConnected = await streamingSession?.connected == true
                trace(wasConnected ? "streaming.connect.reuse" : "streaming.connect.begin", token: token, category: .stt)
                try await streamingSession?.connect()
                guard guardCurrentTrace(token, stage: "streaming.connected") else {
                    return false
                }
                trace(wasConnected ? "streaming.connected.reused" : "streaming.connected", token: token, category: .stt)
                if let diagnostics = await streamingSession?.diagnostics() {
                    trace("streaming.queue.afterConnected", token: token, category: .stt, details: diagnostics.traceDetails)
                }
                return true
            }

            let chunkSize = streamingChunkSizeBytes(for: params.apiFormat)
            recordingController.setStreamingChunkSizeBytes(chunkSize)
            trace("streaming.chunk.config", token: token, category: .audio, details: "bytes=\(chunkSize)")

            // STEP 1: Register the handler before capture starts. The session buffers
            // chunks until the WebSocket connection is ready.
            recordingController.setStreamingHandler { [weak self] chunk in
                Task { [weak self] in
                    do {
                        try await self?.streamingSession?.sendAudioChunk(chunk, isFinal: false)
                    } catch {
                        Logger.error("Failed to send audio chunk: \(error)", category: .stt)
                    }
                }
            }
            trace("streaming.handler.buffering", token: token, category: .audio)

            // STEP 2: Start listening for results before connect so server events are not missed.
            startStreamingResultsListener(token: token)

            if connectBeforeAudio {
                // Connect before opening the microphone. This avoids provider
                // backlog during slow WebSocket handshakes and keeps paced
                // protocols from replaying audio after the user releases.
                guard try await connectStreamingSession() else { return }
                if consumePendingStreamingStop(token: token, stage: "streaming.stop.beforeAudioStart") {
                    await cancelStreamingStartupBeforeAudio(token: token)
                    return
                }
            }

            // STEP 3: Open the microphone only after the provider is ready.
            // This avoids sending startup backlog after the user has already
            // released the hotkey or button.
            trace("streaming.audio.start.begin", token: token, category: .audio)
            try recordingController.startStreaming(saveToFile: true)
            guard guardCurrentTrace(token, stage: "streaming.audio.started") else {
                return
            }
            trace("streaming.audio.started", token: token, category: .audio)
            recordingStartTime = Date()
            editState = .recording(audioLevel: 0)
            startSilenceDetection()
            if consumePendingStreamingStop(token: token, stage: "streaming.stop.afterAudioStart") {
                await finishStreamingRecording(token: token)
                return
            }

            if !connectBeforeAudio {
                // STEP 4: Connect to WebSocket while recording is ongoing.
                guard try await connectStreamingSession() else { return }
            }

            guard case .recording = editState else {
                trace("streaming.connected.afterStop", token: token, category: .stt, details: "state=\(editState)")
                return
            }
            trace("recording.started.streaming", token: token)
        } catch {
            guard guardCurrentTrace(token, stage: "streaming.start.catch") else { return }
            recordingFailed = true
            errorMessage = error.localizedDescription
            editState = .idle
            textAtRecordingStart = nil
            stopSilenceDetection()
            await cleanupStreaming(stopAudio: true)
            finishTrace("streaming.start.failed", token: token, details: "error=\(error.localizedDescription)")
        }
    }

    private func streamingChunkSizeBytes(for apiFormat: ApiFormat) -> Int {
        switch apiFormat {
        case .glmRealtime:
            // GLM documents 100ms frames, but measured URLSession/WebSocket sends
            // fall behind at 10 QPS. Use ~300ms chunks to reduce per-message overhead
            // while keeping end-of-recording backlog bounded.
            return 9_600
        case .iflytekIAT:
            // iFLYTEK recommends 40ms PCM chunks, which is 1280 bytes at
            // 16kHz, 16-bit, mono.
            return 1_280
        default:
            return 9_600
        }
    }

    /// Listen for streaming transcription results
    private func startStreamingResultsListener(token: UUID) {
        streamingTask?.cancel()
        streamingTask = Task { [weak self] in
            guard let self = self, let session = self.streamingSession else { return }
            self.trace("streaming.results.listen", token: token, category: .stt)
            var handledTerminalResult = false

            defer {
                // Ensure cleanup if stream ends unexpectedly
                Task { [weak self, handledTerminalResult] in
                    guard !handledTerminalResult else { return }
                    guard let self else { return }
                    guard self.isCurrentTrace(token) else { return }
                    let shouldStopAudio: Bool
                    if case .recording = self.editState {
                        shouldStopAudio = true
                        self.editState = .idle
                        self.textAtRecordingStart = nil
                    } else {
                        shouldStopAudio = false
                    }
                    // If still in transcribing state, force reset
                    if self.editState == .transcribing {
                        Logger.warning("Stream ended without final result, forcing state reset", category: .stt)
                        await MainActor.run {
                            self.editState = .idle
                        }
                    }
                    await self.cleanupStreaming(stopAudio: shouldStopAudio)
                }
            }

            for await result in session.receiveResults() {
                guard !Task.isCancelled else { break }
                guard self.guardCurrentTrace(token, stage: "streaming.result") else { return }
                guard self.streamingRESTFallbackWinningToken != token else {
                    self.trace("streaming.result.ignored.restFallbackWon", token: token, category: .stt)
                    return
                }

                switch result {
                case .partial(let text):
                    self.trace("streaming.partial", token: token, category: .stt, details: "chars=\(text.count)")
                    await MainActor.run {
                        guard self.guardCurrentTrace(token, stage: "streaming.partial.ui") else { return }
                        switch streamingPartialTextUpdate(
                            hadExistingTextAtRecordingStart: self.textAtRecordingStart != nil,
                            partialText: text
                        ) {
                        case .keepExistingText:
                            break
                        case .replaceText(let text):
                            self.text = text
                        }
                    }

                case .final(let text):
                    handledTerminalResult = true
                    self.trace("streaming.final", token: token, category: .stt, details: "chars=\(text.count)")
                    let shouldEdit = await MainActor.run { () -> Bool in
                        guard self.guardCurrentTrace(token, stage: "streaming.final.ui") else { return false }
                        guard !text.isEmpty else {
                            self.editState = .idle
                            self.textAtRecordingStart = nil
                            self.finishTrace("streaming.done.emptyFinal", token: token, details: "textChars=\(self.text.count)")
                            return false
                        }
                        if let originalText = self.textAtRecordingStart {
                            self.text = originalText
                            self.editState = editStateAfterTranscriptionCompletes(hasExistingText: true)
                            self.trace("ui.state.editing", token: token, category: .ui, details: "instructionChars=\(text.count) textChars=\(self.text.count)")
                            return true
                        } else {
                            self.text = text
                            self.editState = .idle
                            self.textAtRecordingStart = nil
                            self.finishTrace("streaming.done", token: token, details: "textChars=\(self.text.count)")
                            return false
                        }
                    }
                    if shouldEdit {
                        let feature = await MainActor.run { self.providerStore.loadFeatureConfig() }
                        await self.editWithLLM(instruction: text, feature: feature, token: token)
                        await MainActor.run {
                            self.textAtRecordingStart = nil
                            self.finishTrace("streaming.edit.done", token: token, details: "textChars=\(self.text.count)")
                        }
                    }
                    await self.recycleStreamingSessionAfterTerminal(reason: "after-final", token: token)
                    return

                case .error(.noSpeechDetected):
                    handledTerminalResult = true
                    self.trace("streaming.noSpeech", token: token, category: .stt)
                    await MainActor.run {
                        guard self.guardCurrentTrace(token, stage: "streaming.noSpeech.ui") else { return }
                        self.editState = .idle
                        self.textAtRecordingStart = nil
                        self.finishTrace("streaming.done.noSpeech", token: token, details: "textChars=\(self.text.count)")
                    }
                    await self.recycleStreamingSessionAfterTerminal(reason: "after-no-speech", token: token)
                    return

                case .error(let error):
                    handledTerminalResult = true
                    self.trace("streaming.error", token: token, category: .stt, details: "error=\(error.localizedDescription)")
                    let shouldStopAudio = await MainActor.run { () -> Bool in
                        guard self.guardCurrentTrace(token, stage: "streaming.error.ui") else { return false }
                        let wasRecording: Bool
                        if case .recording = self.editState {
                            wasRecording = true
                        } else {
                            wasRecording = false
                        }
                        self.errorMessage = error.localizedDescription
                        self.editState = .idle
                        self.textAtRecordingStart = nil
                        return wasRecording
                    }
                    await self.cleanupStreaming(stopAudio: shouldStopAudio)
                    return
                }
            }

            self.trace("streaming.results.end", token: token, category: .stt)
        }
    }

    /// Cleanup streaming resources
    private func cleanupStreaming(
        stopAudio: Bool = false,
        keepSessionAlive: Bool = false,
        cancelRESTFallback: Bool = true
    ) async {
        pendingStreamingStopToken = nil
        streamingTask?.cancel()
        streamingTask = nil
        if cancelRESTFallback {
            streamingRESTFallbackTask?.cancel()
            streamingRESTFallbackTask = nil
            streamingRESTFallbackWinningToken = nil
        }
        if stopAudio {
            if let audioURL = recordingController.stop() {
                RecordingController.deleteRecording(at: audioURL)
            }
            recordingController.clearStreamingState()
        }
        recordingController.setStreamingHandler(nil)
        if keepSessionAlive,
           streamingSessionKey?.apiFormat == .glmRealtime,
           await streamingSession?.connected == true {
            return
        }

        let sessionToDisconnect = streamingSession
        streamingSession = nil
        streamingSessionKey = nil
        await sessionToDisconnect?.disconnect()
    }

    public func stopRecording() {
        let traceToken = editTraceToken
        trace("recording.stop.requested", token: traceToken)
        // Always reset the failed flag so next gesture can try again
        recordingFailed = false

        guard case .recording = editState else {
            let hasStreamingStartup = streamingStartupToken == traceToken
            if shouldQueueStreamingStartupStop(editState: editState, hasStreamingStartup: hasStreamingStartup) {
                pendingStreamingStopToken = traceToken
                trace("recording.stop.queued", token: traceToken, details: "state=\(editState)")
                return
            }
            trace("recording.stop.ignored", token: traceToken, details: "state=\(editState)")
            return
        }

        pendingStreamingStopToken = nil
        stopSilenceDetection()

        // Check if we're in streaming mode
        trace("recording.stop.mode", token: traceToken, details: "streaming=\(streamingSession != nil)")
        if streamingSession != nil {
            Task {
                await finishStreamingRecording(token: traceToken)
            }
            return
        }

        editState = editStateAfterRecordingStops(hasExistingText: textAtRecordingStart != nil)
        trace("ui.state.transcribing", token: traceToken, category: .ui, details: "willEdit=\(textAtRecordingStart != nil) textChars=\(text.count)")

        let elapsed = Date().timeIntervalSince(recordingStartTime ?? Date())

        if elapsed < minimumRecordingDuration {
            let remaining = minimumRecordingDuration - elapsed
            Task {
                try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
                await finishRecording(token: traceToken)
            }
        } else {
            Task {
                await finishRecording(token: traceToken)
            }
        }
    }

    /// Finish streaming recording and send final audio chunk
    @MainActor
    private func finishStreamingRecording(token: UUID) async {
        guard guardCurrentTrace(token, stage: "streaming.finish") else { return }
        trace("streaming.finish.begin", token: token)

        // Stop recording first - this waits for audio engine to finish processing.
        let audioURL = recordingController.stop()
        trace("streaming.audio.stopped", token: token, category: .audio)
        let fileAudioLevel: Float?
        if let audioURL {
            currentAudioURL = audioURL
            let audioBytes = ((try? FileManager.default.attributesOfItem(atPath: audioURL.path)[.size]) as? Int) ?? 0
            fileAudioLevel = normalizedWAVAudioLevel(at: audioURL)
            trace(
                "streaming.localWav.ready",
                token: token,
                category: .audio,
                details: "audioBytes=\(audioBytes) uiPeak=\(String(format: "%.3f", recordingPeakAudioLevel)) wavLevel=\(formatOptionalLevel(fileAudioLevel)) path=\(audioURL.path)"
            )
        } else {
            fileAudioLevel = nil
        }

        let peakLevel = max(recordingPeakAudioLevel, fileAudioLevel ?? 0)
        if streamingStopDecision(peakAudioLevel: peakLevel, threshold: localNoSpeechPeakThreshold) == .localNoSpeech {
            trace(
                "streaming.localNoSpeech",
                token: token,
                category: .audio,
                details: "peak=\(String(format: "%.3f", peakLevel)) threshold=\(String(format: "%.3f", localNoSpeechPeakThreshold))"
            )
            recordingController.clearStreamingState()
            editState = .idle
            textAtRecordingStart = nil
            finishTrace("streaming.done.localNoSpeech", token: token, details: "textChars=\(text.count)")
            await cleanupStreaming()
            scheduleStreamingPrewarm(reason: "after-local-no-speech")
            return
        }

        editState = editStateAfterRecordingStops(hasExistingText: textAtRecordingStart != nil)
        trace("ui.state.transcribing", token: token, category: .ui, details: "willEdit=\(textAtRecordingStart != nil) textChars=\(text.count)")
        if let audioURL {
            startStreamingRESTFallbackIfAvailable(audioURL: audioURL, token: token)
        }

        // Flush any remaining accumulated audio data
        // CRITICAL: Must call this AFTER stop() which waits for audio engine
        let flushedData = recordingController.flushStreamingData()
        trace("streaming.flush", token: token, category: .audio, details: "bytes=\(flushedData?.count ?? 0)")

        // Now clear streaming state (handler and accumulated data)
        recordingController.clearStreamingState()

        // Send any flushed data BEFORE sending finish-task
        // This ensures proper ordering: audio data first, then finish signal
        do {
            if let diagnostics = await streamingSession?.diagnostics() {
                trace("streaming.queue.beforeFlushSend", token: token, category: .stt, details: diagnostics.traceDetails)
            }

            if let data = flushedData, !data.isEmpty {
                trace("streaming.flush.send.begin", token: token, category: .stt, details: "bytes=\(data.count)")
                try await streamingSession?.sendAudioChunk(data, isFinal: false)
                guard streamingRESTFallbackWinningToken != token else { return }
                guard guardCurrentTrace(token, stage: "streaming.flush.send.done") else { return }
                trace("streaming.flush.send.done", token: token, category: .stt)
                if let diagnostics = await streamingSession?.diagnostics() {
                    trace("streaming.queue.afterFlushSend", token: token, category: .stt, details: diagnostics.traceDetails)
                }
            }

            // Now send final chunk to indicate end of stream
            guard streamingRESTFallbackWinningToken != token else { return }
            guard guardCurrentTrace(token, stage: "streaming.beforeFinalSend") else { return }
            if let diagnostics = await streamingSession?.diagnostics() {
                trace("streaming.queue.beforeFinalSend", token: token, category: .stt, details: diagnostics.traceDetails)
            }
            trace("streaming.final.send.begin", token: token, category: .stt)
            try await streamingSession?.sendAudioChunk(Data(), isFinal: true)
            guard streamingRESTFallbackWinningToken != token else { return }
            guard guardCurrentTrace(token, stage: "streaming.final.send.done") else { return }
            trace("streaming.final.send.done", token: token, category: .stt)
            if let diagnostics = await streamingSession?.diagnostics() {
                trace("streaming.queue.afterFinalSend", token: token, category: .stt, details: diagnostics.traceDetails)
            }
        } catch {
            guard streamingRESTFallbackWinningToken != token else { return }
            guard guardCurrentTrace(token, stage: "streaming.finish.error") else { return }
            Logger.error("Failed to send final chunk: \(error)", category: .stt)
            errorMessage = error.localizedDescription
            editState = .idle
            textAtRecordingStart = nil
            await cleanupStreaming()
        }

        // Results will be handled by streamingTask listener
    }

    private func finishRecording(token: UUID) async {
        guard guardCurrentTrace(token, stage: "finishRecording") else { return }
        guard let audioURL = recordingController.stop() else {
            await MainActor.run {
                guard self.guardCurrentTrace(token, stage: "finishRecording.noAudio") else { return }
                errorMessage = "No audio recorded."
                editState = .idle
                textAtRecordingStart = nil
            }
            return
        }

        let recordingDuration = Date().timeIntervalSince(recordingStartTime ?? Date())
        trace("recording.stopped.file", token: token, details: "duration=\(formatSeconds(recordingDuration))")

        currentAudioURL = audioURL
        await processAudio(audioURL: audioURL, token: token)
    }

    // MARK: - Processing

    private func processAudio(audioURL: URL, token: UUID) async {
        guard guardCurrentTrace(token, stage: "processAudio") else { return }
        let feature = providerStore.loadFeatureConfig()
        let audioBytes = ((try? FileManager.default.attributesOfItem(atPath: audioURL.path)[.size]) as? Int) ?? 0
        let shouldEditExistingText = textAtRecordingStart != nil
        trace("processAudio.begin", token: token, details: "audioBytes=\(audioBytes) willEdit=\(shouldEditExistingText) textChars=\(text.count)")

        // Step 1: Transcribe the voice
        let sttStart = Date()
        guard let transcribedText = await transcribe(audioURL: audioURL, feature: feature, token: token) else {
            if guardCurrentTrace(token, stage: "processAudio.transcribe.nil") {
                editState = .idle
                textAtRecordingStart = nil
                finishTrace("processAudio.done.noText", token: token)
            }
            return
        }
        trace("stt.done", token: token, category: .stt, details: "duration=\(formatSeconds(Date().timeIntervalSince(sttStart))) chars=\(transcribedText.count)")
        guard guardCurrentTrace(token, stage: "processAudio.afterSTT") else { return }

        // Step 2: If recording started with existing text, send the voice instruction to LLM.
        if shouldEditExistingText {
            editState = editStateAfterTranscriptionCompletes(hasExistingText: true)
            trace("ui.state.editing", token: token, category: .ui, details: "instructionChars=\(transcribedText.count) textChars=\(text.count)")
            let llmStart = Date()
            await editWithLLM(instruction: transcribedText, feature: feature, token: token)
            trace("llm.done", token: token, category: .stt, details: "duration=\(formatSeconds(Date().timeIntervalSince(llmStart)))")
        } else {
            guard guardCurrentTrace(token, stage: "processAudio.setText") else { return }
            text = transcribedText
            editState = .idle
        }

        let e2eTotal = Date().timeIntervalSince(e2eStartTime ?? Date())
        textAtRecordingStart = nil
        finishTrace("processAudio.done", token: token, details: "e2e=\(formatSeconds(e2eTotal)) finalTextChars=\(text.count)")

        cleanupAudio()
    }

    private func transcribe(audioURL: URL, feature: FeatureConfig, token: UUID) async -> String? {
        guard let stt = feature.sttPrimary else {
            if guardCurrentTrace(token, stage: "stt.noPrimary") {
                errorMessage = "No STT model configured. Open Settings."
            }
            return nil
        }

        let (result, error) = await tryTranscribe(assignment: stt, audioURL: audioURL, token: token, label: "primary")
        if let result { return result }

        if let fallback = feature.sttFallback {
            let (fallbackResult, fallbackError) = await tryTranscribe(assignment: fallback, audioURL: audioURL, token: token, label: "fallback")
            if let fallbackResult { return fallbackResult }
            if guardCurrentTrace(token, stage: "stt.failed") {
                errorMessage = fallbackError ?? error ?? "Transcription failed."
            }
        } else {
            if guardCurrentTrace(token, stage: "stt.failed") {
                errorMessage = error ?? "Transcription failed."
            }
        }
        return nil
    }

    private func tryTranscribe(assignment: ModelAssignment, audioURL: URL, token: UUID, label: String) async -> (String?, String?) {
        guard let params = providerStore.resolveSTT(assignment) else {
            trace("stt.\(label).resolve.failed", token: token, category: .settings, details: "providerID=\(assignment.providerID)")
            return (nil, "Could not resolve provider. Check API key in Settings.")
        }
        let language = UserDefaults.standard.string(forKey: "language") ?? "auto"
        let service = TranscriptionService(
            apiKey: params.apiKey,
            endpoint: params.endpoint,
            model: params.model,
            language: language == "auto" ? nil : language,
            apiFormat: params.apiFormat
        )
        do {
            let apiStart = Date()
            trace("stt.\(label).api.begin", token: token, category: .stt, details: "model=\(params.model) format=\(params.apiFormat.rawValue)")
            let text = try await service.transcribe(audioFileURL: audioURL)
            trace("stt.\(label).api.done", token: token, category: .stt, details: "model=\(params.model) duration=\(formatSeconds(Date().timeIntervalSince(apiStart))) chars=\(text.count)")
            return (text, nil)
        } catch {
            trace("stt.\(label).api.failed", token: token, category: .stt, details: "model=\(params.model) duration=unknown error=\(error.localizedDescription) endpoint=\(params.endpoint)")
            return (nil, error.localizedDescription)
        }
    }

    private func editWithLLM(instruction: String, feature: FeatureConfig, token: UUID) async {
        guard guardCurrentTrace(token, stage: "llm.edit.begin") else { return }
        trace("llm.edit.begin", token: token, category: .stt, details: "textChars=\(text.count) instructionChars=\(instruction.count)")
        guard let llm = feature.llmPrimary else {
            // No LLM configured -- fall back to appending
            guard guardCurrentTrace(token, stage: "llm.noPrimary") else { return }
            text += (text.isEmpty ? "" : " ") + instruction
            editState = .idle
            errorMessage = "No LLM model configured. Text appended instead."
            trace("llm.edit.appended.noPrimary", token: token, category: .stt, details: "finalTextChars=\(text.count)")
            return
        }

        if let result = await tryLLMEdit(assignment: llm, instruction: instruction, token: token, label: "primary") {
            guard guardCurrentTrace(token, stage: "llm.primary.apply") else { return }
            text = result
            editState = .idle
            trace("llm.primary.applied", token: token, category: .stt, details: "finalTextChars=\(text.count)")
            return
        }

        if let fallback = feature.llmFallback,
           let result = await tryLLMEdit(assignment: fallback, instruction: instruction, token: token, label: "fallback") {
            guard guardCurrentTrace(token, stage: "llm.fallback.apply") else { return }
            text = result
            editState = .idle
            trace("llm.fallback.applied", token: token, category: .stt, details: "finalTextChars=\(text.count)")
            return
        }

        // All failed -- append the instruction as text
        guard guardCurrentTrace(token, stage: "llm.failed.append") else { return }
        text += (text.isEmpty ? "" : " ") + instruction
        editState = .idle
        errorMessage = "LLM edit failed. Text appended instead."
        trace("llm.edit.appended.failure", token: token, category: .stt, details: "finalTextChars=\(text.count)")
    }

    private func tryLLMEdit(assignment: ModelAssignment, instruction: String, token: UUID, label: String) async -> String? {
        guard let params = providerStore.resolveLLM(assignment) else {
            trace("llm.\(label).resolve.failed", token: token, category: .settings, details: "providerID=\(assignment.providerID)")
            return nil
        }

        let systemPrompt = """
        You are a text editor. Modify the provided text according to the user's instruction.

        Rules:
        1. Return ONLY the modified text, no explanations, no markdown code blocks
        2. Preserve the original language
        3. Keep paragraphs and formatting intact
        4. Apply the instruction literally
        """

        let userMessage = """
        Text:
        \(text)

        Instruction:
        \(instruction)
        """

        let service = LLMService(
            apiKey: params.apiKey,
            endpoint: params.endpoint,
            model: params.model
        )
        let apiStart = Date()
        trace(
            "llm.\(label).api.begin",
            token: token,
            category: .stt,
            details: "model=\(params.model) promptChars=\(systemPrompt.count + userMessage.count)"
        )
        do {
            let result = try await service.chat(system: systemPrompt, user: userMessage)
            trace("llm.\(label).api.done", token: token, category: .stt, details: "model=\(params.model) duration=\(formatSeconds(Date().timeIntervalSince(apiStart))) responseChars=\(result.count)")
            return result
        } catch {
            trace("llm.\(label).api.failed", token: token, category: .stt, details: "model=\(params.model) duration=\(formatSeconds(Date().timeIntervalSince(apiStart))) error=\(error.localizedDescription) endpoint=\(params.endpoint)")
            return nil
        }
    }

    // MARK: - External Instruction

    /// Applies a voice instruction to modify the current text using LLM.
    /// Called when the Edit window is already open and user uses the global shortcut.
    public func applyInstruction(_ instruction: String) async {
        guard !instruction.isEmpty else { return }

        let traceToken = beginEditTrace(reason: "external-instruction")
        editState = .editing
        e2eStartTime = Date()
        trace("ui.state.editing", token: traceToken, category: .ui, details: "externalInstructionChars=\(instruction.count) textChars=\(text.count)")

        let feature = providerStore.loadFeatureConfig()

        await editWithLLM(instruction: instruction, feature: feature, token: traceToken)

        let e2eTotal = Date().timeIntervalSince(e2eStartTime ?? Date())
        finishTrace("externalInstruction.done", token: traceToken, details: "e2e=\(formatSeconds(e2eTotal)) finalTextChars=\(text.count)")
    }

    // MARK: - Actions

    public func clear() {
        let keepIdleStreamingSession = editState == .idle
        invalidateEditTrace(reason: "clear")
        textAtRecordingStart = nil
        text = ""
        errorMessage = nil
        editState = .idle
        streamingStartupToken = nil
        pendingStreamingStopToken = nil
        stopSilenceDetection()
        cleanupAudio()
        Task {
            await cleanupStreaming(keepSessionAlive: keepIdleStreamingSession)
        }
    }

    public func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: - Cleanup

    private func cleanupAudio() {
        if let url = currentAudioURL {
            RecordingController.deleteRecording(at: url)
            currentAudioURL = nil
        }
    }
}
