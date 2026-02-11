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

    public var errorDescription: String? {
        switch self {
        case .apiKeyInvalid: return "Invalid API key. Check Settings."
        case .apiKeyMissing: return "No API key configured. Open Settings to add one."
        case .rateLimited: return "Rate limited. Try again in a moment."
        case .serverError(let code, let msg): return "API error (\(code)): \(msg)"
        case .noSpeechDetected: return "No speech detected."
        case .networkError(let msg): return "Network error: \(msg)"
        case .decodingFailed: return "Failed to decode API response."
        }
    }
}

public final class TranscriptionService: Sendable {
    public let apiKey: String
    public let endpoint: String
    public let model: String
    public let language: String?
    public let apiFormat: ApiFormat
    private let session: URLSession

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
        self.session = session ?? {
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 30
            return URLSession(configuration: config)
        }()
    }

    public func transcribe(audioFileURL: URL, retryCount: Int = 0) async throws -> String {
        let request: URLRequest
        switch apiFormat {
        case .whisperMultipart:
            request = try buildWhisperRequest(audioFileURL: audioFileURL)
        case .chatCompletionsAudio:
            request = try buildChatCompletionsRequest(audioFileURL: audioFileURL)
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            if retryCount < 1 {
                return try await transcribe(audioFileURL: audioFileURL, retryCount: retryCount + 1)
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
                return try await transcribe(audioFileURL: audioFileURL, retryCount: retryCount + 1)
            }
            throw TranscriptionError.rateLimited
        default:
            let message = parseErrorMessage(data) ?? "Unknown error"
            throw TranscriptionError.serverError(httpResponse.statusCode, message)
        }
    }

    // MARK: - Whisper Multipart Format (OpenAI, Groq, GLM)

    private func buildWhisperRequest(audioFileURL: URL) throws -> URLRequest {
        let boundary = UUID().uuidString
        var request = URLRequest(url: URL(string: endpoint)!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = try buildMultipartBody(fileURL: audioFileURL, boundary: boundary)
        return request
    }

    private func buildMultipartBody(fileURL: URL, boundary: String) throws -> Data {
        var body = Data()
        let fileData = try Data(contentsOf: fileURL)
        let filename = fileURL.lastPathComponent

        body.appendMultipart(boundary: boundary, name: "file", filename: filename,
                             contentType: "audio/m4a", data: fileData)
        body.appendMultipart(boundary: boundary, name: "model", value: model)
        if let language {
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

    // MARK: - Chat Completions Audio Format (Alibaba Qwen ASR)

    private func buildChatCompletionsRequest(audioFileURL: URL) throws -> URLRequest {
        let audioData = try Data(contentsOf: audioFileURL)
        let base64Audio = audioData.base64EncodedString()

        let body: [String: Any] = [
            "model": model,
            "messages": [
                [
                    "role": "user",
                    "content": [
                        [
                            "type": "input_audio",
                            "input_audio": [
                                "data": base64Audio,
                                "format": "m4a"
                            ]
                        ]
                    ]
                ]
            ]
        ]

        var request = URLRequest(url: URL(string: endpoint)!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    private func parseChatCompletionsResponse(_ data: Data) throws -> String {
        // Response format: { "choices": [{ "message": { "content": "transcribed text" } }] }
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
