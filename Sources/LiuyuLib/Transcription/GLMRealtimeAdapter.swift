import Foundation

/// GLM Realtime WebSocket transcription adapter.
///
/// This adapter uses the transcription-session path only: it streams PCM16 mono
/// microphone audio and returns input-audio transcription events. It deliberately
/// does not create model responses or play output audio.
public actor GLMRealtimeAdapter: WebSocketStrategy {
    public let strategyId = "glm-realtime"

    private var webSocketManager = WebSocketManager(
        heartbeatInterval: 0,
        connectionTimeout: 15
    )
    private var didCommitAudio = false
    private var isTranscriptionSessionReady = false

    public init() {}

    public func setDisconnectHandler(_ handler: DisconnectHandler?) async {
        await webSocketManager.setDisconnectHandler(handler)
    }

    nonisolated public func buildWebSocketURL(config: TranscriptionConfig) throws -> URL {
        if let overrideURL = Self.realtimeURL(from: config.endpoint) {
            return overrideURL
        }

        guard let url = URL(string: "wss://open.bigmodel.cn/api/paas/v4/realtime") else {
            throw TranscriptionError.networkError("Invalid GLM Realtime WebSocket URL")
        }
        return url
    }

    nonisolated public func buildWebSocketHeaders(config: TranscriptionConfig) -> [String: String] {
        [
            "Authorization": "Bearer \(config.apiKey)"
        ]
    }

    nonisolated public func buildSetupMessage(config: TranscriptionConfig) -> [String: Any]? {
        [
            "event_id": Self.eventID(),
            "client_timestamp": Self.timestampMillis(),
            "type": "transcription_session.update",
            "session": [
                "input_audio_format": "pcm",
                "input_audio_noise_reduction": [
                    "type": "near_field"
                ],
                "modalities": ["text"]
            ]
        ]
    }

    nonisolated func buildSessionUpdateMessage(config: TranscriptionConfig) -> [String: Any] {
        [
            "event_id": Self.eventID(),
            "client_timestamp": Self.timestampMillis(),
            "type": "session.update",
            "session": [
                "model": Self.realtimeModel(from: config.model),
                "modalities": ["text"],
                "voice": "tongtong",
                "input_audio_format": "pcm",
                "output_audio_format": "pcm",
                "input_audio_noise_reduction": [
                    "type": "near_field"
                ],
                "beta_fields": [
                    "chat_mode": "audio"
                ]
            ]
        ]
    }

    nonisolated public func buildAudioMessage(_ data: Data, isFinal: Bool) -> [String: Any] {
        if isFinal {
            return buildCommitMessage()
        }

        return [
            "event_id": Self.eventID(),
            "client_timestamp": Self.timestampMillis(),
            "type": "input_audio_buffer.append",
            "audio": data.base64EncodedString()
        ]
    }

    nonisolated public func parseMessage(_ message: String) -> TranscriptionResult? {
        Self.parseServerMessage(message)
    }

    nonisolated public var heartbeatInterval: TimeInterval { 0 }

    public func connect(config: TranscriptionConfig) async throws {
        didCommitAudio = false
        isTranscriptionSessionReady = false

        let url = try buildWebSocketURL(config: config)
        let headers = buildWebSocketHeaders(config: config)

        Logger.info("[GLM Realtime] connecting url=\(url.absoluteString)", category: .stt)
        try await webSocketManager.connect(url: url, headers: headers)

        await setupMessageHandler()

        Logger.info("[GLM Realtime] sending session.update model=\(Self.realtimeModel(from: config.model))", category: .stt)
        try await webSocketManager.sendJSON(buildSessionUpdateMessage(config: config))

        if let setupMessage = buildSetupMessage(config: config) {
            Logger.info("[GLM Realtime] sending transcription_session.update", category: .stt)
            try await webSocketManager.sendJSON(setupMessage)
        }

        let ready = await waitForTranscriptionSessionReady(timeout: 1)
        if ready {
            Logger.info("[GLM Realtime] transcription session ready", category: .stt)
        } else {
            Logger.warning("[GLM Realtime] transcription session ready event not observed; continuing", category: .stt)
        }
    }

    public func sendAudio(_ data: Data, isFinal: Bool) async throws {
        if !data.isEmpty {
            let message = buildAudioMessage(data, isFinal: false)
            Logger.debug("[GLM Realtime] append audio bytes=\(data.count)", category: .stt)
            let sendStart = Date()
            try await webSocketManager.sendJSON(message)
            let duration = Date().timeIntervalSince(sendStart)
            if duration >= 0.200 {
                Logger.info(
                    "[GLM Realtime] append.slow bytes=\(data.count) duration=\(Self.formatSeconds(duration))",
                    category: .stt
                )
            }
        }

        if isFinal {
            try await commitAudioBuffer()
        }
    }

    nonisolated public func receiveResults() -> AsyncStream<TranscriptionResult> {
        AsyncStream { continuation in
            Task { [weak self] in
                await self?.setupResultHandling(continuation: continuation)
            }
        }
    }

    public func disconnect() async {
        await webSocketManager.disconnect()
        didCommitAudio = false
        isTranscriptionSessionReady = false
    }

    private func commitAudioBuffer() async throws {
        guard !didCommitAudio else { return }
        didCommitAudio = true

        Logger.info("[GLM Realtime] committing input_audio_buffer", category: .stt)
        let sendStart = Date()
        try await webSocketManager.sendJSON(buildCommitMessage())
        Logger.info("[GLM Realtime] commit.sent duration=\(Self.formatSeconds(Date().timeIntervalSince(sendStart)))", category: .stt)
    }

    private nonisolated func buildCommitMessage() -> [String: Any] {
        [
            "event_id": Self.eventID(),
            "client_timestamp": Self.timestampMillis(),
            "type": "input_audio_buffer.commit"
        ]
    }

    private func setupResultHandling(continuation: AsyncStream<TranscriptionResult>.Continuation) async {
        await webSocketManager.setContinuation(continuation)
        await setupMessageHandler()
    }

    private func setupMessageHandler() async {
        await webSocketManager.setMessageHandler { text -> TranscriptionResult? in
            if let type = Self.eventType(from: text) {
                switch type {
                case "session.updated",
                     "input_audio_buffer.committed",
                     "input_audio_buffer.speech_started",
                     "input_audio_buffer.speech_stopped":
                    Logger.debug("[GLM Realtime] event=\(type)", category: .stt)
                case "transcription_session.updated",
                     "transcription.session.updated":
                    Logger.info("[GLM Realtime] event=\(type)", category: .stt)
                    Task { [weak self] in
                        await self?.handleTranscriptionSessionReady()
                    }
                case "conversation.item.input_audio_transcription.completed",
                     "conversation.item.input_audio_transcription.failed",
                     "error":
                    Logger.info("[GLM Realtime] event=\(type)", category: .stt)
                default:
                    break
                }
            }

            return Self.parseServerMessage(text)
        }
    }

    private func waitForTranscriptionSessionReady(timeout: TimeInterval) async -> Bool {
        let start = Date()
        while !isTranscriptionSessionReady {
            if Date().timeIntervalSince(start) >= timeout {
                return false
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return true
    }

    private func handleTranscriptionSessionReady() {
        isTranscriptionSessionReady = true
    }

    nonisolated static func parseServerMessage(_ message: String) -> TranscriptionResult? {
        guard let json = jsonObject(from: message),
              let type = json["type"] as? String else {
            return nil
        }

        switch type {
        case "conversation.item.input_audio_transcription.completed":
            let transcript = json["transcript"] as? String ?? ""
            Logger.info("[GLM Realtime] transcription completed chars=\(transcript.count)", category: .stt)
            return .final(transcript)

        case "conversation.item.input_audio_transcription.failed":
            let message = errorMessage(from: json) ?? "GLM Realtime transcription failed."
            Logger.error("[GLM Realtime] transcription failed: \(message)", category: .stt)
            return .error(TranscriptionError.serverError(500, message))

        case "error":
            let message = errorMessage(from: json) ?? "GLM Realtime server error."
            Logger.error("[GLM Realtime] server error: \(message)", category: .stt)
            return .error(TranscriptionError.serverError(500, message))

        default:
            return nil
        }
    }

    private nonisolated static func realtimeURL(from endpoint: String) -> URL? {
        guard !endpoint.isEmpty,
              var components = URLComponents(string: endpoint) else {
            return nil
        }

        switch components.scheme {
        case "wss", "ws":
            return components.url
        case "https":
            components.scheme = "wss"
        case "http":
            components.scheme = "ws"
        default:
            return nil
        }

        guard components.path.contains("realtime") else {
            return nil
        }
        return components.url
    }

    private nonisolated static func eventType(from message: String) -> String? {
        jsonObject(from: message)?["type"] as? String
    }

    private nonisolated static func jsonObject(from message: String) -> [String: Any]? {
        guard let data = message.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return json
    }

    private nonisolated static func errorMessage(from json: [String: Any]) -> String? {
        if let error = json["error"] as? [String: Any] {
            return error["message"] as? String
        }
        return json["message"] as? String
    }

    private nonisolated static func eventID() -> String {
        "evt_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
    }

    private nonisolated static func realtimeModel(from model: String) -> String {
        model.hasPrefix("glm-realtime") ? model : "glm-realtime-flash"
    }

    private nonisolated static func timestampMillis() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }

    private nonisolated static func formatSeconds(_ value: TimeInterval) -> String {
        String(format: "%.3fs", value)
    }
}
