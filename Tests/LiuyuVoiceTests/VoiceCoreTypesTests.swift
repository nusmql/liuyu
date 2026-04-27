import XCTest
@testable import LiuyuVoice

final class VoiceCoreTypesTests: XCTestCase {
    func testAudioFrameCarriesSequenceFormatAndData() {
        let format = VoiceAudioFormat(sampleRate: 16_000, channels: 1, bitDepth: 16)
        let frame = VoiceAudioFrame(
            sequence: 7,
            timestampNanos: 1_000,
            format: format,
            pcm16MonoData: Data([1, 2, 3, 4]),
            isPreRoll: true
        )

        XCTAssertEqual(frame.sequence, 7)
        XCTAssertEqual(frame.format.sampleRate, 16_000)
        XCTAssertEqual(frame.pcm16MonoData.count, 4)
        XCTAssertTrue(frame.isPreRoll)
    }
}
