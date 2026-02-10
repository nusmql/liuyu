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
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-verify")
        let contentType = try XCTUnwrap(request.value(forHTTPHeaderField: "Content-Type"))
        XCTAssertTrue(contentType.contains("multipart/form-data"))
    }
}
