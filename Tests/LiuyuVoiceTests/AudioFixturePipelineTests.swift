import XCTest
@testable import LiuyuVoice

final class AudioFixturePipelineTests: XCTestCase {
    private let recordedFixtureNames = [
        "start-immediate-001.wav",
        "start-after-silence-001.wav",
        "short-utterance-001.wav",
        "tail-particle-ne-001.wav",
        "normal-sentence-001.wav",
        "far-mic-001.wav"
    ]

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
        let expectedEvents = ["prepare", "send:0", "send:1", "send:2", "send:3", "finish"]
        XCTAssertEqual(Array(snapshot.events.prefix(expectedEvents.count)), expectedEvents)
        XCTAssertTrue(snapshot.events.count == expectedEvents.count || snapshot.events == expectedEvents + ["cancel"])
        XCTAssertEqual(finalTexts, ["ok"])
    }

    func testRecordedFixturesReachProbeProviderWithoutFrameLoss() async throws {
        for fixtureName in recordedFixtureNames {
            let wavData = try Data(contentsOf: Self.recordedFixtureURL(named: fixtureName))
            let expectedSource = try AudioFixtureSource(wavData: wavData, samplesPerFrame: 320)
            let expectedFrames = await Self.collectFrames(from: expectedSource.frames())
            let source = try AudioFixtureSource(wavData: wavData, samplesPerFrame: 320)
            let provider = ProbeTranscriptionProvider(finalText: fixtureName)
            let coordinator = VoiceSessionCoordinator(
                source: source,
                provider: provider,
                configuration: VoiceSessionConfiguration(preRollFrameLimit: 0, tailFrameLimit: 0)
            )
            let events = coordinator.events()

            async let collectedEvents = Self.collectEvents(from: events)
            try await coordinator.start(config: .init(apiKey: "key", endpoint: "probe", model: "probe"))
            try await provider.waitUntilSentFrameCount(expectedFrames.count)
            await coordinator.stop(reason: .userReleased)

            let snapshot = await provider.snapshot()
            let finalTexts = try await collectedEvents.compactMap { event -> String? in
                guard case .final(let text, _) = event else { return nil }
                return text
            }

            XCTAssertGreaterThan(expectedFrames.count, 0, fixtureName)
            XCTAssertEqual(expectedFrames.map(\.sequence), Array(0..<Int64(expectedFrames.count)), fixtureName)
            XCTAssertEqual(snapshot.sentFrames, expectedFrames, fixtureName)
            XCTAssertEqual(snapshot.concatenatedPCM, expectedFrames.reduce(Data()) { partial, frame in
                var data = partial
                data.append(frame.pcm16MonoData)
                return data
            }, fixtureName)
            XCTAssertEqual(snapshot.events.first, "prepare", fixtureName)
            XCTAssertEqual(snapshot.events.last, "finish", fixtureName)
            XCTAssertEqual(snapshot.events.filter { $0.hasPrefix("send:") }.count, expectedFrames.count, fixtureName)
            XCTAssertEqual(finalTexts, [fixtureName], fixtureName)
        }
    }

    func testRecordedFixturesContainAudibleSignal() async throws {
        for fixtureName in recordedFixtureNames {
            let wavData = try Data(contentsOf: Self.recordedFixtureURL(named: fixtureName))
            let source = try AudioFixtureSource(wavData: wavData, samplesPerFrame: 320)
            let frames = await Self.collectFrames(from: source.frames())
            let stats = Self.audioStats(for: frames)

            XCTAssertGreaterThan(stats.sampleCount, 16_000, fixtureName)
            XCTAssertGreaterThan(stats.maxAbsSample, 1_000, fixtureName)
            XCTAssertGreaterThan(stats.normalizedRMS, 0.005, fixtureName)
        }
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

    private static func collectFrames(from stream: AsyncStream<VoiceAudioFrame>) async -> [VoiceAudioFrame] {
        var frames: [VoiceAudioFrame] = []
        for await frame in stream {
            frames.append(frame)
        }
        return frames
    }

    private static func recordedFixtureURL(named name: String) throws -> URL {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let url = root.appendingPathComponent("Tests/Fixtures/Audio").appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw AudioFixturePipelineError.missingFixture(url.path)
        }
        return url
    }

    private static func audioStats(for frames: [VoiceAudioFrame]) -> AudioStats {
        var sampleCount = 0
        var maxAbsSample = 0
        var squareSum = 0.0

        for frame in frames {
            let data = frame.pcm16MonoData
            var offset = 0
            while offset + 1 < data.count {
                let raw = UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
                let sample = Int(Int16(bitPattern: raw))
                let absSample = abs(sample)
                sampleCount += 1
                maxAbsSample = max(maxAbsSample, absSample)
                let normalized = Double(sample) / 32768.0
                squareSum += normalized * normalized
                offset += 2
            }
        }

        let normalizedRMS = sampleCount > 0 ? sqrt(squareSum / Double(sampleCount)) : 0
        return AudioStats(
            sampleCount: sampleCount,
            maxAbsSample: maxAbsSample,
            normalizedRMS: normalizedRMS
        )
    }
}

private struct AudioStats {
    let sampleCount: Int
    let maxAbsSample: Int
    let normalizedRMS: Double
}

private enum AudioFixturePipelineError: Error {
    case timedOut
    case missingFixture(String)
}
