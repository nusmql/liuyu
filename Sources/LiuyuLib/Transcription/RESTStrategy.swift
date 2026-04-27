// Sources/LiuyuLib/Transcription/RESTStrategy.swift
import Foundation

/// REST API strategy for transcription
/// Used by OpenAI, Groq, GLM, and other providers using HTTP multipart or JSON APIs
public actor RESTStrategy: TranscriptionStrategy {
    public let strategyId = "rest"
    public let supportsStreaming = false

    public enum ApiFormat: Sendable {
        case whisperMultipart
        case chatCompletionsAudio
    }

    private var config: TranscriptionConfig?
    private var apiFormat: ApiFormat
    private var session: URLSession
    private var continuation: AsyncStream<TranscriptionResult>.Continuation?
    private var pendingResults: [TranscriptionResult] = []
    private var pendingFinish = false

    public init(
        apiFormat: ApiFormat = .whisperMultipart,
        session: URLSession? = nil
    ) {
        self.apiFormat = apiFormat
        self.session = session ?? {
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 30
            return URLSession(configuration: config)
        }()
    }

    public func connect(config: TranscriptionConfig) async throws {
        self.config = config
    }

    public func sendAudio(_ data: Data, isFinal: Bool) async throws {
        guard let config = config else {
            throw TranscriptionError.apiKeyMissing
        }

        let request: URLRequest
        switch apiFormat {
        case .whisperMultipart:
            request = try buildWhisperRequest(config: config, audioData: data)
        case .chatCompletionsAudio:
            request = try buildChatCompletionsRequest(config: config, audioData: data)
        }

        // Execute request with retry logic
        let resultText = try await executeWithRetry(request: request)

        // Yield result through stream
        yieldOrBuffer(.final(resultText), finish: true)
    }

    nonisolated public func receiveResults() -> AsyncStream<TranscriptionResult> {
        AsyncStream { continuation in
            // Store continuation in task-local storage or use another mechanism
            // For now, we use a simple approach with detached task
            Task { [weak self] in
                await self?.setContinuation(continuation)
            }
        }
    }

    private func setContinuation(_ cont: AsyncStream<TranscriptionResult>.Continuation) {
        self.continuation = cont
        flushPendingResults()
    }

    private func yieldOrBuffer(_ result: TranscriptionResult, finish: Bool) {
        guard let continuation else {
            pendingResults.append(result)
            pendingFinish = pendingFinish || finish
            return
        }

        continuation.yield(result)
        if finish {
            continuation.finish()
            self.continuation = nil
        }
    }

    private func flushPendingResults() {
        guard let continuation else { return }

        for result in pendingResults {
            continuation.yield(result)
        }
        pendingResults.removeAll()

        if pendingFinish {
            continuation.finish()
            pendingFinish = false
            self.continuation = nil
        }
    }

    public func disconnect() async {
        continuation?.finish()
        continuation = nil
        pendingResults.removeAll()
        pendingFinish = false
        config = nil
    }

    // MARK: - Private Methods

    private func executeWithRetry(request: URLRequest, retryCount: Int = 0) async throws -> String {
        let data: Data
        let response: URLResponse

        do {
            (data, response) = try await session.data(for: request)
        } catch {
            if retryCount < 1 {
                return try await executeWithRetry(request: request, retryCount: retryCount + 1)
            }
            throw TranscriptionError.networkError(error.localizedDescription)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw TranscriptionError.decodingFailed
        }

        switch httpResponse.statusCode {
        case 200:
            switch apiFormat {
            case .whisperMultipart:
                return try parseWhisperResponse(data)
            case .chatCompletionsAudio:
                return try parseChatCompletionsResponse(data)
            }
        case 401:
            throw TranscriptionError.apiKeyInvalid
        case 429:
            if retryCount < 1 {
                try await Task.sleep(for: .seconds(2))
                return try await executeWithRetry(request: request, retryCount: retryCount + 1)
            }
            throw TranscriptionError.rateLimited
        default:
            let message = parseErrorMessage(data) ?? "Unknown error"
            throw TranscriptionError.serverError(httpResponse.statusCode, message)
        }
    }

    // MARK: - Whisper Multipart Format

    private func buildWhisperRequest(config: TranscriptionConfig, audioData: Data) throws -> URLRequest {
        let boundary = UUID().uuidString
        var request = URLRequest(url: URL(string: config.endpoint)!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = buildMultipartBody(
            audioData: audioData,
            boundary: boundary,
            model: config.model,
            language: config.language
        )
        return request
    }

    private func buildMultipartBody(
        audioData: Data,
        boundary: String,
        model: String,
        language: String?
    ) -> Data {
        var body = Data()
        let filename = "audio.wav"
        let contentType = "audio/wav"

        body.appendMultipart(boundary: boundary, name: "file", filename: filename,
                             contentType: contentType, data: audioData)
        body.appendMultipart(boundary: boundary, name: "model", value: model)
        if let language = language {
            body.appendMultipart(boundary: boundary, name: "language", value: language)
        }
        body.appendMultipart(boundary: boundary, name: "response_format", value: "json")
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        return body
    }

    private func parseWhisperResponse(_ data: Data) throws -> String {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = json["text"] as? String else {
            throw TranscriptionError.decodingFailed
        }
        if text.isEmpty {
            throw TranscriptionError.noSpeechDetected
        }
        return text
    }

    // MARK: - Chat Completions Audio Format

    private func buildChatCompletionsRequest(config: TranscriptionConfig, audioData: Data) throws -> URLRequest {
        let base64Audio = audioData.base64EncodedString()

        let body: [String: Any] = [
            "model": config.model,
            "messages": [
                [
                    "role": "user",
                    "content": [
                        [
                            "type": "input_audio",
                            "input_audio": [
                                "data": base64Audio,
                                "format": "wav"
                            ]
                        ]
                    ]
                ]
            ]
        ]

        var request = URLRequest(url: URL(string: config.endpoint)!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    private func parseChatCompletionsResponse(_ data: Data) throws -> String {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw TranscriptionError.decodingFailed
        }
        if content.isEmpty {
            throw TranscriptionError.noSpeechDetected
        }
        return content
    }

    // MARK: - Error Parsing

    private func parseErrorMessage(_ data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = json["error"] as? [String: Any],
              let message = error["message"] as? String else {
            return nil
        }
        return message
    }
}

// MARK: - Data Extension

private extension Data {
    mutating func appendMultipart(boundary: String, name: String, filename: String,
                                   contentType: String, data: Data) {
        append("--\(boundary)\r\n".data(using: .utf8)!)
        append("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
        append("Content-Type: \(contentType)\r\n\r\n".data(using: .utf8)!)
        append(data)
        append("\r\n".data(using: .utf8)!)
    }

    mutating func appendMultipart(boundary: String, name: String, value: String) {
        append("--\(boundary)\r\n".data(using: .utf8)!)
        append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
        append("\(value)\r\n".data(using: .utf8)!)
    }
}
