// Tests/LiuyuTests/HotkeyTests.swift
import XCTest
import CoreGraphics
@testable import LiuyuLib

final class HotkeyTests: XCTestCase {

    // MARK: - RecordedShortcut Tests

    func testFnOnlyShortcutIsValid() {
        let shortcut = RecordedShortcut(flags: [], keyCode: nil, includesFnKey: true)
        XCTAssertTrue(shortcut.isValid, "Fn-only shortcut should be valid")
        XCTAssertTrue(shortcut.isModifierOnly, "Fn-only should be modifier-only")
        XCTAssertEqual(shortcut.displayString, "Fn")
    }

    func testOptionOnlyShortcutIsValid() {
        let shortcut = RecordedShortcut(flags: .maskAlternate, keyCode: nil, includesFnKey: false)
        XCTAssertTrue(shortcut.isValid, "Option-only shortcut should be valid")
        XCTAssertTrue(shortcut.isModifierOnly, "Option-only should be modifier-only")
        XCTAssertEqual(shortcut.displayString, "⌥")
    }

    func testFnPlusCtrlShortcutIsValid() {
        let shortcut = RecordedShortcut(flags: .maskControl, keyCode: nil, includesFnKey: true)
        XCTAssertTrue(shortcut.isValid, "Fn+Ctrl shortcut should be valid")
        XCTAssertTrue(shortcut.isModifierOnly, "Fn+Ctrl should be modifier-only")
        XCTAssertEqual(shortcut.displayString, "Fn ⌃")
    }

    func testKeyCombinationIsNotModifierOnly() {
        let shortcut = RecordedShortcut(flags: .maskCommand, keyCode: 15, includesFnKey: false) // Cmd+R
        XCTAssertTrue(shortcut.isValid, "Key combination should be valid")
        XCTAssertFalse(shortcut.isModifierOnly, "Key combination should not be modifier-only")
    }

    func testEmptyShortcutIsNotValid() {
        let shortcut = RecordedShortcut(flags: [], keyCode: nil, includesFnKey: false)
        XCTAssertFalse(shortcut.isValid, "Empty shortcut should not be valid")
        XCTAssertTrue(shortcut.isModifierOnly, "Empty shortcut should be modifier-only (no key)")
    }

    func testFnPlusKeyIsNotModifierOnly() {
        let shortcut = RecordedShortcut(flags: [], keyCode: 122, includesFnKey: true) // Fn+F1
        XCTAssertTrue(shortcut.isValid, "Fn+Key should be valid")
        XCTAssertFalse(shortcut.isModifierOnly, "Fn+Key should not be modifier-only (has key)")
    }

    // MARK: - KeyCode Tests

    func testKeyCodeZeroIsStoredAsFFFF() {
        // Key A (keyCode 0) should be stored as 0xFFFF to distinguish from "no key"
        let shortcut = RecordedShortcut(flags: [], keyCode: 0, includesFnKey: false)
        XCTAssertEqual(shortcut.keyCode, 0, "keyCode should return 0")
        XCTAssertFalse(shortcut.isModifierOnly, "Key A should not be modifier-only")
    }

    func testNilKeyCodeIsModifierOnly() {
        let shortcut = RecordedShortcut(flags: .maskControl, keyCode: nil, includesFnKey: false)
        XCTAssertEqual(shortcut.keyCode, 0, "Nil keyCode should return 0")
        XCTAssertTrue(shortcut.isModifierOnly, "Nil keyCode should be modifier-only")
    }

    // MARK: - Display String Tests

    func testDisplayStringForFnOnly() {
        let shortcut = RecordedShortcut(flags: [], keyCode: nil, includesFnKey: true)
        XCTAssertEqual(shortcut.displayString, "Fn")
    }

    func testDisplayStringForModifiers() {
        let shortcut = RecordedShortcut(flags: [.maskControl, .maskAlternate], keyCode: nil, includesFnKey: false)
        // Note: displayString uses space separator between parts
        XCTAssertEqual(shortcut.displayString, "⌃ ⌥")
    }

    func testDisplayStringForFnWithModifiers() {
        let shortcut = RecordedShortcut(flags: .maskShift, keyCode: nil, includesFnKey: true)
        XCTAssertEqual(shortcut.displayString, "Fn ⇧")
    }

    // MARK: - Modifier Matching Logic Tests

    func testFnOnlyModifierMatching() {
        // Simulate the logic in handleFlagsChangedEvent for Fn-only shortcut
        let shortcut = RecordedShortcut(flags: [], keyCode: nil, includesFnKey: true)

        // When Fn is pressed (maskSecondaryFn = 0x800100)
        let flagsWhenPressed: CGEventFlags = .maskSecondaryFn
        let fnKeyPressed = flagsWhenPressed.contains(.maskSecondaryFn)
        let fnMatch = shortcut.includesFnKey == fnKeyPressed
        XCTAssertTrue(fnMatch, "Fn key should match when pressed")

        // When Fn is released (flags = 0x100)
        let flagsWhenReleased: CGEventFlags = .maskAlphaShift // Just an example of no Fn
        let fnKeyReleased = flagsWhenReleased.contains(.maskSecondaryFn)
        let fnMatchReleased = shortcut.includesFnKey == fnKeyReleased
        XCTAssertFalse(fnMatchReleased, "Fn key should not match when released")
    }

    func testModifierOnlyMatching() {
        // For Option-only shortcut
        let shortcut = RecordedShortcut(flags: .maskAlternate, keyCode: nil, includesFnKey: false)

        // When Option is pressed
        let targetFlags = shortcut.flags
        let flagsWhenPressed: CGEventFlags = .maskAlternate
        let modifierMatch = flagsWhenPressed.intersection(targetFlags) == targetFlags
        XCTAssertTrue(modifierMatch, "Option modifier should match")

        // When Option is released
        let flagsWhenReleased: CGEventFlags = []
        let modifierMatchReleased = flagsWhenReleased.intersection(targetFlags) == targetFlags
        XCTAssertFalse(modifierMatchReleased, "No modifier should not match")
    }

    func testModifierOnlyRequiresExactModifiers() {
        let shortcut = RecordedShortcut(flags: .maskAlternate, keyCode: nil)

        XCTAssertTrue(ShortcutMatcher.matches(
            cgFlags: .maskAlternate,
            keyCode: nil,
            shortcut: shortcut
        ))

        XCTAssertFalse(ShortcutMatcher.matches(
            cgFlags: [.maskAlternate, .maskCommand],
            keyCode: nil,
            shortcut: shortcut
        ))
    }

    func testKeyCombinationRequiresExactModifiersAndKey() {
        let shortcut = RecordedShortcut(flags: [.maskCommand, .maskShift], keyCode: 15)

        XCTAssertTrue(ShortcutMatcher.matches(
            cgFlags: [.maskCommand, .maskShift],
            keyCode: 15,
            shortcut: shortcut
        ))

        XCTAssertFalse(ShortcutMatcher.matches(
            cgFlags: [.maskCommand, .maskShift, .maskAlternate],
            keyCode: 15,
            shortcut: shortcut
        ))

        XCTAssertFalse(ShortcutMatcher.matches(
            cgFlags: [.maskCommand, .maskShift],
            keyCode: 16,
            shortcut: shortcut
        ))
    }

    func testFnMustMatchSeparately() {
        let shortcut = RecordedShortcut(flags: .maskControl, keyCode: nil, includesFnKey: true)

        XCTAssertTrue(ShortcutMatcher.matches(
            cgFlags: [.maskControl, .maskSecondaryFn],
            keyCode: nil,
            shortcut: shortcut
        ))

        XCTAssertFalse(ShortcutMatcher.matches(
            cgFlags: .maskControl,
            keyCode: nil,
            shortcut: shortcut
        ))
    }

    func testShortcutRecordingCancelPreservesCommittedShortcut() {
        var state = ShortcutRecorderState(committed: .default, draft: nil)

        state.begin()
        state.cancel()

        XCTAssertEqual(state.committed, .default)
        XCTAssertNil(state.draft)
    }

    func testShortcutRecordingCommitReplacesCommittedShortcut() {
        var state = ShortcutRecorderState(committed: .default, draft: nil)
        let replacement = RecordedShortcut(flags: [.maskControl, .maskAlternate], keyCode: nil)

        state.begin()
        state.commit(replacement)

        XCTAssertEqual(state.committed, replacement)
        XCTAssertNil(state.draft)
    }
}
