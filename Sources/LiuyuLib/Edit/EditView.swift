// Sources/LiuyuLib/Edit/EditView.swift
import SwiftUI

struct EditView: View {
    @StateObject private var viewModel: EditViewModel
    @State private var waveformLevels: [Float] = Array(repeating: 0, count: 7)

    let onInsert: (String) -> Void
    let onClose: () -> Void

    init(initialText: String = "", onInsert: @escaping (String) -> Void, onClose: @escaping () -> Void) {
        self.onInsert = onInsert
        self.onClose = onClose
        _viewModel = StateObject(wrappedValue: {
            let vm = EditViewModel()
            vm.text = initialText
            return vm
        }())
    }

    init(viewModel: EditViewModel, onInsert: @escaping (String) -> Void, onClose: @escaping () -> Void) {
        self.onInsert = onInsert
        self.onClose = onClose
        _viewModel = StateObject(wrappedValue: viewModel)
    }

    var body: some View {
        VStack(spacing: 0) {
            contentArea
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            actionBar
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
        }
        .modifier(EditViewKeyboardHandler(
            hasText: viewModel.hasText,
            editState: viewModel.editState,
            onEscape: {
                viewModel.clear()
            },
            onCopy: {
                viewModel.copy()
            },
            onStartRecording: {
                viewModel.startRecording()
            },
            onStopRecording: {
                viewModel.stopRecording()
            }
        ))
    }

    // MARK: - Content Area

    @ViewBuilder
    private var contentArea: some View {
        // Force evaluation of the logger
        let _ = Logger.debug("=== contentArea EVALUATING ===", category: .ui)
        let _ = Logger.debug("contentArea: hasText=\(viewModel.hasText)", category: .ui)
        if viewModel.hasText {
            // Has text: TextEditor fills available space, mic area fixed at bottom
            VStack(spacing: 0) {
                // Custom text editor with proper Return key handling
                MacTextEditor(text: $viewModel.text, onReturn: {
                    if viewModel.hasText {
                        onInsert(viewModel.text)
                        onClose()
                    }
                })
                    .font(.system(size: 14))
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .onAppear {
                        Logger.debug("MacTextEditor appeared in view hierarchy", category: .ui)
                    }

                Divider()

                micArea
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
            }
        } else {
            // Empty: mic area centered vertically
            VStack {
                Spacer()
                micArea
                Spacer()
            }
            .padding(20)
        }
    }

    @ViewBuilder
    private var micArea: some View {
        // Gesture lives on this stable VStack so it persists when
        // the inner content switches from micButton → waveform.
        VStack {
            switch viewModel.editState {
            case .idle:
                micButtonContent

            case .recording:
                waveformView
                    .onChange(of: viewModel.audioLevel) { newLevel in
                        waveformLevels.removeFirst()
                        waveformLevels.append(newLevel)
                    }

            case .transcribing:
                processingView(text: "Transcribing...")

            case .editing:
                processingView(text: "Editing...")
            }
        }
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    if viewModel.editState == .idle {
                        viewModel.startRecording()
                    }
                }
                .onEnded { _ in
                    viewModel.stopRecording()
                }
        )

        if let error = viewModel.errorMessage {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 12))
                Text(error)
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(.orange)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.orange.opacity(0.1))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.orange.opacity(0.3), lineWidth: 1)
                    )
            )
            .frame(maxWidth: .infinity, alignment: .center)
            .onAppear {
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                    viewModel.errorMessage = nil
                }
            }
        }
    }

    private var micButtonContent: some View {
        VStack(spacing: 12) {
            Text(viewModel.micButtonLabel)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)

            Image(nsImage: IconManager.shared.mic)
                .renderingMode(.template)
                .resizable()
                .frame(width: 28, height: 28)
                .foregroundStyle(.white)
                .padding(.horizontal, 48)
                .padding(.vertical, 14)
                .background(Capsule().fill(Color(nsColor: .darkGray)))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    // WeChat-style recording view: mic with pulsing circles behind
    private var waveformView: some View {
        VStack(spacing: 8) {
            ZStack {
                // Pulsing background circles (like WeChat voice input)
                PulsingCircles(audioLevel: viewModel.audioLevel)
                    .frame(width: 80, height: 80)

                // Mic icon
                Image(nsImage: IconManager.shared.mic)
                    .renderingMode(.template)
                    .resizable()
                    .frame(width: 28, height: 28)
                    .foregroundColor(.white)
            }

            Text("Release to send")
                .foregroundColor(.secondary)
                .font(.system(size: 12))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
    }

    // Processing view with rotating arc only (no mic icon)
    private func processingView(text: String) -> some View {
        VStack(spacing: 12) {
            RotatingArc()
                .frame(width: 56, height: 56)
                .id("rotating-\(viewModel.editState)")

            Text(text)
                .foregroundColor(.secondary)
                .font(.system(size: 13))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
    }

    // MARK: - Helpers

    private var clearButtonLabel: String {
        let requiresDoubleTap = UserDefaults.standard.bool(forKey: "editClearDoubleTap")
        return requiresDoubleTap ? "Clear (Esc x2)" : "Clear (Esc)"
    }

    // MARK: - Action Bar

    private var actionBar: some View {
        HStack(spacing: 10) {
            Spacer()

            Button(action: { viewModel.clear() }) {
                Label {
                    Text(clearButtonLabel)
                } icon: {
                    Image(nsImage: IconManager.shared.trash2)
                        .resizable()
                        .frame(width: 16, height: 16)
                }
                .font(.system(size: 16))
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .disabled(!viewModel.hasText)

            Button(action: { viewModel.copy() }) {
                Label {
                    Text("Copy (⌘C)")
                } icon: {
                    Image(nsImage: IconManager.shared.clipboardCopy)
                        .resizable()
                        .frame(width: 16, height: 16)
                }
                .font(.system(size: 16))
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .disabled(!viewModel.hasText)

            Button(action: {
                onInsert(viewModel.text)
                onClose()
            }) {
                Label {
                    Text("Insert")
                } icon: {
                    Image(nsImage: IconManager.shared.cornerDownLeft)
                        .resizable()
                        .frame(width: 16, height: 16)
                }
                .font(.system(size: 16))
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .disabled(!viewModel.hasText)
        }
    }
}

// MARK: - WeChat Style Animations

// Pulsing circles behind mic (like WeChat voice input)
private struct PulsingCircles: View {
    let audioLevel: Float
    @State private var scale1: CGFloat = 0.5
    @State private var opacity1: Double = 1.0
    @State private var scale2: CGFloat = 0.5
    @State private var opacity2: Double = 1.0
    @State private var scale3: CGFloat = 0.5
    @State private var opacity3: Double = 1.0

    var body: some View {
        ZStack {
            // Outer ring - larger, brighter, and more visible
            Circle()
                .fill(Color.weChatGreen)
                .frame(width: 64, height: 64)
                .scaleEffect(scale1)
                .opacity(opacity1)

            // Middle ring
            Circle()
                .fill(Color.weChatGreen)
                .frame(width: 64, height: 64)
                .scaleEffect(scale2)
                .opacity(opacity2)

            // Inner ring
            Circle()
                .fill(Color.weChatGreen)
                .frame(width: 64, height: 64)
                .scaleEffect(scale3)
                .opacity(opacity3)

            // Center solid
            Circle()
                .fill(Color.weChatGreen)
                .frame(width: 56, height: 56)
                .shadow(color: Color.weChatGreen.opacity(0.6), radius: 12, x: 0, y: 0)
        }
        .onAppear {
            // Animate ring 1 - slower animation for better visibility
            withAnimation(.easeOut(duration: 1.5).repeatForever(autoreverses: false)) {
                scale1 = 2.5
                opacity1 = 0
            }

            // Animate ring 2 (delayed)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                withAnimation(.easeOut(duration: 1.5).repeatForever(autoreverses: false)) {
                    scale2 = 2.5
                    opacity2 = 0
                }
            }

            // Animate ring 3 (more delayed)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                withAnimation(.easeOut(duration: 1.5).repeatForever(autoreverses: false)) {
                    scale3 = 2.5
                    opacity3 = 0
                }
            }
        }
    }
}

// Rotating arc for processing state (like WeChat when sending)
private struct RotatingArc: View {
    @State private var rotation: Double = 0

    var body: some View {
        TimelineView(.animation(minimumInterval: 1/60, paused: false)) { _ in
            Circle()
                .trim(from: 0, to: 0.75)
                .stroke(Color.weChatGreen, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .frame(width: 56, height: 56)
                .rotationEffect(.degrees(rotation))
        }
        .onAppear {
            // Start continuous rotation animation
            withAnimation(.linear(duration: 1.0).repeatForever(autoreverses: false)) {
                rotation = 360
            }
        }
    }
}

// MARK: - Mac Text Editor with Return Key Handling

/// A macOS-native text editor that properly handles the Return key
struct MacTextEditor: NSViewRepresentable {
    @Binding var text: String
    var onReturn: () -> Void

    func makeNSView(context: Context) -> NSScrollView {
        Logger.debug("MacTextEditor makeNSView", category: .ui)
        let scrollView = NSTextView.scrollableTextView()
        let textView = scrollView.documentView as! NSTextView

        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isSelectable = true
        textView.isEditable = true
        textView.backgroundColor = .clear

        // Ensure text view can become first responder
        textView.autoresizingMask = [.width, .height]

        Logger.debug("MacTextEditor: delegate set to coordinator", category: .ui)

        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        let textView = nsView.documentView as! NSTextView
        Logger.debug("MacTextEditor updateNSView: text='\(text.prefix(20))...', textView.string='\(textView.string.prefix(20))...'", category: .ui)
        if textView.string != text {
            textView.string = text
        }
        // Update the coordinator's reference to parent to ensure callbacks work
        context.coordinator.updateParent(self)

        // Ensure text view becomes first responder when window is key
        // This fixes the issue where Return key doesn't work after window appears
        if let window = textView.window, window.isKeyWindow {
            if window.firstResponder !== textView {
                Logger.debug("MacTextEditor: Making textView first responder", category: .ui)
                window.makeFirstResponder(textView)
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Logger.debug("MacTextEditor makeCoordinator", category: .ui)
        return Coordinator(self)
    }

    class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MacTextEditor

        init(_ parent: MacTextEditor) {
            self.parent = parent
        }

        func updateParent(_ parent: MacTextEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            Logger.debug("MacTextEditor doCommandBy: \(commandSelector)", category: .ui)
            // Intercept Return key (Insert Newline command)
            // Check for various newline selectors that might be sent
            if commandSelector == #selector(NSResponder.insertNewline(_:)) ||
               commandSelector == #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)) ||
               commandSelector == #selector(NSResponder.insertLineBreak(_:)) {
                Logger.debug("MacTextEditor: Return key intercepted, calling onReturn", category: .ui)
                parent.onReturn()
                return true  // Handled
            }
            return false  // Let default handling proceed
        }
    }
}

// MARK: - Keyboard Handler

/// A view modifier that handles keyboard shortcuts in the Edit view.
private struct EditViewKeyboardHandler: ViewModifier {
    let hasText: Bool
    let editState: EditState
    let onEscape: () -> Void
    let onCopy: () -> Void
    let onStartRecording: () -> Void
    let onStopRecording: () -> Void

    @State private var keyMonitor: Any?
    @State private var isRecordingViaShortcut = false
    @State private var lastEscapePressTime: Date?

    // Load settings
    private var voiceEditShortcut: RecordedShortcut { .loadEditRecordShortcut() }
    private var clearRequiresDoubleTap: Bool { UserDefaults.standard.bool(forKey: "editClearDoubleTap") }

    func body(content: Content) -> some View {
        content
            .onAppear {
                // Fail-safe: ensure clean state when view appears
                isRecordingViaShortcut = false

                keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { event in
                    // Note: Return key is handled by TextEditor's .onKeyPress(.return)
                    // to avoid duplicate events and ensure proper focus handling

                    // Escape key (53) - Clear text (with optional double-tap)
                    if event.keyCode == 53 {
                        if self.handleEscapeKey() {
                            return nil
                        }
                        return event
                    }

                    // Cmd+C - Copy text (when not in text editor)
                    if event.keyCode == 8 && event.modifierFlags.contains(.command) && hasText {
                        onCopy()
                        return nil
                    }

                    // Voice edit shortcut - Hold to record edits, release to stop
                    // On keyDown: check full shortcut match
                    if event.type == .keyDown && self.matchesVoiceEditShortcut(event) {
                        // Fail-safe: if stuck in non-idle state, reset first
                        if isRecordingViaShortcut && editState != .idle {
                            Logger.warning("Fail-safe: resetting stuck recording state", category: .hotkey)
                            isRecordingViaShortcut = false
                            onStopRecording()
                        }

                        if !isRecordingViaShortcut {
                            // Only start if currently idle
                            if case .idle = editState {
                                isRecordingViaShortcut = true
                                onStartRecording()
                            }
                        }
                        return nil
                    }

                    // On keyUp: check if we're recording and keyCode matches
                    // Must check this AFTER the shortcut match above, and only if we're recording
                    if event.type == .keyUp && isRecordingViaShortcut {
                        let shortcut = voiceEditShortcut
                        // For modifier-only shortcuts (keyCode=0), any keyUp stops recording
                        // For key shortcuts, only matching keyCode stops recording
                        let shouldStop = shortcut.keyCode == 0 || event.keyCode == shortcut.keyCode
                        if shouldStop {
                            isRecordingViaShortcut = false
                            onStopRecording()
                            return nil
                        }
                    }

                    return event
                }
            }
            .onDisappear {
                if let monitor = keyMonitor {
                    NSEvent.removeMonitor(monitor)
                }
            }
    }

    /// Handles Escape key press, considering double-tap setting.
    /// Returns true if the key should be consumed, false otherwise.
    private func handleEscapeKey() -> Bool {
        let now = Date()
        defer { lastEscapePressTime = now }

        if clearRequiresDoubleTap {
            // Check if this is a double-tap (within 0.3 seconds)
            if let lastPress = lastEscapePressTime, now.timeIntervalSince(lastPress) < 0.3 {
                onEscape()
                return true
            }
            // Single tap - don't clear, but consume the event
            return true
        } else {
            // Single tap clears
            onEscape()
            return true
        }
    }

    /// Checks if the event matches the Voice Edit shortcut.
    private func matchesVoiceEditShortcut(_ event: NSEvent) -> Bool {
        let shortcut = voiceEditShortcut

        // Debug logging - more detailed
        let eventFlagsRaw = event.modifierFlags.rawValue
        let eventDeviceFlags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).rawValue
        Logger.debug("Checking shortcut: keyCode(event:\(event.keyCode), target:\(shortcut.keyCode)), eventFlags:\(eventFlagsRaw), eventDeviceFlags:\(eventDeviceFlags), shortcutFlags:\(shortcut.modifierFlags), includesFn:\(shortcut.includesFnKey)", category: .hotkey)

        // For modifier-only shortcuts (like Fn+Ctrl), keyCode is 0
        // We only check keyCode if shortcut has a specific key
        if shortcut.keyCode != 0 {
            guard event.keyCode == shortcut.keyCode else {
                Logger.debug("KeyCode mismatch: event=\(event.keyCode), target=\(shortcut.keyCode)", category: .hotkey)
                return false
            }
        }

        // Check modifier flags match
        let eventModifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var shortcutModifiers: NSEvent.ModifierFlags = []
        let flags = shortcut.flags

        if flags.contains(.maskCommand) { shortcutModifiers.insert(.command) }
        if flags.contains(.maskShift) { shortcutModifiers.insert(.shift) }
        if flags.contains(.maskAlternate) { shortcutModifiers.insert(.option) }
        if flags.contains(.maskControl) { shortcutModifiers.insert(.control) }
        // IMPORTANT: If shortcut includes Fn key, add it to shortcutModifiers for comparison
        if shortcut.includesFnKey { shortcutModifiers.insert(.function) }

        // Check Fn key if needed
        let fnKeyPressed = event.modifierFlags.contains(.function)
        let fnMatch = shortcut.includesFnKey == fnKeyPressed

        let modifiersMatch = eventModifiers == shortcutModifiers
        Logger.debug("Event modifiers: \(eventModifiers.rawValue), Shortcut modifiers: \(shortcutModifiers.rawValue), Match: \(modifiersMatch), Fn match: \(fnMatch)", category: .hotkey)

        return modifiersMatch && fnMatch
    }

}
