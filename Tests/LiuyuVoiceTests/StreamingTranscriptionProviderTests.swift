import XCTest
@testable import LiuyuVoice

final class StreamingTranscriptionProviderTests: XCTestCase {
    func testStreamingProviderFinishesAfterAllFramesAreSent() async throws {
        let transport = MockStreamingTransport()
        let provider = StreamingTranscriptionProvider(transport: transport, chunkFrameLimit: 2)

        try await provider.prepare(config: .init(apiKey: "key", endpoint: "mock", model: "mock"))
        try await provider.send(Self.frame(1))
        try await provider.send(Self.frame(2))
        try await provider.send(Self.frame(3))
        try await provider.finish()

        let events = await transport.snapshot()
        XCTAssertEqual(events, [.connect, .send([1, 2]), .send([3]), .finish])
    }

    private static func frame(_ sequence: Int64) -> VoiceAudioFrame {
        VoiceAudioFrame(
            sequence: sequence,
            timestampNanos: sequence,
            format: .pcm16Mono16k,
            pcm16MonoData: Data([1, 2]),
            isPreRoll: false
        )
    }
}
