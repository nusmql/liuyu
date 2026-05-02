import CryptoKit
import Foundation

enum IFlytekIATAuthentication: Equatable, Sendable {
    case hmac(apiKey: String, apiSecret: String)
    case oauth2(accessToken: String)
}

struct IFlytekIATCredentials: Equatable, Sendable {
    let appID: String
    let authentication: IFlytekIATAuthentication

    static func parse(_ rawValue: String) -> IFlytekIATCredentials? {
        let separators = CharacterSet(charactersIn: "|,\n\t ")
        let parts = rawValue
            .components(separatedBy: separators)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard parts.count == 3 else { return nil }

        let kind = parts[0].lowercased()
        if kind == "oauth2" || kind == "bearer" {
            return IFlytekIATCredentials(
                appID: parts[1],
                authentication: .oauth2(accessToken: parts[2])
            )
        }

        return IFlytekIATCredentials(
            appID: parts[0],
            authentication: .hmac(apiKey: parts[1], apiSecret: parts[2])
        )
    }
}

enum IFlytekIATParsedMessage: Equatable {
    case segment(sequence: Int, text: String, isFinal: Bool)
    case finalNoSpeech
    case error(code: Int, message: String)
}

/// iFLYTEK voice dictation WebAPI v2 adapter.
///
/// The API expects 16kHz mono PCM chunks sent over WebSocket with HMAC
/// authentication in the URL query string. We keep this adapter separate from
/// GLM/Alibaba because iFLYTEK uses a provider-specific frame envelope and
/// result payload shape.
public actor IFlytekIATAdapter: WebSocketStrategy {
    public let strategyId = "iflytek-iat"

    private var webSocketManager = WebSocketManager(
        heartbeatInterval: 0,
        connectionTimeout: 10
    )
    private var credentials: IFlytekIATCredentials?
    private var didSendFirstAudioFrame = false
    private var nextSequence = 0
    private var lastAudioSendNanos: UInt64?
    private var segments: [Int: String] = [:]

    public init() {}

    public func setDisconnectHandler(_ handler: DisconnectHandler?) async {
        await webSocketManager.setDisconnectHandler(handler)
    }

    nonisolated public func buildWebSocketURL(config: TranscriptionConfig) throws -> URL {
        guard let credentials = IFlytekIATCredentials.parse(config.apiKey) else {
            throw TranscriptionError.apiKeyInvalid
        }
        return try Self.webSocketURL(
            endpoint: config.endpoint.isEmpty ? Self.defaultEndpoint : config.endpoint,
            credentials: credentials,
            date: Date()
        )
    }

    nonisolated public func buildWebSocketHeaders(config: TranscriptionConfig) -> [String: String] {
        guard let credentials = IFlytekIATCredentials.parse(config.apiKey) else { return [:] }
        switch credentials.authentication {
        case .hmac:
            return [:]
        case .oauth2(let accessToken):
            return ["Authorization": "Bearer \(accessToken)"]
        }
    }

    nonisolated public func buildSetupMessage(config: TranscriptionConfig) -> [String: Any]? {
        nil
    }

    nonisolated public func buildAudioMessage(_ data: Data, isFinal: Bool) -> [String: Any] {
        Self.buildFrameMessage(
            appID: "",
            data: data,
            status: isFinal ? 2 : 0,
            includeCommonAndBusiness: !isFinal
        )
    }

    nonisolated public func parseMessage(_ message: String) -> TranscriptionResult? {
        switch Self.parseServerMessage(message) {
        case .segment(_, let text, let isFinal):
            return isFinal ? .final(text) : .partial(text)
        case .finalNoSpeech:
            return .error(.noSpeechDetected)
        case .error(let code, let message):
            return .error(.serverError(code, message))
        case nil:
            return nil
        }
    }

    nonisolated public var heartbeatInterval: TimeInterval { 0 }

    public func connect(config: TranscriptionConfig) async throws {
        guard let parsedCredentials = IFlytekIATCredentials.parse(config.apiKey) else {
            throw TranscriptionError.apiKeyInvalid
        }

        credentials = parsedCredentials
        didSendFirstAudioFrame = false
        nextSequence = 0
        lastAudioSendNanos = nil
        segments.removeAll(keepingCapacity: true)

        let url = try Self.webSocketURL(
            endpoint: config.endpoint.isEmpty ? Self.defaultEndpoint : config.endpoint,
            credentials: parsedCredentials,
            date: Date()
        )
        let headers = buildWebSocketHeaders(config: config)

        Logger.info("[iFLYTEK IAT] connecting host=\(url.host ?? "unknown") path=\(url.path)", category: .stt)
        try await webSocketManager.connect(url: url, headers: headers)
        await setupMessageHandler()
        Logger.info("[iFLYTEK IAT] connected", category: .stt)
    }

    public func sendAudio(_ data: Data, isFinal: Bool) async throws {
        guard let credentials else {
            throw TranscriptionError.apiKeyInvalid
        }

        if !data.isEmpty {
            let status = didSendFirstAudioFrame ? 1 : 0
            let message = Self.buildFrameMessage(
                appID: credentials.appID,
                data: data,
                status: status,
                includeCommonAndBusiness: status == 0
            )
            try await sendPacedJSON(message)
            didSendFirstAudioFrame = true
            nextSequence += 1
        }

        if isFinal {
            let message = Self.buildFrameMessage(
                appID: credentials.appID,
                data: Data(),
                status: 2,
                includeCommonAndBusiness: false
            )
            try await sendPacedJSON(message)
            nextSequence += 1
            Logger.info("[iFLYTEK IAT] final frame sent", category: .stt)
        }
    }

    nonisolated public func receiveResults() -> AsyncStream<TranscriptionResult> {
        AsyncStream { continuation in
            Task { [weak self] in
                await self?.setupResultHandling(continuation: continuation)
            }
        }
    }

    public func disconnect() async {
        await webSocketManager.disconnect()
        credentials = nil
        didSendFirstAudioFrame = false
        nextSequence = 0
        lastAudioSendNanos = nil
        segments.removeAll(keepingCapacity: true)
    }

    private func setupResultHandling(continuation: AsyncStream<TranscriptionResult>.Continuation) async {
        await webSocketManager.setContinuation(continuation)
        await setupMessageHandler()
    }

    private func setupMessageHandler() async {
        let adapter = self
        await webSocketManager.setMessageHandler { text -> TranscriptionResult? in
            Task {
                await adapter.handleServerMessage(text)
            }
            return nil
        }
    }

    private func handleServerMessage(_ message: String) async {
        guard let parsed = Self.parseServerMessage(message) else { return }

        switch parsed {
        case .segment(let sequence, let text, let isFinal):
            if !text.isEmpty {
                segments[sequence] = text
            }
            let fullText = segments
                .sorted { $0.key < $1.key }
                .map(\.value)
                .joined()

            if isFinal {
                let finalText = fullText.trimmingCharacters(in: .whitespacesAndNewlines)
                Logger.info("[iFLYTEK IAT] final chars=\(finalText.count)", category: .stt)
                if finalText.isEmpty {
                    await webSocketManager.yieldResult(.error(.noSpeechDetected))
                } else {
                    await webSocketManager.yieldResult(.final(finalText))
                }
                await webSocketManager.disconnect()
            } else if !fullText.isEmpty {
                await webSocketManager.yieldResult(.partial(fullText))
            }

        case .finalNoSpeech:
            Logger.info("[iFLYTEK IAT] final no speech", category: .stt)
            await webSocketManager.yieldResult(.error(.noSpeechDetected))
            await webSocketManager.disconnect()

        case .error(let code, let message):
            Logger.error("[iFLYTEK IAT] error code=\(code) message=\(message)", category: .stt)
            await webSocketManager.yieldResult(.error(.serverError(code, message)))
            await webSocketManager.disconnect()
        }
    }

    private func sendPacedJSON(_ message: [String: Any]) async throws {
        let data = try JSONSerialization.data(withJSONObject: message)
        guard let text = String(data: data, encoding: .utf8) else {
            throw TranscriptionError.decodingFailed
        }
        try await sleepUntilNextAudioSend()
        try await webSocketManager.sendText(text)
        lastAudioSendNanos = DispatchTime.now().uptimeNanoseconds
    }

    private func sleepUntilNextAudioSend() async throws {
        guard let lastAudioSendNanos else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        let minimumIntervalNanos: UInt64 = 40_000_000
        guard now > lastAudioSendNanos else { return }

        let elapsed = now - lastAudioSendNanos
        if elapsed < minimumIntervalNanos {
            try await Task.sleep(nanoseconds: minimumIntervalNanos - elapsed)
        }
    }

    nonisolated static func webSocketURL(
        endpoint: String,
        credentials: IFlytekIATCredentials,
        date: Date
    ) throws -> URL {
        switch credentials.authentication {
        case .hmac:
            return try signedURL(endpoint: endpoint, credentials: credentials, date: date)
        case .oauth2:
            return try unsignedWebSocketURL(endpoint: endpoint)
        }
    }

    nonisolated static func signedURL(
        endpoint: String,
        credentials: IFlytekIATCredentials,
        date: Date
    ) throws -> URL {
        guard case .hmac(let apiKey, let apiSecret) = credentials.authentication else {
            throw TranscriptionError.apiKeyInvalid
        }

        guard var components = URLComponents(string: endpoint) else {
            throw TranscriptionError.networkError("Invalid iFLYTEK IAT WebSocket URL")
        }

        if components.scheme == "https" {
            components.scheme = "wss"
        } else if components.scheme == "http" {
            components.scheme = "ws"
        }

        guard let host = components.host, !components.path.isEmpty else {
            throw TranscriptionError.networkError("Invalid iFLYTEK IAT WebSocket URL")
        }

        let dateString = rfc1123DateString(from: date)
        let requestLine = "GET \(components.path) HTTP/1.1"
        let signatureOrigin = "host: \(host)\ndate: \(dateString)\n\(requestLine)"
        let signature = hmacSHA256Base64(message: signatureOrigin, secret: apiSecret)
        let authorizationOrigin = #"api_key="\#(apiKey)", algorithm="hmac-sha256", headers="host date request-line", signature="\#(signature)""#
        let authorization = Data(authorizationOrigin.utf8).base64EncodedString()

        components.queryItems = [
            URLQueryItem(name: "authorization", value: authorization),
            URLQueryItem(name: "date", value: dateString),
            URLQueryItem(name: "host", value: host)
        ]

        guard let url = components.url else {
            throw TranscriptionError.networkError("Invalid iFLYTEK IAT signed URL")
        }
        return url
    }

    private nonisolated static func unsignedWebSocketURL(endpoint: String) throws -> URL {
        guard var components = URLComponents(string: endpoint) else {
            throw TranscriptionError.networkError("Invalid iFLYTEK IAT WebSocket URL")
        }

        if components.scheme == "https" {
            components.scheme = "wss"
        } else if components.scheme == "http" {
            components.scheme = "ws"
        }

        guard let url = components.url else {
            throw TranscriptionError.networkError("Invalid iFLYTEK IAT WebSocket URL")
        }
        return url
    }

    nonisolated static func buildFrameMessage(
        appID: String,
        data: Data,
        status: Int,
        includeCommonAndBusiness: Bool
    ) -> [String: Any] {
        var message: [String: Any] = [
            "data": [
                "status": status,
                "format": "audio/L16;rate=16000",
                "encoding": "raw",
                "audio": data.base64EncodedString()
            ] as [String: Any]
        ]

        if includeCommonAndBusiness {
            message["common"] = ["app_id": appID]
            message["business"] = [
                "language": "zh_cn",
                "domain": "iat",
                "accent": "mandarin",
                "ptt": 1
            ] as [String: Any]
        }

        return message
    }

    nonisolated static func parseServerMessage(_ message: String) -> IFlytekIATParsedMessage? {
        guard let json = jsonObject(from: message) else { return nil }

        let code = json["code"] as? Int ?? 0
        if code != 0 {
            return .error(code: code, message: json["message"] as? String ?? "iFLYTEK IAT server error")
        }

        guard let data = json["data"] as? [String: Any] else {
            return nil
        }

        let dataStatus = data["status"] as? Int
        guard let result = data["result"] as? [String: Any] else {
            return dataStatus == 2 ? .finalNoSpeech : nil
        }

        let sequence = result["sn"] as? Int ?? 0
        let isFinal = (result["ls"] as? Bool == true) || dataStatus == 2
        let text = text(from: result)

        if isFinal && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .finalNoSpeech
        }
        return .segment(sequence: sequence, text: text, isFinal: isFinal)
    }

    private nonisolated static let defaultEndpoint = "wss://iat-api.xfyun.cn/v2/iat"

    private nonisolated static func text(from result: [String: Any]) -> String {
        guard let words = result["ws"] as? [[String: Any]] else { return "" }
        return words.compactMap { word in
            guard let candidates = word["cw"] as? [[String: Any]],
                  let first = candidates.first,
                  let value = first["w"] as? String else {
                return nil
            }
            return value
        }.joined()
    }

    private nonisolated static func jsonObject(from message: String) -> [String: Any]? {
        guard let data = message.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return json
    }

    private nonisolated static func rfc1123DateString(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return formatter.string(from: date)
    }

    private nonisolated static func hmacSHA256Base64(message: String, secret: String) -> String {
        let key = SymmetricKey(data: Data(secret.utf8))
        let signature = HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: key)
        return Data(signature).base64EncodedString()
    }
}
