// Sources/LiuyuLib/Transcription/TranscriptionStrategy.swift
import Foundation

/// Result from transcription streaming
public enum TranscriptionResult: Sendable {
    /// Intermediate result during streaming (WebSocket only)
    case partial(String)
    /// Final transcription result
    case final(String)
    /// Error occurred
    case error(TranscriptionError)
}

/// Configuration for transcription strategies
public struct TranscriptionConfig: Sendable {
    public let apiKey: String
    public let endpoint: String
    public let model: String
    public let language: String?
    public let timeout: TimeInterval

    public init(
        apiKey: String,
        endpoint: String,
        model: String,
        language: String? = nil,
        timeout: TimeInterval = 30
    ) {
        self.apiKey = apiKey
        self.endpoint = endpoint
        self.model = model
        self.language = language
        self.timeout = timeout
    }
}

/// Protocol defining the interface for all transcription strategies
/// Implementations can use REST API, WebSocket streaming, or other protocols
public protocol TranscriptionStrategy: Sendable {
    /// Unique identifier for this strategy
    var strategyId: String { get }

    /// Whether this strategy supports real-time streaming results
    var supportsStreaming: Bool { get }

    /// Connect and prepare for transcription
    /// - Parameter config: Configuration including API key, endpoint, model, etc.
    func connect(config: TranscriptionConfig) async throws

    /// Send audio data for transcription
    /// - Parameters:
    ///   - data: Audio data chunk
    ///   - isFinal: Whether this is the final chunk (for streaming protocols)
    func sendAudio(_ data: Data, isFinal: Bool) async throws

    /// Receive transcription results as an async stream
    /// For REST strategies, this will yield a single .final result
    /// For WebSocket strategies, this may yield multiple .partial followed by .final
    /// Note: This must be nonisolated to allow calling from any context
    nonisolated func receiveResults() -> AsyncStream<TranscriptionResult>

    /// Disconnect and cleanup resources
    func disconnect() async
}

// MARK: - Default Implementations

public extension TranscriptionStrategy {
    /// Convenience method to transcribe an entire audio file
    /// Automatically handles reading file, sending chunks, and collecting results
    func transcribe(audioFileURL: URL) async throws -> String {
        // Read entire file
        let audioData = try Data(contentsOf: audioFileURL)

        // Send all audio at once (isFinal = true)
        try await sendAudio(audioData, isFinal: true)

        // Collect results
        var finalText = ""
        for await result in receiveResults() {
            switch result {
            case .partial(let text):
                finalText = text
            case .final(let text):
                return text
            case .error(let error):
                throw error
            }
        }

        return finalText
    }
}
