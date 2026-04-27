// Sources/LiuyuLib/Edit/EditView.swift
import SwiftUI

struct EditView: View {
    @StateObject private var viewModel: EditViewModel

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

            EditActionBar(
                hasText: viewModel.hasText,
                clearButtonLabel: clearButtonLabel,
                onClear: viewModel.clear,
                onCopy: viewModel.copy,
                onInsert: insertAndClose
            )
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

                recordingControl
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
            }
        } else {
            // Empty: mic area centered vertically
            VStack {
                Spacer()
                recordingControl
                Spacer()
            }
            .padding(20)
        }
    }

    private var recordingControl: some View {
        EditRecordingControl(
            editState: viewModel.editState,
            audioLevel: viewModel.audioLevel,
            micButtonLabel: viewModel.micButtonLabel,
            errorMessage: viewModel.errorMessage,
            onStartRecording: viewModel.startRecording,
            onStopRecording: viewModel.stopRecording,
            onClearError: {
                viewModel.errorMessage = nil
            }
        )
    }

    // MARK: - Helpers

    private var clearButtonLabel: String {
        let requiresDoubleTap = UserDefaults.standard.bool(forKey: "editClearDoubleTap")
        return requiresDoubleTap ? "Clear (Esc x2)" : "Clear (Esc)"
    }

    private func insertAndClose() {
        onInsert(viewModel.text)
        onClose()
    }
}
