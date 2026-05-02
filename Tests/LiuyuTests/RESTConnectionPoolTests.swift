import Foundation
import XCTest
@testable import LiuyuLib

final class RESTConnectionPoolTests: XCTestCase {
    func testLeaseReusesSessionForSameHost() {
        let pool = RESTConnectionPool()
        defer { pool.reset() }

        let first = pool.lease(for: "https://api.example.com/v1/audio/transcriptions")
        let second = pool.lease(for: "https://api.example.com/v1/chat/completions")

        XCTAssertEqual(first.state, .created)
        XCTAssertEqual(second.state, .reused)
        XCTAssertTrue(first.session === second.session)
        XCTAssertEqual(second.sessionCount, 1)
    }

    func testLeaseSeparatesDifferentHosts() {
        let pool = RESTConnectionPool()
        defer { pool.reset() }

        let first = pool.lease(for: "https://api.example.com/v1/audio/transcriptions")
        let second = pool.lease(for: "https://open.bigmodel.cn/api/paas/v4/audio/transcriptions")

        XCTAssertEqual(first.state, .created)
        XCTAssertEqual(second.state, .created)
        XCTAssertFalse(first.session === second.session)
        XCTAssertEqual(second.sessionCount, 2)
    }

    func testResetDropsExistingSessions() {
        let pool = RESTConnectionPool()

        let first = pool.lease(for: "https://api.example.com/v1/audio/transcriptions")
        pool.reset()
        let second = pool.lease(for: "https://api.example.com/v1/audio/transcriptions")
        defer { pool.reset() }

        XCTAssertEqual(second.state, .created)
        XCTAssertFalse(first.session === second.session)
        XCTAssertEqual(second.sessionCount, 1)
    }
}
