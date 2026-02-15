// Sources/LiuyuLib/Edit/EditView.swift
import SwiftUI
import LucideIcons

struct EditView: View {
    @StateObject private var viewModel = EditViewModel()
    @State private var waveformLevels: [Float] = Array(repeating: 0, count: 7)

    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            contentArea
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            actionBar
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
        }
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
                    if case .recording = viewModel.editState {
                        viewModel.stopRecording()
                    }
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

    // MARK: - Action Bar

    private var actionBar: some View {
        HStack(spacing: 10) {
            Spacer()

            Button(action: { viewModel.clear() }) {
                Label {
                    Text("Clear")
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
                viewModel.insert()
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
