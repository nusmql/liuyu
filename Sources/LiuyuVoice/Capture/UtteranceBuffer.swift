import Foundation

public struct UtteranceBuffer: Sendable {
    private let preRollFrameLimit: Int
    private let tailFrameLimit: Int
    private var preRoll: [VoiceAudioFrame] = []
    private var utterance: [VoiceAudioFrame] = []
    private var isRecording = false
    private var tailFramesRemaining = 0
    private var isClosed = false

    public init(preRollFrameLimit: Int, tailFrameLimit: Int) {
        self.preRollFrameLimit = max(0, preRollFrameLimit)
        self.tailFrameLimit = max(0, tailFrameLimit)
    }

    @discardableResult
    public mutating func accept(_ frame: VoiceAudioFrame) -> Bool {
        guard !isClosed else { return false }

        if isRecording || tailFramesRemaining > 0 {
            utterance.append(frame)
            if !isRecording {
                tailFramesRemaining -= 1
                if tailFramesRemaining == 0 {
                    isClosed = true
                }
            }
            return true
        }

        preRoll.append(frame)
        if preRoll.count > preRollFrameLimit {
            preRoll.removeFirst(preRoll.count - preRollFrameLimit)
        }
        return true
    }

    @discardableResult
    public mutating func beginUtterance() -> [VoiceAudioFrame] {
        guard !isRecording else { return [] }

        isRecording = true
        let frames = preRoll.map { frame in
            VoiceAudioFrame(
                sequence: frame.sequence,
                timestampNanos: frame.timestampNanos,
                format: frame.format,
                pcm16MonoData: frame.pcm16MonoData,
                isPreRoll: true
            )
        }
        utterance.append(contentsOf: frames)
        preRoll.removeAll()
        return frames
    }

    public mutating func requestEnd() {
        guard isRecording else { return }
        isRecording = false
        tailFramesRemaining = tailFrameLimit
        if tailFramesRemaining == 0 {
            isClosed = true
        }
    }

    public mutating func forceClose() {
        isRecording = false
        tailFramesRemaining = 0
        isClosed = true
    }

    public func snapshot() -> [VoiceAudioFrame] {
        utterance
    }

    public var closed: Bool {
        isClosed
    }
}
