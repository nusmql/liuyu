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

    public var hasText: Bool { !text.isEmpty }

    public var micButtonLabel: String {
        hasText ? "Hold to Edit" : "Hold to Record"
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
    }

    // MARK: - Recording

    public func startRecording() {
        guard !recordingFailed else { return }
        errorMessage = nil
        do {
            try recordingController.start()
            recordingStartTime = Date()
            editState = .recording(audioLevel: 0)
        } catch {
            recordingFailed = true
            errorMessage = error.localizedDescription
        }
    }

    public func stopRecording() {
        // Reset the failed flag so next gesture can try again
        recordingFailed = false

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
        guard let transcribedText = await transcribe(audioURL: audioURL, feature: feature) else {
            editState = .idle
            return
        }

        // Step 2: If there's existing text, send to LLM for editing
        if hasText {
            await editWithLLM(instruction: transcribedText, feature: feature)
        } else {
            text = transcribedText
            editState = .idle
        }

        cleanupAudio()
    }

    private func transcribe(audioURL: URL, feature: FeatureConfig) async -> String? {
        guard let stt = feature.sttPrimary else {
            errorMessage = "No STT model configured. Open Settings."
            return nil
        }

        if let result = await tryTranscribe(assignment: stt, audioURL: audioURL) {
            return result
        }

        if let fallback = feature.sttFallback,
           let result = await tryTranscribe(assignment: fallback, audioURL: audioURL) {
            return result
        }

        errorMessage = "Transcription failed. Check Settings."
        return nil
    }

    private func tryTranscribe(assignment: ModelAssignment, audioURL: URL) async -> String? {
        guard let params = providerStore.resolveSTT(assignment) else { return nil }
        let language = UserDefaults.standard.string(forKey: "language") ?? "auto"
        let service = TranscriptionService(
            apiKey: params.apiKey,
            endpoint: params.endpoint,
            model: params.model,
            language: language == "auto" ? nil : language,
            apiFormat: params.apiFormat
        )
        return try? await service.transcribe(audioFileURL: audioURL)
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
        You are a text editor assistant. The user will give you existing text and a voice instruction.
        Apply the instruction to the text and return ONLY the edited text. Do not add explanations.
        If the instruction is unclear, make your best interpretation and apply it.
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
        return try? await service.chat(system: systemPrompt, user: userMessage)
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

    /// Copy text, activate the previously focused app, and simulate Cmd+V.
    public func insert() {
        copy()

        // Find the last non-Liuyu app to paste into
        let liuyuBundleID = Bundle.main.bundleIdentifier
        let targetApp = NSWorkspace.shared.runningApplications
            .filter { $0.isActive == false && $0.bundleIdentifier != liuyuBundleID }
            .sorted { ($0.activationPolicy.rawValue) < ($1.activationPolicy.rawValue) }
            .first(where: { $0.activationPolicy == .regular })

        targetApp?.activate()
        Task {
            try? await Task.sleep(nanoseconds: 100_000_000) // 0.1s
            Self.simulatePaste()
        }
    }

    private static func simulatePaste() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true)
        keyDown?.flags = .maskCommand
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false)
        keyUp?.flags = .maskCommand
        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
    }

    // MARK: - Cleanup

    private func cleanupAudio() {
        if let url = currentAudioURL {
            RecordingController.deleteRecording(at: url)
            currentAudioURL = nil
        }
    }
}
