import Foundation

public enum TranscriptionMode: Sendable, Equatable {
    case batch
    case streaming
}

public struct TranscriptionProviderConfig: Sendable, Equatable {
    public let apiKey: String
    public let endpoint: String
    public let model: String
    public let language: String?

    public init(apiKey: String, endpoint: String, model: String, language: String? = nil) {
        self.apiKey = apiKey
        self.endpoint = endpoint
        self.model = model
        self.language = language
    }
}

public enum TranscriptionProviderResult: Sendable, Equatable {
    case partial(String)
    case final(String)
    case failure(String)
}

public protocol TranscriptionProvider: Sendable {
    var mode: TranscriptionMode { get }
    func prepare(config: TranscriptionProviderConfig) async throws
    func send(_ frame: VoiceAudioFrame) async throws
    func finish() async throws
    func results() -> AsyncStream<TranscriptionProviderResult>
    func cancel() async
}
