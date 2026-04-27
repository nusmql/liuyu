import Foundation

public struct VoiceAudioFormat: Sendable, Equatable {
    public let sampleRate: Int
    public let channels: Int
    public let bitDepth: Int

    public init(sampleRate: Int, channels: Int, bitDepth: Int) {
        self.sampleRate = sampleRate
        self.channels = channels
        self.bitDepth = bitDepth
    }

    public static let pcm16Mono16k = VoiceAudioFormat(sampleRate: 16_000, channels: 1, bitDepth: 16)
}
