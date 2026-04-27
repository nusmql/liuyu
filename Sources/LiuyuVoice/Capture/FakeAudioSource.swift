import Foundation

public actor FakeAudioSource: AudioSource {
    private nonisolated let scriptedFrames: [VoiceAudioFrame]

    public init(frames: [VoiceAudioFrame]) {
        self.scriptedFrames = frames
    }

    public func start() async throws {}

    public func stop() async {}

    public nonisolated func frames() -> AsyncStream<VoiceAudioFrame> {
        let frames = scriptedFrames
        return AsyncStream { continuation in
            for frame in frames {
                continuation.yield(frame)
            }
            continuation.finish()
        }
    }
}
