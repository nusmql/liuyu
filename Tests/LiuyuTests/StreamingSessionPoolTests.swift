import Foundation
import XCTest
@testable import LiuyuLib

final class StreamingSessionPoolTests: XCTestCase {
    func testAcquireReusesConnectedSessionForSameKey() async throws {
        let pool = StreamingSessionPool()
        let key = Self.key(apiFormat: .glmRealtime)
        let firstStrategy = PoolTestStrategy()

        let firstLease = await pool.acquireSession(for: key) {
            Self.session(strategy: firstStrategy)
        }
        XCTAssertEqual(firstLease.state, .created)
        try await firstLease.session.connect()

        let secondLease = await pool.acquireSession(for: key) {
            Self.session(strategy: PoolTestStrategy())
        }

        XCTAssertEqual(secondLease.state, .reused)
        let isConnected = await secondLease.session.connected
        let connectCount = await firstStrategy.connectCount
        let disconnectCount = await firstStrategy.disconnectCount
        XCTAssertTrue(isConnected)
        XCTAssertEqual(connectCount, 1)
        XCTAssertEqual(disconnectCount, 0)
    }

    func testAcquireReplacesSessionForDifferentKey() async throws {
        let pool = StreamingSessionPool()
        let oldStrategy = PoolTestStrategy()

        let firstLease = await pool.acquireSession(for: Self.key(model: "old")) {
            Self.session(strategy: oldStrategy)
        }
        try await firstLease.session.connect()

        let secondLease = await pool.acquireSession(for: Self.key(model: "new")) {
            Self.session(strategy: PoolTestStrategy())
        }

        XCTAssertEqual(secondLease.state, .replaced)
        let disconnectCount = await oldStrategy.disconnectCount
        XCTAssertEqual(disconnectCount, 1)
    }

    func testPrewarmDoesNotReplaceDifferentActiveKey() async throws {
        let pool = StreamingSessionPool()
        let activeLease = await pool.acquireSession(for: Self.key(model: "active")) {
            Self.session(strategy: PoolTestStrategy())
        }
        try await activeLease.session.connect()

        let prewarmedSession = Self.session(strategy: PoolTestStrategy())
        try await prewarmedSession.connect()

        let state = await pool.installPrewarmedSession(
            prewarmedSession,
            for: Self.key(model: "other")
        )

        XCTAssertEqual(state, .discardedExistingDifferentKey)
        let isConnected = await activeLease.session.connected
        XCTAssertTrue(isConnected)
    }

    func testDisconnectCanKeepAliveMatchingProvider() async throws {
        let pool = StreamingSessionPool()
        let strategy = PoolTestStrategy()
        let lease = await pool.acquireSession(for: Self.key(apiFormat: .glmRealtime)) {
            Self.session(strategy: strategy)
        }
        try await lease.session.connect()

        await pool.disconnectCurrent(keepingAliveFor: .glmRealtime)
        let connectedAfterKeepAlive = await lease.session.connected
        let disconnectCountAfterKeepAlive = await strategy.disconnectCount
        XCTAssertTrue(connectedAfterKeepAlive)
        XCTAssertEqual(disconnectCountAfterKeepAlive, 0)

        await pool.disconnectCurrent()
        let disconnectCountAfterClose = await strategy.disconnectCount
        XCTAssertEqual(disconnectCountAfterClose, 1)
    }

    private static func key(
        model: String = "model",
        apiFormat: ApiFormat = .glmRealtime
    ) -> StreamingSessionKey {
        StreamingSessionKey(
            apiKey: "key",
            endpoint: "wss://example.test/realtime",
            model: model,
            apiFormat: apiFormat,
            language: nil
        )
    }

    private static func session(strategy: TranscriptionStrategy) -> StreamingTranscriptionSession {
        StreamingTranscriptionSession(
            strategy: strategy,
            config: TranscriptionConfig(
                apiKey: "key",
                endpoint: "wss://example.test/realtime",
                model: "model"
            )
        )
    }
}

private actor PoolTestStrategy: TranscriptionStrategy {
    let strategyId = "pool-test"
    let supportsStreaming = true
    private(set) var connectCount = 0
    private(set) var disconnectCount = 0

    func connect(config: TranscriptionConfig) async throws {
        connectCount += 1
    }

    func sendAudio(_ data: Data, isFinal: Bool) async throws {}

    nonisolated func receiveResults() -> AsyncStream<TranscriptionResult> {
        AsyncStream { continuation in
            continuation.finish()
        }
    }

    func disconnect() async {
        disconnectCount += 1
    }
}
