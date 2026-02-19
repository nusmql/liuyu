// Sources/LiuyuLib/Settings/ShortcutRecorder.swift
import Cocoa
import CoreGraphics

/// Protocol for receiving events from ShortcutRecorder.
@MainActor public protocol ShortcutRecorderDelegate: AnyObject {
    /// Called when the recorder begins recording mode.
    func shortcutRecorderDidBeginRecording(_ recorder: ShortcutRecorder)

    /// Called when recording finishes (or is cancelled with nil).
    func shortcutRecorder(_ recorder: ShortcutRecorder, didRecord shortcut: RecordedShortcut?)
}

/// An NSView that allows users to record a keyboard shortcut by pressing modifier keys.
public class ShortcutRecorder: NSView {

    // MARK: - Public Properties

    public weak var delegate: ShortcutRecorderDelegate?

    // MARK: - Private Properties

    private var isRecording = false
    private var localMonitor: Any?
    private var currentFlags: CGEventFlags = []
    private var currentKeyCode: UInt16 = 0
    private var currentIncludesFnKey: Bool = false

    private let label: NSTextField
    private let clearButton: NSButton

    private var currentShortcut: RecordedShortcut?

    // MARK: - Constants

    private enum Constants {
        static let cornerRadius: CGFloat = 6
        static let borderWidth: CGFloat = 1
        static let height: CGFloat = 28
        static let buttonWidth: CGFloat = 24
        static let padding: CGFloat = 8
    }

    // MARK: - Initialization

    public init() {
        label = NSTextField(labelWithString: "Click to record")
        clearButton = NSButton(title: "×", target: nil, action: nil)

        super.init(frame: .zero)

        setupUI()
        setupConstraints()
        updateAppearance()
    }

    required init?(coder: NSCoder) {
        label = NSTextField(labelWithString: "Click to record")
        clearButton = NSButton(title: "×", target: nil, action: nil)

        super.init(coder: coder)

        setupUI()
        setupConstraints()
        updateAppearance()
    }

    // MARK: - UI Setup

    private func setupUI() {
        wantsLayer = true
        layer?.cornerRadius = Constants.cornerRadius
        layer?.borderWidth = Constants.borderWidth

        // Label setup
        label.alignment = .center
        label.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        label.textColor = .secondaryLabelColor
        label.isEditable = false
        label.isSelectable = false
        label.isBordered = false
        label.backgroundColor = .clear
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        // Clear button setup
        clearButton.bezelStyle = .rounded
        clearButton.setButtonType(.momentaryPushIn)
        clearButton.target = self
        clearButton.action = #selector(clearButtonClicked)
        clearButton.toolTip = "Clear shortcut"
        clearButton.translatesAutoresizingMaskIntoConstraints = false
        clearButton.isHidden = true
        addSubview(clearButton)

        // Click gesture
        let clickGesture = NSClickGestureRecognizer(target: self, action: #selector(viewClicked))
        addGestureRecognizer(clickGesture)
    }

    private func setupConstraints() {
        NSLayoutConstraint.activate([
            // Height constraint
            heightAnchor.constraint(equalToConstant: Constants.height),

            // Label constraints - centered
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: Constants.padding),
            label.trailingAnchor.constraint(lessThanOrEqualTo: clearButton.leadingAnchor, constant: -4),

            // Clear button constraints - right side
            clearButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            clearButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            clearButton.widthAnchor.constraint(equalToConstant: Constants.buttonWidth),
            clearButton.heightAnchor.constraint(equalToConstant: Constants.buttonWidth)
        ])
    }

    // MARK: - Public Methods

    /// Sets the current shortcut and updates the display.
    public func setShortcut(_ shortcut: RecordedShortcut?) {
        currentShortcut = shortcut
        updateLabel()
        updateAppearance()
    }

    // MARK: - Private Methods

    @objc private func viewClicked() {
        if !isRecording {
            startRecording()
        }
    }

    @objc private func clearButtonClicked() {
        setShortcut(nil)
        delegate?.shortcutRecorder(self, didRecord: nil)
    }

    private func updateLabel() {
        if isRecording {
            if currentFlags.isEmpty && currentKeyCode == 0 && !currentIncludesFnKey {
                label.stringValue = "Press shortcut..."
                label.textColor = .controlAccentColor
            } else {
                let flagsStr = flagsDisplayString(currentFlags)
                let keyStr = KeyCodeMap.string(for: currentKeyCode) ?? ""
                let fnPrefix = currentIncludesFnKey ? "Fn " : ""
                label.stringValue = fnPrefix + flagsStr + keyStr
                label.textColor = .labelColor
            }
        } else {
            if let shortcut = currentShortcut, shortcut.isValid {
                label.stringValue = shortcut.displayString
                label.textColor = .labelColor
                clearButton.isHidden = false
            } else {
                label.stringValue = "Click to record"
                label.textColor = .secondaryLabelColor
                clearButton.isHidden = true
            }
        }
    }

    private func updateAppearance() {
        if isRecording {
            layer?.borderColor = NSColor.systemRed.cgColor
            layer?.backgroundColor = NSColor.systemRed.withAlphaComponent(0.05).cgColor
        } else {
            layer?.borderColor = NSColor.separatorColor.cgColor
            layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        }
    }

    private func flagsDisplayString(_ flags: CGEventFlags) -> String {
        var symbols: [String] = []

        if flags.contains(.maskControl) {
            symbols.append("⌃")
        }
        if flags.contains(.maskAlternate) {
            symbols.append("⌥")
        }
        if flags.contains(.maskShift) {
            symbols.append("⇧")
        }
        if flags.contains(.maskCommand) {
            symbols.append("⌘")
        }

        return symbols.joined()
    }

    // MARK: - Recording

    private func startRecording() {
        isRecording = true
        currentFlags = []
        updateLabel()
        updateAppearance()

        NotificationCenter.default.post(name: .hotkeyRecordingDidBegin, object: self)
        delegate?.shortcutRecorderDidBeginRecording(self)

        // Install local event monitor for key events
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown, .keyUp]) { [weak self] event in
            guard let self = self else { return event }

            switch event.type {
            case .flagsChanged:
                self.handleFlagsChanged(event)
                return nil // Consume the event

            case .keyDown:
                if event.keyCode == 53 { // Escape key
                    self.cancelRecording()
                } else if event.keyCode == 36 { // Return key
                    self.finishRecording()
                } else {
                    // Capture the key code along with modifiers
                    // Also check if Fn is being held
                    if event.modifierFlags.contains(.function) {
                        self.currentIncludesFnKey = true
                    }
                    self.currentKeyCode = event.keyCode
                    self.updateLabel()
                    self.finishRecording()
                }
                return nil // Consume the event

            default:
                return event
            }
        }

        // Also install a global monitor to catch events outside our window
        // This helps ensure we don't miss the key release
        NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { [weak self] event in
            guard let self = self else { return }

            if event.type == .flagsChanged {
                DispatchQueue.main.async {
                    self.handleFlagsChanged(event)
                }
            } else if event.type == .keyDown {
                DispatchQueue.main.async {
                    if event.keyCode == 53 { // Escape
                        self.cancelRecording()
                    } else {
                        // Check if Fn is being held during key press
                        if event.modifierFlags.contains(.function) {
                            self.currentIncludesFnKey = true
                        }
                        self.currentKeyCode = event.keyCode
                        self.updateLabel()
                        self.finishRecording()
                    }
                }
            }
        }
    }

    private func handleFlagsChanged(_ event: NSEvent) {
        let flags = event.modifierFlags

        // Check for Fn key
        if flags.contains(.function) {
            currentIncludesFnKey = true
        }

        // Get device-independent flags
        let deviceFlags = flags.intersection(.deviceIndependentFlagsMask)

        // Convert NSEvent modifier flags to CGEventFlags
        var cgFlags: CGEventFlags = []
        if deviceFlags.contains(.control) {
            cgFlags.insert(.maskControl)
        }
        if deviceFlags.contains(.option) {
            cgFlags.insert(.maskAlternate)
        }
        if deviceFlags.contains(.shift) {
            cgFlags.insert(.maskShift)
        }
        if deviceFlags.contains(.command) {
            cgFlags.insert(.maskCommand)
        }

        currentFlags = cgFlags
        updateLabel()

        // If all modifiers are released and we had some before, finish recording
        if cgFlags.isEmpty && !currentFlags.isEmpty {
            // Small delay to allow for key combinations
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                guard let self = self, self.isRecording else { return }
                if self.currentFlags.isEmpty {
                    // If still empty after delay, user released all keys
                    // Don't auto-finish - wait for Return or another key
                }
            }
        }
    }

    private func finishRecording() {
        guard isRecording else { return }

        let shortcut: RecordedShortcut?
        if currentFlags.isEmpty && currentKeyCode == 0 && !currentIncludesFnKey {
            shortcut = nil
        } else {
            shortcut = RecordedShortcut(flags: currentFlags, keyCode: currentKeyCode, includesFnKey: currentIncludesFnKey)
        }

        cleanupRecording()

        if let shortcut = shortcut {
            setShortcut(shortcut)
        }

        // Call delegate first to update the shortcut, THEN post notification
        delegate?.shortcutRecorder(self, didRecord: shortcut)
        NotificationCenter.default.post(name: .hotkeyRecordingDidEnd, object: self)
    }

    private func cancelRecording() {
        guard isRecording else { return }

        cleanupRecording()
        updateLabel()
        updateAppearance()

        // Call delegate first, THEN post notification
        delegate?.shortcutRecorder(self, didRecord: nil)
        NotificationCenter.default.post(name: .hotkeyRecordingDidEnd, object: self)
    }

    private func cleanupRecording() {
        isRecording = false
        currentFlags = []
        currentKeyCode = 0
        currentIncludesFnKey = false

        if let monitor = localMonitor {
            NSEvent.removeMonitor(monitor)
            localMonitor = nil
        }
    }

    // MARK: - Cleanup

    deinit {
        // Clean up the monitor if it exists
        // Use MainActor.assumeIsolated since NSView deinit runs on MainActor
        MainActor.assumeIsolated {
            if let monitor = localMonitor {
                NSEvent.removeMonitor(monitor)
            }
        }
    }
}

// MARK: - SwiftUI Wrapper

import SwiftUI

/// A SwiftUI wrapper for ShortcutRecorder.
public struct ShortcutRecorderView: NSViewRepresentable {
    @Binding var shortcut: RecordedShortcut?
    var onBeginRecording: (() -> Void)?

    public init(shortcut: Binding<RecordedShortcut?>, onBeginRecording: (() -> Void)? = nil) {
        self._shortcut = shortcut
        self.onBeginRecording = onBeginRecording
    }

    public func makeNSView(context: Context) -> ShortcutRecorder {
        let recorder = ShortcutRecorder()
        recorder.delegate = context.coordinator
        recorder.setShortcut(shortcut)
        return recorder
    }

    public func updateNSView(_ nsView: ShortcutRecorder, context: Context) {
        nsView.setShortcut(shortcut)
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    @MainActor public class Coordinator: NSObject, ShortcutRecorderDelegate {
        let parent: ShortcutRecorderView

        init(_ parent: ShortcutRecorderView) {
            self.parent = parent
        }

        public func shortcutRecorderDidBeginRecording(_ recorder: ShortcutRecorder) {
            parent.onBeginRecording?()
        }

        public func shortcutRecorder(_ recorder: ShortcutRecorder, didRecord shortcut: RecordedShortcut?) {
            parent.shortcut = shortcut
        }
    }
}
