import XCTest
import LiuyuVoice
@testable import LiuyuLib

final class GLMRealtimeAdapterTests: XCTestCase {
    func testBuildSetupMessageUsesTranscriptionSessionOnly() {
        let adapter = GLMRealtimeAdapter()
        let message = adapter.buildSetupMessage(config: .init(
            apiKey: "glm-key",
            endpoint: "wss://open.bigmodel.cn/api/paas/v4/realtime",
            model: "glm-realtime-flash"
        ))

        XCTAssertEqual(message?["type"] as? String, "transcription_session.update")
        let session = message?["session"] as? [String: Any]
        XCTAssertEqual(session?["input_audio_format"] as? String, "pcm")
        XCTAssertEqual(session?["modalities"] as? [String], ["text"])
        XCTAssertNil(session?["turn_detection"])
    }

    func testBuildSessionUpdateSetsRealtimeModelAndTextOnlyMode() {
        let adapter = GLMRealtimeAdapter()
        let message = adapter.buildSessionUpdateMessage(config: .init(
            apiKey: "glm-key",
            endpoint: "wss://open.bigmodel.cn/api/paas/v4/realtime",
            model: "glm-realtime-air"
        ))

        XCTAssertEqual(message["type"] as? String, "session.update")
        let session = message["session"] as? [String: Any]
        XCTAssertEqual(session?["model"] as? String, "glm-realtime-air")
        XCTAssertEqual(session?["modalities"] as? [String], ["text"])
        XCTAssertEqual(session?["input_audio_format"] as? String, "pcm")
    }

    func testBuildSessionUpdateCoercesLegacyGLMASRModelToRealtimeFlash() {
        let adapter = GLMRealtimeAdapter()
        let message = adapter.buildSessionUpdateMessage(config: .init(
            apiKey: "glm-key",
            endpoint: "wss://open.bigmodel.cn/api/paas/v4/realtime",
            model: "glm-asr-2512"
        ))

        let session = message["session"] as? [String: Any]
        XCTAssertEqual(session?["model"] as? String, "glm-realtime-flash")
    }

    func testBuildAudioAppendMessageBase64EncodesPCM() {
        let adapter = GLMRealtimeAdapter()
        let message = adapter.buildAudioMessage(Data([1, 2, 3]), isFinal: false)

        XCTAssertEqual(message["type"] as? String, "input_audio_buffer.append")
        XCTAssertEqual(message["audio"] as? String, Data([1, 2, 3]).base64EncodedString())
    }

    func testBuildFinalAudioMessageCommitsBuffer() {
        let adapter = GLMRealtimeAdapter()
        let message = adapter.buildAudioMessage(Data(), isFinal: true)

        XCTAssertEqual(message["type"] as? String, "input_audio_buffer.commit")
    }

    func testRealtimeURLUsesExplicitRealtimeEndpoint() throws {
        let adapter = GLMRealtimeAdapter()

        let url = try adapter.buildWebSocketURL(config: .init(
            apiKey: "glm-key",
            endpoint: "https://open.bigmodel.cn/api/paas/v4/realtime",
            model: "glm-realtime-flash"
        ))

        XCTAssertEqual(url.absoluteString, "wss://open.bigmodel.cn/api/paas/v4/realtime")
    }

    func testRealtimeURLIgnoresLegacyTranscriptionEndpoint() throws {
        let adapter = GLMRealtimeAdapter()

        let url = try adapter.buildWebSocketURL(config: .init(
            apiKey: "glm-key",
            endpoint: "https://open.bigmodel.cn/api/paas/v4/audio/transcriptions",
            model: "glm-realtime-flash"
        ))

        XCTAssertEqual(url.absoluteString, "wss://open.bigmodel.cn/api/paas/v4/realtime")
    }

    func testParseTranscriptionCompletedAsFinal() {
        let message = """
        {
          "event_id": "event1",
          "type": "conversation.item.input_audio_transcription.completed",
          "transcript": "我已经到地铁站了"
        }
        """

        let result = GLMRealtimeAdapter.parseServerMessage(message)

        guard case .final(let text) = result else {
            return XCTFail("Expected final transcription")
        }
        XCTAssertEqual(text, "我已经到地铁站了")
    }

    func testParseTranscriptionSessionUpdatedDoesNotEmitResult() {
        let message = """
        {
          "event_id": "event_5678",
          "type": "transcription_session.updated",
          "session": {
            "input_audio_format": "pcm16"
          }
        }
        """

        XCTAssertNil(GLMRealtimeAdapter.parseServerMessage(message))
    }

    func testParseTranscriptionFailureAsNoSpeechDetected() {
        let message = """
        {
          "type": "conversation.item.input_audio_transcription.failed",
          "error": {
            "message": "asr_no_result"
          }
        }
        """

        let result = GLMRealtimeAdapter.parseServerMessage(message)

        guard case .error(.noSpeechDetected) = result else {
            return XCTFail("Expected noSpeechDetected, got \(String(describing: result))")
        }
    }

    func testParseTranscriptionFailureAsServerError() {
        let message = """
        {
          "type": "conversation.item.input_audio_transcription.failed",
          "error": {
            "message": "upstream unavailable"
          }
        }
        """

        let result = GLMRealtimeAdapter.parseServerMessage(message)

        guard case .error(let error) = result else {
            return XCTFail("Expected transcription error")
        }
        XCTAssertTrue(error.localizedDescription.contains("upstream unavailable"))
    }

    func testTransportMapsEmptyFinalToFailure() async {
        let stream = AsyncStream<TranscriptionResult> { continuation in
            continuation.yield(.final(""))
            continuation.finish()
        }

        var mapped: [TranscriptionProviderResult] = []
        for await result in GLMRealtimeTransport.mapAdapterResults(stream) {
            mapped.append(result)
        }

        XCTAssertEqual(mapped, [.failure("No transcription result returned by GLM Realtime.")])
    }
}
