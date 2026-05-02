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

public struct StreamingQueueDiagnostics: Equatable, Sendable {
    public let isConnected: Bool
    public let isDraining: Bool
    public let pendingChunks: Int
    public let pendingBytes: Int
    public let pendingFinalChunks: Int
    public let totalQueuedChunks: Int
    public let totalQueuedBytes: Int
    public let totalSentChunks: Int
    public let totalSentBytes: Int
    public let totalSentFinalChunks: Int
    public let oldestPendingAge: TimeInterval?

    public var traceDetails: String {
        let oldestAge = oldestPendingAge.map { Self.formatSeconds($0) } ?? "none"
        return "connected=\(isConnected) draining=\(isDraining) pendingChunks=\(pendingChunks) pendingBytes=\(pendingBytes) pendingFinal=\(pendingFinalChunks) queuedChunks=\(totalQueuedChunks) queuedBytes=\(totalQueuedBytes) sentChunks=\(totalSentChunks) sentBytes=\(totalSentBytes) sentFinal=\(totalSentFinalChunks) oldestPendingAge=\(oldestAge)"
    }

    private static func formatSeconds(_ value: TimeInterval) -> String {
        String(format: "%.3fs", value)
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
    private var totalQueuedChunks = 0
    private var totalQueuedBytes = 0
    private var totalSentChunks = 0
    private var totalSentBytes = 0
    private var totalSentFinalChunks = 0

    private struct QueuedChunk {
        let data: Data
        let isFinal: Bool
        let queuedAt: Date
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
            Task { [weak self] in
                try? await self?.drainQueuedChunksIfPossible()
            }
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
            queuedChunks.append(QueuedChunk(data: data, isFinal: isFinal, queuedAt: Date(), continuation: continuation))
            totalQueuedChunks += 1
            totalQueuedBytes += data.count

            let diagnostics = makeDiagnostics()
            if shouldLogEnqueue(diagnostics: diagnostics, isFinal: isFinal) {
                Logger.info("[StreamingSession] queued chunk bytes=\(data.count) final=\(isFinal) \(diagnostics.traceDetails)", category: .stt)
            }

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

    public func diagnostics() -> StreamingQueueDiagnostics {
        makeDiagnostics()
    }

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

        let startDiagnostics = makeDiagnostics()
        let startSentChunks = totalSentChunks
        let startSentBytes = totalSentBytes
        let startSentFinalChunks = totalSentFinalChunks
        let flushStart = Date()
        if startDiagnostics.pendingChunks > 0 {
            Logger.info("[StreamingSession] drain.begin \(startDiagnostics.traceDetails)", category: .stt)
        }

        while isConnected, !queuedChunks.isEmpty {
            let chunk = queuedChunks.removeFirst()
            do {
                try await strategy.sendAudio(chunk.data, isFinal: chunk.isFinal)
                totalSentChunks += 1
                totalSentBytes += chunk.data.count
                if chunk.isFinal {
                    totalSentFinalChunks += 1
                }
                chunk.continuation.resume()
            } catch {
                chunk.continuation.resume(throwing: error)
                failQueuedChunks(error)
                throw error
            }
        }

        if startDiagnostics.pendingChunks > 0 {
            let drainedChunks = totalSentChunks - startSentChunks
            let drainedBytes = totalSentBytes - startSentBytes
            let drainedFinalChunks = totalSentFinalChunks - startSentFinalChunks
            Logger.info(
                "[StreamingSession] drain.done duration=\(Self.formatSeconds(Date().timeIntervalSince(flushStart))) drainedChunks=\(drainedChunks) drainedBytes=\(drainedBytes) drainedFinal=\(drainedFinalChunks) \(makeDiagnostics(isDrainingOverride: false).traceDetails)",
                category: .stt
            )
        }
    }

    private func shouldLogEnqueue(diagnostics: StreamingQueueDiagnostics, isFinal: Bool) -> Bool {
        isFinal
            || diagnostics.pendingChunks == 1
            || diagnostics.pendingChunks % 10 == 0
            || (diagnostics.pendingBytes >= 64_000 && diagnostics.pendingChunks % 5 == 0)
    }

    private func makeDiagnostics(isDrainingOverride: Bool? = nil) -> StreamingQueueDiagnostics {
        let now = Date()
        let pendingBytes = queuedChunks.reduce(0) { $0 + $1.data.count }
        let pendingFinalChunks = queuedChunks.reduce(0) { $0 + ($1.isFinal ? 1 : 0) }
        let oldestPendingAge = queuedChunks.first.map { now.timeIntervalSince($0.queuedAt) }

        return StreamingQueueDiagnostics(
            isConnected: isConnected,
            isDraining: isDrainingOverride ?? isDrainingQueuedChunks,
            pendingChunks: queuedChunks.count,
            pendingBytes: pendingBytes,
            pendingFinalChunks: pendingFinalChunks,
            totalQueuedChunks: totalQueuedChunks,
            totalQueuedBytes: totalQueuedBytes,
            totalSentChunks: totalSentChunks,
            totalSentBytes: totalSentBytes,
            totalSentFinalChunks: totalSentFinalChunks,
            oldestPendingAge: oldestPendingAge
        )
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
