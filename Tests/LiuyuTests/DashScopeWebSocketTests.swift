// Tests/LiuyuTests/DashScopeWebSocketTests.swift
import XCTest
@testable import LiuyuLib

/// Tests for DashScope WebSocket real-time ASR
final class DashScopeWebSocketTests: XCTestCase {

    /// Test that WebSocket URL is correctly built
    func testBuildWebSocketURL() throws {
        let adapter = AlibabaRealtimeAdapter()
        let config = TranscriptionConfig(
            apiKey: "sk-test123",
            endpoint: "https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions",
            model: "fun-asr-realtime",
            language: nil,
            timeout: 30
        )

        let url = try adapter.buildWebSocketURL(config: config)

        XCTAssertEqual(url.scheme, "wss")
        XCTAssertEqual(url.host, "dashscope.aliyuncs.com")
        XCTAssertEqual(url.path, "/api-ws/v1/inference")
    }

    /// Test that Bearer token header is correctly built
    func testBuildWebSocketHeaders() {
        let adapter = AlibabaRealtimeAdapter()
        let config = TranscriptionConfig(
            apiKey: "sk-test123",
            endpoint: "",
            model: "fun-asr-realtime",
            language: nil,
            timeout: 30
        )

        let headers = adapter.buildWebSocketHeaders(config: config)

        XCTAssertEqual(headers["Authorization"], "Bearer sk-test123")
    }

    /// Test run-task message format
    func testBuildSetupMessage() {
        let adapter = AlibabaRealtimeAdapter()
        let config = TranscriptionConfig(
            apiKey: "sk-test123",
            endpoint: "",
            model: "fun-asr-realtime",
            language: nil,
            timeout: 30
        )

        guard let message = adapter.buildSetupMessage(config: config) else {
            XCTFail("Setup message should not be nil")
            return
        }

        // Verify header
        guard let header = message["header"] as? [String: Any] else {
            XCTFail("Header should exist")
            return
        }
        XCTAssertEqual(header["action"] as? String, "run-task")
        XCTAssertEqual(header["streaming"] as? String, "duplex")
        XCTAssertNotNil(header["task_id"])

        // Verify payload
        guard let payload = message["payload"] as? [String: Any] else {
            XCTFail("Payload should exist")
            return
        }
        XCTAssertEqual(payload["task_group"] as? String, "audio")
        XCTAssertEqual(payload["task"] as? String, "asr")
        XCTAssertEqual(payload["function"] as? String, "recognition")
        XCTAssertEqual(payload["model"] as? String, "fun-asr-realtime")

        // Verify parameters
        guard let parameters = payload["parameters"] as? [String: Any] else {
            XCTFail("Parameters should exist")
            return
        }
        XCTAssertEqual(parameters["format"] as? String, "pcm")
        XCTAssertEqual(parameters["sample_rate"] as? Int, 16000)
    }

    /// Test parsing task-started event
    func testParseTaskStartedEvent() {
        let adapter = AlibabaRealtimeAdapter()
        let message = """
        {
            "header": {
                "task_id": "test-task-id",
                "event": "task-started",
                "attributes": {}
            },
            "payload": {}
        }
        """

        let result = adapter.parseMessage(message)
        XCTAssertNil(result) // task-started doesn't produce a transcription result
    }

    /// Test parsing result-generated event (partial result)
    func testParseResultGeneratedPartial() {
        let adapter = AlibabaRealtimeAdapter()
        let message = """
        {
            "header": {
                "task_id": "test-task-id",
                "event": "result-generated",
                "attributes": {}
            },
            "payload": {
                "output": {
                    "sentence": {
                        "begin_time": 170,
                        "text": "你好",
                        "sentence_end": false
                    }
                }
            }
        }
        """

        guard let result = adapter.parseMessage(message) else {
            XCTFail("Should parse partial result")
            return
        }

        if case .partial(let text) = result {
            XCTAssertEqual(text, "你好")
        } else {
            XCTFail("Expected partial result")
        }
    }

    /// Test parsing result-generated event (final result)
    func testParseResultGeneratedFinal() {
        let adapter = AlibabaRealtimeAdapter()
        let message = """
        {
            "header": {
                "task_id": "test-task-id",
                "event": "result-generated",
                "attributes": {}
            },
            "payload": {
                "output": {
                    "sentence": {
                        "begin_time": 170,
                        "end_time": 920,
                        "text": "你好世界",
                        "sentence_end": true
                    }
                },
                "usage": {
                    "duration": 3
                }
            }
        }
        """

        guard let result = adapter.parseMessage(message) else {
            XCTFail("Should parse final result")
            return
        }

        if case .final(let text) = result {
            XCTAssertEqual(text, "你好世界")
        } else {
            XCTFail("Expected final result")
        }
    }

    /// Test parsing task-finished event
    func testParseTaskFinishedEvent() {
        let adapter = AlibabaRealtimeAdapter()
        let message = """
        {
            "header": {
                "task_id": "test-task-id",
                "event": "task-finished",
                "attributes": {}
            },
            "payload": {
                "output": {}
            }
        }
        """

        let result = adapter.parseMessage(message)
        // task-finished returns empty final result to signal completion
        if case .final(let text) = result {
            XCTAssertEqual(text, "")
        } else {
            XCTFail("Expected .final(\"\") for task-finished event")
        }
    }

    /// Test parsing task-failed event
    func testParseTaskFailedEvent() {
        let adapter = AlibabaRealtimeAdapter()
        let message = """
        {
            "header": {
                "task_id": "test-task-id",
                "event": "task-failed",
                "error_code": "CLIENT_ERROR",
                "error_message": "request timeout after 23 seconds.",
                "attributes": {}
            },
            "payload": {}
        }
        """

        guard let result = adapter.parseMessage(message) else {
            XCTFail("Should parse error")
            return
        }

        if case .error(let error) = result {
            XCTAssertTrue(error.localizedDescription.contains("request timeout"))
        } else {
            XCTFail("Expected error result")
        }
    }

    /// Test that task_id is generated correctly (32 chars, no dashes)
    func testTaskIdFormat() {
        let adapter = AlibabaRealtimeAdapter()
        let config = TranscriptionConfig(
            apiKey: "sk-test123",
            endpoint: "",
            model: "fun-asr-realtime",
            language: nil,
            timeout: 30
        )

        guard let message = adapter.buildSetupMessage(config: config),
              let header = message["header"] as? [String: Any],
              let taskId = header["task_id"] as? String else {
            XCTFail("Should have task_id")
            return
        }

        XCTAssertEqual(taskId.count, 32)
        XCTAssertFalse(taskId.contains("-"))
    }
}
