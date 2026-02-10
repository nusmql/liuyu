import XCTest
@testable import LiuyuLib

final class KeychainHelperTests: XCTestCase {
    let testService = "com.liuyu.test"

    override func tearDown() {
        // Clean up test keys
        let helper = KeychainHelper(service: testService)
        try? helper.delete(key: "api-key")
        try? helper.delete(key: "nonexistent")
        try? helper.delete(key: "to-delete")
        super.tearDown()
    }

    func testSaveAndRead() throws {
        let helper = KeychainHelper(service: testService)
        try helper.save(key: "api-key", value: "sk-test-123")
        let result = try helper.read(key: "api-key")
        XCTAssertEqual(result, "sk-test-123")
    }

    func testReadMissing() throws {
        let helper = KeychainHelper(service: testService)
        let result = try helper.read(key: "nonexistent")
        XCTAssertNil(result)
    }

    func testOverwrite() throws {
        let helper = KeychainHelper(service: testService)
        try helper.save(key: "api-key", value: "old-value")
        try helper.save(key: "api-key", value: "new-value")
        let result = try helper.read(key: "api-key")
        XCTAssertEqual(result, "new-value")
    }

    func testDelete() throws {
        let helper = KeychainHelper(service: testService)
        try helper.save(key: "to-delete", value: "delete-me")
        try helper.delete(key: "to-delete")
        let result = try helper.read(key: "to-delete")
        XCTAssertNil(result)
    }
}
