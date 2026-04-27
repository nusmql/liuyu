import XCTest
@testable import LiuyuVoice

final class MockTranscriptionProviderTests: XCTestCase {
    func testMockProviderRecordsSendBeforeFinishOrder() async throws {
        let provider = MockTranscriptionProvider(finalText: "hello")
        try await provider.prepare(config: .init(apiKey: "key", endpoint: "mock", model: "mock"))
        try await provider.send(makeFrame(sequence: 1))
        try await provider.send(makeFrame(sequence: 2))
        try await provider.finish()

        let state = await provider.snapshot()
        XCTAssertEqual(state.sentSequences, [1, 2])
        XCTAssertTrue(state.finished)
        XCTAssertLessThan(state.lastSendOrder!, state.finishOrder!)
    }

    private func makeFrame(sequence: Int64) -> VoiceAudioFrame {
        VoiceAudioFrame(
            sequence: sequence,
            timestampNanos: sequence,
            format: .pcm16Mono16k,
            pcm16MonoData: Data([1, 2]),
            isPreRoll: false
        )
    }
}
