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
                    .padding(.top, 20)

                micArea
                    .padding(.horizontal, 20)
                    .padding(.bottom, 12)
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
                HStack(spacing: 8) {
                    ProgressView()
                        .scaleEffect(0.8)
                    Text("Transcribing...")
                        .foregroundStyle(.secondary)
                        .font(.system(size: 13))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)

            case .editing:
                HStack(spacing: 8) {
                    ProgressView()
                        .scaleEffect(0.8)
                    Text("Editing...")
                        .foregroundStyle(.secondary)
                        .font(.system(size: 13))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
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

    private var waveformView: some View {
        HStack(spacing: 3) {
            ForEach(0..<7, id: \.self) { index in
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.red.opacity(0.7))
                    .frame(width: 4, height: CGFloat(8 + waveformLevels[index] * 32))
                    .animation(.easeInOut(duration: 0.08), value: waveformLevels[index])
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
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
                    Text("Copy")
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

// MARK: - Keyboard Handler

/// A view modifier that handles keyboard shortcuts in the Edit view.
private struct EditViewKeyboardHandler: ViewModifier {
    let hasText: Bool
    let editState: EditState
    let onReturn: () -> Void
    let onEscape: () -> Void
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
