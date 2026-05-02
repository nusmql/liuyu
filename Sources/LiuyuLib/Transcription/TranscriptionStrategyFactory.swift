// Sources/LiuyuLib/Transcription/TranscriptionStrategyFactory.swift
import Foundation

/// Factory for creating transcription strategies based on provider and API format
/// This factory decouples the transcription service from specific implementation details
public enum TranscriptionStrategyFactory {

    /// Creates a transcription strategy based on the provider and API format
    /// - Parameters:
    ///   - provider: The provider type (OpenAI, Alibaba, etc.)
    ///   - apiFormat: The API format indicating which protocol to use
    /// - Returns: An appropriate TranscriptionStrategy implementation
    public static func createStrategy(
        provider: ProviderType,
        apiFormat: ApiFormat,
        session: URLSession? = nil
    ) -> TranscriptionStrategy {
        switch apiFormat {
        case .whisperMultipart, .glmMultipartEventStream, .chatCompletionsAudio:
            // REST-based providers (OpenAI, Groq, GLM, Alibaba REST)
            return RESTStrategy(apiFormat: apiFormat.toRESTFormat(), session: session)

        case .glmRealtime:
            return GLMRealtimeAdapter()

        case .alibabaRealtime:
            // Alibaba Cloud real-time speech recognition via WebSocket
            return AlibabaRealtimeAdapter()

        case .tencentRealtime:
            // Tencent Cloud real-time speech recognition via WebSocket
            // TODO: Implement TencentRealtimeAdapter
            // For now, fall back to REST strategy
            Logger.warning("TencentRealtime not yet implemented, falling back to REST", category: .stt)
            return RESTStrategy(apiFormat: .whisperMultipart, session: session)
        }
    }

    /// Creates a strategy from a provider configuration
    /// - Parameter config: The resolved provider configuration
    /// - Returns: An appropriate TranscriptionStrategy implementation
    public static func createStrategy(from config: ProviderConfig, session: URLSession? = nil) -> TranscriptionStrategy {
        // Get the provider definition to determine the API format
        guard let definition = ProviderDefinition.catalog[config.provider] else {
            Logger.error("Unknown provider: \(config.provider), using default REST strategy", category: .stt)
            return RESTStrategy(apiFormat: .whisperMultipart, session: session)
        }

        return createStrategy(
            provider: config.provider,
            apiFormat: definition.sttApiFormat,
            session: session
        )
    }

    /// Creates a strategy from provider, model, and explicit API format
    /// This is the recommended method when both provider and model are known
    public static func createStrategy(
        provider: ProviderType,
        model: String,
        apiFormat: ApiFormat? = nil,
        session: URLSession? = nil
    ) -> TranscriptionStrategy {
        // If explicit API format is provided, use it
        if let apiFormat = apiFormat {
            return createStrategy(provider: provider, apiFormat: apiFormat, session: session)
        }

        // Otherwise, infer from model name
        switch (provider, model) {
        case (.glm, "glm-realtime"), (.glm, "glm-realtime-flash"), (.glm, "glm-realtime-air"):
            return GLMRealtimeAdapter()
        case (.alibaba, "fun-asr-realtime"), (.alibaba, "fun-asr-realtime-2025-11-07"):
            return AlibabaRealtimeAdapter()
        default:
            // Fall back to catalog definition
            guard let definition = ProviderDefinition.catalog[provider] else {
                return RESTStrategy(apiFormat: .whisperMultipart, session: session)
            }
            return createStrategy(provider: provider, apiFormat: definition.sttApiFormat, session: session)
        }
    }
}

// MARK: - Helper Extension

private extension ApiFormat {
    func toRESTFormat() -> RESTStrategy.ApiFormat {
        switch self {
        case .whisperMultipart:
            return .whisperMultipart
        case .glmMultipartEventStream:
            return .glmMultipartEventStream
        case .chatCompletionsAudio:
            return .chatCompletionsAudio
        case .glmRealtime, .alibabaRealtime, .tencentRealtime:
            // These should not be converted - they're handled separately
            // But if called, default to whisper format
            return .whisperMultipart
        }
    }
}
