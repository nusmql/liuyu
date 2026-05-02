import XCTest
@testable import LiuyuLib

final class EditPipelineStateTests: XCTestCase {
    func testVoiceEditShowsTranscribingAfterRecordingStops() {
        XCTAssertEqual(editStateAfterRecordingStops(hasExistingText: true), .transcribing)
    }

    func testNewDictationShowsTranscribingAfterRecordingStops() {
        XCTAssertEqual(editStateAfterRecordingStops(hasExistingText: false), .transcribing)
    }

    func testVoiceEditShowsEditingOnlyAfterInstructionTranscriptionCompletes() {
        XCTAssertEqual(editStateAfterTranscriptionCompletes(hasExistingText: true), .editing)
    }

    func testStreamingPartialKeepsExistingTextDuringVoiceEdit() {
        XCTAssertEqual(
            streamingPartialTextUpdate(hadExistingTextAtRecordingStart: true, partialText: "make it shorter"),
            .keepExistingText
        )
    }

    func testStreamingPartialReplacesTextForNewDictation() {
        XCTAssertEqual(
            streamingPartialTextUpdate(hadExistingTextAtRecordingStart: false, partialText: "hello"),
            .replaceText("hello")
        )
    }
}
