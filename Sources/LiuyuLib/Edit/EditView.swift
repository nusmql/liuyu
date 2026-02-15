// Sources/LiuyuLib/Edit/EditView.swift
import SwiftUI
import LucideIcons

struct EditView: View {
    @StateObject private var viewModel = EditViewModel()
    @State private var waveformLevels: [Float] = Array(repeating: 0, count: 7)

    let previousApp: NSRunningApplication?
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
        ScrollView {
            VStack(spacing: 16) {
                if viewModel.hasText {
                    TextEditor(text: $viewModel.text)
                        .font(.system(size: 14))
                        .scrollContentBackground(.hidden)
                        .frame(maxWidth: .infinity, minHeight: 100)
                }

                micArea
            }
            .padding(20)
        }
    }

    @ViewBuilder
    private var micArea: some View {
        switch viewModel.editState {
        case .idle:
            micButton

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

    private var micButton: some View {
        Image(nsImage: Lucide.mic)
            .resizable()
            .frame(width: 24, height: 24)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 20)
            .contentShape(Rectangle())
            .overlay {
                Text(viewModel.micButtonLabel)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .offset(y: 28)
            }
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
        HStack(spacing: 8) {
            Spacer()

            Button(action: { viewModel.clear() }) {
                Label {
                    Text("Clear")
                } icon: {
                    Image(nsImage: Lucide.trash2)
                        .resizable()
                        .frame(width: 12, height: 12)
                }
                .font(.system(size: 12))
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
                        .frame(width: 12, height: 12)
                }
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .disabled(!viewModel.hasText)

            Button(action: {
                viewModel.insert(previousApp: previousApp)
                onClose()
            }) {
                Label {
                    Text("Insert")
                } icon: {
                    Image(nsImage: Lucide.cornerDownLeft)
                        .resizable()
                        .frame(width: 12, height: 12)
                }
                .font(.system(size: 12))
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(!viewModel.hasText)
        }
    }
}
