import XCTest
@testable import LiuyuVoice

final class RESTTranscriptionProviderTests: XCTestCase {
    func testWAVEncoderProducesRIFFPayload() throws {
        let wavData = WAVEncoder.encodePCM16Mono(frames: [Self.frame(1), Self.frame(2)])
        let header = String(data: wavData.prefix(4), encoding: .ascii)
        let waveMarker = String(data: wavData.dropFirst(8).prefix(4), encoding: .ascii)

        XCTAssertEqual(header, "RIFF")
        XCTAssertEqual(waveMarker, "WAVE")
        XCTAssertGreaterThan(wavData.count, 44)
    }

    func testRESTProviderYieldsFinalAfterFinish() async throws {
        let recorder = RESTTranscriptionRecorder()
        let provider = RESTTranscriptionProvider(modeName: "test-rest") { data, config in
            await recorder.record(data: data, config: config)
            return "rest result"
        }

        try await provider.prepare(config: .init(apiKey: "key", endpoint: "mock", model: "mock-model"))
        try await provider.send(Self.frame(1))
        try await provider.send(Self.frame(2))

        let results = provider.results()
        try await provider.finish()

        var final: String?
        for await result in results {
            if case .final(let text) = result {
                final = text
                break
            }
        }

        let snapshot = await recorder.snapshot()
        XCTAssertEqual(String(data: snapshot.data.prefix(4), encoding: .ascii), "RIFF")
        XCTAssertEqual(snapshot.config?.model, "mock-model")
        XCTAssertEqual(final, "rest result")
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

private actor RESTTranscriptionRecorder {
    private var data = Data()
    private var config: TranscriptionProviderConfig?

    func record(data: Data, config: TranscriptionProviderConfig) {
        self.data = data
        self.config = config
    }

    func snapshot() -> (data: Data, config: TranscriptionProviderConfig?) {
        (data, config)
    }
}
