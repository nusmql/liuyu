// Sources/LiuyuLib/Transcription/WebSocketStrategy.swift
import Foundation

/// Protocol for WebSocket-based transcription strategies
/// Provides hooks for provider-specific implementations
///
/// All methods are nonisolated because they are pure functions that don't
/// access mutable state - they just format messages for the protocol.
public protocol WebSocketStrategy: TranscriptionStrategy {
    /// Build the WebSocket URL with authentication
    nonisolated func buildWebSocketURL(config: TranscriptionConfig) throws -> URL

    /// Build HTTP headers for WebSocket connection (e.g., Authorization)
    nonisolated func buildWebSocketHeaders(config: TranscriptionConfig) -> [String: String]

    /// Build the initial setup message sent after connection
    nonisolated func buildSetupMessage(config: TranscriptionConfig) -> [String: Any]?

    /// Build audio data message
    nonisolated func buildAudioMessage(_ data: Data, isFinal: Bool) -> [String: Any]

    /// Parse WebSocket message into TranscriptionResult
    nonisolated func parseMessage(_ message: String) -> TranscriptionResult?

    /// Heartbeat interval in seconds (0 to disable)
    nonisolated var heartbeatInterval: TimeInterval { get }

    /// Build heartbeat message
    nonisolated func buildHeartbeatMessage() -> [String: Any]?
}

// MARK: - Default Implementations

public extension WebSocketStrategy {
    var supportsStreaming: Bool { true }

    var heartbeatInterval: TimeInterval { 30 }

    func buildWebSocketHeaders(config: TranscriptionConfig) -> [String: String] {
        return [:]
    }

    func buildHeartbeatMessage() -> [String: Any]? {
        return ["type": "ping"]
    }
}

// MARK: - WebSocket Manager

/// Manages WebSocket connection for transcription strategies
public actor WebSocketManager {
    public private(set) var webSocketTask: URLSessionWebSocketTask?
    private var resultContinuation: AsyncStream<TranscriptionResult>.Continuation?
    private var heartbeatTimer: Timer?
    public private(set) var isConnected = false

    private let buildHeartbeatMessage: @Sendable () -> [String: Any]?
    private let heartbeatInterval: TimeInterval

    public init(
        heartbeatInterval: TimeInterval = 30,
        buildHeartbeatMessage: @escaping @Sendable () -> [String: Any]? = { ["type": "ping"] }
    ) {
        self.heartbeatInterval = heartbeatInterval
        self.buildHeartbeatMessage = buildHeartbeatMessage
    }

    public func connect(url: URL, headers: [String: String] = [:]) async throws {
        Logger.info("WebSocket connecting to: \(url.absoluteString)", category: .stt)

        // Create WebSocket task with custom headers
        let session = URLSession(configuration: .default)

        if headers.isEmpty {
            webSocketTask = session.webSocketTask(with: url)
        } else {
            // Create URLRequest with custom headers for authentication
            var request = URLRequest(url: url)
            for (key, value) in headers {
                request.setValue(value, forHTTPHeaderField: key)
            }
            Logger.debug("WebSocket headers: \(headers.keys.joined(separator: ", "))", category: .stt)
            webSocketTask = session.webSocketTask(with: request)
        }

        // Set up message handler
        setupMessageHandler()

        // Connect
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            webSocketTask?.resume()
            Logger.debug("WebSocket task resumed", category: .stt)

            // Wait for connection to establish
            Task { [weak self] in
                guard let self = self else {
                    continuation.resume(throwing: TranscriptionError.networkError("WebSocket connection timeout"))
                    return
                }
                try? await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds (increased from 1)
                let connected = await self.isConnected
                Logger.debug("WebSocket connection check: isConnected=\(connected)", category: .stt)
                if connected {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: TranscriptionError.networkError("WebSocket connection timeout"))
                }
            }
        }
    }

    public func sendJSON(_ object: [String: Any]) async throws {
        let data = try JSONSerialization.data(withJSONObject: object)
        guard let text = String(data: data, encoding: .utf8) else {
            throw TranscriptionError.decodingFailed
        }
        try await webSocketTask?.send(.string(text))
    }

    public func sendData(_ data: Data) async throws {
        try await webSocketTask?.send(.data(data))
    }

    public func disconnect() {
        stopHeartbeat()

        if let task = webSocketTask {
            task.cancel(with: .normalClosure, reason: nil)
            webSocketTask = nil
        }

        isConnected = false
        resultContinuation?.finish()
        resultContinuation = nil
    }

    public func setContinuation(_ continuation: AsyncStream<TranscriptionResult>.Continuation) {
        self.resultContinuation = continuation
    }

    public func yieldResult(_ result: TranscriptionResult) {
        resultContinuation?.yield(result)
    }

    // MARK: - Private Methods

    private func setupMessageHandler() {
        webSocketTask?.receive { [weak self] result in
            Task { [weak self] in
                await self?.handleMessage(result: result)
            }
        }
    }

    private func handleMessage(result: Result<URLSessionWebSocketTask.Message, Error>) {
        switch result {
        case .success(let message):
            switch message {
            case .string(let text):
                handleTextMessage(text)
            case .data(let data):
                handleBinaryMessage(data)
            @unknown default:
                break
            }

            // Continue receiving
            setupMessageHandler()

        case .failure(let error):
            Logger.error("WebSocket error: \(error)", category: .stt)
            resultContinuation?.yield(.error(TranscriptionError.networkError(error.localizedDescription)))
        }
    }

    private func handleTextMessage(_ text: String) {
        Logger.debug("WebSocket received text: \(text.prefix(200))", category: .stt)

        // Check for connection acknowledgment
        // Support various provider acknowledgment messages:
        // - Generic: "connected", "ready"
        // - DashScope: "task-started"
        if text.contains("connected") || text.contains("ready") || text.contains("task-started") {
            Logger.info("WebSocket connection acknowledged", category: .stt)
            isConnected = true
            return
        }
    }

    private func handleBinaryMessage(_ data: Data) {
        // Most providers use JSON text messages
        // Override in strategy if binary messages are used
    }

    // MARK: - Heartbeat

    private func startHeartbeat() {
        guard heartbeatInterval > 0 else { return }

        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: heartbeatInterval, repeats: true) { [weak self] _ in
            Task { [weak self] in
                guard let self = self else { return }
                if let message = self.buildHeartbeatMessage() {
                    try? await self.sendJSON(message)
                }
            }
        }
    }

    private func stopHeartbeat() {
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
    }
}
