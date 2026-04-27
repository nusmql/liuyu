import Foundation

public protocol AudioSource: Sendable {
    func frames() -> AsyncStream<VoiceAudioFrame>
    func start() async throws
    func stop() async
}
