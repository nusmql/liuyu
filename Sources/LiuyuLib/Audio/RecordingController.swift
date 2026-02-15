// Sources/LiuyuLib/Audio/RecordingController.swift
@preconcurrency import Foundation
@preconcurrency import AVFoundation
import Combine

@MainActor
public class RecordingController: ObservableObject {
    @Published public var audioLevel: Float = 0.0

    private var engine: AVAudioEngine?
    private var audioFile: AVAudioFile?
    private var tempFileURL: URL?

    public init() {}

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

    /// Start recording. Returns immediately. Call stop() to get the file URL.
    public func start() throws {
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        // Create temp file with settings for the Whisper API
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("liuyu_\(UUID().uuidString).m4a")

        let outputSettings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]

        let audioFile: AVAudioFile
        do {
            audioFile = try AVAudioFile(forWriting: tempURL, settings: outputSettings)
        } catch {
            throw RecordingError.fileCreationFailed(error)
        }

        // Install tap for audio data and metering.
        // The converter resamples to 16 kHz mono PCM; AVAudioFile handles AAC encoding.
        // Delegate to a free function so the closure is NOT @MainActor-isolated
        // (non-Sendable captures from @MainActor methods inherit actor isolation,
        // which crashes when AVAudioEngine calls the tap from its render thread).
        let pcmFormat = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
        let converter = AVAudioConverter(from: inputFormat, to: pcmFormat)
        _installAudioTap(on: inputNode, format: inputFormat,
                         converter: converter, audioFile: audioFile, controller: self)

        do {
            try engine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            throw RecordingError.engineStartFailed(error)
        }

        self.engine = engine
        self.audioFile = audioFile
        self.tempFileURL = tempURL
    }

    /// Stop recording and return the temp file URL.
    public func stop() -> URL? {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        audioFile = nil
        audioLevel = 0.0
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

    fileprivate nonisolated func processBuffer(_ buffer: AVAudioPCMBuffer,
                                               converter: AVAudioConverter?,
                                               audioFile: AVAudioFile) {
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

        Task { @MainActor [weak self] in
            self?.audioLevel = normalized
        }

        // Write converted audio to file
        if let converter {
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
                try? audioFile.write(from: convertedBuffer)
            }
        }
    }
}

// Free function — no @MainActor context, so the closure is non-isolated
// and safe to call from AVAudioEngine's render thread.
private func _installAudioTap(
    on inputNode: AVAudioInputNode,
    format: AVAudioFormat,
    converter: AVAudioConverter?,
    audioFile: AVAudioFile,
    controller: RecordingController
) {
    weak let weakController = controller
    inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
        weakController?.processBuffer(buffer, converter: converter, audioFile: audioFile)
    }
}
