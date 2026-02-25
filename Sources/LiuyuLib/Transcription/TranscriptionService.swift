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

/// Unified transcription service that automatically selects the appropriate strategy
/// based on the provider and API format. Supports both REST APIs and WebSocket streaming.
public final class TranscriptionService: Sendable {
    public let apiKey: String
    public let endpoint: String
    public let model: String
    public let language: String?
    public let apiFormat: ApiFormat

    private let strategy: TranscriptionStrategy

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

        // Create the appropriate strategy based on provider, model, and format
        self.strategy = TranscriptionStrategyFactory.createStrategy(
            provider: provider,
            model: model,
            apiFormat: apiFormat
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
}
