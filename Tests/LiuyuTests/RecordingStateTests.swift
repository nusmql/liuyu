// Tests/LiuyuTests/RecordingStateTests.swift
import XCTest
import Combine
@testable import LiuyuLib

@MainActor
final class RecordingStateTests: XCTestCase {
    var state: RecordingState!
    var cancellables: Set<AnyCancellable> = []

    override func setUp() {
        super.setUp()
        state = RecordingState.shared
        state.cancel() // Reset to idle
    }

    override func tearDown() {
        state.cancel()
        cancellables.removeAll()
        super.tearDown()
    }

    // MARK: - State Transition Tests

    func testInitialStateIsIdle() {
        XCTAssertEqual(state.phase, .idle)
    }

    func testKeyDownTransitionsToDebouncing() {
        let expectation = expectation(description: "State changes to debouncing")

        state.$phase
            .filter { $0 == .debouncing }
            .first()
            .sink { _ in
                expectation.fulfill()
            }
            .store(in: &cancellables)

        state.keyDown()

        wait(for: [expectation], timeout: 0.1)
        XCTAssertEqual(state.phase, .debouncing)
    }

    func testDebounceCompletesToRecording() {
        // Set short debounce for testing
        state.configuration.debounceDuration = 0.2

        let expectation = expectation(description: "State changes to recording")

        state.$phase
            .filter { $0 == .recording }
            .first()
            .sink { _ in
                expectation.fulfill()
            }
            .store(in: &cancellables)

        state.keyDown()
        XCTAssertEqual(state.phase, .debouncing)

        wait(for: [expectation], timeout: 2.0)
        XCTAssertEqual(state.phase, .recording)
        XCTAssertNotNil(state.recordingStartTime)
    }

    func testKeyUpDuringDebounceCancels() {
        state.keyDown()
        XCTAssertEqual(state.phase, .debouncing)

        state.keyUp()
        XCTAssertEqual(state.phase, .idle)
    }

    func testKeyUpDuringRecordingStops() {
        // Set short debounce but low minimum duration for testing
        state.configuration.debounceDuration = 0.1
        state.configuration.minimumRecordingDuration = 0.05

        let recordingExpectation = expectation(description: "State changes to recording")
        let processingExpectation = expectation(description: "State changes to processing")

        state.$phase
            .filter { $0 == .recording }
            .first()
            .sink { [weak self] _ in
                recordingExpectation.fulfill()
                // Wait a bit to exceed minimum duration, then simulate keyUp
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    self?.state.keyUp()
                }
            }
            .store(in: &cancellables)

        state.$phase
            .filter { $0 == .processing }
            .first()
            .sink { _ in
                processingExpectation.fulfill()
            }
            .store(in: &cancellables)

        state.keyDown()

        wait(for: [recordingExpectation, processingExpectation], timeout: 2.0)
        XCTAssertEqual(state.phase, .processing)
    }

    func testDoubleKeyDownIgnored() {
        state.keyDown()
        XCTAssertEqual(state.phase, .debouncing)

        // Second keyDown should be ignored
        state.keyDown()
        XCTAssertEqual(state.phase, .debouncing)
    }

    // MARK: - Audio Activity Tests

    func testAudioActivityUpdatesLastActivityTime() {
        state.configuration.debounceDuration = 0.1
        state.keyDown()

        let expectation = expectation(description: "State changes to recording")

        state.$phase
            .filter { $0 == .recording }
            .first()
            .sink { [weak self] _ in
                // Simulate audio activity
                self?.state.updateAudioActivity(level: 0.5)
                XCTAssertNotNil(self?.state.lastAudioActivity)
                expectation.fulfill()
            }
            .store(in: &cancellables)

        wait(for: [expectation], timeout: 1.0)
    }

    func testSilenceTimeoutTransitionsToProcessing() {
        state.configuration.debounceDuration = 0.05
        state.configuration.silenceTimeout = 0.2 // Short for testing

        let recordingExpectation = expectation(description: "State changes to recording")
        let processingExpectation = expectation(description: "State changes to processing")

        state.$phase
            .filter { $0 == .recording }
            .first()
            .sink { _ in
                recordingExpectation.fulfill()
            }
            .store(in: &cancellables)

        state.$phase
            .filter { $0 == .processing }
            .first()
            .sink { _ in
                processingExpectation.fulfill()
            }
            .store(in: &cancellables)

        state.keyDown()

        wait(for: [recordingExpectation, processingExpectation], timeout: 2.0)
        XCTAssertEqual(state.phase, .processing)
    }

    // MARK: - Configuration Tests

    func testConfigurationIsConfigurable() {
        var config = RecordingState.Configuration()
        config.debounceDuration = 1.0
        config.silenceTimeout = 10.0
        config.minimumRecordingDuration = 0.5

        state.configuration = config

        XCTAssertEqual(state.configuration.debounceDuration, 1.0)
        XCTAssertEqual(state.configuration.silenceTimeout, 10.0)
        XCTAssertEqual(state.configuration.minimumRecordingDuration, 0.5)
    }
}
