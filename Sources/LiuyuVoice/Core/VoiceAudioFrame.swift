import Foundation

public struct VoiceAudioFrame: Sendable, Equatable {
    public let sequence: Int64
    public let timestampNanos: Int64
    public let format: VoiceAudioFormat
    public let pcm16MonoData: Data
    public let isPreRoll: Bool

    public init(
        sequence: Int64,
        timestampNanos: Int64,
        format: VoiceAudioFormat,
        pcm16MonoData: Data,
        isPreRoll: Bool
    ) {
        self.sequence = sequence
        self.timestampNanos = timestampNanos
        self.format = format
        self.pcm16MonoData = pcm16MonoData
        self.isPreRoll = isPreRoll
    }
}
