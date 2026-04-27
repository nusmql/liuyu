import XCTest
@testable import LiuyuVoice

final class AudioFixturePipelineTests: XCTestCase {
    func testAudioFixtureSourceDecodesWAVIntoFrames() async throws {
        let pcmChunks = [
            Data([0x01, 0x00, 0x02, 0x00]),
            Data([0x03, 0x00, 0x04, 0x00]),
            Data([0x05, 0x00, 0x06, 0x00])
        ]
        let wavData = WAVEncoder.encodePCM16Mono(frames: Self.frames(from: pcmChunks))
        let source = try AudioFixtureSource(wavData: wavData, samplesPerFrame: 2)

        var decoded: [VoiceAudioFrame] = []
        for await frame in source.frames() {
            decoded.append(frame)
        }

        XCTAssertEqual(decoded.map(\.sequence), [0, 1, 2])
        XCTAssertEqual(decoded.map(\.pcm16MonoData), pcmChunks)
        XCTAssertEqual(decoded.map(\.format), [.pcm16Mono16k, .pcm16Mono16k, .pcm16Mono16k])
        XCTAssertEqual(decoded.map(\.timestampNanos), [0, 125_000, 250_000])
    }

    func testProbeProviderReceivesExactFixtureAudioFromCoordinator() async throws {
        let pcmChunks = [
            Data([0x10, 0x00, 0x11, 0x00]),
            Data([0x12, 0x00, 0x13, 0x00]),
            Data([0x14, 0x00, 0x15, 0x00]),
            Data([0x16, 0x00, 0x17, 0x00])
        ]
        let wavData = WAVEncoder.encodePCM16Mono(frames: Self.frames(from: pcmChunks))
        let source = try AudioFixtureSource(wavData: wavData, samplesPerFrame: 2)
        let provider = ProbeTranscriptionProvider(finalText: "ok")
        let coordinator = VoiceSessionCoordinator(
            source: source,
            provider: provider,
            configuration: VoiceSessionConfiguration(preRollFrameLimit: 0, tailFrameLimit: 0)
        )
        let events = coordinator.events()

        async let collectedEvents = Self.collectEvents(from: events)
        try await coordinator.start(config: .init(apiKey: "key", endpoint: "probe", model: "probe"))
        try await provider.waitUntilSentFrameCount(4)
        await coordinator.stop(reason: .userReleased)

        let snapshot = await provider.snapshot()
        let finalTexts = try await collectedEvents.compactMap { event -> String? in
            guard case .final(let text, _) = event else { return nil }
            return text
        }

        XCTAssertEqual(snapshot.sentFrames.map(\.sequence), [0, 1, 2, 3])
        XCTAssertEqual(snapshot.sentFrames.map(\.pcm16MonoData), pcmChunks)
        XCTAssertEqual(snapshot.concatenatedPCM, pcmChunks.reduce(Data(), +))
        XCTAssertEqual(snapshot.events, ["prepare", "send:0", "send:1", "send:2", "send:3", "finish"])
        XCTAssertEqual(finalTexts, ["ok"])
    }

    private static func frames(from pcmChunks: [Data]) -> [VoiceAudioFrame] {
        pcmChunks.enumerated().map { index, data in
            VoiceAudioFrame(
                sequence: Int64(index),
                timestampNanos: Int64(index),
                format: .pcm16Mono16k,
                pcm16MonoData: data,
                isPreRoll: false
            )
        }
    }

    private static func collectEvents(
        from stream: AsyncStream<VoiceSessionEvent>,
        timeout: Duration = .seconds(1)
    ) async throws -> [VoiceSessionEvent] {
        try await withThrowingTaskGroup(of: [VoiceSessionEvent].self) { group in
            group.addTask {
                var events: [VoiceSessionEvent] = []
                for await event in stream {
                    events.append(event)
                }
                return events
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw AudioFixturePipelineError.timedOut
            }

            let events = try await group.next()!
            group.cancelAll()
            return events
        }
    }
}

private enum AudioFixturePipelineError: Error {
    case timedOut
}
