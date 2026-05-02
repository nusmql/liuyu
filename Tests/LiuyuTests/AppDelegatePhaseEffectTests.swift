import XCTest
@testable import LiuyuLib

final class AppDelegatePhaseEffectTests: XCTestCase {
    func testIdlePhaseRequestsVoiceSessionCleanup() {
        XCTAssertEqual(recordingPhaseEffect(for: .idle), .cleanupVoiceSession)
    }

    func testNewGlobalRecordingClearsVisibleEditWindow() {
        XCTAssertEqual(editWindowPreparationForNewGlobalRecording(isEditWindowVisible: true), .clearEditWindow)
    }

    func testNewGlobalRecordingDoesNotClearHiddenEditWindow() {
        XCTAssertEqual(editWindowPreparationForNewGlobalRecording(isEditWindowVisible: false), .none)
    }
}
