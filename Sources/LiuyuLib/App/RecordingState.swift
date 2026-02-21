// Sources/LiuyuLib/App/RecordingState.swift
import Combine
import Foundation

/// Centralized recording state machine using Combine
@MainActor
public final class RecordingState: ObservableObject {
    public static let shared = RecordingState()

    // MARK: - Published States

    /// Current recording phase
    @Published public private(set) var phase: RecordingPhase = .idle

    /// Recording start time (for calculating duration)
    @Published public private(set) var recordingStartTime: Date?

    /// Current audio level for UI display
    @Published public private(set) var audioLevel: Float = 0.0

    /// Last audio activity timestamp (for silence detection)
    @Published public private(set) var lastAudioActivity: Date?

    /// Current transcription result
    @Published public private(set) var transcriptionResult: String?

    /// Error message if any
    @Published public private(set) var errorMessage: String?

    // MARK: - State Enum

    public enum RecordingPhase: Equatable {
        case idle
        case debouncing          // 0.5s debounce after keyDown
        case recording           // Actually recording
        case processing          // Transcribing
        case completed(String)   // Finished with result
        case error(String)       // Error occurred

        public var isRecording: Bool {
            if case .recording = self { return true }
            return false
        }

        public var isActive: Bool {
            switch self {
            case .debouncing, .recording, .processing:
                return true
            default:
                return false
            }
        }
    }

    // MARK: - Configuration

    public struct Configuration {
        var debounceDuration: TimeInterval = 0.5
        var minimumRecordingDuration: TimeInterval = 0.3
        var silenceTimeout: TimeInterval = 5.0
        var audioActivityThreshold: Float = 0.25
    }

    public var configuration = Configuration()

    // MARK: - Private Properties

    private var cancellables = Set<AnyCancellable>()
    private var debounceTimer: Timer?
    private var silenceCheckTimer: Timer?

    private init() {
        setupStateTransitions()
    }

    // MARK: - State Transitions

    private func setupStateTransitions() {
        // When entering debouncing state, start timer
        $phase
            .filter { $0 == .debouncing }
            .sink { [weak self] _ in
                self?.startDebounceTimer()
            }
            .store(in: &cancellables)

        // When entering recording state, start silence detection
        $phase
            .filter { $0 == .recording }
            .sink { [weak self] _ in
                self?.startSilenceDetection()
            }
            .store(in: &cancellables)

        // When leaving active states, cleanup
        $phase
            .filter { !$0.isActive }
            .sink { [weak self] _ in
                self?.cleanup()
            }
            .store(in: &cancellables)
    }

    // MARK: - Public Actions

    /// Called when hotkey is pressed
    public func keyDown() {
        guard phase == .idle else {
            Logger.debug("Ignoring keyDown, current phase: \(phase)", category: .app)
            return
        }
        transition(to: .debouncing)
    }

    /// Called when hotkey is released
    public func keyUp() {
        switch phase {
        case .debouncing:
            // Released before debounce - treat as click, cancel
            Logger.info("Key released during debounce, canceling", category: .app)
            cancelDebounce()
            transition(to: .idle)

        case .recording:
            // Normal recording stop
            let duration = Date().timeIntervalSince(recordingStartTime ?? Date())
            if duration < configuration.minimumRecordingDuration {
                Logger.info("Recording too short (\(duration)s), canceling", category: .app)
                transition(to: .idle)
            } else {
                stopRecording()
            }

        case .processing:
            // Ignore keyUp during processing
            Logger.debug("Ignoring keyUp during processing", category: .app)

        default:
            break
        }
    }

    /// Called when audio activity is detected
    public func updateAudioActivity(level: Float) {
        audioLevel = level

        if level > configuration.audioActivityThreshold {
            lastAudioActivity = Date()
        }
    }

    /// Cancel current operation
    public func cancel() {
        cleanup()
        transition(to: .idle)
    }

    // MARK: - State Transitions

    /// Internal method to force transition to a specific state (use with caution)
    public func transition(to newPhase: RecordingPhase) {
        Logger.debug("State transition: \(phase) → \(newPhase)", category: .app)

        // Exit current phase
        switch phase {
        case .debouncing:
            debounceTimer?.invalidate()
        case .recording:
            silenceCheckTimer?.invalidate()
        default:
            break
        }

        // Enter new phase
        phase = newPhase

        switch newPhase {
        case .recording:
            recordingStartTime = Date()
            lastAudioActivity = Date()

        case .completed(let text):
            transcriptionResult = text

        case .error(let message):
            errorMessage = message

        default:
            break
        }
    }

    // MARK: - Private Methods

    private func startDebounceTimer() {
        debounceTimer?.invalidate()
        debounceTimer = Timer.scheduledTimer(withTimeInterval: configuration.debounceDuration, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self = self, self.phase == .debouncing else { return }
                self.transition(to: .recording)
            }
        }
    }

    private func cancelDebounce() {
        debounceTimer?.invalidate()
        debounceTimer = nil
    }

    private func startSilenceDetection() {
        silenceCheckTimer?.invalidate()
        silenceCheckTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.checkSilenceTimeout()
            }
        }
    }

    private func checkSilenceTimeout() {
        guard phase == .recording,
              let lastActivity = lastAudioActivity,
              configuration.silenceTimeout > 0 else { return }

        let silenceDuration = Date().timeIntervalSince(lastActivity)
        if silenceDuration >= configuration.silenceTimeout {
            Logger.info("Silence timeout after \(String(format: "%.1f", silenceDuration))s", category: .audio)
            stopRecording()
        }
    }

    private func stopRecording() {
        guard phase == .recording else { return }
        transition(to: .processing)
        // Actual stop logic will be handled by RecordingController
    }

    private func cleanup() {
        debounceTimer?.invalidate()
        silenceCheckTimer?.invalidate()
        recordingStartTime = nil
        audioLevel = 0.0
    }
}
