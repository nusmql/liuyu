// Sources/LiuyuLib/Transcription/AlibabaRealtimeAdapter.swift
import Foundation
import CryptoKit
import CommonCrypto

/// Alibaba Cloud Real-time Speech Recognition Adapter
/// Uses WebSocket protocol for streaming transcription
/// Documentation: https://help.aliyun.com/document_detail/84535.html
public actor AlibabaRealtimeAdapter: WebSocketStrategy {

    public let strategyId = "alibaba-realtime"
    private var config: TranscriptionConfig?
    private var webSocketManager = WebSocketManager(
        heartbeatInterval: 0, // Disable default heartbeat
        buildHeartbeatMessage: { nil }
    )

    public init() {}

    // MARK: - WebSocketStrategy Implementation

    /// Build WebSocket URL with Alibaba-specific authentication
    /// Format: wss://nls-gateway.aliyuncs.com/ws/v1?token={token}
    nonisolated public func buildWebSocketURL(config: TranscriptionConfig) throws -> URL {
        // Generate token from API key
        let token = try generateToken(apiKey: config.apiKey)

        var components = URLComponents()
        components.scheme = "wss"
        components.host = "nls-gateway.aliyuncs.com"
        components.path = "/ws/v1"
        components.queryItems = [
            URLQueryItem(name: "token", value: token),
            URLQueryItem(name: "appkey", value: config.model)
        ]

        guard let url = components.url else {
            throw TranscriptionError.networkError("Invalid WebSocket URL")
        }

        return url
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

        // Build WebSocket URL
        let url = try buildWebSocketURL(config: config)

        // Connect using manager
        try await webSocketManager.connect(url: url)

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

    // MARK: - Token Generation

    nonisolated private func generateToken(apiKey: String) throws -> String {
        let parts = apiKey.split(separator: ":", maxSplits: 1)
        guard parts.count == 2 else {
            return apiKey
        }

        let accessKeyId = String(parts[0])
        let accessKeySecret = String(parts[1])

        let timestamp = String(Int(Date().timeIntervalSince1970))
        let signatureString = "GET\n\n\n" + timestamp + "\n/nls-gateway/ws/v1"

        guard let secretData = accessKeySecret.data(using: .utf8),
              let signatureData = signatureString.data(using: .utf8) else {
            throw TranscriptionError.apiKeyInvalid
        }

        // Use CommonCrypto for SHA1 HMAC
        var signature = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
        signatureData.withUnsafeBytes { signatureBytes in
            secretData.withUnsafeBytes { secretBytes in
                CCHmac(CCHmacAlgorithm(kCCHmacAlgSHA1),
                       secretBytes.baseAddress, secretData.count,
                       signatureBytes.baseAddress, signatureData.count,
                       &signature)
            }
        }
        let signatureBase64 = Data(signature).base64EncodedString()

        return "\(accessKeyId):\(signatureBase64):\(timestamp)"
    }
}
