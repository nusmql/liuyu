// Sources/LiuyuLib/Transcription/TranscriptionService.swift
import Foundation

public enum TranscriptionError: Error, LocalizedError, Sendable {
    case apiKeyInvalid
    case apiKeyMissing
    case rateLimited
    case serverError(Int, String)
    case noSpeechDetected
    case networkError(String)
    case decodingFailed
    case streamingNotSupported

    public var errorDescription: String? {
        switch self {
        case .apiKeyInvalid: return "Invalid API key. Check Settings."
        case .apiKeyMissing: return "No API key configured. Open Settings to add one."
        case .rateLimited: return "Rate limited. Try again in a moment."
        case .serverError(let code, let msg): return "API error (\(code)): \(msg)"
        case .noSpeechDetected: return "No speech detected."
        case .networkError(let msg): return "Network error: \(msg)"
        case .decodingFailed: return "Failed to decode API response."
        case .streamingNotSupported: return "Streaming not supported by this provider."
        }
    }
}

/// Streaming transcription session for real-time audio
/// Used by WebSocket-based strategies to receive audio chunks as they arrive
/// This class is an actor to ensure thread-safe access to connection state
public actor StreamingTranscriptionSession {
    private let strategy: TranscriptionStrategy
    private let config: TranscriptionConfig
    private var isConnected = false
    private var queuedChunks: [QueuedChunk] = []
    private var isDrainingQueuedChunks = false

    private struct QueuedChunk {
        let data: Data
        let isFinal: Bool
        let continuation: CheckedContinuation<Void, Error>
    }

    init(strategy: TranscriptionStrategy, config: TranscriptionConfig) {
        self.strategy = strategy
        self.config = config
    }

    /// Connect to the transcription service
    public func connect() async throws {
        guard !isConnected else { return }
        do {
            try await strategy.connect(config: config)
            isConnected = true
            try await drainQueuedChunksIfPossible()
        } catch {
            failQueuedChunks(error)
            throw error
        }
    }

    /// Send an audio chunk for real-time transcription
    /// - Parameters:
    ///   - data: Audio chunk (typically ~300ms of 16kHz 16-bit PCM)
    ///   - isFinal: Whether this is the final chunk (end of recording)
    public func sendAudioChunk(_ data: Data, isFinal: Bool) async throws {
        try await withCheckedThrowingContinuation { continuation in
            queuedChunks.append(QueuedChunk(data: data, isFinal: isFinal, continuation: continuation))
            Task { [weak self] in
                try? await self?.drainQueuedChunksIfPossible()
            }
        }
    }

    /// Receive transcription results as a stream
    /// For WebSocket: yields partial results during streaming, final result at end
    /// For REST: yields final result only
    /// This is nonisolated because AsyncStream is Sendable and the strategy handles its own isolation
    nonisolated public func receiveResults() -> AsyncStream<TranscriptionResult> {
        strategy.receiveResults()
    }

    /// Disconnect and cleanup
    public func disconnect() async {
        isConnected = false
        failQueuedChunks(TranscriptionError.networkError("Streaming session disconnected"))
        await strategy.disconnect()
    }

    /// Check if the session is currently connected
    public var connected: Bool { isConnected }

    /// Set a handler to be called when the WebSocket disconnects unexpectedly
    /// Only applies to WebSocket-based strategies
    public func setDisconnectHandler(_ handler: @Sendable @escaping () -> Void) async {
        // Cast strategy to WebSocketStrategy to access disconnect handler
        if let wsStrategy = strategy as? any WebSocketStrategy {
            await wsStrategy.setDisconnectHandler(handler)
        }
    }

    nonisolated private static func formatSeconds(_ value: TimeInterval) -> String {
        String(format: "%.3fs", value)
    }

    private func drainQueuedChunksIfPossible() async throws {
        guard isConnected, !isDrainingQueuedChunks else { return }

        isDrainingQueuedChunks = true
        defer { isDrainingQueuedChunks = false }

        let queuedCount = queuedChunks.count
        let queuedBytes = queuedChunks.reduce(0) { $0 + $1.data.count }
        let flushStart = Date()
        if queuedCount > 0 {
            Logger.info("[StreamingSession] flushing queued audio chunks=\(queuedCount) bytes=\(queuedBytes)", category: .stt)
        }

        while isConnected, !queuedChunks.isEmpty {
            let chunk = queuedChunks.removeFirst()
            do {
                try await strategy.sendAudio(chunk.data, isFinal: chunk.isFinal)
                chunk.continuation.resume()
            } catch {
                chunk.continuation.resume(throwing: error)
                failQueuedChunks(error)
                throw error
            }
        }

        if queuedCount > 0 {
            Logger.info(
                "[StreamingSession] queued audio flush done chunks=\(queuedCount) bytes=\(queuedBytes) duration=\(Self.formatSeconds(Date().timeIntervalSince(flushStart)))",
                category: .stt
            )
        }
    }

    private func failQueuedChunks(_ error: Error) {
        let chunks = queuedChunks
        queuedChunks.removeAll()
        for chunk in chunks {
            chunk.continuation.resume(throwing: error)
        }
    }
}

/// Unified transcription service that automatically selects the appropriate strategy
/// based on the provider and API format. Supports both REST APIs and WebSocket streaming.
public final class TranscriptionService: Sendable {
    public let apiKey: String
    public let endpoint: String
    public let model: String
    public let language: String?
    public let apiFormat: ApiFormat

    private let strategy: TranscriptionStrategy
    private let provider: ProviderType

    /// Creates a transcription service with the specified configuration
    /// Automatically selects the appropriate strategy (REST or WebSocket) based on apiFormat
    public init(
        apiKey: String,
        endpoint: String = "https://api.openai.com/v1/audio/transcriptions",
        model: String = "whisper-1",
        language: String? = nil,
        apiFormat: ApiFormat = .whisperMultipart,
        session: URLSession? = nil
    ) {
        self.apiKey = apiKey
        self.endpoint = endpoint
        self.model = model
        self.language = language
        self.apiFormat = apiFormat

        // Infer provider from endpoint for strategy selection
        let provider: ProviderType
        if endpoint.contains("aliyun") || endpoint.contains("dashscope") {
            provider = .alibaba
        } else if endpoint.contains("groq") {
            provider = .groq
        } else if endpoint.contains("bigmodel") {
            provider = .glm
        } else {
            provider = .openai
        }
        self.provider = provider

        // Create the appropriate strategy based on provider, model, and format
        self.strategy = TranscriptionStrategyFactory.createStrategy(
            provider: provider,
            model: model,
            apiFormat: apiFormat,
            session: session
        )
    }

    /// Transcribe audio file using the selected strategy
    /// This method signature is kept unchanged for backward compatibility
    public func transcribe(audioFileURL: URL, retryCount: Int = 0) async throws -> String {
        // Build configuration
        let config = TranscriptionConfig(
            apiKey: apiKey,
            endpoint: endpoint,
            model: model,
            language: language,
            timeout: 30
        )

        // Connect to the transcription service
        try await strategy.connect(config: config)

        // Read audio data
        let audioData = try Data(contentsOf: audioFileURL)

        // Send audio and receive results
        try await strategy.sendAudio(audioData, isFinal: true)

        // Collect results
        var finalText = ""
        var lastError: TranscriptionError?

        for await result in strategy.receiveResults() {
            switch result {
            case .partial(let text):
                finalText = text
            case .final(let text):
                await strategy.disconnect()
                return text
            case .error(let error):
                lastError = error
                break
            }
        }

        await strategy.disconnect()

        // If we got an error during streaming, throw it
        if let error = lastError {
            throw error
        }

        // If we only got partial results, return the last one
        if !finalText.isEmpty {
            return finalText
        }

        throw TranscriptionError.noSpeechDetected
    }

    /// Stream transcription results in real-time
    /// Available for WebSocket-based strategies
    public func transcribeStream(audioFileURL: URL) async throws -> AsyncStream<TranscriptionResult> {
        // Build configuration
        let config = TranscriptionConfig(
            apiKey: apiKey,
            endpoint: endpoint,
            model: model,
            language: language,
            timeout: 30
        )

        // Connect to the transcription service
        try await strategy.connect(config: config)

        // Read audio data
        let audioData = try Data(contentsOf: audioFileURL)

        // Send audio
        try await strategy.sendAudio(audioData, isFinal: true)

        // Return the result stream directly
        return strategy.receiveResults()
    }

    /// Create a streaming transcription session for real-time audio
    /// This allows sending audio chunks as they arrive from the microphone
    /// - Returns: A StreamingTranscriptionSession for managing the connection
    @MainActor
    public func createStreamingSession() -> StreamingTranscriptionSession {
        let config = TranscriptionConfig(
            apiKey: apiKey,
            endpoint: endpoint,
            model: model,
            language: language,
            timeout: 30
        )

        return StreamingTranscriptionSession(strategy: strategy, config: config)
    }

    /// Whether this service supports real-time streaming
    public var supportsStreaming: Bool {
        strategy.supportsStreaming
    }
}
