// Sources/LiuyuLib/Audio/RecordingController.swift
@preconcurrency import Foundation
@preconcurrency import AVFoundation
import AppKit
import Combine

@MainActor
public class RecordingController: ObservableObject {
    // Compatibility wrapper candidate: new voice flows should use LiuyuVoice.MacMicrophoneAudioSource.
    @Published public var audioLevel: Float = 0.0

    private var engine: AVAudioEngine?
    private var tempFileURL: URL?
    private var isWarmedUp = false
    private var converter: AVAudioConverter?
    private var configChangeObserver: NSObjectProtocol?
    private var needsRewarm = false
    private var warmedInputSampleRate: Double?

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

        // Handle system sleep/wake to prevent audio engine overload after wake
        NotificationCenter.default.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isWarmedUp else { return }
                Logger.info("System will sleep — cooling down audio engine", category: .audio)
                self.coolDown()
            }
        }

        NotificationCenter.default.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                Logger.info("System woke up — will warm up audio engine when needed", category: .audio)
                // Don't warm up immediately; let the next recording request trigger it
                // This avoids racing with audio device initialization
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
        // Use RunLoop polling instead of Thread.sleep to avoid blocking main thread.
        var inputFormat = inputNode.outputFormat(forBus: 0)
        let maxWaitTime: TimeInterval = 2.0  // Maximum total wait time
        let pollInterval: TimeInterval = 0.05  // Poll every 50ms
        var totalWaited: TimeInterval = 0

        while (inputFormat.sampleRate == 0 || inputFormat.channelCount == 0) && totalWaited < maxWaitTime {
            // Use RunLoop to yield control instead of blocking Thread.sleep
            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: pollInterval))
            inputFormat = inputNode.outputFormat(forBus: 0)
            totalWaited += pollInterval
        }

        guard inputFormat.sampleRate > 0 else {
            Logger.error("No audio input available after \(String(format: "%.2f", totalWaited))s", category: .audio)
            self.engine = nil
            throw RecordingError.engineStartFailed(NSError(domain: "RecordingController", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Audio input not available after sleep/wake"]))
        }

        // Create 16-bit PCM format (not Float32) for WebSocket streaming compatibility
        guard let pcmFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true) else {
            throw RecordingError.engineStartFailed(NSError(domain: "RecordingController", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Failed to create 16-bit PCM audio format"]))
        }
        let converter = AVAudioConverter(from: inputFormat, to: pcmFormat)
        self.converter = converter
        warmedInputSampleRate = inputFormat.sampleRate

        // Install tap that continuously converts audio and feeds AudioState.
        // Delegate to a free function so the closure is NOT @MainActor-isolated.
        _installAudioTap(on: inputNode, format: inputFormat,
                         converter: converter, audioState: audioState, controller: self)

        // Pre-allocate audio resources before starting
        newEngine.prepare()

        do {
            try newEngine.start()
            isWarmedUp = true
            Logger.info(
                "Engine warmed up — pre-roll buffering active inputRate=\(String(format: "%.0f", inputFormat.sampleRate)) inputChannels=\(inputFormat.channelCount) inputFormat=\(inputFormat.commonFormat.rawValue) interleaved=\(inputFormat.isInterleaved)",
                category: .audio
            )
        } catch {
            inputNode.removeTap(onBus: 0)
            newEngine.stop()
            self.converter = nil
            self.engine = nil
            warmedInputSampleRate = nil
            throw RecordingError.engineStartFailed(error)
        }
    }

    /// Recreate the engine/tap before a real recording session. This is more
    /// defensive than warmUp(): devices can leave AVAudioEngine running while
    /// the tap no longer delivers buffers after sleep/device changes.
    public func restartWarmUp() throws {
        coolDown()
        try warmUp()
    }

    /// Prepare for providers that must begin recording immediately while their
    /// WebSocket connects. Reuse a stable warmed engine when possible: repeatedly
    /// rebuilding AVAudioEngine can leave the tap installed but not delivering
    /// buffers on some devices.
    public func prepareForImmediateStreamingRecording() throws {
        if isWarmedUp,
           engine?.isRunning == true,
           let warmedInputSampleRate,
           warmedInputSampleRate <= 32_000 {
            Logger.info(
                "Engine reused for immediate streaming inputRate=\(String(format: "%.0f", warmedInputSampleRate))",
                category: .audio
            )
            return
        }

        try restartWarmUp()
    }

    /// Release the audio engine and microphone.
    public func coolDown() {
        guard isWarmedUp, let engine = engine else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        converter = nil
        self.engine = nil
        warmedInputSampleRate = nil
        isWarmedUp = false
        audioState.clear()
        Logger.info("Engine cooled down", category: .audio)
    }

    // MARK: - Recording

    /// Start recording. The engine must be warmed up (done automatically if needed).
    /// Pre-roll audio (~0.5s captured before this call) is flushed to the file.
    public func start() throws {
        try startInternal(skipFileCreation: false)
    }

    /// Start recording in streaming mode.
    /// Used for WebSocket streaming where audio is sent directly to server.
    /// When `saveToFile` is true, a local WAV is written for diagnostics and fallback.
    public func startStreaming(saveToFile: Bool = false) throws {
        try startInternal(skipFileCreation: !saveToFile)
    }

    private func startInternal(skipFileCreation: Bool) throws {
        // Re-warm if engine died (e.g. after system sleep)
        if isWarmedUp && !(engine?.isRunning ?? false) {
            coolDown()
        }
        if !isWarmedUp {
            try warmUp()
        }

        var audioWriter: AudioFileBufferWriter? = nil
        var tempURL: URL? = nil

        if !skipFileCreation {
            // Create temp WAV file using explicit 16-bit PCM settings
            // This ensures format compatibility with the converter output
            tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("liuyu_\(UUID().uuidString).wav")

            // Create format that matches the converter output exactly
            guard let outputFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true) else {
                throw RecordingError.engineStartFailed(NSError(domain: "RecordingController", code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "Failed to create output audio format"]))
            }

            do {
                audioWriter = try AudioFileBufferWriter(url: tempURL!, format: outputFormat)
                Logger.debug("Created audio file with format: \(outputFormat)", category: .audio)
            } catch {
                throw RecordingError.fileCreationFailed(error)
            }
        }

        // Atomically flush pre-roll buffers to file and start recording
        audioState.startRecording(audioWriter: audioWriter)
        Logger.info("Audio recording started diagnostics=\(audioState.diagnostics().traceDetails)", category: .audio)

        // Reset audio activity tracking
        lastAudioActivityTime = Date()

        self.tempFileURL = tempURL
    }

    /// Stop recording and return the temp file URL.
    /// The engine stays warm for the next recording.
    public func stop() -> URL? {
        // stopRecording() internally waits for audio engine to settle
        audioState.stopRecording()
        let url = tempFileURL
        tempFileURL = nil
        Logger.info("Audio recording stopped diagnostics=\(audioState.diagnostics().traceDetails)", category: .audio)

        // Log file size for debugging
        if let url,
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

        return url
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

    // MARK: - Streaming Support

    /// Set the streaming handler for real-time audio streaming
    /// This enables WebSocket-based transcription to receive audio chunks as they arrive
    public func setStreamingHandler(_ handler: AudioChunkHandler?) {
        audioState.setStreamingHandler(handler)
        if handler != nil {
            Logger.info("🎬 [A1] Audio streaming handler registered", category: .audio)
        }
    }

    /// Configure how much PCM data is batched into each WebSocket audio message.
    /// The input is 16kHz 16-bit mono PCM, so 32,000 bytes is roughly 1 second.
    public func setStreamingChunkSizeBytes(_ bytes: Int) {
        audioState.setStreamingChunkSizeBytes(bytes)
    }

    /// Flush any remaining accumulated audio data (call when stopping recording)
    /// Returns the accumulated data that needs to be sent, or nil if nothing to send
    public func flushStreamingData() -> Data? {
        Logger.info("🎬 [FLUSH] Flushing streaming data...", category: .audio)
        return audioState.flushAccumulatedData()
    }

    /// Clear streaming state after flushing data
    public func clearStreamingState() {
        audioState.clearStreamingState()
    }

    // MARK: - Audio Processing (called from audio render thread)

    fileprivate nonisolated func processBuffer(_ buffer: AVAudioPCMBuffer,
                                               converter: AVAudioConverter?,
                                               audioState: AudioState) {
        audioState.noteInputBuffer()

        // Convert to 16kHz mono PCM
        guard let converter else {
            Logger.debug("🎬 [PROCESS] No converter, skipping", category: .audio)
            audioState.noteConversionFailure()
            return
        }
        let outputFrameCapacity = AVAudioFrameCount(
            ceil(Double(buffer.frameLength) * (16000.0 / buffer.format.sampleRate))
        )
        guard let convertedBuffer = AVAudioPCMBuffer(
            pcmFormat: converter.outputFormat,
            frameCapacity: outputFrameCapacity
        ) else { return }

        var error: NSError?
        // Use a simple class wrapper to safely track state within the synchronous conversion block
        // The converter calls this block synchronously on the same thread, so this is safe
        final class DataFlag: @unchecked Sendable {
            var value = false
        }
        let hasData = DataFlag()
        converter.convert(to: convertedBuffer, error: &error) { _, status in
            if hasData.value {
                status.pointee = .noDataNow
                return nil
            }
            hasData.value = true
            status.pointee = .haveData
            return buffer
        }

        if error == nil && convertedBuffer.frameLength > 0 {
            audioState.noteConvertedBuffer(frameLength: Int(convertedBuffer.frameLength))
            let normalized = normalizedPCM16BufferAudioLevel(convertedBuffer)

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

            // AudioState routes the buffer to pre-roll ring buffer or audio file
            audioState.handleBuffer(convertedBuffer)
        } else {
            audioState.noteConversionFailure()
            if let error {
                Logger.warning("Audio conversion failed: \(error.localizedDescription)", category: .audio)
            }
        }
    }
}

// MARK: - Thread-Safe Audio State

/// Audio chunk callback for streaming
/// Returns true if the chunk was successfully processed (for async tracking)
public typealias AudioChunkHandler = @Sendable (Data) -> Void

final class AudioFileBufferWriter: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.liuyu.audio-file-writer")
    private let queueKey = DispatchSpecificKey<Bool>()
    private let url: URL
    private let sampleRate: UInt32
    private let channels: UInt16
    private let bitsPerSample: UInt16
    private var pcmData = Data()
    private var isClosed = false

    init(url: URL, format: AVAudioFormat) throws {
        self.url = url
        self.sampleRate = UInt32(format.sampleRate)
        self.channels = UInt16(format.channelCount)
        self.bitsPerSample = UInt16(format.streamDescription.pointee.mBitsPerChannel)
        queue.setSpecific(key: queueKey, value: true)

        let emptyWAV = Self.makeWAVData(
            pcmData: Data(),
            sampleRate: sampleRate,
            channels: channels,
            bitsPerSample: bitsPerSample
        )
        try emptyWAV.write(to: url, options: .atomic)
    }

    func write(_ buffer: AVAudioPCMBuffer) {
        guard let copiedData = Self.copyPCMData(buffer) else {
            Logger.error("Failed to copy audio buffer before file write", category: .audio)
            return
        }

        queue.async { [weak self] in
            guard let self, !self.isClosed else { return }
            self.pcmData.append(copiedData)
        }
    }

    func close() {
        if DispatchQueue.getSpecific(key: queueKey) == true {
            closeOnQueue()
        } else {
            queue.sync {
                closeOnQueue()
            }
        }
    }

    private func closeOnQueue() {
        guard !isClosed else { return }
        isClosed = true

        let wavData = Self.makeWAVData(
            pcmData: pcmData,
            sampleRate: sampleRate,
            channels: channels,
            bitsPerSample: bitsPerSample
        )

        do {
            try wavData.write(to: url, options: .atomic)
        } catch {
            Logger.error("Failed to finalize WAV file: \(error)", category: .audio)
        }

        pcmData = Data()
    }

    private static func copyPCMData(_ buffer: AVAudioPCMBuffer) -> Data? {
        guard buffer.frameLength > 0 else { return nil }

        let sourceList = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: buffer.audioBufferList)
        )

        var data = Data()
        for sourceBuffer in sourceList {
            guard sourceBuffer.mDataByteSize > 0 else { continue }
            guard let sourceData = sourceBuffer.mData else { return nil }
            data.append(sourceData.assumingMemoryBound(to: UInt8.self), count: Int(sourceBuffer.mDataByteSize))
        }

        return data
    }

    private static func makeWAVData(
        pcmData: Data,
        sampleRate: UInt32,
        channels: UInt16,
        bitsPerSample: UInt16
    ) -> Data {
        let bytesPerSample = UInt32(bitsPerSample / 8)
        let byteRate = sampleRate * UInt32(channels) * bytesPerSample
        let blockAlign = channels * (bitsPerSample / 8)
        let dataSize = UInt32(pcmData.count)
        let riffSize = UInt32(36) + dataSize

        var data = Data()
        data.appendASCII("RIFF")
        data.appendLittleEndian(riffSize)
        data.appendASCII("WAVE")
        data.appendASCII("fmt ")
        data.appendLittleEndian(UInt32(16))
        data.appendLittleEndian(UInt16(1))
        data.appendLittleEndian(channels)
        data.appendLittleEndian(sampleRate)
        data.appendLittleEndian(byteRate)
        data.appendLittleEndian(blockAlign)
        data.appendLittleEndian(bitsPerSample)
        data.appendASCII("data")
        data.appendLittleEndian(dataSize)
        data.append(pcmData)
        return data
    }
}

func preRollEvictionCount(currentFrameLengths: [Int], maxFrames: Int) -> Int {
    guard maxFrames > 0 else { return currentFrameLengths.count }

    var totalFrames = currentFrameLengths.reduce(0, +)
    var evictionCount = 0

    for frameLength in currentFrameLengths where totalFrames > maxFrames {
        totalFrames -= frameLength
        evictionCount += 1
    }

    return evictionCount
}

func streamingChunkSplit(
    _ data: Data,
    chunkSize: Int,
    includeRemainder: Bool
) -> (chunks: [Data], remainder: Data) {
    let normalizedChunkSize = max(1, chunkSize)
    var chunks: [Data] = []
    var offset = data.startIndex

    while data.distance(from: offset, to: data.endIndex) >= normalizedChunkSize {
        let end = data.index(offset, offsetBy: normalizedChunkSize)
        chunks.append(data.subdata(in: offset..<end))
        offset = end
    }

    let remainder = offset < data.endIndex ? data.subdata(in: offset..<data.endIndex) : Data()
    if includeRemainder, !remainder.isEmpty {
        chunks.append(remainder)
        return (chunks, Data())
    }

    return (chunks, remainder)
}

func normalizedPCM16BufferAudioLevel(_ buffer: AVAudioPCMBuffer) -> Float {
    guard buffer.frameLength > 0, let channelData = buffer.int16ChannelData else {
        return 0
    }

    let channelCount = max(1, Int(buffer.format.channelCount))
    let frameCount = Int(buffer.frameLength)
    var rms: Float = 0
    var sampleCount = 0

    for channel in 0..<channelCount {
        let samples = UnsafeBufferPointer(start: channelData[channel], count: frameCount)
        for sample in samples {
            let normalizedSample = Float(sample) / Float(Int16.max)
            rms += normalizedSample * normalizedSample
        }
        sampleCount += frameCount
    }

    rms = sqrt(rms / Float(max(sampleCount, 1)))
    let db = 20 * log10(max(rms, 1e-6))
    return max(0, min(1, (db + 50) / 50))
}

struct AudioStateDiagnostics: Equatable {
    let inputBuffers: Int
    let convertedBuffers: Int
    let convertedFrames: Int
    let conversionFailures: Int
    let recordedBuffers: Int
    let preRollBuffers: Int
    let preRollFrames: Int
    let accumulatedBytes: Int

    var traceDetails: String {
        "inputBuffers=\(inputBuffers) convertedBuffers=\(convertedBuffers) convertedFrames=\(convertedFrames) conversionFailures=\(conversionFailures) recordedBuffers=\(recordedBuffers) preRollBuffers=\(preRollBuffers) preRollFrames=\(preRollFrames) accumulatedBytes=\(accumulatedBytes)"
    }
}

private extension Data {
    mutating func appendASCII(_ string: String) {
        append(string.data(using: .ascii)!)
    }

    mutating func appendLittleEndian(_ value: UInt16) {
        var littleEndian = value.littleEndian
        append(Data(bytes: &littleEndian, count: MemoryLayout<UInt16>.size))
    }

    mutating func appendLittleEndian(_ value: UInt32) {
        var littleEndian = value.littleEndian
        append(Data(bytes: &littleEndian, count: MemoryLayout<UInt32>.size))
    }
}

/// Shared state between @MainActor (start/stop) and the audio render thread (tap callback).
/// Routes converted PCM buffers to either a pre-roll ring buffer, audio file, or streaming handler.
fileprivate final class AudioState: @unchecked Sendable {
    private let lock = NSLock()
    private var _isRecording = false
    private var _audioWriter: AudioFileBufferWriter?
    private var _preRollBuffers: [AVAudioPCMBuffer] = []
    private var _preRollFrameCount = 0
    private var _streamingHandler: AudioChunkHandler?
    private var _accumulatedData: Data = Data()
    private var _lastSentTime: Date = Date()
    private var inputBufferCount = 0
    private var convertedBufferCount = 0
    private var convertedFrameCount = 0
    private var conversionFailureCount = 0
    private var recordedBufferCount = 0

    // Keep one second of converted 16kHz PCM pre-roll. Buffer duration varies by
    // input device, so frame count is the stable unit here.
    private let maxPreRollFrames = 16_000

    // Default stream chunk size: ~300ms of 16kHz 16-bit mono = 9600 bytes.
    private var streamChunkSize = 9_600

    var isRecording: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _isRecording
    }

    func noteInputBuffer() {
        lock.lock()
        inputBufferCount += 1
        lock.unlock()
    }

    func noteConvertedBuffer(frameLength: Int) {
        lock.lock()
        convertedBufferCount += 1
        convertedFrameCount += frameLength
        lock.unlock()
    }

    func noteConversionFailure() {
        lock.lock()
        conversionFailureCount += 1
        lock.unlock()
    }

    func diagnostics() -> AudioStateDiagnostics {
        lock.lock()
        defer { lock.unlock() }
        return AudioStateDiagnostics(
            inputBuffers: inputBufferCount,
            convertedBuffers: convertedBufferCount,
            convertedFrames: convertedFrameCount,
            conversionFailures: conversionFailureCount,
            recordedBuffers: recordedBufferCount,
            preRollBuffers: _preRollBuffers.count,
            preRollFrames: _preRollFrameCount,
            accumulatedBytes: _accumulatedData.count
        )
    }

    /// Set the streaming handler for real-time audio streaming (e.g., WebSocket)
    /// If audio has been recorded before the handler was set, it will be buffered in _accumulatedData
    /// and sent when the handler is set.
    func setStreamingHandler(_ handler: AudioChunkHandler?) {
        lock.lock()
        _streamingHandler = handler

        // If we have buffered audio data and a handler is being set, send full
        // fixed-size chunks and keep the tail for the normal stop-time flush.
        if let handler = handler, !_accumulatedData.isEmpty {
            let split = streamingChunkSplit(
                _accumulatedData,
                chunkSize: streamChunkSize,
                includeRemainder: false
            )
            _accumulatedData = split.remainder
            lock.unlock()
            for chunk in split.chunks {
                Logger.info("🎬 [HANDLER-SET] Sending \(chunk.count) bytes of buffered audio", category: .audio)
                handler(chunk)
            }
            return
        }

        lock.unlock()
    }

    func setStreamingChunkSizeBytes(_ bytes: Int) {
        lock.lock()
        streamChunkSize = max(1_280, bytes)
        lock.unlock()
        Logger.info("🎬 [STREAM-CHUNK] chunkSizeBytes=\(max(1_280, bytes))", category: .audio)
    }

    /// Called from audio thread on each tap callback.
    /// If recording: writes to file AND streams if handler is set.
    /// If not recording: stores in ring buffer (oldest evicted when full).
    func handleBuffer(_ buffer: AVAudioPCMBuffer) {
        lock.lock()

        Logger.debug("🎬 [HANDLE] isRecording=\(_isRecording), handler=\(_streamingHandler != nil), frameLength=\(buffer.frameLength)", category: .audio)

        // Convert buffer to PCM data
        let pcmData = convertBufferToData(buffer)

        if _isRecording {
            recordedBufferCount += 1

            // Write to file for persistence
            _audioWriter?.write(buffer)

            // Stream for real-time recognition
            // ALWAYS accumulate data when recording (even if handler not set yet)
            if let data = pcmData {
                _accumulatedData.append(data)
                Logger.debug("🎬 [ACCUMULATE] Added \(data.count) bytes, total: \(_accumulatedData.count)", category: .audio)

                // Send chunk when accumulated enough (~300ms) and handler is set
                if let handler = _streamingHandler, _accumulatedData.count >= streamChunkSize {
                    let split = streamingChunkSplit(
                        _accumulatedData,
                        chunkSize: streamChunkSize,
                        includeRemainder: false
                    )
                    _accumulatedData = split.remainder
                    _lastSentTime = Date()
                    lock.unlock()
                    for chunk in split.chunks {
                        Logger.info("🎬 [SEND-CHUNK] Sending \(chunk.count) bytes", category: .audio)
                        handler(chunk)
                    }
                    return
                }
            }
        } else {
            // Not recording: store in pre-roll buffer
            if pcmData != nil {
                _preRollBuffers.append(buffer)
                _preRollFrameCount += Int(buffer.frameLength)

                let evictionCount = preRollEvictionCount(
                    currentFrameLengths: _preRollBuffers.map { Int($0.frameLength) },
                    maxFrames: maxPreRollFrames
                )
                if evictionCount > 0 {
                    for _ in 0..<evictionCount {
                        _preRollFrameCount -= Int(_preRollBuffers.removeFirst().frameLength)
                    }
                }
            }
        }

        lock.unlock()
    }

    /// Flush any remaining accumulated data (call when stopping recording)
    /// Returns the accumulated data that needs to be sent, or nil if nothing to send
    func flushAccumulatedData() -> Data? {
        lock.lock()
        Logger.info("🎬 [FLUSH-AUDIO] accumulated: \(_accumulatedData.count) bytes", category: .audio)
        if !_accumulatedData.isEmpty {
            let remainingData = _accumulatedData
            _accumulatedData = Data()
            lock.unlock()
            Logger.info("🎬 [FLUSH-AUDIO] Returning \(remainingData.count) bytes to send", category: .audio)
            return remainingData
        } else {
            lock.unlock()
            return nil
        }
    }

    /// Called from MainActor. Flushes pre-roll buffers to file, then starts recording.
    /// The lock ensures no gap between pre-roll flush and live recording.
    func startRecording(audioWriter: AudioFileBufferWriter? = nil) {
        lock.lock()
        // Write buffered pre-roll audio to file first (if file is provided)
        let preRollCount = _preRollBuffers.count
        let preRollFrames = _preRollFrameCount

        // Process pre-roll buffers: accumulate for streaming AND write to file
        if !_preRollBuffers.isEmpty {
            Logger.info(
                "🎬 [A2] Processing pre-roll: \(_preRollBuffers.count) buffers, frames=\(preRollFrames), duration=\(String(format: "%.3f", Double(preRollFrames) / 16_000.0))s",
                category: .audio
            )

            // Accumulate for streaming
            for buffer in _preRollBuffers {
                if let data = convertBufferToData(buffer) {
                    _accumulatedData.append(data)
                }
            }

            // Write to file when a recording file or streaming diagnostic file is active.
            if let audioWriter {
                for buffer in _preRollBuffers {
                    audioWriter.write(buffer)
                }
            }

            // If handler is already set and we have enough data, send immediately
            if let handler = _streamingHandler, _accumulatedData.count >= streamChunkSize {
                let split = streamingChunkSplit(
                    _accumulatedData,
                    chunkSize: streamChunkSize,
                    includeRemainder: false
                )
                _accumulatedData = split.remainder
                lock.unlock()
                for chunk in split.chunks {
                    Logger.info("🎬 [A3] Sending pre-roll chunk: \(chunk.count) bytes", category: .audio)
                    handler(chunk)
                }
                // Re-acquire lock for the rest of the function
                lock.lock()
            }

            // Clear pre-roll buffers after processing
            _preRollBuffers.removeAll()
            _preRollFrameCount = 0
        }

        _audioWriter = audioWriter
        _isRecording = true
        _lastSentTime = Date()
        lock.unlock()

        if preRollCount > 0 {
            Logger.debug(
                "Flushed \(preRollCount) pre-roll buffers (\(preRollFrames) frames)",
                category: .audio
            )
        }
    }

    /// Called from MainActor. Stops routing buffers to file.
    /// Buffers resume going to the pre-roll ring buffer.
    /// NOTE: Does NOT clear accumulated data - call flushAccumulatedData() to get remaining data.
    func stopRecording() {
        lock.lock()
        Logger.info("🎬 [STOP] isRecording=\(_isRecording), accumulated=\(_accumulatedData.count) bytes", category: .audio)
        _isRecording = false
        let writer = _audioWriter
        _audioWriter = nil
        // Don't clear handler or accumulated data here - let flushAccumulatedData() handle it
        lock.unlock()
        writer?.close()
    }

    /// Clear streaming state after flushing
    func clearStreamingState() {
        lock.lock()
        _streamingHandler = nil
        _accumulatedData = Data()
        lock.unlock()
    }

    /// Clear all state (used during coolDown).
    func clear() {
        lock.lock()
        _preRollBuffers.removeAll()
        _preRollFrameCount = 0
        _accumulatedData = Data()
        _isRecording = false
        let writer = _audioWriter
        _audioWriter = nil
        _streamingHandler = nil
        inputBufferCount = 0
        convertedBufferCount = 0
        convertedFrameCount = 0
        conversionFailureCount = 0
        recordedBufferCount = 0
        lock.unlock()
        writer?.close()
    }

    /// Convert AVAudioPCMBuffer to Data (16-bit PCM)
    /// The converter outputs 16-bit PCM, so we use int16ChannelData directly
    private func convertBufferToData(_ buffer: AVAudioPCMBuffer) -> Data? {
        guard buffer.frameLength > 0 else {
            Logger.debug("🎬 [CONVERT] frameLength is 0", category: .audio)
            return nil
        }

        let frameLength = Int(buffer.frameLength)
        let bytesPerSample = 2  // 16-bit = 2 bytes

        Logger.debug("🎬 [CONVERT] frameLength=\(frameLength), format=\(buffer.format)", category: .audio)

        // The converter outputs 16-bit interleaved PCM
        if let channelData = buffer.int16ChannelData {
            let totalBytes = frameLength * bytesPerSample
            Logger.debug("🎬 [CONVERT] Success: \(totalBytes) bytes", category: .audio)
            return Data(bytes: channelData[0], count: totalBytes)
        }

        Logger.debug("🎬 [CONVERT] Failed: no int16ChannelData", category: .audio)
        return nil
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
