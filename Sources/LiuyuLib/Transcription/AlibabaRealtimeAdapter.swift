// Sources/LiuyuLib/Transcription/AlibabaRealtimeAdapter.swift
import Foundation

/// Audio chunk with sequence info for ordered processing
private struct AudioChunk {
    let data: Data
    let isFinal: Bool
    let sequenceNumber: Int
}

/// Alibaba Cloud DashScope Real-time Speech Recognition Adapter
/// Uses WebSocket protocol with Bearer token authentication
/// Documentation: https://help.aliyun.com/document_detail/84535.html
public actor AlibabaRealtimeAdapter: WebSocketStrategy {

    public let strategyId = "alibaba-realtime"
    private var config: TranscriptionConfig?
    private var taskId: String = ""
    private var webSocketManager = WebSocketManager(
        heartbeatInterval: 0 // DashScope doesn't require heartbeat
    )

    // State management for proper streaming
    private var isTaskStarted = false
    private var isFinished = false

    // Continuation for waiting task-started event in connect()
    private var taskStartedContinuation: CheckedContinuation<Void, Never>?

    // MARK: - Ordered Queue System
    // Use a queue to ensure strict ordering: audio chunks are sent in order,
    // and finish-task is only sent after all audio chunks are sent.
    private var audioQueue: [AudioChunk] = []
    private var nextSequenceNumber = 0
    private var isProcessingQueue = false
    private var totalAudioReceived: Int = 0
    private var totalAudioSent: Int = 0

    public init() {}

    // MARK: - WebSocketStrategy Implementation

    /// Build WebSocket URL for DashScope API
    /// Format: wss://dashscope.aliyuncs.com/api-ws/v1/inference
    nonisolated public func buildWebSocketURL(config: TranscriptionConfig) throws -> URL {
        var components = URLComponents()
        components.scheme = "wss"
        components.host = "dashscope.aliyuncs.com"
        components.path = "/api-ws/v1/inference"

        guard let url = components.url else {
            throw TranscriptionError.networkError("Invalid WebSocket URL")
        }

        return url
    }

    /// Build HTTP headers with Bearer token authentication
    nonisolated public func buildWebSocketHeaders(config: TranscriptionConfig) -> [String: String] {
        return [
            "Authorization": "Bearer \(config.apiKey)" // Format: Bearer <api-key>
        ]
    }

    /// Build run-task message to start recognition
    nonisolated public func buildSetupMessage(config: TranscriptionConfig) -> [String: Any]? {
        // Generate 32-character task ID (UUID without dashes, truncated to 32 chars)
        let taskId = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(32).description

        // Build parameters with required settings
        var parameters: [String: Any] = [
            "sample_rate": 16000,
            "format": "pcm"
        ]

        // Add language if specified (otherwise model auto-detects)
        // Note: language_hints is an array per DashScope documentation
        if let language = config.language, !language.isEmpty, language != "auto" {
            parameters["language_hints"] = [language]
        }

        return [
            "header": [
                "action": "run-task",
                "task_id": taskId,
                "streaming": "duplex"
            ],
            "payload": [
                "task_group": "audio",
                "task": "asr",
                "function": "recognition",
                "model": config.model.isEmpty ? "fun-asr-realtime" : config.model,
                "parameters": parameters,
                "input": [:]
            ]
        ]
    }

    /// Audio is sent as binary chunks, not JSON messages
    nonisolated public func buildAudioMessage(_ data: Data, isFinal: Bool) -> [String: Any] {
        // DashScope expects raw binary audio data, not base64 JSON
        // This method is not used; we send Data directly via sendData
        return [:]
    }

    /// Build finish-task message
    private func buildFinishTaskMessage() -> [String: Any] {
        return [
            "header": [
                "action": "finish-task",
                "task_id": taskId,
                "streaming": "duplex"
            ],
            "payload": [
                "input": [:]
            ]
        ]
    }

    /// Parse DashScope response message
    nonisolated public func parseMessage(_ message: String) -> TranscriptionResult? {
        guard let data = message.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        guard let header = json["header"] as? [String: Any],
              let event = header["event"] as? String else {
            return nil
        }

        switch event {
        case "task-started":
            // Task started successfully, ready to send audio
            return nil

        case "result-generated":
            // Recognition result received
            guard let payload = json["payload"] as? [String: Any],
                  let output = payload["output"] as? [String: Any],
                  let sentence = output["sentence"] as? [String: Any],
                  let text = sentence["text"] as? String else {
                return nil
            }
            // Check if this is a final result
            let isFinal = sentence["end_time"] != nil
            return isFinal ? .final(text) : .partial(text)

        case "task-finished":
            // Task completed - return empty final result to signal completion
            Logger.info("🎬 [WS-PARSE] task-finished received from server", category: .stt)
            return .final("")

        case "task-failed":
            let errorMessage = header["error_message"] as? String ?? "Unknown error"
            Logger.error("🎬 [WS-PARSE] task-failed: \(errorMessage)", category: .stt)
            return .error(TranscriptionError.serverError(500, errorMessage))

        default:
            return nil
        }
    }

    nonisolated public var heartbeatInterval: TimeInterval { 0 }

    // MARK: - TranscriptionStrategy Implementation

    public func connect(config: TranscriptionConfig) async throws {
        self.config = config

        // Reset state for new connection
        isTaskStarted = false
        isFinished = false
        audioQueue.removeAll()
        nextSequenceNumber = 0
        totalAudioReceived = 0
        totalAudioSent = 0

        // Generate task ID (32 characters, UUID without dashes)
        self.taskId = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(32).description
        Logger.info("Generated task ID: \(taskId)", category: .stt)

        // Build WebSocket URL and headers
        let url = try buildWebSocketURL(config: config)
        let headers = buildWebSocketHeaders(config: config)

        // Connect using manager with Bearer token headers
        Logger.info("Connecting to DashScope WebSocket...", category: .stt)
        try await webSocketManager.connect(url: url, headers: headers)
        Logger.info("WebSocket connected, sending run-task...", category: .stt)

        // Set up message handler BEFORE sending run-task
        // This ensures we can detect task-started when it arrives
        await setupResultHandling()
        Logger.info("🎬 [CONN] Message handler set up", category: .stt)

        // Send run-task message
        if let setupMessage = buildSetupMessage(config: config) {
            Logger.debug("Sending run-task: \(setupMessage)", category: .stt)
            try await webSocketManager.sendJSON(setupMessage)
            Logger.info("Run-task sent, waiting for task-started...", category: .stt)
        }

        // Wait for task-started event with a timeout
        // This ensures connect() only returns when we're ready to receive audio
        Logger.info("🎬 [CONN-WAIT] Waiting for task-started event...", category: .stt)

        // Use withTaskGroup to race between task-started and timeout
        let taskStartedResult: Bool = await withTaskGroup(of: Bool.self) { [weak self] group in
            guard let self = self else { return false }

            // Task 1: Wait for task-started event
            group.addTask {
                // Wait for handleTaskStarted to resume this continuation
                await withCheckedContinuation { continuation in
                    // Capture continuation on the actor
                    Task { [weak self] in
                        await self?.storeContinuation(continuation)
                    }
                }
                return true // task-started received
            }

            // Task 2: Timeout
            group.addTask {
                try? await Task.sleep(nanoseconds: 5_000_000_000) // 5 seconds
                return false // timeout
            }

            // Return first result and cancel others
            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }

        if !taskStartedResult {
            Logger.error("🎬 [CONN-WAIT] Timeout waiting for task-started", category: .stt)
            throw TranscriptionError.serverError(500, "Failed to receive task-started from server")
        }

        // Mark as started
        isTaskStarted = true
        Logger.info("🎬 [CONN-WAIT] task-started received, connect() returning", category: .stt)
    }

    /// Send audio chunk for real-time transcription
    /// Uses a queue to ensure strict ordering: all audio chunks must be sent before finish-task
    public func sendAudio(_ data: Data, isFinal: Bool) async throws {
        Logger.info("🎬 [WS-RECV] sendAudio called: \(data.count) bytes, isFinal=\(isFinal), taskStarted=\(isTaskStarted)", category: .stt)

        // Track received audio for proper finish-task timing
        if !data.isEmpty {
            totalAudioReceived += data.count
        }

        // Add to queue with sequence number for strict ordering
        let chunk = AudioChunk(data: data, isFinal: isFinal, sequenceNumber: nextSequenceNumber)
        nextSequenceNumber += 1
        audioQueue.append(chunk)

        Logger.info("🎬 [WS-QUEUE] Added to queue: seq=\(chunk.sequenceNumber), size=\(data.count), isFinal=\(isFinal), queueSize=\(audioQueue.count)", category: .stt)

        // Process queue immediately - don't wait for task-started
        // The server expects audio data immediately after run-task
        if !isProcessingQueue {
            await processAudioQueue()
        }
    }

    /// Process the audio queue in strict order
    /// Ensures all audio is sent before sending finish-task
    private func processAudioQueue() async {
        // If task hasn't started, we can still queue but not send yet
        // The queue will be processed again when task-started is received
        guard isTaskStarted else {
            Logger.info("🎬 [WS-QUEUE] Task not started yet, audio queued for later", category: .stt)
            return
        }

        // Prevent re-entrant processing
        guard !isProcessingQueue else { return }
        isProcessingQueue = true

        while !audioQueue.isEmpty {
            let chunk = audioQueue.removeFirst()

            // Send audio data if not empty
            if !chunk.data.isEmpty {
                do {
                    Logger.info("🎬 [WS-SEND] Sending queued chunk seq=\(chunk.sequenceNumber): \(chunk.data.count) bytes", category: .stt)
                    try await webSocketManager.sendData(chunk.data)
                    totalAudioSent += chunk.data.count
                    Logger.info("🎬 [WS-SENT] Chunk seq=\(chunk.sequenceNumber) sent (totalSent: \(totalAudioSent))", category: .stt)
                } catch {
                    Logger.error("🎬 [WS-SEND-FAIL] Failed to send chunk seq=\(chunk.sequenceNumber): \(error)", category: .stt)
                }
            }

            // If this is the final chunk, send finish-task AFTER all previous audio is sent
            if chunk.isFinal {
                // Wait a moment to ensure any trailing audio arrives in the queue
                try? await Task.sleep(nanoseconds: 100_000_000) // 100ms

                // Check if more audio arrived during the wait
                if audioQueue.isEmpty {
                    Logger.info("🎬 [WS-FINISH] Queue empty after final chunk, sending finish-task (totalSent: \(totalAudioSent), totalReceived: \(totalAudioReceived))", category: .stt)
                    await sendFinishTask()
                    isFinished = true
                } else {
                    Logger.info("🎬 [WS-FINISH-DELAY] More audio arrived after final flag, processing... (queueSize: \(audioQueue.count))", category: .stt)
                    // Continue processing the queue - don't reset isProcessingQueue yet
                    isProcessingQueue = false
                    await processAudioQueue()
                    return
                }
            }
        }

        isProcessingQueue = false
        Logger.info("🎬 [WS-QUEUE] Queue processing complete, queueSize=\(audioQueue.count)", category: .stt)
    }

    /// Send finish-task message
    private func sendFinishTask() async {
        guard isTaskStarted else {
            isFinished = true
            Logger.info("🎬 [WS-A4] Delaying finish-task until task-started is received", category: .stt)
            return
        }

        Logger.info("🎬 [WS-A5] Sending finish-task to complete streaming", category: .stt)
        let finishMessage: [String: Any] = [
            "header": [
                "action": "finish-task",
                "task_id": taskId,
                "streaming": "duplex"
            ],
            "payload": [
                "input": [:]
            ]
        ]
        try? await webSocketManager.sendJSON(finishMessage)
    }

    nonisolated public func receiveResults() -> AsyncStream<TranscriptionResult> {
        AsyncStream { continuation in
            Task { [weak self] in
                await self?.setupResultHandling(continuation: continuation)
            }
        }
    }

    /// Setup result handling for streaming transcription (used by receiveResults)
    private func setupResultHandling(continuation: AsyncStream<TranscriptionResult>.Continuation) async {
        await webSocketManager.setContinuation(continuation)
        // Also set up the message handler with continuation support
        await setupMessageHandler()
    }

    /// Setup message handler for detecting task-started and parsing results
    /// Called during connect() to ensure we detect task-started immediately
    private func setupResultHandling() async {
        await setupMessageHandler()
    }

    /// Set up the message handler that detects task-started and parses results
    private func setupMessageHandler() async {
        // Capture self strongly in the handler to ensure task-started is processed
        // The adapter lifecycle is tied to the streaming session, so this is safe
        let adapter = self

        // Set message handler to parse incoming WebSocket messages
        await webSocketManager.setMessageHandler { text -> TranscriptionResult? in
            // Check for task-started event
            if let data = text.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let header = json["header"] as? [String: Any],
               let event = header["event"] as? String {

                if event == "task-started" {
                    Logger.info("🎬 [WS-HANDLER] task-started detected, scheduling handleTaskStarted", category: .stt)
                    // Schedule handleTaskStarted on the adapter's actor
                    Task {
                        await adapter.handleTaskStarted()
                    }
                }
            }

            // Parse the message for transcription results
            return AlibabaRealtimeAdapter.parseMessageStatic(text)
        }
    }

    /// Store continuation for task-started event (actor-isolated)
    private func storeContinuation(_ continuation: CheckedContinuation<Void, Never>) {
        taskStartedContinuation = continuation
    }

    /// Handle task-started event - called by WebSocketManager
    func handleTaskStarted() async {
        Logger.info("🎬 [WS-T1] Task started received - processing queued audio (queueSize: \(audioQueue.count), totalReceived: \(totalAudioReceived))", category: .stt)

        // Mark task as started - this is crucial for queue processing
        isTaskStarted = true
        Logger.info("🎬 [WS-T1] isTaskStarted set to true", category: .stt)

        // Resume the continuation if connect() is waiting
        if let continuation = taskStartedContinuation {
            Logger.info("🎬 [WS-T1] Resuming taskStartedContinuation", category: .stt)
            taskStartedContinuation = nil
            continuation.resume()
        }

        // Start processing the queue - this will send all buffered audio in order
        await processAudioQueue()
    }

    /// Static helper for message parsing to avoid actor isolation issues
    private static func parseMessageStatic(_ message: String) -> TranscriptionResult? {
        guard let data = message.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        guard let header = json["header"] as? [String: Any],
              let event = header["event"] as? String else {
            return nil
        }

        switch event {
        case "task-started":
            // Note: task-started handling is done via handleTaskStarted() called by the adapter
            return nil

        case "result-generated":
            guard let payload = json["payload"] as? [String: Any],
                  let output = payload["output"] as? [String: Any],
                  let sentence = output["sentence"] as? [String: Any],
                  let text = sentence["text"] as? String,
                  !text.isEmpty else {
                return nil
            }
            let isFinal = sentence["sentence_end"] as? Bool ?? false
            let beginTime = sentence["begin_time"] as? Int ?? 0
            let endTime = sentence["end_time"] as? Int ?? 0
            if isFinal {
                Logger.info("🎬 [WS-PARSE] Final result parsed: \"\(text)\" (\(beginTime)-\(endTime)ms)", category: .stt)
            } else {
                Logger.info("🎬 [WS-PARSE] Partial result parsed: \"\(text)\" (\(beginTime)-\(endTime)ms)", category: .stt)
            }
            return isFinal ? .final(text) : .partial(text)

        case "task-finished":
            // Task completed - return empty final result to signal completion
            Logger.info("🎬 [WS-PARSE] task-finished received from server", category: .stt)
            return .final("")

        case "task-failed":
            let errorMessage = header["error_message"] as? String ?? "Unknown error"
            Logger.error("🎬 [WS-PARSE] task-failed: \(errorMessage)", category: .stt)
            return .error(TranscriptionError.serverError(500, errorMessage))

        default:
            return nil
        }
    }

    public func disconnect() async {
        await webSocketManager.disconnect()
        config = nil
        isTaskStarted = false
        isFinished = false
        totalAudioReceived = 0
        totalAudioSent = 0
        audioQueue.removeAll()
        nextSequenceNumber = 0
        isProcessingQueue = false
        // Clean up any waiting continuation
        if let continuation = taskStartedContinuation {
            taskStartedContinuation = nil
            continuation.resume()
        }
    }
}
