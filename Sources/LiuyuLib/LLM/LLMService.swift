// Sources/LiuyuLib/LLM/LLMService.swift
import Foundation

public enum LLMError: Error, LocalizedError, Sendable {
    case apiKeyInvalid
    case rateLimited
    case serverError(Int, String)
    case networkError(String)
    case decodingFailed
    case emptyResponse

    public var errorDescription: String? {
        switch self {
        case .apiKeyInvalid: return "Invalid API key. Check Settings."
        case .rateLimited: return "Rate limited. Try again in a moment."
        case .serverError(let code, let msg): return "API error (\(code)): \(msg)"
        case .networkError(let msg): return "Network error: \(msg)"
        case .decodingFailed: return "Failed to decode API response."
        case .emptyResponse: return "LLM returned an empty response."
        }
    }
}

public final class LLMService: Sendable {
    public let apiKey: String
    public let endpoint: String
    public let model: String
    private let session: URLSession

    public init(
        apiKey: String,
        endpoint: String,
        model: String,
        session: URLSession? = nil
    ) {
        self.apiKey = apiKey
        self.endpoint = endpoint
        self.model = model
        self.session = session ?? {
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 60
            return URLSession(configuration: config)
        }()
    }

    public func chat(system: String, user: String, retryCount: Int = 0) async throws -> String {
        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user]
            ]
        ]

        var request = URLRequest(url: URL(string: endpoint)!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            if retryCount < 1 {
                return try await chat(system: system, user: user, retryCount: retryCount + 1)
            }
            throw LLMError.networkError(error.localizedDescription)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw LLMError.decodingFailed
        }

        switch httpResponse.statusCode {
        case 200:
            return try parseResponse(data)
        case 401:
            throw LLMError.apiKeyInvalid
        case 429:
            if retryCount < 1 {
                try await Task.sleep(for: .seconds(2))
                return try await chat(system: system, user: user, retryCount: retryCount + 1)
            }
            throw LLMError.rateLimited
        default:
            let message = parseErrorMessage(data) ?? "Unknown error"
            throw LLMError.serverError(httpResponse.statusCode, message)
        }
    }

    private func parseResponse(_ data: Data) throws -> String {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw LLMError.decodingFailed
        }
        if content.isEmpty {
            throw LLMError.emptyResponse
        }
        return content
    }

    private func parseErrorMessage(_ data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = json["error"] as? [String: Any],
              let message = error["message"] as? String else {
            return nil
        }
        return message
    }
}
