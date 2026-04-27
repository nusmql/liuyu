import XCTest
@testable import LiuyuVoice

final class UtteranceBufferTests: XCTestCase {
    func testBeginIncludesConfiguredPreRollFrames() {
        var buffer = UtteranceBuffer(preRollFrameLimit: 3, tailFrameLimit: 2)

        buffer.accept(makeFrame(sequence: 1))
        buffer.accept(makeFrame(sequence: 2))
        buffer.accept(makeFrame(sequence: 3))
        buffer.accept(makeFrame(sequence: 4))

        let started = buffer.beginUtterance()

        XCTAssertEqual(started.map(\.sequence), [2, 3, 4])
        XCTAssertTrue(started.allSatisfy(\.isPreRoll))
        XCTAssertEqual(buffer.snapshot().map(\.sequence), [2, 3, 4])
    }

    func testLiveFramesContinueAfterPreRollWithoutGap() {
        var buffer = UtteranceBuffer(preRollFrameLimit: 2, tailFrameLimit: 2)

        buffer.accept(makeFrame(sequence: 10))
        buffer.accept(makeFrame(sequence: 11))
        _ = buffer.beginUtterance()
        buffer.accept(makeFrame(sequence: 12))
        buffer.accept(makeFrame(sequence: 13))

        XCTAssertEqual(buffer.snapshot().map(\.sequence), [10, 11, 12, 13])
    }

    func testEndIncludesTailFramesThenCloses() {
        var buffer = UtteranceBuffer(preRollFrameLimit: 1, tailFrameLimit: 2)

        buffer.accept(makeFrame(sequence: 1))
        _ = buffer.beginUtterance()
        buffer.accept(makeFrame(sequence: 2))
        buffer.requestEnd()
        buffer.accept(makeFrame(sequence: 3))
        XCTAssertFalse(buffer.closed)
        buffer.accept(makeFrame(sequence: 4))
        XCTAssertTrue(buffer.closed)
        buffer.accept(makeFrame(sequence: 5))

        XCTAssertEqual(buffer.snapshot().map(\.sequence), [1, 2, 3, 4])
    }

    private func makeFrame(sequence: Int64) -> VoiceAudioFrame {
        VoiceAudioFrame(
            sequence: sequence,
            timestampNanos: sequence * 1_000,
            format: .pcm16Mono16k,
            pcm16MonoData: Data([UInt8(sequence % 255), 0]),
            isPreRoll: false
        )
    }
}
