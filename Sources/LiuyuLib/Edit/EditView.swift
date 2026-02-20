// Sources/LiuyuLib/Edit/EditView.swift
import SwiftUI
import LucideIcons

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
            onReturn: {
                onInsert(viewModel.text)
                onClose()
            },
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
        if viewModel.hasText {
            // Has text: TextEditor fills available space, mic area fixed at bottom
            VStack(spacing: 0) {
                TextEditor(text: $viewModel.text)
                    .font(.system(size: 14))
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

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
            Text(error)
                .font(.caption)
                .foregroundStyle(.red)
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

            Image(nsImage: {
                    let img = Lucide.mic.copy() as! NSImage
                    img.isTemplate = true
                    return img
                }())
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
                Image(nsImage: {
                    let img = Lucide.mic.copy() as! NSImage
                    img.isTemplate = true
                    return img
                }())
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

    // Processing view with rotating arc around mic icon (like WeChat)
    private func processingView(text: String) -> some View {
        VStack(spacing: 12) {
            ZStack {
                // Rotating arc
                RotatingArc()
                    .frame(width: 56, height: 56)

                // Mic icon
                Image(nsImage: {
                    let img = Lucide.mic.copy() as! NSImage
                    img.isTemplate = true
                    return img
                }())
                .resizable()
                .frame(width: 24, height: 24)
                .foregroundColor(.white)
            }

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
                    Image(nsImage: Lucide.trash2)
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
                    Image(nsImage: Lucide.clipboardCopy)
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
                    Image(nsImage: Lucide.cornerDownLeft)
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
    @State private var pulse1: Bool = false
    @State private var pulse2: Bool = false

    var body: some View {
        ZStack {
            // Outer circle
            Circle()
                .fill(Color.weChatGreen.opacity(0.15))
                .scaleEffect(pulse1 ? 1.5 : 1.0)
                .opacity(pulse1 ? 0 : 1)

            // Middle circle
            Circle()
                .fill(Color.weChatGreen.opacity(0.25))
                .scaleEffect(pulse2 ? 1.3 : 0.8)
                .opacity(pulse2 ? 0.3 : 0.8)

            // Inner solid circle (mic background)
            Circle()
                .fill(Color.weChatGreen)
                .frame(width: 56, height: 56)
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: false)) {
                pulse1 = true
            }
            withAnimation(.easeInOut(duration: 1.2).delay(0.4).repeatForever(autoreverses: false)) {
                pulse2 = true
            }
        }
        .onChange(of: audioLevel) { _ in
            // Animation intensity could be adjusted based on audio level
        }
    }
}

// Rotating arc for processing state (like WeChat when sending)
private struct RotatingArc: View {
    @State private var rotation: Double = 0

    var body: some View {
        Circle()
            .trim(from: 0, to: 0.75)
            .stroke(Color.weChatGreen, lineWidth: 3)
            .rotationEffect(.degrees(rotation))
            .onAppear {
                withAnimation(.linear(duration: 1.0).repeatForever(autoreverses: false)) {
                    rotation = 360
                }
            }
    }
}

// MARK: - Keyboard Handler

/// A view modifier that handles keyboard shortcuts in the Edit view.
private struct EditViewKeyboardHandler: ViewModifier {
    let hasText: Bool
    let editState: EditState
    let onReturn: () -> Void
    let onEscape: () -> Void
    let onCopy: () -> Void
    let onStartRecording: () -> Void
    let onStopRecording: () -> Void

    @State private var keyMonitor: Any?
    @State private var isRecordingViaShortcut = false
    @State private var lastEscapePressTime: Date?

    // Load settings
    private var recordShortcut: RecordedShortcut { .loadEditRecordShortcut() }
    private var clearRequiresDoubleTap: Bool { UserDefaults.standard.bool(forKey: "editClearDoubleTap") }

    func body(content: Content) -> some View {
        content
            .onAppear {
                keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { event in
                    // Return key (36) - Insert and close
                    if event.keyCode == 36 && hasText {
                        onReturn()
                        return nil
                    }

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

                    // Voice record shortcut - Hold to record, release to stop
                    if self.matchesRecordShortcut(event) {
                        if event.type == .keyDown && !isRecordingViaShortcut {
                            // Only start if currently idle
                            if case .idle = editState {
                                isRecordingViaShortcut = true
                                onStartRecording()
                            }
                        } else if event.type == .keyUp && isRecordingViaShortcut {
                            isRecordingViaShortcut = false
                            onStopRecording()
                        }
                        return nil
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

    /// Checks if the event matches the custom record shortcut.
    private func matchesRecordShortcut(_ event: NSEvent) -> Bool {
        let shortcut = recordShortcut

        // Check key code matches
        guard event.keyCode == shortcut.keyCode else {
            return false
        }

        // Check modifier flags match
        let eventModifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var shortcutModifiers: NSEvent.ModifierFlags = []
        let flags = shortcut.flags

        if flags.contains(.maskCommand) { shortcutModifiers.insert(.command) }
        if flags.contains(.maskShift) { shortcutModifiers.insert(.shift) }
        if flags.contains(.maskAlternate) { shortcutModifiers.insert(.option) }
        if flags.contains(.maskControl) { shortcutModifiers.insert(.control) }

        // Check Fn key if needed
        let fnKeyPressed = event.modifierFlags.contains(.function)
        let fnMatch = shortcut.includesFnKey == fnKeyPressed

        return eventModifiers == shortcutModifiers && fnMatch
    }
}
