// Sources/LiuyuLib/Edit/EditViewModel.swift
import AppKit
import Combine

public enum EditState: Equatable {
    case idle
    case recording(audioLevel: Float)
    case transcribing
    case editing  // LLM processing
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

    private let minimumRecordingDuration: TimeInterval = 0.3
    private var e2eStartTime: Date?

    // Streaming transcription support
    private var streamingSession: StreamingTranscriptionSession?
    private var streamingTask: Task<Void, Never>?

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

    // MARK: - Recording

    public func startRecording() {
        // Fail-safe: reset any stuck state from previous errors
        recordingFailed = false
        stopSilenceDetection()
        cleanupAudio()

        errorMessage = nil
        e2eStartTime = Date()
        Logger.info("🎬 [T0] startRecording called", category: .app)

        // Check if we should use streaming transcription
        let feature = providerStore.loadFeatureConfig()
        Logger.debug("Checking streaming mode: sttPrimary=\(feature.sttPrimary != nil)", category: .app)

        if let stt = feature.sttPrimary {
            if let params = providerStore.resolveSTT(stt) {
                Logger.debug("Resolved STT: model=\(params.model), format=\(params.apiFormat)", category: .app)
                if params.apiFormat == .alibabaRealtime || params.apiFormat == .tencentRealtime {
                    // Use streaming for WebSocket-based providers
                    Task {
                        await startStreamingRecording(stt: stt, params: params)
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
            Logger.debug("Recording started (file-based)", category: .app)
        } catch {
            recordingFailed = true
            errorMessage = error.localizedDescription
            editState = .idle  // Fail-safe: ensure state resets on error
        }
    }

    /// Start recording with real-time streaming transcription
    @MainActor
    private func startStreamingRecording(stt: ModelAssignment, params: (apiKey: String, endpoint: String, model: String, apiFormat: ApiFormat)) async {
        Logger.info("🎬 [T1] startStreamingRecording called - model: \(params.model)", category: .app)

        // Create transcription service
        let language = UserDefaults.standard.string(forKey: "language") ?? "auto"
        let service = TranscriptionService(
            apiKey: params.apiKey,
            endpoint: params.endpoint,
            model: params.model,
            language: language == "auto" ? nil : language,
            apiFormat: params.apiFormat
        )

        // Create streaming session
        streamingSession = service.createStreamingSession()

        do {
            // STEP 1: Start recording FIRST to capture all audio
            // This ensures we don't miss audio during WebSocket connection
            Logger.info("🎬 [T2] Starting audio recording...", category: .audio)
            try recordingController.startStreaming()
            Logger.info("🎬 [T3] Audio recording started", category: .audio)
            recordingStartTime = Date()
            editState = .recording(audioLevel: 0)
            startSilenceDetection()

            // STEP 2: Connect to WebSocket while recording is ongoing
            Logger.info("🎬 [T4] Connecting WebSocket...", category: .stt)
            try await streamingSession?.connect()
            Logger.info("🎬 [T5] WebSocket connected", category: .stt)

            // STEP 3: Set up streaming handler - this will flush any buffered audio
            recordingController.setStreamingHandler { [weak self] chunk in
                Task { [weak self] in
                    do {
                        try await self?.streamingSession?.sendAudioChunk(chunk, isFinal: false)
                    } catch {
                        Logger.error("Failed to send audio chunk: \(error)", category: .stt)
                    }
                }
            }
            Logger.info("🎬 [T6] Streaming handler set up", category: .audio)

            // STEP 4: Start listening for results
            startStreamingResultsListener()

            Logger.debug("Recording started (streaming)", category: .app)
        } catch {
            recordingFailed = true
            errorMessage = error.localizedDescription
            editState = .idle
            await streamingSession?.disconnect()
            streamingSession = nil
        }
    }

    /// Listen for streaming transcription results
    private func startStreamingResultsListener() {
        streamingTask?.cancel()
        streamingTask = Task { [weak self] in
            guard let self = self, let session = self.streamingSession else { return }
            Logger.info("🎬 [T7] Started listening for transcription results", category: .stt)

            defer {
                // Ensure cleanup if stream ends unexpectedly
                Task { [weak self] in
                    guard let self else { return }
                    // If still in transcribing state, force reset
                    if self.editState == .transcribing {
                        Logger.warning("Stream ended without final result, forcing state reset", category: .stt)
                        await MainActor.run {
                            self.editState = .idle
                        }
                    }
                    await self.cleanupStreaming()
                }
            }

            for await result in session.receiveResults() {
                guard !Task.isCancelled else { break }

                switch result {
                case .partial(let text):
                    Logger.info("🎬 [T8] Partial result: \"\(text)\"", category: .stt)
                    // Show partial results in UI for real-time streaming feedback
                    await MainActor.run {
                        // Combine existing text with partial result for display
                        if self.hasText {
                            self.text = text
                        } else {
                            self.text = text
                        }
                    }

                case .final(let text):
                    Logger.info("🎬 [T9] Final result received: \"\(text)\"", category: .stt)
                    await MainActor.run {
                        // If text is empty (task-finished signal), keep existing text
                        if !text.isEmpty {
                            self.text = text
                        }
                        self.editState = .idle
                    }
                    await self.cleanupStreaming()
                    return

                case .error(let error):
                    Logger.error("🎬 [T9-ERROR] Streaming error: \(error)", category: .stt)
                    await MainActor.run {
                        self.errorMessage = error.localizedDescription
                        self.editState = .idle
                    }
                    await self.cleanupStreaming()
                    return
                }
            }

            Logger.info("🎬 [T7-END] Result stream ended", category: .stt)
        }
    }

    /// Cleanup streaming resources
    private func cleanupStreaming() async {
        streamingTask?.cancel()
        streamingTask = nil
        recordingController.setStreamingHandler(nil)
        await streamingSession?.disconnect()
        streamingSession = nil
    }

    public func stopRecording() {
        Logger.info("🎬 [T10] stopRecording called", category: .app)
        // Always reset the failed flag so next gesture can try again
        recordingFailed = false

        guard case .recording = editState else {
            Logger.warning("stopRecording: not in recording state (current: \(editState))", category: .app)
            return
        }

        stopSilenceDetection()

        // Check if we're in streaming mode
        Logger.debug("stopRecording: streamingSession=\(streamingSession != nil)", category: .app)
        if streamingSession != nil {
            Task {
                await finishStreamingRecording()
            }
            return
        }

        // Immediately switch to processing state so UI shows "Processing" instead of stuck waveform
        if hasText {
            editState = .editing
        } else {
            editState = .transcribing
        }

        let elapsed = Date().timeIntervalSince(recordingStartTime ?? Date())

        if elapsed < minimumRecordingDuration {
            let remaining = minimumRecordingDuration - elapsed
            Task {
                try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
                await finishRecording()
            }
        } else {
            Task {
                await finishRecording()
            }
        }
    }

    /// Finish streaming recording and send final audio chunk
    @MainActor
    private func finishStreamingRecording() async {
        Logger.info("🎬 [T11] finishStreamingRecording started", category: .app)

        // Stop recording first - this waits for audio engine to finish processing
        _ = recordingController.stop() // Stop file recording (we don't use the file)
        Logger.info("🎬 [T12] Audio recording stopped", category: .audio)

        // Immediately switch to processing state so UI shows "Processing"
        if hasText {
            editState = .editing
        } else {
            editState = .transcribing
        }

        // Flush any remaining accumulated audio data
        // CRITICAL: Must call this AFTER stop() which waits for audio engine
        let flushedData = recordingController.flushStreamingData()
        Logger.info("🎬 [T12b] Flushed data: \(flushedData?.count ?? 0) bytes", category: .audio)

        // Now clear streaming state (handler and accumulated data)
        recordingController.clearStreamingState()

        // Send any flushed data BEFORE sending finish-task
        // This ensures proper ordering: audio data first, then finish signal
        do {
            if let data = flushedData, !data.isEmpty {
                Logger.info("🎬 [T13] Sending flushed audio data: \(data.count) bytes...", category: .stt)
                try await streamingSession?.sendAudioChunk(data, isFinal: false)
                Logger.info("🎬 [T13b] Flushed data sent", category: .stt)
            }

            // Now send final chunk to indicate end of stream
            Logger.info("🎬 [T14] Sending final audio chunk (finish-task)...", category: .stt)
            try await streamingSession?.sendAudioChunk(Data(), isFinal: true)
            Logger.info("🎬 [T15] Final chunk sent, waiting for transcription...", category: .stt)
        } catch {
            Logger.error("Failed to send final chunk: \(error)", category: .stt)
            errorMessage = error.localizedDescription
            editState = .idle
            await cleanupStreaming()
        }

        // Results will be handled by streamingTask listener
    }

    private func finishRecording() async {
        guard let audioURL = recordingController.stop() else {
            await MainActor.run {
                errorMessage = "No audio recorded."
                editState = .idle
            }
            return
        }

        let recordingDuration = Date().timeIntervalSince(recordingStartTime ?? Date())
        Logger.debug("Recording stopped — duration: \(String(format: "%.2f", recordingDuration))s", category: .app)

        currentAudioURL = audioURL
        await processAudio(audioURL: audioURL)
    }

    // MARK: - Processing

    private func processAudio(audioURL: URL) async {
        let feature = providerStore.loadFeatureConfig()

        // Step 1: Transcribe the voice
        let sttStart = Date()
        guard let transcribedText = await transcribe(audioURL: audioURL, feature: feature) else {
            editState = .idle
            return
        }
        Logger.debug("STT completed — \(String(format: "%.2f", Date().timeIntervalSince(sttStart)))s — \"\(transcribedText.prefix(80))\"", category: .stt)

        // Step 2: If there's existing text, send to LLM for editing
        if hasText {
            let llmStart = Date()
            await editWithLLM(instruction: transcribedText, feature: feature)
            Logger.debug("LLM edit completed — \(String(format: "%.2f", Date().timeIntervalSince(llmStart)))s", category: .stt)
        } else {
            text = transcribedText
            editState = .idle
        }

        let e2eTotal = Date().timeIntervalSince(e2eStartTime ?? Date())
        Logger.info("End-to-end total: \(String(format: "%.2f", e2eTotal))s", category: .app)

        cleanupAudio()
    }

    private func transcribe(audioURL: URL, feature: FeatureConfig) async -> String? {
        guard let stt = feature.sttPrimary else {
            errorMessage = "No STT model configured. Open Settings."
            return nil
        }

        let (result, error) = await tryTranscribe(assignment: stt, audioURL: audioURL)
        if let result { return result }

        if let fallback = feature.sttFallback {
            let (fallbackResult, fallbackError) = await tryTranscribe(assignment: fallback, audioURL: audioURL)
            if let fallbackResult { return fallbackResult }
            errorMessage = fallbackError ?? error ?? "Transcription failed."
        } else {
            errorMessage = error ?? "Transcription failed."
        }
        return nil
    }

    private func tryTranscribe(assignment: ModelAssignment, audioURL: URL) async -> (String?, String?) {
        guard let params = providerStore.resolveSTT(assignment) else {
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
            let text = try await service.transcribe(audioFileURL: audioURL)
            Logger.debug("STT API call [\(params.model)] — \(String(format: "%.2f", Date().timeIntervalSince(apiStart)))s", category: .stt)
            return (text, nil)
        } catch {
            Logger.error("[\(params.model)] \(error.localizedDescription) | endpoint=\(params.endpoint)", category: .stt)
            return (nil, error.localizedDescription)
        }
    }

    private func editWithLLM(instruction: String, feature: FeatureConfig) async {
        guard let llm = feature.llmPrimary else {
            // No LLM configured -- fall back to appending
            text += (text.isEmpty ? "" : " ") + instruction
            editState = .idle
            errorMessage = "No LLM model configured. Text appended instead."
            return
        }

        if let result = await tryLLMEdit(assignment: llm, instruction: instruction) {
            text = result
            editState = .idle
            return
        }

        if let fallback = feature.llmFallback,
           let result = await tryLLMEdit(assignment: fallback, instruction: instruction) {
            text = result
            editState = .idle
            return
        }

        // All failed -- append the instruction as text
        text += (text.isEmpty ? "" : " ") + instruction
        editState = .idle
        errorMessage = "LLM edit failed. Text appended instead."
    }

    private func tryLLMEdit(assignment: ModelAssignment, instruction: String) async -> String? {
        guard let params = providerStore.resolveLLM(assignment) else { return nil }

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
        let result = try? await service.chat(system: systemPrompt, user: userMessage)
        Logger.debug("LLM API call [\(params.model)] — \(String(format: "%.2f", Date().timeIntervalSince(apiStart)))s", category: .stt)
        return result
    }

    // MARK: - External Instruction

    /// Applies a voice instruction to modify the current text using LLM.
    /// Called when the Edit window is already open and user uses the global shortcut.
    public func applyInstruction(_ instruction: String) async {
        guard !instruction.isEmpty else { return }

        editState = .editing
        e2eStartTime = Date()

        let feature = providerStore.loadFeatureConfig()

        await editWithLLM(instruction: instruction, feature: feature)

        let e2eTotal = Date().timeIntervalSince(e2eStartTime ?? Date())
        Logger.info("End-to-end total: \(String(format: "%.2f", e2eTotal))s", category: .app)
    }

    // MARK: - Actions

    public func clear() {
        text = ""
        errorMessage = nil
        editState = .idle
        stopSilenceDetection()
        cleanupAudio()
        Task {
            await cleanupStreaming()
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
