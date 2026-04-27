import XCTest
@testable import LiuyuVoice

final class VoiceAudioFormatTests: XCTestCase {
    func testDefaultPortableFormatIsPcm16Mono16k() {
        XCTAssertEqual(VoiceAudioFormat.pcm16Mono16k.sampleRate, 16_000)
        XCTAssertEqual(VoiceAudioFormat.pcm16Mono16k.channels, 1)
        XCTAssertEqual(VoiceAudioFormat.pcm16Mono16k.bitDepth, 16)
    }
}
