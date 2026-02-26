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
        var debounceDuration: TimeInterval = 0.5  // 0.5s debounce to prevent accidental triggers
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

    /// Notification to reset transcription result flag
    public static let resetTranscriptionFlag = Notification.Name("resetTranscriptionFlag")

    /// Called when hotkey is pressed
    public func keyDown() {
        // Fail-safe: if stuck in completed/error state, force reset to idle
        if case .completed = phase {
            Logger.warning("Fail-safe: resetting from completed state to idle", category: .app)
            cancel()
        } else if case .error = phase {
            Logger.warning("Fail-safe: resetting from error state to idle", category: .app)
            cancel()
        }

        guard phase == .idle else {
            Logger.debug("Ignoring keyDown, current phase: \(phase)", category: .app)
            return
        }
        transition(to: .debouncing)
    }

    /// Called when hotkey is released
    public func keyUp() {
        Logger.info("🎬 [KEYUP] Received keyUp, current phase: \(phase)", category: .app)
        switch phase {
        case .debouncing:
            // Released before debounce - treat as click, cancel
            Logger.info("Key released during debounce, canceling", category: .app)
            cancelDebounce()
            transition(to: .idle)

        case .recording:
            // Normal recording stop
            let duration = Date().timeIntervalSince(recordingStartTime ?? Date())
            Logger.info("🎬 [KEYUP] In recording phase, duration: \(duration)s", category: .app)
            if duration < configuration.minimumRecordingDuration {
                Logger.info("Recording too short (\(duration)s), canceling", category: .app)
                transition(to: .idle)
            } else {
                stopRecording(caller: "keyUp.recording")
            }

        case .processing:
            // Ignore keyUp during processing
            Logger.debug("Ignoring keyUp during processing", category: .app)

        default:
            Logger.debug("KeyUp in phase: \(phase), ignoring", category: .app)
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
    public func transition(to newPhase: RecordingPhase, caller: String = #function, line: Int = #line) {
        Logger.debug("🎬 [TRANSITION] \(phase) → \(newPhase) (from: \(caller):\(line))", category: .app)

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
        Logger.info("🎬 [DEBOUNCE] Starting debounce timer (\(configuration.debounceDuration)s)", category: .app)
        debounceTimer = Timer.scheduledTimer(withTimeInterval: configuration.debounceDuration, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self = self, self.phase == .debouncing else {
                    Logger.debug("Debounce timer fired but phase is not debouncing, skipping", category: .app)
                    return
                }
                Logger.info("🎬 [DEBOUNCE] Timer fired, transitioning to recording", category: .app)
                self.transition(to: .recording, caller: "debounce-timer")
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
              configuration.silenceTimeout > 0 else {
            if phase == .recording {
                Logger.debug("🎬 [SILENCE] Check skipped - lastActivity: \(lastAudioActivity != nil), timeout: \(configuration.silenceTimeout)", category: .audio)
            }
            return
        }

        let silenceDuration = Date().timeIntervalSince(lastActivity)
        if silenceDuration >= configuration.silenceTimeout {
            Logger.info("🎬 [SILENCE] Silence timeout after \(String(format: "%.1f", silenceDuration))s", category: .audio)
            stopRecording(caller: "checkSilenceTimeout")
        }
    }

    private func stopRecording(caller: String = #function, file: String = #file, line: Int = #line) {
        guard phase == .recording else {
            Logger.debug("stopRecording called from \(caller):\(line) but phase is \(phase), skipping", category: .app)
            return
        }
        Logger.info("🎬 [STOP] stopRecording called from \(caller):\(line)", category: .app)
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
