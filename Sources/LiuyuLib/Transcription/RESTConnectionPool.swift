import Foundation

struct RESTConnectionKey: Hashable, Sendable {
    let scheme: String
    let host: String
    let port: Int?

    init(endpoint: String) {
        if let url = URL(string: endpoint), let host = url.host {
            self.scheme = url.scheme ?? "https"
            self.host = host
            self.port = url.port
        } else {
            self.scheme = "unknown"
            self.host = endpoint
            self.port = nil
        }
    }

    var traceDescription: String {
        if let port {
            return "\(scheme)://\(host):\(port)"
        }
        return "\(scheme)://\(host)"
    }
}

enum RESTConnectionLeaseState: String, Sendable {
    case reused
    case created
    case injected
}

struct RESTConnectionLease: Sendable {
    let session: URLSession
    let state: RESTConnectionLeaseState
    let keyDescription: String
    let sessionCount: Int
}

final class RESTConnectionPool: @unchecked Sendable {
    static let shared = RESTConnectionPool()

    private let lock = NSLock()
    private let timeoutIntervalForRequest: TimeInterval
    private var sessions: [RESTConnectionKey: URLSession] = [:]

    init(timeoutIntervalForRequest: TimeInterval = 30) {
        self.timeoutIntervalForRequest = timeoutIntervalForRequest
    }

    func lease(for endpoint: String) -> RESTConnectionLease {
        let key = RESTConnectionKey(endpoint: endpoint)
        lock.lock()
        defer { lock.unlock() }

        if let session = sessions[key] {
            return RESTConnectionLease(
                session: session,
                state: .reused,
                keyDescription: key.traceDescription,
                sessionCount: sessions.count
            )
        }

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = timeoutIntervalForRequest
        let session = URLSession(configuration: config)
        sessions[key] = session
        return RESTConnectionLease(
            session: session,
            state: .created,
            keyDescription: key.traceDescription,
            sessionCount: sessions.count
        )
    }

    func reset() {
        lock.lock()
        let sessionsToClose = sessions.values
        sessions.removeAll()
        lock.unlock()

        for session in sessionsToClose {
            session.invalidateAndCancel()
        }
    }
}
