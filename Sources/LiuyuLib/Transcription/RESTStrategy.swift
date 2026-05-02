// Sources/LiuyuLib/Transcription/RESTStrategy.swift
import Foundation

/// REST API strategy for transcription
/// Used by OpenAI, Groq, GLM, and other providers using HTTP multipart or JSON APIs
public actor RESTStrategy: TranscriptionStrategy {
    public let strategyId = "rest"
    public let supportsStreaming = false

    public enum ApiFormat: Sendable {
        case whisperMultipart
        case glmMultipartEventStream
        case chatCompletionsAudio

        var logName: String {
            switch self {
            case .whisperMultipart:
                return "whisperMultipart"
            case .glmMultipartEventStream:
                return "glmMultipartEventStream"
            case .chatCompletionsAudio:
                return "chatCompletionsAudio"
            }
        }
    }

    private var config: TranscriptionConfig?
    private var apiFormat: ApiFormat
    private let injectedSession: URLSession?
    private let connectionPool: RESTConnectionPool
    private var continuation: AsyncStream<TranscriptionResult>.Continuation?
    private var pendingResults: [TranscriptionResult] = []
    private var pendingFinish = false

    public init(
        apiFormat: ApiFormat = .whisperMultipart,
        session: URLSession? = nil
    ) {
        self.init(apiFormat: apiFormat, session: session, connectionPool: .shared)
    }

    init(
        apiFormat: ApiFormat = .whisperMultipart,
        session: URLSession? = nil,
        connectionPool: RESTConnectionPool
    ) {
        self.apiFormat = apiFormat
        self.injectedSession = session
        self.connectionPool = connectionPool
    }

    public func connect(config: TranscriptionConfig) async throws {
        self.config = config
    }

    public func sendAudio(_ data: Data, isFinal: Bool) async throws {
        guard let config = config else {
            throw TranscriptionError.apiKeyMissing
        }

        let totalStart = Date()
        Logger.info(
            "[STT REST] begin model=\(config.model) format=\(apiFormat.logName) audioBytes=\(data.count) estimatedAudio=\(estimatedPCM16MonoDuration(data.count)) host=\(hostDescription(config.endpoint))",
            category: .stt
        )
        let connectionLease = restConnectionLease(for: config.endpoint)
        Logger.info(
            "[STT REST] connection.pool model=\(config.model) state=\(connectionLease.state.rawValue) key=\(connectionLease.keyDescription) sessions=\(connectionLease.sessionCount)",
            category: .stt
        )

        let buildStart = Date()
        let request: URLRequest
        switch apiFormat {
        case .whisperMultipart:
            request = try buildWhisperRequest(config: config, audioData: data)
        case .glmMultipartEventStream:
            request = try buildGLMEventStreamRequest(config: config, audioData: data)
        case .chatCompletionsAudio:
            request = try buildChatCompletionsRequest(config: config, audioData: data)
        }
        Logger.info(
            "[STT REST] request.built model=\(config.model) bodyBytes=\(request.httpBody?.count ?? 0) build=\(formatSeconds(Date().timeIntervalSince(buildStart)))",
            category: .stt
        )

        // Execute request with retry logic
        let resultText: String
        switch apiFormat {
        case .glmMultipartEventStream:
            resultText = try await executeEventStreamWithRetry(
                request: request,
                model: config.model,
                session: connectionLease.session
            )
        case .whisperMultipart, .chatCompletionsAudio:
            resultText = try await executeWithRetry(
                request: request,
                model: config.model,
                session: connectionLease.session
            )
        }
        Logger.info(
            "[STT REST] done model=\(config.model) total=\(formatSeconds(Date().timeIntervalSince(totalStart))) chars=\(resultText.count)",
            category: .stt
        )

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

    private func restConnectionLease(for endpoint: String) -> RESTConnectionLease {
        if let injectedSession {
            return RESTConnectionLease(
                session: injectedSession,
                state: .injected,
                keyDescription: hostDescription(endpoint),
                sessionCount: 0
            )
        }
        return connectionPool.lease(for: endpoint)
    }

    private func executeWithRetry(
        request: URLRequest,
        model: String,
        session: URLSession,
        retryCount: Int = 0
    ) async throws -> String {
        let data: Data
        let response: URLResponse
        let networkStart = Date()

        do {
            Logger.info(
                "[STT REST] network.begin model=\(model) retry=\(retryCount) bodyBytes=\(request.httpBody?.count ?? 0) host=\(hostDescription(request.url?.absoluteString ?? ""))",
                category: .stt
            )
            (data, response) = try await session.data(for: request)
        } catch {
            if retryCount < 1 {
                Logger.warning(
                    "[STT REST] network.retry model=\(model) retry=\(retryCount) error=\(error.localizedDescription)",
                    category: .stt
                )
                return try await executeWithRetry(
                    request: request,
                    model: model,
                    session: session,
                    retryCount: retryCount + 1
                )
            }
            Logger.error(
                "[STT REST] network.failed model=\(model) retry=\(retryCount) duration=\(formatSeconds(Date().timeIntervalSince(networkStart))) error=\(error.localizedDescription)",
                category: .stt
            )
            throw TranscriptionError.networkError(error.localizedDescription)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw TranscriptionError.decodingFailed
        }
        let networkDuration = Date().timeIntervalSince(networkStart)
        Logger.info(
            "[STT REST] network.done model=\(model) retry=\(retryCount) status=\(httpResponse.statusCode) duration=\(formatSeconds(networkDuration)) responseBytes=\(data.count)",
            category: .stt
        )

        switch httpResponse.statusCode {
        case 200:
            let parseStart = Date()
            let text: String
            switch apiFormat {
            case .whisperMultipart, .glmMultipartEventStream:
                text = try parseWhisperResponse(data)
            case .chatCompletionsAudio:
                text = try parseChatCompletionsResponse(data)
            }
            Logger.info(
                "[STT REST] parse.done model=\(model) duration=\(formatSeconds(Date().timeIntervalSince(parseStart))) chars=\(text.count)",
                category: .stt
            )
            return text
        case 401:
            throw TranscriptionError.apiKeyInvalid
        case 429:
            if retryCount < 1 {
                Logger.warning(
                    "[STT REST] rateLimited.retry model=\(model) retry=\(retryCount) sleep=2.000s",
                    category: .stt
                )
                try await Task.sleep(for: .seconds(2))
                return try await executeWithRetry(
                    request: request,
                    model: model,
                    session: session,
                    retryCount: retryCount + 1
                )
            }
            throw TranscriptionError.rateLimited
        default:
            let message = parseErrorMessage(data) ?? "Unknown error"
            throw TranscriptionError.serverError(httpResponse.statusCode, message)
        }
    }

    private func executeEventStreamWithRetry(
        request: URLRequest,
        model: String,
        session: URLSession,
        retryCount: Int = 0
    ) async throws -> String {
        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        let networkStart = Date()

        do {
            Logger.info(
                "[STT REST] eventStream.begin model=\(model) retry=\(retryCount) bodyBytes=\(request.httpBody?.count ?? 0) host=\(hostDescription(request.url?.absoluteString ?? ""))",
                category: .stt
            )
            (bytes, response) = try await session.bytes(for: request)
        } catch {
            if retryCount < 1 {
                Logger.warning(
                    "[STT REST] eventStream.retry model=\(model) retry=\(retryCount) error=\(error.localizedDescription)",
                    category: .stt
                )
                return try await executeEventStreamWithRetry(
                    request: request,
                    model: model,
                    session: session,
                    retryCount: retryCount + 1
                )
            }
            throw TranscriptionError.networkError(error.localizedDescription)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw TranscriptionError.decodingFailed
        }

        Logger.info(
            "[STT REST] eventStream.headers model=\(model) retry=\(retryCount) status=\(httpResponse.statusCode) duration=\(formatSeconds(Date().timeIntervalSince(networkStart)))",
            category: .stt
        )

        switch httpResponse.statusCode {
        case 200:
            var transcript = ""
            var eventCount = 0
            var firstDeltaLogged = false

            do {
                for try await line in bytes.lines {
                    guard let payload = ssePayload(from: line) else { continue }
                    if payload == "[DONE]" { break }
                    guard let delta = parseEventStreamText(payload), !delta.isEmpty else { continue }
                    eventCount += 1
                    transcript = mergeStreamText(current: transcript, incoming: delta)
                    if !firstDeltaLogged {
                        firstDeltaLogged = true
                        Logger.info(
                            "[STT REST] eventStream.firstDelta model=\(model) retry=\(retryCount) duration=\(formatSeconds(Date().timeIntervalSince(networkStart))) chars=\(transcript.count)",
                            category: .stt
                        )
                    }
                    yieldOrBuffer(.partial(transcript), finish: false)
                }
            } catch {
                throw TranscriptionError.networkError(error.localizedDescription)
            }

            Logger.info(
                "[STT REST] eventStream.done model=\(model) retry=\(retryCount) status=200 duration=\(formatSeconds(Date().timeIntervalSince(networkStart))) events=\(eventCount) chars=\(transcript.count)",
                category: .stt
            )

            guard !transcript.isEmpty else {
                throw TranscriptionError.noSpeechDetected
            }
            return transcript

        case 401:
            throw TranscriptionError.apiKeyInvalid
        case 429:
            if retryCount < 1 {
                try await Task.sleep(for: .seconds(2))
                return try await executeEventStreamWithRetry(
                    request: request,
                    model: model,
                    session: session,
                    retryCount: retryCount + 1
                )
            }
            throw TranscriptionError.rateLimited
        default:
            throw TranscriptionError.serverError(httpResponse.statusCode, "Event stream request failed.")
        }
    }

    private func hostDescription(_ endpoint: String) -> String {
        URL(string: endpoint)?.host ?? "unknown"
    }

    private func estimatedPCM16MonoDuration(_ bytes: Int) -> String {
        guard bytes > 44 else { return "0.000s" }
        let pcmBytes = bytes - 44
        let seconds = Double(pcmBytes) / 32_000.0
        return formatSeconds(seconds)
    }

    private func formatSeconds(_ value: TimeInterval) -> String {
        "\(String(format: "%.3f", value))s"
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

    private func buildGLMEventStreamRequest(config: TranscriptionConfig, audioData: Data) throws -> URLRequest {
        let boundary = UUID().uuidString
        var request = URLRequest(url: URL(string: config.endpoint)!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = buildMultipartBody(
            audioData: audioData,
            boundary: boundary,
            model: config.model,
            language: config.language,
            stream: true
        )
        return request
    }

    private func buildMultipartBody(
        audioData: Data,
        boundary: String,
        model: String,
        language: String?,
        stream: Bool = false
    ) -> Data {
        var body = Data()
        let filename = "audio.wav"
        let contentType = "audio/wav"

        body.appendMultipart(boundary: boundary, name: "file", filename: filename,
                             contentType: contentType, data: audioData)
        body.appendMultipart(boundary: boundary, name: "model", value: model)
        if stream {
            body.appendMultipart(boundary: boundary, name: "stream", value: "true")
        }
        if let language = language {
            body.appendMultipart(boundary: boundary, name: "language", value: language)
        }
        body.appendMultipart(boundary: boundary, name: "response_format", value: "json")
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        return body
    }

    private func ssePayload(from line: String) -> String? {
        guard line.hasPrefix("data:") else { return nil }
        return String(line.dropFirst("data:".count)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func parseEventStreamText(_ payload: String) -> String? {
        guard let data = payload.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        if let type = json["type"] as? String,
           type == "transcript.text.delta",
           let delta = json["delta"] as? String {
            return delta
        }

        if let text = json["text"] as? String {
            return text
        }

        if let choices = json["choices"] as? [[String: Any]],
           let first = choices.first {
            if let delta = first["delta"] as? [String: Any],
               let content = delta["content"] as? String {
                return content
            }
            if let message = first["message"] as? [String: Any],
               let content = message["content"] as? String {
                return content
            }
        }

        return nil
    }

    private func mergeStreamText(current: String, incoming: String) -> String {
        if incoming.hasPrefix(current) {
            return incoming
        }
        return current + incoming
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
