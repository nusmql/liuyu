import Foundation

public enum StreamingTransportEvent: Sendable, Equatable {
    case connect
    case send([Int64])
    case finish
}

public protocol StreamingTranscriptionTransport: Sendable {
    func connect(config: TranscriptionProviderConfig) async throws
    func send(frames: [VoiceAudioFrame]) async throws
    func finish() async throws
    func results() -> AsyncStream<TranscriptionProviderResult>
    func cancel() async
}

public actor StreamingTranscriptionProvider: TranscriptionProvider {
    public let mode: TranscriptionMode = .streaming
    private let transport: any StreamingTranscriptionTransport
    private let chunkFrameLimit: Int
    private var pending: [VoiceAudioFrame] = []

    public init(transport: any StreamingTranscriptionTransport, chunkFrameLimit: Int = 5) {
        self.transport = transport
        self.chunkFrameLimit = max(1, chunkFrameLimit)
    }

    public func prepare(config: TranscriptionProviderConfig) async throws {
        pending.removeAll(keepingCapacity: true)
        try await transport.connect(config: config)
    }

    public func send(_ frame: VoiceAudioFrame) async throws {
        pending.append(frame)
        if pending.count >= chunkFrameLimit {
            try await flush()
        }
    }

    public func finish() async throws {
        try await flush()
        try await transport.finish()
    }

    private func flush() async throws {
        guard !pending.isEmpty else { return }
        let frames = pending
        pending.removeAll(keepingCapacity: true)
        try await transport.send(frames: frames)
    }

    public nonisolated func results() -> AsyncStream<TranscriptionProviderResult> {
        transport.results()
    }

    public func cancel() async {
        pending.removeAll(keepingCapacity: true)
        await transport.cancel()
    }
}

public actor MockStreamingTransport: StreamingTranscriptionTransport {
    private var events: [StreamingTransportEvent] = []

    public init() {}

    public func connect(config: TranscriptionProviderConfig) async throws {
        events.append(.connect)
    }

    public func send(frames: [VoiceAudioFrame]) async throws {
        events.append(.send(frames.map(\.sequence)))
    }

    public func finish() async throws {
        events.append(.finish)
    }

    public nonisolated func results() -> AsyncStream<TranscriptionProviderResult> {
        AsyncStream { continuation in
            continuation.finish()
        }
    }

    public func cancel() async {}

    public func snapshot() -> [StreamingTransportEvent] {
        events
    }
}
