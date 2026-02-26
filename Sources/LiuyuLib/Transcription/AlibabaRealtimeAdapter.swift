// Sources/LiuyuLib/Transcription/AlibabaRealtimeAdapter.swift
import Foundation

/// Alibaba Cloud DashScope Real-time Speech Recognition Adapter
/// Uses WebSocket protocol with Bearer token authentication
/// Documentation: https://help.aliyun.com/document_detail/84535.html
public actor AlibabaRealtimeAdapter: WebSocketStrategy {

    public let strategyId = "alibaba-realtime"
    private var config: TranscriptionConfig?
    private var taskId: String = ""
    private var webSocketManager = WebSocketManager(
        heartbeatInterval: 0 // DashScope doesn't require heartbeat
    )

    public init() {}

    // MARK: - WebSocketStrategy Implementation

    /// Build WebSocket URL for DashScope API
    /// Format: wss://dashscope.aliyuncs.com/api-ws/v1/inference
    nonisolated public func buildWebSocketURL(config: TranscriptionConfig) throws -> URL {
        var components = URLComponents()
        components.scheme = "wss"
        components.host = "dashscope.aliyuncs.com"
        components.path = "/api-ws/v1/inference"

        guard let url = components.url else {
            throw TranscriptionError.networkError("Invalid WebSocket URL")
        }

        return url
    }

    /// Build HTTP headers with Bearer token authentication
    nonisolated public func buildWebSocketHeaders(config: TranscriptionConfig) -> [String: String] {
        return [
            "Authorization": "Bearer \(config.apiKey)" // Format: Bearer <api-key>
        ]
    }

    /// Build run-task message to start recognition
    nonisolated public func buildSetupMessage(config: TranscriptionConfig) -> [String: Any]? {
        // Generate 32-character task ID (UUID without dashes, truncated to 32 chars)
        let taskId = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(32).description

        return [
            "header": [
                "action": "run-task",
                "task_id": taskId,
                "streaming": "duplex"
            ],
            "payload": [
                "task_group": "audio",
                "task": "asr",
                "function": "recognition",
                "model": config.model.isEmpty ? "fun-asr-realtime" : config.model,
                "parameters": [
                    "sample_rate": 16000,
                    "format": "wav"
                ],
                "input": [:]
            ]
        ]
    }

    /// Audio is sent as binary chunks, not JSON messages
    nonisolated public func buildAudioMessage(_ data: Data, isFinal: Bool) -> [String: Any] {
        // DashScope expects raw binary audio data, not base64 JSON
        // This method is not used; we send Data directly via sendData
        return [:]
    }

    /// Build finish-task message
    private func buildFinishTaskMessage() -> [String: Any] {
        return [
            "header": [
                "action": "finish-task",
                "task_id": taskId,
                "streaming": "duplex"
            ],
            "payload": [
                "input": [:]
            ]
        ]
    }

    /// Parse DashScope response message
    nonisolated public func parseMessage(_ message: String) -> TranscriptionResult? {
        guard let data = message.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        guard let header = json["header"] as? [String: Any],
              let event = header["event"] as? String else {
            return nil
        }

        switch event {
        case "task-started":
            // Task started successfully, ready to send audio
            return nil

        case "result-generated":
            // Recognition result received
            guard let payload = json["payload"] as? [String: Any],
                  let output = payload["output"] as? [String: Any],
                  let sentence = output["sentence"] as? [String: Any],
                  let text = sentence["text"] as? String else {
                return nil
            }
            // Check if this is a final result
            let isFinal = sentence["end_time"] != nil
            return isFinal ? .final(text) : .partial(text)

        case "task-finished":
            // Task completed successfully
            return nil

        case "task-failed":
            let errorMessage = header["error_message"] as? String ?? "Unknown error"
            return .error(TranscriptionError.serverError(500, errorMessage))

        default:
            return nil
        }
    }

    nonisolated public var heartbeatInterval: TimeInterval { 0 }

    // MARK: - TranscriptionStrategy Implementation

    public func connect(config: TranscriptionConfig) async throws {
        self.config = config

        // Generate task ID (32 characters, UUID without dashes)
        self.taskId = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(32).description
        Logger.info("Generated task ID: \(taskId)", category: .stt)

        // Build WebSocket URL and headers
        let url = try buildWebSocketURL(config: config)
        let headers = buildWebSocketHeaders(config: config)

        // Connect using manager with Bearer token headers
        Logger.info("Connecting to DashScope WebSocket...", category: .stt)
        try await webSocketManager.connect(url: url, headers: headers)
        Logger.info("WebSocket connected, sending run-task...", category: .stt)

        // Send run-task message
        if let setupMessage = buildSetupMessage(config: config) {
            Logger.debug("Sending run-task: \(setupMessage)", category: .stt)
            try await webSocketManager.sendJSON(setupMessage)
            Logger.info("Run-task sent, waiting for task-started...", category: .stt)
        }
    }

    public func sendAudio(_ data: Data, isFinal: Bool) async throws {
        // DashScope expects raw binary audio chunks, not JSON messages
        // Send in chunks (16KB each) with 100ms delay between chunks
        let chunkSize = 16 * 1024
        var offset = 0

        while offset < data.count {
            let end = min(offset + chunkSize, data.count)
            let chunk = data.subdata(in: offset..<end)

            // Send raw binary data
            try await webSocketManager.sendData(chunk)

            offset = end

            // Small delay between chunks to simulate streaming
            if offset < data.count {
                try await Task.sleep(nanoseconds: 100_000_000) // 100ms
            }
        }

        // Send finish-task message when audio stream ends
        if isFinal {
            // Build finish-task message inline to avoid Sendable issues
            let finishMessage: [String: Any] = [
                "header": [
                    "action": "finish-task",
                    "task_id": taskId,
                    "streaming": "duplex"
                ],
                "payload": [
                    "input": [:]
                ]
            ]
            try await webSocketManager.sendJSON(finishMessage)
        }
    }

    nonisolated public func receiveResults() -> AsyncStream<TranscriptionResult> {
        AsyncStream { continuation in
            Task { [weak self] in
                await self?.setupResultHandling(continuation: continuation)
            }
        }
    }

    private func setupResultHandling(continuation: AsyncStream<TranscriptionResult>.Continuation) async {
        await webSocketManager.setContinuation(continuation)
        // Set message handler to parse incoming WebSocket messages
        await webSocketManager.setMessageHandler { [weak self] text in
            // Access the parseMessage method through a nonisolated context
            AlibabaRealtimeAdapter.parseMessageStatic(text)
        }
    }

    /// Static helper for message parsing to avoid actor isolation issues
    private static func parseMessageStatic(_ message: String) -> TranscriptionResult? {
        guard let data = message.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        guard let header = json["header"] as? [String: Any],
              let event = header["event"] as? String else {
            return nil
        }

        switch event {
        case "task-started":
            return nil

        case "result-generated":
            guard let payload = json["payload"] as? [String: Any],
                  let output = payload["output"] as? [String: Any],
                  let sentence = output["sentence"] as? [String: Any],
                  let text = sentence["text"] as? String,
                  !text.isEmpty else {
                return nil
            }
            let isFinal = sentence["sentence_end"] as? Bool ?? false
            return isFinal ? .final(text) : .partial(text)

        case "task-finished":
            return nil

        case "task-failed":
            let errorMessage = header["error_message"] as? String ?? "Unknown error"
            return .error(TranscriptionError.serverError(500, errorMessage))

        default:
            return nil
        }
    }

    public func disconnect() async {
        await webSocketManager.disconnect()
        config = nil
    }
}
