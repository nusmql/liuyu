// Sources/LiuyuLib/Audio/RecordingController.swift
@preconcurrency import Foundation
@preconcurrency import AVFoundation
import Combine

@MainActor
public class RecordingController: ObservableObject {
    @Published public var audioLevel: Float = 0.0

    private var engine: AVAudioEngine?
    private var tempFileURL: URL?
    private var isWarmedUp = false
    private var converter: AVAudioConverter?
    private var configChangeObserver: NSObjectProtocol?
    private var needsRewarm = false

    // Thread-safe state shared with the audio render thread
    fileprivate let audioState = AudioState()

    /// Threshold for detecting speech activity (normalized 0-1)
    private let speechThreshold: Float = 0.25 // Increased from 0.15 (~-42dB) to 0.25 (~-37dB) to ignore background noise
    /// Time of last audio activity above threshold
    public private(set) var lastAudioActivityTime: Date?
    /// Whether there has been recent audio activity
    public var hasRecentAudioActivity: Bool {
        guard let lastTime = lastAudioActivityTime else { return false }
        // Consider active if audio detected within last 2 seconds
        return Date().timeIntervalSince(lastTime) < 2.0
    }

    public init() {
        // Re-warm the engine when the audio device changes (e.g. user switches mic).
        // The tap format must match the new hardware format.
        configChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isWarmedUp else { return }
                if self.audioState.isRecording {
                    // Don't destroy active recording — re-warm after stop()
                    self.needsRewarm = true
                    Logger.warning("Audio device changed during recording — will re-warm after stop", category: .audio)
                    return
                }
                Logger.info("Audio device changed — re-warming engine", category: .audio)
                self.coolDown()
            }
        }
    }

    public enum RecordingError: Error, LocalizedError {
        case microphonePermissionDenied
        case engineStartFailed(Error)
        case fileCreationFailed(Error)

        public var errorDescription: String? {
            switch self {
            case .microphonePermissionDenied:
                return "Microphone access denied. Grant access in System Settings > Privacy & Security > Microphone."
            case .engineStartFailed(let e):
                return "Failed to start audio engine: \(e.localizedDescription)"
            case .fileCreationFailed(let e):
                return "Failed to create audio file: \(e.localizedDescription)"
            }
        }
    }

    /// Request microphone permission. Returns true if granted.
    public static func requestMicrophonePermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    // MARK: - Engine Lifecycle

    /// Pre-warm the audio engine so recording starts instantly.
    /// The engine runs continuously with a tap that fills a ring buffer.
    /// Call this early (e.g. when the Edit window opens) for best results.
    public func warmUp() throws {
        guard !isWarmedUp else { return }

        // Create a fresh engine instance to avoid stale format caches from previous devices
        let newEngine = AVAudioEngine()
        self.engine = newEngine

        let inputNode = newEngine.inputNode

        // After sleep/wake or device change, inputNode may report stale format.
        // Retry multiple times with increasing delays to sync with hardware.
        var inputFormat = inputNode.outputFormat(forBus: 0)
        var retries = 0
        let maxRetries = 5

        while (inputFormat.sampleRate == 0 || inputFormat.channelCount == 0) && retries < maxRetries {
            Thread.sleep(forTimeInterval: 0.05 * Double(retries + 1))
            inputFormat = inputNode.outputFormat(forBus: 0)
            retries += 1
        }

        guard inputFormat.sampleRate > 0 else {
            Logger.error("No audio input available after \(maxRetries) retries", category: .audio)
            self.engine = nil
            return
        }

        let pcmFormat = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
        let converter = AVAudioConverter(from: inputFormat, to: pcmFormat)
        self.converter = converter

        // Install tap that continuously converts audio and feeds AudioState.
        // Delegate to a free function so the closure is NOT @MainActor-isolated.
        _installAudioTap(on: inputNode, format: inputFormat,
                         converter: converter, audioState: audioState, controller: self)

        // Pre-allocate audio resources before starting
        newEngine.prepare()

        do {
            try newEngine.start()
            isWarmedUp = true
            Logger.info("Engine warmed up — pre-roll buffering active", category: .audio)
        } catch {
            inputNode.removeTap(onBus: 0)
            newEngine.stop()
            self.converter = nil
            self.engine = nil
            throw RecordingError.engineStartFailed(error)
        }
    }

    /// Release the audio engine and microphone.
    public func coolDown() {
        guard isWarmedUp, let engine = engine else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        converter = nil
        self.engine = nil
        isWarmedUp = false
        audioState.clear()
        Logger.info("Engine cooled down", category: .audio)
    }

    // MARK: - Recording

    /// Start recording. The engine must be warmed up (done automatically if needed).
    /// Pre-roll audio (~0.5s captured before this call) is flushed to the file.
    public func start() throws {
        // Re-warm if engine died (e.g. after system sleep)
        if isWarmedUp && !(engine?.isRunning ?? false) {
            coolDown()
        }
        if !isWarmedUp {
            try warmUp()
        }

        // Create temp WAV file (16 kHz, mono, 16-bit PCM)
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("liuyu_\(UUID().uuidString).wav")

        let outputSettings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false
        ]

        let audioFile: AVAudioFile
        do {
            audioFile = try AVAudioFile(forWriting: tempURL, settings: outputSettings)
        } catch {
            throw RecordingError.fileCreationFailed(error)
        }

        // Atomically flush pre-roll buffers to file and start recording
        audioState.startRecording(audioFile: audioFile)

        // Reset audio activity tracking
        lastAudioActivityTime = Date()

        self.tempFileURL = tempURL
    }

    /// Stop recording and return the temp file URL.
    /// The engine stays warm for the next recording.
    public func stop() -> URL? {
        audioState.stopRecording()

        // Log file size for debugging
        if let url = tempFileURL,
           let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let size = attrs[.size] as? Int {
            Logger.debug("WAV file: \(size) bytes at \(url.lastPathComponent)", category: .audio)
        }

        audioLevel = 0.0

        // Re-warm if audio device changed during recording
        if needsRewarm {
            needsRewarm = false
            Logger.info("Deferred re-warm — applying now", category: .audio)
            coolDown()
            try? warmUp()
        }

        return tempFileURL
    }

    /// Clean up orphaned temp files from previous sessions.
    public nonisolated static func cleanupOrphanedFiles() {
        let tempDir = FileManager.default.temporaryDirectory
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: tempDir, includingPropertiesForKeys: nil
        ) else { return }

        for file in files where file.lastPathComponent.hasPrefix("liuyu_") {
            try? FileManager.default.removeItem(at: file)
        }
    }

    /// Delete a specific recording file.
    public nonisolated static func deleteRecording(at url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Audio Processing (called from audio render thread)

    fileprivate nonisolated func processBuffer(_ buffer: AVAudioPCMBuffer,
                                               converter: AVAudioConverter?,
                                               audioState: AudioState) {
        // Calculate RMS audio level
        guard let channelData = buffer.floatChannelData?[0] else { return }
        let frameCount = Int(buffer.frameLength)

        var rms: Float = 0
        for i in 0..<frameCount {
            rms += channelData[i] * channelData[i]
        }
        rms = sqrt(rms / Float(max(frameCount, 1)))

        // Normalize to 0...1 (typical speech RMS is -40dB to -10dB)
        let db = 20 * log10(max(rms, 1e-6))
        let normalized = max(0, min(1, (db + 50) / 50))

        // Only publish audio level while recording (avoids phantom UI updates)
        if audioState.isRecording {
            Task { @MainActor [weak self] in
                self?.audioLevel = normalized
                // Track audio activity for smart timeout
                if normalized > (self?.speechThreshold ?? 0.25) {
                    self?.lastAudioActivityTime = Date()
                    Logger.debug("Activity detected: \(String(format: "%.2f", normalized))", category: .audio)
                }
            }
        }

        // Convert to 16kHz mono PCM
        guard let converter else { return }
        let outputFrameCapacity = AVAudioFrameCount(
            ceil(Double(buffer.frameLength) * (16000.0 / buffer.format.sampleRate))
        )
        guard let convertedBuffer = AVAudioPCMBuffer(
            pcmFormat: converter.outputFormat,
            frameCapacity: outputFrameCapacity
        ) else { return }

        var error: NSError?
        // The converter calls this block synchronously, so the capture is safe.
        // Use nonisolated(unsafe) to silence the Swift 6 concurrency warning.
        nonisolated(unsafe) var hasData = false
        converter.convert(to: convertedBuffer, error: &error) { _, status in
            if hasData {
                status.pointee = .noDataNow
                return nil
            }
            hasData = true
            status.pointee = .haveData
            return buffer
        }

        if error == nil && convertedBuffer.frameLength > 0 {
            // AudioState routes the buffer to pre-roll ring buffer or audio file
            audioState.handleBuffer(convertedBuffer)
        }
    }
}

// MARK: - Thread-Safe Audio State

/// Shared state between @MainActor (start/stop) and the audio render thread (tap callback).
/// Routes converted PCM buffers to either a pre-roll ring buffer or the active audio file.
fileprivate final class AudioState: @unchecked Sendable {
    private let lock = NSLock()
    private var _isRecording = false
    private var _audioFile: AVAudioFile?
    private var _preRollBuffers: [AVAudioPCMBuffer] = []

    // At 16kHz input with 1024-frame tap buffers at ~48kHz, each callback ≈ 21ms.
    // 24 buffers ≈ 0.5 seconds of pre-roll audio.
    private let maxPreRollCount = 24

    var isRecording: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _isRecording
    }

    /// Called from audio thread on each tap callback.
    /// If recording: writes directly to audio file.
    /// If not recording: stores in ring buffer (oldest evicted when full).
    func handleBuffer(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        if _isRecording, let file = _audioFile {
            // Hold strong reference to file, then unlock before I/O
            lock.unlock()
            try? file.write(from: buffer)
        } else {
            _preRollBuffers.append(buffer)
            if _preRollBuffers.count > maxPreRollCount {
                _preRollBuffers.removeFirst()
            }
            lock.unlock()
        }
    }

    /// Called from MainActor. Flushes pre-roll buffers to file, then starts recording.
    /// The lock ensures no gap between pre-roll flush and live recording.
    func startRecording(audioFile: AVAudioFile) {
        lock.lock()
        // Write buffered pre-roll audio to file first
        let preRollCount = _preRollBuffers.count
        for buffer in _preRollBuffers {
            try? audioFile.write(from: buffer)
        }
        _preRollBuffers.removeAll()
        _audioFile = audioFile
        _isRecording = true
        lock.unlock()

        if preRollCount > 0 {
            Logger.debug("Flushed \(preRollCount) pre-roll buffers (~\(preRollCount * 21)ms)", category: .audio)
        }
    }

    /// Called from MainActor. Stops routing buffers to file.
    /// Buffers resume going to the pre-roll ring buffer.
    func stopRecording() {
        lock.lock()
        _isRecording = false
        _audioFile = nil
        lock.unlock()
    }

    /// Clear all state (used during coolDown).
    func clear() {
        lock.lock()
        _preRollBuffers.removeAll()
        _isRecording = false
        _audioFile = nil
        lock.unlock()
    }
}

// MARK: - Tap Installation (free function)

// Free function — no @MainActor context, so the closure is non-isolated
// and safe to call from AVAudioEngine's render thread.
private func _installAudioTap(
    on inputNode: AVAudioInputNode,
    format: AVAudioFormat,
    converter: AVAudioConverter?,
    audioState: AudioState,
    controller: RecordingController
) {
    weak let weakController = controller
    inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
        weakController?.processBuffer(buffer, converter: converter, audioState: audioState)
    }
}
