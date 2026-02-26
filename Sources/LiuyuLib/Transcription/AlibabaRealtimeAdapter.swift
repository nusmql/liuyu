// Sources/LiuyuLib/Transcription/AlibabaRealtimeAdapter.swift
import Foundation

/// Alibaba Cloud DashScope Real-time Speech Recognition Adapter
/// Uses WebSocket protocol with Bearer token authentication
/// Documentation: https://help.aliyun.com/document_detail/84535.html
public actor AlibabaRealtimeAdapter: WebSocketStrategy {

    public let strategyId = "alibaba-realtime"
    private var config: TranscriptionConfig?
    private var webSocketManager = WebSocketManager(
        heartbeatInterval: 30, // Enable heartbeat for DashScope
        buildHeartbeatMessage: {
            return [
                "type": "ping"
            ]
        }
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
            "Authorization": "Bearer \(config.apiKey)",
            "Content-Type": "application/json"
        ]
    }

    /// Build Alibaba-specific setup message
    nonisolated public func buildSetupMessage(config: TranscriptionConfig) -> [String: Any]? {
        return [
            "header": [
                "message_id": UUID().uuidString,
                "task_id": UUID().uuidString,
                "namespace": "SpeechTranscriber",
                "name": "StartTranscription"
            ],
            "payload": [
                "format": "wav",
                "sample_rate": 16000,
                "enable_intermediate_result": true,
                "enable_punctuation_prediction": true,
                "enable_inverse_text_normalization": true,
                "max_sentence_silence": 800
            ]
        ]
    }

    /// Build audio data message in Alibaba format
    nonisolated public func buildAudioMessage(_ data: Data, isFinal: Bool) -> [String: Any] {
        var message: [String: Any] = [
            "header": [
                "message_id": UUID().uuidString,
                "namespace": "SpeechTranscriber",
                "name": "RunTranscription"
            ],
            "payload": [
                "audio": data.base64EncodedString()
            ]
        ]

        if isFinal {
            message["payload"] = [
                "audio": "",
                "completed": true
            ]
        }

        return message
    }

    /// Parse Alibaba-specific response message
    nonisolated public func parseMessage(_ message: String) -> TranscriptionResult? {
        guard let data = message.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        guard let header = json["header"] as? [String: Any],
              let name = header["name"] as? String else {
            return nil
        }

        switch name {
        case "TranscriptionResultChanged":
            guard let payload = json["payload"] as? [String: Any],
                  let text = payload["result"] as? String else {
                return nil
            }
            return .partial(text)

        case "SentenceEnd":
            guard let payload = json["payload"] as? [String: Any],
                  let text = payload["result"] as? String else {
                return nil
            }
            return .final(text)

        case "TranscriptionCompleted":
            return nil

        case "TaskFailed":
            guard let payload = json["payload"] as? [String: Any],
                  let errorMessage = payload["message"] as? String else {
                return .error(TranscriptionError.serverError(500, "Unknown error"))
            }
            return .error(TranscriptionError.serverError(500, errorMessage))

        default:
            return nil
        }
    }

    nonisolated public var heartbeatInterval: TimeInterval { 0 }

    // MARK: - TranscriptionStrategy Implementation

    public func connect(config: TranscriptionConfig) async throws {
        self.config = config

        // Build WebSocket URL and headers
        let url = try buildWebSocketURL(config: config)
        let headers = buildWebSocketHeaders(config: config)

        // Connect using manager with Bearer token headers
        try await webSocketManager.connect(url: url, headers: headers)

        // Send setup message
        if let setupMessage = buildSetupMessage(config: config) {
            try await webSocketManager.sendJSON(setupMessage)
        }
    }

    public func sendAudio(_ data: Data, isFinal: Bool) async throws {
        // Send in chunks
        let chunkSize = 16 * 1024
        var offset = 0

        while offset < data.count {
            let end = min(offset + chunkSize, data.count)
            let chunk = data.subdata(in: offset..<end)
            let isLastChunk = (end >= data.count) && isFinal

            let message = buildAudioMessage(chunk, isFinal: isLastChunk)
            try await webSocketManager.sendJSON(message)

            offset = end

            if offset < data.count {
                try await Task.sleep(nanoseconds: 100_000_000)
            }
        }

        if isFinal {
            try await webSocketManager.sendJSON(["type": "end"])
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
    }

    public func disconnect() async {
        await webSocketManager.disconnect()
        config = nil
    }
}
