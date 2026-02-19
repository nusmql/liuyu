// Sources/LiuyuLib/Edit/EditViewModel.swift
import Foundation
import Combine
import AppKit

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

    public var hasText: Bool { !text.isEmpty }

    public var micButtonLabel: String {
        let shortcut = RecordedShortcut.loadEditRecordShortcut()
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
                print("[Liuyu Audio] Pre-warm failed (will retry on first recording): \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Recording

    public func startRecording() {
        guard !recordingFailed else { return }
        errorMessage = nil
        e2eStartTime = Date()
        do {
            try recordingController.start()
            recordingStartTime = Date()
            editState = .recording(audioLevel: 0)
            print("[Liuyu Timing] Recording started")
        } catch {
            recordingFailed = true
            errorMessage = error.localizedDescription
        }
    }

    public func stopRecording() {
        // Always reset the failed flag so next gesture can try again
        recordingFailed = false

        guard case .recording = editState else { return }

        let elapsed = Date().timeIntervalSince(recordingStartTime ?? Date())

        if elapsed < minimumRecordingDuration {
            let remaining = minimumRecordingDuration - elapsed
            Task {
                try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
                finishRecording()
            }
        } else {
            finishRecording()
        }
    }

    private func finishRecording() {
        guard let audioURL = recordingController.stop() else {
            errorMessage = "No audio recorded."
            editState = .idle
            return
        }

        let recordingDuration = Date().timeIntervalSince(recordingStartTime ?? Date())
        print("[Liuyu Timing] Recording stopped — duration: \(String(format: "%.2f", recordingDuration))s")

        currentAudioURL = audioURL

        if hasText {
            editState = .editing
        } else {
            editState = .transcribing
        }

        Task {
            await processAudio(audioURL: audioURL)
        }
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
        print("[Liuyu Timing] STT completed — \(String(format: "%.2f", Date().timeIntervalSince(sttStart)))s — \"\(transcribedText.prefix(80))\"")

        // Step 2: If there's existing text, send to LLM for editing
        if hasText {
            let llmStart = Date()
            await editWithLLM(instruction: transcribedText, feature: feature)
            print("[Liuyu Timing] LLM edit completed — \(String(format: "%.2f", Date().timeIntervalSince(llmStart)))s")
        } else {
            text = transcribedText
            editState = .idle
        }

        let e2eTotal = Date().timeIntervalSince(e2eStartTime ?? Date())
        print("[Liuyu Timing] End-to-end total: \(String(format: "%.2f", e2eTotal))s")

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
            print("[Liuyu Timing] STT API call [\(params.model)] — \(String(format: "%.2f", Date().timeIntervalSince(apiStart)))s")
            return (text, nil)
        } catch {
            let detail = "[\(params.model)] \(error.localizedDescription)"
            print("[Liuyu STT] \(detail) | endpoint=\(params.endpoint)")
            return (nil, detail)
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
        You are a text editor. Process the user's text according to their instruction.

        Default mode: EDIT - Apply the instruction to modify the text while preserving the original language and core meaning.

        Alternative modes (when explicitly requested):
        - REWRITE: Restructure and rephrase completely while keeping the meaning
        - REFINE: Polish and improve expression without changing content
        - OPTIMIZE: Enhance clarity, conciseness, and impact

        Rules:
        1. Return ONLY the processed text, no explanations
        2. Preserve the original language(s) used in the text
        3. Maintain formatting (paragraphs, lists, etc.)
        4. If the instruction is unclear, make a reasonable interpretation
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
        print("[Liuyu Timing] LLM API call [\(params.model)] — \(String(format: "%.2f", Date().timeIntervalSince(apiStart)))s")
        return result
    }

    // MARK: - Actions

    public func clear() {
        text = ""
        errorMessage = nil
        editState = .idle
        cleanupAudio()
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
