import XCTest
@testable import LiuyuLib

final class EditPipelineStateTests: XCTestCase {
    func testVoiceEditShowsTranscribingAfterRecordingStops() {
        XCTAssertEqual(editStateAfterRecordingStops(hasExistingText: true), .transcribing)
    }

    func testNewDictationShowsTranscribingAfterRecordingStops() {
        XCTAssertEqual(editStateAfterRecordingStops(hasExistingText: false), .transcribing)
    }

    func testVoiceEditShowsEditingOnlyAfterInstructionTranscriptionCompletes() {
        XCTAssertEqual(editStateAfterTranscriptionCompletes(hasExistingText: true), .editing)
    }

    func testStreamingPartialKeepsExistingTextDuringVoiceEdit() {
        XCTAssertEqual(
            streamingPartialTextUpdate(hadExistingTextAtRecordingStart: true, partialText: "make it shorter"),
            .keepExistingText
        )
    }

    func testStreamingPartialReplacesTextForNewDictation() {
        XCTAssertEqual(
            streamingPartialTextUpdate(hadExistingTextAtRecordingStart: false, partialText: "hello"),
            .replaceText("hello")
        )
    }

    func testLocalNoSpeechRequiresPeakBelowThreshold() {
        XCTAssertTrue(isLocalNoSpeech(peakAudioLevel: 0.01, threshold: 0.06))
        XCTAssertFalse(isLocalNoSpeech(peakAudioLevel: 0.06, threshold: 0.06))
        XCTAssertFalse(isLocalNoSpeech(peakAudioLevel: 0.12, threshold: 0.06))
    }

    func testAllSilentStreamingStopEndsLocallyInsteadOfWaitingForProvider() {
        let silentPCM = pcm16Data(repeating: 0, sampleCount: 16_000)
        let level = normalizedPCM16RMSAudioLevel(silentPCM)

        XCTAssertEqual(level, 0, accuracy: 0.0001)
        XCTAssertEqual(
            streamingStopDecision(peakAudioLevel: level, threshold: 0.06),
            .localNoSpeech
        )
    }

    func testAudibleStreamingStopStillSendsFinalToProvider() {
        let audiblePCM = pcm16Data(repeating: 8_192, sampleCount: 16_000)
        let level = normalizedPCM16RMSAudioLevel(audiblePCM)

        XCTAssertGreaterThan(level, 0.06)
        XCTAssertEqual(
            streamingStopDecision(peakAudioLevel: level, threshold: 0.06),
            .sendFinalToProvider
        )
    }

    func testSilentWAVAudioLevelEndsLocallyInsteadOfWaitingForProvider() throws {
        let silentPCM = pcm16Data(repeating: 0, sampleCount: 16_000)
        let wavData = makePCM16WAV(pcmData: silentPCM)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("liuyu-silent-\(UUID().uuidString).wav")
        try wavData.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertEqual(pcm16DataFromWAV(wavData), silentPCM)
        let level = try XCTUnwrap(normalizedWAVAudioLevel(at: url))
        XCTAssertEqual(level, 0, accuracy: 0.0001)
        XCTAssertEqual(
            streamingStopDecision(peakAudioLevel: level, threshold: 0.06),
            .localNoSpeech
        )
    }

    func testGLMRealtimeUsesGLMRESTFallbackParams() throws {
        let params = try XCTUnwrap(streamingRESTFallbackParams(
            apiKey: "glm-key",
            apiFormat: .glmRealtime,
            language: "zh"
        ))

        XCTAssertEqual(params.apiKey, "glm-key")
        XCTAssertEqual(params.endpoint, "https://open.bigmodel.cn/api/paas/v4/audio/transcriptions")
        XCTAssertEqual(params.model, "glm-asr-2512")
        XCTAssertEqual(params.apiFormat, .whisperMultipart)
        XCTAssertEqual(params.language, "zh")
    }

    func testNonRealtimeStreamingDoesNotUseEditWindowRESTFallback() {
        XCTAssertNil(streamingRESTFallbackParams(
            apiKey: "key",
            apiFormat: .whisperMultipart,
            language: nil
        ))
        XCTAssertNil(streamingRESTFallbackParams(
            apiKey: "key",
            apiFormat: .alibabaRealtime,
            language: nil
        ))
        XCTAssertNil(streamingRESTFallbackParams(
            apiKey: "key",
            apiFormat: .iflytekIAT,
            language: nil
        ))
    }

    func testWebSocketStreamingFormatIncludesIFlytekIAT() {
        XCTAssertTrue(isWebSocketStreamingFormat(.glmRealtime))
        XCTAssertTrue(isWebSocketStreamingFormat(.alibabaRealtime))
        XCTAssertTrue(isWebSocketStreamingFormat(.tencentRealtime))
        XCTAssertTrue(isWebSocketStreamingFormat(.iflytekIAT))

        XCTAssertFalse(isWebSocketStreamingFormat(.whisperMultipart))
        XCTAssertFalse(isWebSocketStreamingFormat(.glmMultipartEventStream))
        XCTAssertFalse(isWebSocketStreamingFormat(.chatCompletionsAudio))
    }

    func testStreamingProvidersChooseProviderSpecificStartOrder() {
        XCTAssertTrue(shouldConnectBeforeRecordingStart(.glmRealtime))
        XCTAssertTrue(shouldConnectBeforeRecordingStart(.alibabaRealtime))
        XCTAssertTrue(shouldConnectBeforeRecordingStart(.tencentRealtime))
        XCTAssertFalse(shouldConnectBeforeRecordingStart(.iflytekIAT))
        XCTAssertFalse(shouldConnectBeforeRecordingStart(.whisperMultipart))
        XCTAssertFalse(shouldConnectBeforeRecordingStart(.glmMultipartEventStream))
        XCTAssertFalse(shouldConnectBeforeRecordingStart(.chatCompletionsAudio))
    }

    func testOnlyGLMRealtimeUsesIdlePrewarm() {
        XCTAssertTrue(shouldPrewarmStreamingSession(.glmRealtime))
        XCTAssertFalse(shouldPrewarmStreamingSession(.alibabaRealtime))
        XCTAssertFalse(shouldPrewarmStreamingSession(.tencentRealtime))
        XCTAssertFalse(shouldPrewarmStreamingSession(.iflytekIAT))
        XCTAssertFalse(shouldPrewarmStreamingSession(.whisperMultipart))
        XCTAssertFalse(shouldPrewarmStreamingSession(.glmMultipartEventStream))
        XCTAssertFalse(shouldPrewarmStreamingSession(.chatCompletionsAudio))
    }

    func testStopDuringStreamingStartupIsQueuedBeforeRecordingBegins() {
        XCTAssertTrue(shouldQueueStreamingStartupStop(editState: .idle, hasStreamingStartup: true))
        XCTAssertTrue(shouldQueueStreamingStartupStop(editState: .connecting, hasStreamingStartup: true))
        XCTAssertFalse(shouldQueueStreamingStartupStop(editState: .idle, hasStreamingStartup: false))
        XCTAssertFalse(shouldQueueStreamingStartupStop(editState: .connecting, hasStreamingStartup: false))
        XCTAssertFalse(shouldQueueStreamingStartupStop(editState: .recording(audioLevel: 0), hasStreamingStartup: true))
        XCTAssertFalse(shouldQueueStreamingStartupStop(editState: .transcribing, hasStreamingStartup: true))
        XCTAssertFalse(shouldQueueStreamingStartupStop(editState: .editing, hasStreamingStartup: true))
    }

    func testVisualAudioLevelIsClampedAndQuantized() {
        XCTAssertEqual(visualAudioLevel(-0.1), 0)
        XCTAssertEqual(visualAudioLevel(0.03), 0.05)
        XCTAssertEqual(visualAudioLevel(0.52), 0.5)
        XCTAssertEqual(visualAudioLevel(1.2), 1)
    }
}

private func pcm16Data(repeating sample: Int16, sampleCount: Int) -> Data {
    var data = Data()
    data.reserveCapacity(sampleCount * 2)
    for _ in 0..<sampleCount {
        var littleEndian = sample.littleEndian
        data.append(Data(bytes: &littleEndian, count: MemoryLayout<Int16>.size))
    }
    return data
}

private func makePCM16WAV(pcmData: Data) -> Data {
    let sampleRate: UInt32 = 16_000
    let channels: UInt16 = 1
    let bitsPerSample: UInt16 = 16
    let bytesPerSample = UInt32(bitsPerSample / 8)
    let byteRate = sampleRate * UInt32(channels) * bytesPerSample
    let blockAlign = channels * (bitsPerSample / 8)
    let dataSize = UInt32(pcmData.count)
    let riffSize = UInt32(36) + dataSize

    var data = Data()
    data.appendASCII("RIFF")
    data.appendLittleEndian(riffSize)
    data.appendASCII("WAVE")
    data.appendASCII("fmt ")
    data.appendLittleEndian(UInt32(16))
    data.appendLittleEndian(UInt16(1))
    data.appendLittleEndian(channels)
    data.appendLittleEndian(sampleRate)
    data.appendLittleEndian(byteRate)
    data.appendLittleEndian(blockAlign)
    data.appendLittleEndian(bitsPerSample)
    data.appendASCII("data")
    data.appendLittleEndian(dataSize)
    data.append(pcmData)
    return data
}

private extension Data {
    mutating func appendASCII(_ string: String) {
        append(string.data(using: .ascii)!)
    }

    mutating func appendLittleEndian(_ value: UInt16) {
        var littleEndian = value.littleEndian
        append(Data(bytes: &littleEndian, count: MemoryLayout<UInt16>.size))
    }

    mutating func appendLittleEndian(_ value: UInt32) {
        var littleEndian = value.littleEndian
        append(Data(bytes: &littleEndian, count: MemoryLayout<UInt32>.size))
    }
}
