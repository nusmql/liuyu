import XCTest
@testable import LiuyuLib

final class AppDelegatePhaseEffectTests: XCTestCase {
    func testIdlePhaseRequestsVoiceSessionCleanup() {
        XCTAssertEqual(recordingPhaseEffect(for: .idle), .cleanupVoiceSession)
    }
}
