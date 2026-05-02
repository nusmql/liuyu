// Tests/LiuyuTests/TranscriptionServiceTests.swift
import XCTest
@testable import LiuyuLib

class MockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

final class TranscriptionServiceTests: XCTestCase {

    func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: config)
    }

    private enum ResultCollectionError: Error {
        case timedOut
    }

    private func collectResults(
        from stream: AsyncStream<TranscriptionResult>,
        timeout: Duration = .seconds(1)
    ) async throws -> [TranscriptionResult] {
        try await withThrowingTaskGroup(of: [TranscriptionResult].self) { group in
            group.addTask {
                var results: [TranscriptionResult] = []
                for await result in stream {
                    results.append(result)
                }
                return results
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw ResultCollectionError.timedOut
            }

            let results = try await group.next()!
            group.cancelAll()
            return results
        }
    }

    func testSuccessfulTranscription() async throws {
        MockURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200,
                httpVersion: nil, headerFields: nil
            )!
            let json = #"{"text": "Hello world"}"#
            return (response, json.data(using: .utf8)!)
        }

        let service = TranscriptionService(
            apiKey: "sk-test",
            endpoint: "https://api.openai.com/v1/audio/transcriptions",
            session: makeSession()
        )

        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("test.m4a")
        try Data([0x00]).write(to: tempURL)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let result = try await service.transcribe(audioFileURL: tempURL)
        XCTAssertEqual(result, "Hello world")
    }

    func testInvalidApiKey() async throws {
        MockURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 401,
                httpVersion: nil, headerFields: nil
            )!
            let json = #"{"error": {"message": "Invalid API key"}}"#
            return (response, json.data(using: .utf8)!)
        }

        let service = TranscriptionService(
            apiKey: "sk-bad",
            endpoint: "https://api.openai.com/v1/audio/transcriptions",
            session: makeSession()
        )

        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("test.m4a")
        try Data([0x00]).write(to: tempURL)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        do {
            _ = try await service.transcribe(audioFileURL: tempURL)
            XCTFail("Expected apiKeyInvalid error")
        } catch let error as TranscriptionError {
            if case .apiKeyInvalid = error {
                // expected
            } else {
                XCTFail("Expected apiKeyInvalid, got \(error)")
            }
        }
    }

    func testEmptyTranscription() async throws {
        MockURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200,
                httpVersion: nil, headerFields: nil
            )!
            let json = #"{"text": ""}"#
            return (response, json.data(using: .utf8)!)
        }

        let service = TranscriptionService(
            apiKey: "sk-test",
            endpoint: "https://api.openai.com/v1/audio/transcriptions",
            session: makeSession()
        )

        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("test.m4a")
        try Data([0x00]).write(to: tempURL)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        do {
            _ = try await service.transcribe(audioFileURL: tempURL)
            XCTFail("Expected noSpeechDetected error")
        } catch let error as TranscriptionError {
            if case .noSpeechDetected = error {
                // expected
            } else {
                XCTFail("Expected noSpeechDetected, got \(error)")
            }
        }
    }

    func testRequestFormat() async throws {
        var capturedRequest: URLRequest?

        MockURLProtocol.handler = { request in
            capturedRequest = request
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200,
                httpVersion: nil, headerFields: nil
            )!
            return (response, #"{"text": "test"}"#.data(using: .utf8)!)
        }

        let service = TranscriptionService(
            apiKey: "sk-verify",
            endpoint: "https://api.openai.com/v1/audio/transcriptions",
            language: "en",
            session: makeSession()
        )

        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("test.m4a")
        try Data([0x00]).write(to: tempURL)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        _ = try await service.transcribe(audioFileURL: tempURL)

        let request = try XCTUnwrap(capturedRequest)
        XCTAssertEqual(request.url?.absoluteString, "https://api.openai.com/v1/audio/transcriptions")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-verify")
        let contentType = try XCTUnwrap(request.value(forHTTPHeaderField: "Content-Type"))
        XCTAssertTrue(contentType.contains("multipart/form-data"))
    }

    func testGLMEventStreamRequestAndTranscriptDeltas() async throws {
        var capturedRequest: URLRequest?
        var capturedBody: Data?
        MockURLProtocol.handler = { request in
            capturedRequest = request
            capturedBody = Self.requestBodyData(from: request)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "text/event-stream"]
            )!
            let stream = """
            data: {"type":"transcript.text.delta","delta":"你"}

            data: {"type":"transcript.text.delta","delta":"好"}

            data: [DONE]

            """
            return (response, Data(stream.utf8))
        }

        let service = TranscriptionService(
            apiKey: "glm-test",
            endpoint: "https://open.bigmodel.cn/api/paas/v4/audio/transcriptions",
            model: "glm-asr-2512",
            apiFormat: .glmMultipartEventStream,
            session: makeSession()
        )

        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("test-\(UUID().uuidString).wav")
        try Data([0x00]).write(to: tempURL)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let result = try await service.transcribe(audioFileURL: tempURL)

        let request = try XCTUnwrap(capturedRequest)
        let body = try XCTUnwrap(capturedBody)
        XCTAssertEqual(result, "你好")
        XCTAssertEqual(request.url?.absoluteString, "https://open.bigmodel.cn/api/paas/v4/audio/transcriptions")
        XCTAssertNotNil(body.range(of: Data(#"name="stream""#.utf8)))
        XCTAssertNotNil(body.range(of: Data("true".utf8)))
    }

    func testRESTStrategyBuffersFinalResultBeforeResultsStreamIsSubscribed() async throws {
        MockURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200,
                httpVersion: nil, headerFields: nil
            )!
            return (response, #"{"text": "Buffered hello"}"#.data(using: .utf8)!)
        }

        let strategy = RESTStrategy(apiFormat: .whisperMultipart, session: makeSession())
        try await strategy.connect(config: TranscriptionConfig(
            apiKey: "sk-test",
            endpoint: "https://api.openai.com/v1/audio/transcriptions",
            model: "whisper-1"
        ))

        try await strategy.sendAudio(Data([0x00]), isFinal: true)

        let results = try await collectResults(from: strategy.receiveResults())

        XCTAssertEqual(results.count, 1)
        guard case .final("Buffered hello") = results.first else {
            return XCTFail("Expected buffered final result, got \(String(describing: results.first))")
        }
    }

    func testStreamingSessionSendsFinalAfterQueuedAudioFlushCompletes() async throws {
        let strategy = OrderedStreamingStrategy(sendDelay: .milliseconds(50))
        let session = StreamingTranscriptionSession(
            strategy: strategy,
            config: TranscriptionConfig(apiKey: "key", endpoint: "wss://example.test/realtime", model: "test")
        )

        async let firstSend: Void = session.sendAudioChunk(Data([0x01]), isFinal: false)
        async let secondSend: Void = session.sendAudioChunk(Data([0x02]), isFinal: false)

        try await Task.sleep(for: .milliseconds(10))

        async let connect: Void = session.connect()

        try await Task.sleep(for: .milliseconds(10))

        async let finalSend: Void = session.sendAudioChunk(Data(), isFinal: true)

        _ = try await (firstSend, secondSend, finalSend, connect)

        let events = await strategy.snapshot()
        XCTAssertEqual(events.first, "connect")
        XCTAssertEqual(events.last, "send:empty:final")
        XCTAssertEqual(Set(events.dropFirst().dropLast()), Set(["send:01:audio", "send:02:audio"]))
    }

    private static func requestBodyData(from request: URLRequest) -> Data? {
        if let body = request.httpBody {
            return body
        }
        guard let stream = request.httpBodyStream else {
            return nil
        }

        stream.open()
        defer { stream.close() }

        var data = Data()
        let bufferSize = 4096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }

        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: bufferSize)
            if read > 0 {
                data.append(buffer, count: read)
            } else {
                break
            }
        }
        return data
    }
}

private actor OrderedStreamingStrategy: TranscriptionStrategy {
    let strategyId = "ordered-streaming-test"
    let supportsStreaming = true

    private let sendDelay: Duration
    private var events: [String] = []

    init(sendDelay: Duration) {
        self.sendDelay = sendDelay
    }

    func connect(config: TranscriptionConfig) async throws {
        events.append("connect")
    }

    func sendAudio(_ data: Data, isFinal: Bool) async throws {
        let label = data.first.map { String(format: "%02X", $0) } ?? "empty"
        events.append("send:\(label):\(isFinal ? "final" : "audio")")
        try await Task.sleep(for: sendDelay)
    }

    nonisolated func receiveResults() -> AsyncStream<TranscriptionResult> {
        AsyncStream { continuation in
            continuation.finish()
        }
    }

    func disconnect() async {}

    func snapshot() -> [String] {
        events
    }
}
