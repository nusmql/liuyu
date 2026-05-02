// Sources/LiuyuLib/Transcription/WebSocketStrategy.swift
import Foundation

/// Protocol for WebSocket-based transcription strategies
/// Provides hooks for provider-specific implementations
///
/// All methods are nonisolated because they are pure functions that don't
/// access mutable state - they just format messages for the protocol.
public protocol WebSocketStrategy: TranscriptionStrategy {
    /// Set a handler to be called when the WebSocket disconnects unexpectedly
    func setDisconnectHandler(_ handler: DisconnectHandler?) async

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

/// Delegate to monitor WebSocket connection state
private final class WebSocketDelegate: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    var onOpen: (() -> Void)?
    var onClose: ((URLSessionWebSocketTask.CloseCode, Data?) -> Void)?
    var onError: ((Error) -> Void)?

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        Logger.info("🎬 [WS-CONN] WebSocket didOpenWithProtocol: \(`protocol` ?? "none")", category: .stt)
        onOpen?()
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        Logger.info("WebSocket didCloseWith code: \(closeCode)", category: .stt)
        if let reason = reason, let reasonString = String(data: reason, encoding: .utf8) {
            Logger.info("WebSocket close reason: \(reasonString)", category: .stt)
        }
        onClose?(closeCode, reason)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error {
            Logger.error("WebSocket didCompleteWithError: \(error)", category: .stt)
            onError?(error)
        }
    }
}

/// Message handler type for parsing WebSocket messages
public typealias MessageHandler = @Sendable (String) -> TranscriptionResult?

/// Disconnect handler type
public typealias DisconnectHandler = @Sendable () -> Void

/// Manages WebSocket connection for transcription strategies
public actor WebSocketManager {
    public private(set) var webSocketTask: URLSessionWebSocketTask?
    private var resultContinuation: AsyncStream<TranscriptionResult>.Continuation?
    private var heartbeatTimer: Timer?
    public private(set) var isConnected = false

    private let buildHeartbeatMessage: @Sendable () -> [String: Any]?
    private let heartbeatInterval: TimeInterval
    private let connectionTimeout: TimeInterval
    private var webSocketDelegate: WebSocketDelegate?
    private var messageHandler: MessageHandler?
    private var disconnectHandler: DisconnectHandler?
    private var connectionContinuation: CheckedContinuation<Void, Error>?
    private var connectionTimeoutTask: Task<Void, Never>?

    public init(
        heartbeatInterval: TimeInterval = 30,
        connectionTimeout: TimeInterval = 3,
        buildHeartbeatMessage: @escaping @Sendable () -> [String: Any]? = { ["type": "ping"] }
    ) {
        self.heartbeatInterval = heartbeatInterval
        self.connectionTimeout = connectionTimeout
        self.buildHeartbeatMessage = buildHeartbeatMessage
    }

    /// Set the message handler for parsing incoming WebSocket messages
    public func setMessageHandler(_ handler: MessageHandler?) {
        self.messageHandler = handler
    }

    /// Set the disconnect handler to be called when WebSocket disconnects
    public func setDisconnectHandler(_ handler: DisconnectHandler?) {
        self.disconnectHandler = handler
    }

    /// Handle disconnect - clear state and notify handler
    private func handleDisconnect() {
        isConnected = false
        stopHeartbeat()
        if let handler = disconnectHandler {
            handler()
        }
    }

    public func connect(url: URL, headers: [String: String] = [:]) async throws {
        Logger.info("WebSocket connecting to: \(url.absoluteString)", category: .stt)

        // Create delegate for connection monitoring
        let delegate = WebSocketDelegate()
        self.webSocketDelegate = delegate

        // Create WebSocket task with custom headers
        // Use ephemeral session with delegate to monitor connection state
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = connectionTimeout
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)

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

        // Set up delegate callbacks
        delegate.onOpen = { [weak self] in
            Logger.info("🎬 [WS-DELEGATE] Connection opened", category: .stt)
            Task { [weak self] in
                await self?.completeConnection(success: true)
            }
        }
        delegate.onClose = { [weak self] code, reason in
            Logger.warning("🎬 [WS-DELEGATE] WebSocket closed with code: \(code)", category: .stt)
            Task { [weak self] in
                await self?.handleDisconnect()
            }
        }
        delegate.onError = { [weak self] error in
            Logger.error("🎬 [WS-DELEGATE] WebSocket delegate error: \(error)", category: .stt)
            Task { [weak self] in
                await self?.completeConnection(success: false, error: error)
            }
        }

        // Set up message handler
        setupMessageHandler()

        // Connect with proper timeout handling
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            // Store continuation for later resumption
            self.connectionContinuation = continuation

            // Start timeout task
            self.connectionTimeoutTask = Task { [weak self] in
                guard let self else { return }
                let timeout = self.connectionTimeout
                try? await Task.sleep(for: .seconds(timeout))
                await self.completeConnection(
                    success: false,
                    error: TranscriptionError.networkError("WebSocket connection timeout after \(Int(timeout))s")
                )
            }

            // Start WebSocket connection
            webSocketTask?.resume()
            Logger.debug("WebSocket task resumed", category: .stt)
        }
    }

    /// Complete the connection by resuming the continuation
    private func completeConnection(success: Bool, error: Error? = nil) {
        // Cancel timeout task if still running
        connectionTimeoutTask?.cancel()
        connectionTimeoutTask = nil

        // Resume continuation if not already resumed
        if let continuation = connectionContinuation {
            connectionContinuation = nil
            if success {
                isConnected = true
                continuation.resume()
            } else {
                // Cancel WebSocket task on failure
                webSocketTask?.cancel()
                let errorToThrow = error ?? TranscriptionError.networkError("WebSocket connection failed")
                continuation.resume(throwing: errorToThrow)
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
            // Check for specific error types
            let nsError = error as NSError
            Logger.error("Error domain: \(nsError.domain), code: \(nsError.code)", category: .stt)
            if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? Error {
                Logger.error("Underlying error: \(underlying)", category: .stt)
            }
            resultContinuation?.yield(.error(TranscriptionError.networkError(error.localizedDescription)))
        }
    }

    private func handleTextMessage(_ text: String) {
        // Check for connection acknowledgment first
        if text.contains("task-started") {
            Logger.info("🎬 [WS-T0] task-started received", category: .stt)
            isConnected = true
        }

        Logger.debug("WebSocket received text: \(text.prefix(200))", category: .stt)

        // Parse the message using the registered handler
        if let handler = messageHandler, let result = handler(text) {
            Logger.debug("Parsed result: \(result)", category: .stt)
            yieldResult(result)
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
