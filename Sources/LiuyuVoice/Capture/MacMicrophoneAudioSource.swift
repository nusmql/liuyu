@preconcurrency import AVFoundation
import Foundation

public actor MacMicrophoneAudioSource: AudioSource {
    private nonisolated let frameState = MicrophoneFrameState()
    private var engine: AVAudioEngine?
    private var converter: AVAudioConverter?

    public init() {}

    public func start() async throws {
        guard engine?.isRunning != true else { return }

        try await ensureMicrophonePermission()

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let inputFormat = try await waitForUsableInputFormat(inputNode: inputNode)

        guard let pcmFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: Double(VoiceAudioFormat.pcm16Mono16k.sampleRate),
            channels: AVAudioChannelCount(VoiceAudioFormat.pcm16Mono16k.channels),
            interleaved: true
        ) else {
            throw MacMicrophoneAudioSourceError.outputFormatUnavailable
        }

        guard let converter = AVAudioConverter(from: inputFormat, to: pcmFormat) else {
            throw MacMicrophoneAudioSourceError.converterUnavailable
        }

        self.engine = engine
        self.converter = converter

        installMicrophoneTap(
            on: inputNode,
            inputFormat: inputFormat,
            converter: converter,
            frameState: frameState
        )

        engine.prepare()

        do {
            try engine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            self.converter = nil
            self.engine = nil
            throw MacMicrophoneAudioSourceError.engineStartFailed(error)
        }
    }

    public func stop() async {
        guard let engine else {
            frameState.finish()
            return
        }

        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        converter = nil
        self.engine = nil
        frameState.finish()
    }

    public nonisolated func frames() -> AsyncStream<VoiceAudioFrame> {
        AsyncStream { continuation in
            frameState.setContinuation(continuation)
        }
    }

    private func ensureMicrophonePermission() async throws {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return
        case .notDetermined:
            let granted = await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    continuation.resume(returning: granted)
                }
            }
            if granted { return }
            throw MacMicrophoneAudioSourceError.microphonePermissionDenied
        case .denied, .restricted:
            throw MacMicrophoneAudioSourceError.microphonePermissionDenied
        @unknown default:
            throw MacMicrophoneAudioSourceError.microphonePermissionDenied
        }
    }

    private func waitForUsableInputFormat(inputNode: AVAudioInputNode) async throws -> AVAudioFormat {
        let maxAttempts = 40
        for _ in 0..<maxAttempts {
            let format = inputNode.outputFormat(forBus: 0)
            if format.sampleRate > 0 && format.channelCount > 0 {
                return format
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw MacMicrophoneAudioSourceError.inputFormatUnavailable
    }
}

public enum MacMicrophoneAudioSourceError: Error, LocalizedError, Sendable {
    case microphonePermissionDenied
    case inputFormatUnavailable
    case outputFormatUnavailable
    case converterUnavailable
    case engineStartFailed(Error)

    public var errorDescription: String? {
        switch self {
        case .microphonePermissionDenied:
            return "Microphone access denied."
        case .inputFormatUnavailable:
            return "Audio input format is unavailable."
        case .outputFormatUnavailable:
            return "Failed to create PCM16 mono output format."
        case .converterUnavailable:
            return "Failed to create microphone audio converter."
        case .engineStartFailed(let error):
            return "Failed to start microphone audio engine: \(error.localizedDescription)"
        }
    }
}

private final class MicrophoneFrameState: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncStream<VoiceAudioFrame>.Continuation?
    private var nextSequence: Int64 = 0

    func setContinuation(_ continuation: AsyncStream<VoiceAudioFrame>.Continuation) {
        lock.lock()
        self.continuation = continuation
        lock.unlock()
    }

    func yield(pcm16MonoData: Data, audioLevel: Float) {
        let frame: VoiceAudioFrame
        let continuation: AsyncStream<VoiceAudioFrame>.Continuation?

        lock.lock()
        frame = VoiceAudioFrame(
            sequence: nextSequence,
            timestampNanos: Int64(DispatchTime.now().uptimeNanoseconds),
            format: .pcm16Mono16k,
            pcm16MonoData: pcm16MonoData,
            isPreRoll: false,
            audioLevel: audioLevel
        )
        nextSequence += 1
        continuation = self.continuation
        lock.unlock()

        continuation?.yield(frame)
    }

    func finish() {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()

        continuation?.finish()
    }
}

private func installMicrophoneTap(
    on inputNode: AVAudioInputNode,
    inputFormat: AVAudioFormat,
    converter: AVAudioConverter,
    frameState: MicrophoneFrameState
) {
    inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { buffer, _ in
        guard let convertedBuffer = convertMicrophoneBuffer(buffer, converter: converter),
              let data = pcm16Data(from: convertedBuffer) else {
            return
        }
        frameState.yield(
            pcm16MonoData: data,
            audioLevel: normalizedAudioLevel(from: convertedBuffer)
        )
    }
}

private func convertMicrophoneBuffer(
    _ buffer: AVAudioPCMBuffer,
    converter: AVAudioConverter
) -> AVAudioPCMBuffer? {
    let sampleRateRatio = Double(VoiceAudioFormat.pcm16Mono16k.sampleRate) / buffer.format.sampleRate
    let outputFrameCapacity = AVAudioFrameCount(ceil(Double(buffer.frameLength) * sampleRateRatio))
    guard let convertedBuffer = AVAudioPCMBuffer(
        pcmFormat: converter.outputFormat,
        frameCapacity: outputFrameCapacity
    ) else {
        return nil
    }

    final class ConversionFlag: @unchecked Sendable {
        var hasData = false
    }
    let flag = ConversionFlag()
    var error: NSError?

    converter.convert(to: convertedBuffer, error: &error) { _, status in
        if flag.hasData {
            status.pointee = .noDataNow
            return nil
        }
        flag.hasData = true
        status.pointee = .haveData
        return buffer
    }

    guard error == nil, convertedBuffer.frameLength > 0 else {
        return nil
    }
    return convertedBuffer
}

private func pcm16Data(from buffer: AVAudioPCMBuffer) -> Data? {
    guard buffer.frameLength > 0, let channelData = buffer.int16ChannelData else {
        return nil
    }

    let bytesPerSample = MemoryLayout<Int16>.size
    return Data(bytes: channelData[0], count: Int(buffer.frameLength) * bytesPerSample)
}

private func normalizedAudioLevel(from buffer: AVAudioPCMBuffer) -> Float {
    guard buffer.frameLength > 0, let channelData = buffer.int16ChannelData else {
        return 0
    }

    let frameCount = Int(buffer.frameLength)
    let samples = UnsafeBufferPointer(start: channelData[0], count: frameCount)
    var rms: Float = 0
    for sample in samples {
        let normalizedSample = Float(sample) / Float(Int16.max)
        rms += normalizedSample * normalizedSample
    }
    rms = sqrt(rms / Float(max(frameCount, 1)))

    let db = 20 * log10(max(rms, 1e-6))
    return max(0, min(1, (db + 50) / 50))
}
