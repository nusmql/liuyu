import Foundation

struct StreamingSessionKey: Equatable, Sendable {
    let apiKey: String
    let endpoint: String
    let model: String
    let apiFormat: ApiFormat
    let language: String?
}

enum StreamingSessionPoolAcquireState: Equatable, Sendable {
    case reused
    case created
    case replaced
}

struct StreamingSessionPoolLease: Sendable {
    let session: StreamingTranscriptionSession
    let state: StreamingSessionPoolAcquireState
}

enum StreamingSessionPoolInstallState: Equatable, Sendable {
    case installed
    case replaced
    case alreadyConnected
    case discardedExistingDifferentKey
}

actor StreamingSessionPool {
    private var currentSession: StreamingTranscriptionSession?
    private var currentKey: StreamingSessionKey?

    func acquireSession(
        for key: StreamingSessionKey,
        create: @Sendable () -> StreamingTranscriptionSession
    ) async -> StreamingSessionPoolLease {
        if let currentSession,
           currentKey == key,
           await currentSession.connected {
            return StreamingSessionPoolLease(session: currentSession, state: .reused)
        }

        let oldSession = currentSession
        let state: StreamingSessionPoolAcquireState = oldSession == nil ? .created : .replaced
        currentSession = nil
        currentKey = nil
        await oldSession?.disconnect()

        let session = create()
        currentSession = session
        currentKey = key
        return StreamingSessionPoolLease(session: session, state: state)
    }

    func installPrewarmedSession(
        _ session: StreamingTranscriptionSession,
        for key: StreamingSessionKey
    ) async -> StreamingSessionPoolInstallState {
        if let currentSession,
           currentKey == key,
           await currentSession.connected {
            return .alreadyConnected
        }

        guard currentKey == nil || currentKey == key else {
            return .discardedExistingDifferentKey
        }

        let oldSession = currentSession
        let state: StreamingSessionPoolInstallState = oldSession == nil ? .installed : .replaced
        currentSession = nil
        currentKey = nil
        await oldSession?.disconnect()

        currentSession = session
        currentKey = key
        return state
    }

    func current() -> StreamingTranscriptionSession? {
        currentSession
    }

    func key() -> StreamingSessionKey? {
        currentKey
    }

    func isConnected(for key: StreamingSessionKey) async -> Bool {
        guard currentKey == key, let currentSession else { return false }
        return await currentSession.connected
    }

    func diagnostics() async -> StreamingQueueDiagnostics? {
        guard let currentSession else { return nil }
        return await currentSession.diagnostics()
    }

    func disconnectCurrent(keepingAliveFor apiFormat: ApiFormat? = nil) async {
        if let apiFormat,
           currentKey?.apiFormat == apiFormat,
           let currentSession,
           await currentSession.connected {
            return
        }

        let sessionToDisconnect = currentSession
        currentSession = nil
        currentKey = nil
        await sessionToDisconnect?.disconnect()
    }
}
