// Sources/LiuyuLib/Settings/ShortcutRecorder.swift
@preconcurrency import Cocoa
import CoreGraphics
import SwiftUI

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
    // Use nonisolated(unsafe) to allow cleanup in deinit
    // The monitor is created on main thread but deinit can happen anywhere
    nonisolated(unsafe) private var localMonitor: Any?
    private var currentFlags: CGEventFlags = []
    private var accumulatedFlags: CGEventFlags = []  // Track all modifiers pressed during recording
    private var currentKeyCode: UInt16 = UInt16.max
    private var currentIncludesFnKey: Bool = false
    private var isFnPressed: Bool = false
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

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
            label.stringValue = "Press shortcut..."
            label.textColor = .controlAccentColor
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
        Logger.debug("Start recording", category: .settings)
        isRecording = true
        currentFlags = []
        accumulatedFlags = []  // Reset accumulated flags
        currentKeyCode = UInt16.max
        isFnPressed = false
        updateLabel()
        updateAppearance()

        NotificationCenter.default.post(name: .hotkeyRecordingDidBegin, object: self)
        delegate?.shortcutRecorderDidBeginRecording(self)

        // Use CGEventTap to reliably capture Fn and modifier states
        let mask: CGEventMask = (1 << CGEventType.flagsChanged.rawValue)
            | (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
        if let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, _, event, refcon -> Unmanaged<CGEvent>? in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let recorder = Unmanaged<ShortcutRecorder>.fromOpaque(refcon).takeUnretainedValue()
                return recorder.handleEventTap(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) {
            eventTap = tap
            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            runLoopSource = source
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
        }

        // Local monitor for Escape/Return to control recording lifecycle
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self = self else { return event }
            if event.keyCode == 53 { self.cancelRecording(); return nil }
            if event.keyCode == 36 { self.finishRecording(); return nil }
            return event
        }
    }

    private func handleEventTap(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        switch event.type {
        case .flagsChanged:
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                let flags = event.flags
                let fnDown = flags.contains(.maskSecondaryFn)
                let hadFn = self.isFnPressed
                self.isFnPressed = fnDown
                if fnDown { self.currentIncludesFnKey = true }
                var cgFlags: CGEventFlags = []
                if flags.contains(.maskControl) { cgFlags.insert(.maskControl) }
                if flags.contains(.maskAlternate) { cgFlags.insert(.maskAlternate) }
                if flags.contains(.maskShift) { cgFlags.insert(.maskShift) }
                if flags.contains(.maskCommand) { cgFlags.insert(.maskCommand) }

                // Accumulate all modifiers that were pressed during recording
                self.accumulatedFlags.formUnion(cgFlags)

                let wereFlags = !self.currentFlags.isEmpty
                self.currentFlags = cgFlags

                // Check if Fn was released (and no other keys were pressed)
                let fnReleased = hadFn && !fnDown && self.currentKeyCode == UInt16.max

                // Finish recording if:
                // 1. Modifiers were released and no key was pressed, OR
                // 2. Fn was released (treat as "Fn-only" shortcut)
                if (wereFlags && cgFlags.isEmpty && self.currentKeyCode == UInt16.max) || fnReleased {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                        guard let self = self, self.isRecording else { return }
                        // If user released all keys (including Fn) and hasn't pressed a regular key yet
                        if self.currentFlags.isEmpty && !self.isFnPressed && self.currentKeyCode == UInt16.max {
                            self.finishRecording()
                        }
                    }
                }
            }
            return Unmanaged.passUnretained(event)
        case .keyDown:
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                let code = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
                let flags = event.flags

                // Capture modifiers at keyDown time too (they might not be in accumulatedFlags yet)
                var cgFlags: CGEventFlags = []
                if flags.contains(.maskControl) { cgFlags.insert(.maskControl) }
                if flags.contains(.maskAlternate) { cgFlags.insert(.maskAlternate) }
                if flags.contains(.maskShift) { cgFlags.insert(.maskShift) }
                if flags.contains(.maskCommand) { cgFlags.insert(.maskCommand) }
                self.accumulatedFlags.formUnion(cgFlags)

                // F13 (105) is treated as a regular function key (mapped from Fn via Karabiner)
                // We don't set includesFnKey for it - it's just a regular keyCode
                if flags.contains(.maskSecondaryFn) { self.currentIncludesFnKey = true }
                self.currentKeyCode = code

                Logger.debug("ShortcutRecorder: keyDown code=\(code), flags=\(flags.rawValue), accumulated=\(self.accumulatedFlags.rawValue)", category: .settings)

                self.finishRecording()
            }
            return Unmanaged.passUnretained(event)
        case .keyUp:
            // keyUp handling - no special treatment needed for F13
            return Unmanaged.passUnretained(event)
        default:
            return Unmanaged.passUnretained(event)
        }
    }

    private func handleFlagsChanged(_ event: NSEvent) {
        let flags = event.modifierFlags

        // Get device-independent flags first to check for changes
        let deviceFlags = flags.intersection(.deviceIndependentFlagsMask)
        var cgFlags: CGEventFlags = []
        if deviceFlags.contains(.control) { cgFlags.insert(.maskControl) }
        if deviceFlags.contains(.option) { cgFlags.insert(.maskAlternate) }
        if deviceFlags.contains(.shift) { cgFlags.insert(.maskShift) }
        if deviceFlags.contains(.command) { cgFlags.insert(.maskCommand) }

        // Accumulate all modifiers that were pressed during recording
        accumulatedFlags.formUnion(cgFlags)

        // Check Fn state change
        let fnWasPressed = isFnPressed
        if flags.contains(.function) {
            currentIncludesFnKey = true
            isFnPressed = true
        } else {
            isFnPressed = false
        }

        // Detect release
        // 1. Modifiers released: previous had flags, now empty
        let flagsReleased = !currentFlags.isEmpty && cgFlags.isEmpty
        // 2. Fn released: previous had Fn, now no Fn (and no other flags)
        let fnReleased = fnWasPressed && !isFnPressed && cgFlags.isEmpty

        currentFlags = cgFlags
        updateLabel()

        if flagsReleased || fnReleased {
             // Small delay to allow for key combinations
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                guard let self = self, self.isRecording else { return }

                // If user released all keys (including Fn) and hasn't pressed a regular key yet
                if self.currentFlags.isEmpty && !self.isFnPressed && self.currentKeyCode == UInt16.max {
                     self.finishRecording()
                }
            }
        }
    }

    private func finishRecording() {
        guard isRecording else { return }

        let shortcut: RecordedShortcut?
        // Use accumulatedFlags to capture all modifiers that were pressed during recording
        let effectiveFlags = accumulatedFlags.isEmpty ? currentFlags : accumulatedFlags
        if effectiveFlags.isEmpty && currentKeyCode == UInt16.max && !currentIncludesFnKey {
            shortcut = nil
        } else {
            let kc: UInt16? = (currentKeyCode == UInt16.max) ? nil : currentKeyCode
            shortcut = RecordedShortcut(flags: effectiveFlags, keyCode: kc, includesFnKey: currentIncludesFnKey)
        }

        cleanupRecording()

        // Important: Update local state FIRST to avoid race condition with binding
        setShortcut(shortcut)

        // Notify delegate (updates binding)
        delegate?.shortcutRecorder(self, didRecord: shortcut)
        // Notify system (triggers HotkeyManager start)
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
        accumulatedFlags = []  // Reset accumulated flags
        currentKeyCode = UInt16.max
        currentIncludesFnKey = false
        isFnPressed = false

        if let monitor = localMonitor {
            NSEvent.removeMonitor(monitor)
            localMonitor = nil
        }
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            eventTap = nil
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
            runLoopSource = nil
        }
        
        updateAppearance()
    }

    // MARK: - Cleanup

    deinit {
        // Clean up the monitor if it exists
        // NSEvent.removeMonitor is thread-safe
        // Capture monitor locally to avoid accessing actor-isolated property in deinit
        if let monitor = localMonitor {
            NSEvent.removeMonitor(monitor)
        }

        // Disable EventTap if active - MUST happen to prevent callback to dangling pointer
        // EventTap is not actor-isolated, safe to access from deinit
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
        }
    }
}

// MARK: - SwiftUI Wrapper

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
