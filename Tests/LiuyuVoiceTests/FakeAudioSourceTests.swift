import XCTest
@testable import LiuyuVoice

final class FakeAudioSourceTests: XCTestCase {
    func testFakeAudioSourceEmitsFramesInOrder() async {
        let source = FakeAudioSource(frames: [
            makeFrame(sequence: 1),
            makeFrame(sequence: 2),
            makeFrame(sequence: 3)
        ])

        var received: [Int64] = []
        for await frame in source.frames() {
            received.append(frame.sequence)
        }

        XCTAssertEqual(received, [1, 2, 3])
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
