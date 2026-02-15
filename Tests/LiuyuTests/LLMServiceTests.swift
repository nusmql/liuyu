// Tests/LiuyuTests/LLMServiceTests.swift
import XCTest
import Foundation
@testable import LiuyuLib

final class LLMServiceTests: XCTestCase {

    private func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: config)
    }

    func testSuccessfulChat() async throws {
        MockURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200,
                httpVersion: nil, headerFields: nil
            )!
            let json = """
            {"choices":[{"message":{"content":"Edited text here."}}]}
            """
            return (response, json.data(using: .utf8)!)
        }

        let service = LLMService(
            apiKey: "sk-test",
            endpoint: "https://api.openai.com/v1/chat/completions",
            model: "gpt-4o-mini",
            session: makeSession()
        )

        let result = try await service.chat(system: "You are helpful.", user: "Fix this text.")
        XCTAssertEqual(result, "Edited text here.")
    }

    func testInvalidApiKey() async throws {
        MockURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 401,
                httpVersion: nil, headerFields: nil
            )!
            return (response, #"{"error":{"message":"Invalid key"}}"#.data(using: .utf8)!)
        }

        let service = LLMService(
            apiKey: "sk-bad",
            endpoint: "https://api.openai.com/v1/chat/completions",
            model: "gpt-4o-mini",
            session: makeSession()
        )

        do {
            _ = try await service.chat(system: "test", user: "test")
            XCTFail("Expected error")
        } catch let error as LLMError {
            if case .apiKeyInvalid = error {} else {
                XCTFail("Expected apiKeyInvalid, got \(error)")
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
            return (response, #"{"choices":[{"message":{"content":"ok"}}]}"#.data(using: .utf8)!)
        }

        let service = LLMService(
            apiKey: "sk-verify",
            endpoint: "https://api.openai.com/v1/chat/completions",
            model: "gpt-4o-mini",
            session: makeSession()
        )

        _ = try await service.chat(system: "sys", user: "usr")

        let request = try XCTUnwrap(capturedRequest)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-verify")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")

        let body: Data
        if let httpBody = request.httpBody {
            body = httpBody
        } else if let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            let bufferSize = 1024
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
            defer { buffer.deallocate() }
            while stream.hasBytesAvailable {
                let read = stream.read(buffer, maxLength: bufferSize)
                if read > 0 { data.append(buffer, count: read) }
                else { break }
            }
            stream.close()
            body = data
        } else {
            XCTFail("No request body found")
            return
        }
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["model"] as? String, "gpt-4o-mini")
        let messages = try XCTUnwrap(json["messages"] as? [[String: String]])
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages[0]["role"], "system")
        XCTAssertEqual(messages[0]["content"], "sys")
        XCTAssertEqual(messages[1]["role"], "user")
        XCTAssertEqual(messages[1]["content"], "usr")
    }

    func testEmptyResponse() async throws {
        MockURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200,
                httpVersion: nil, headerFields: nil
            )!
            return (response, #"{"choices":[{"message":{"content":""}}]}"#.data(using: .utf8)!)
        }

        let service = LLMService(
            apiKey: "sk-test",
            endpoint: "https://api.openai.com/v1/chat/completions",
            model: "gpt-4o-mini",
            session: makeSession()
        )

        do {
            _ = try await service.chat(system: "test", user: "test")
            XCTFail("Expected error")
        } catch let error as LLMError {
            if case .emptyResponse = error {} else {
                XCTFail("Expected emptyResponse, got \(error)")
            }
        }
    }
}
