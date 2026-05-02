import SwiftUI

struct EditRecordingControl: View {
    let editState: EditState
    let audioLevel: Float
    let micButtonLabel: String
    let errorMessage: String?
    let onStartRecording: () -> Void
    let onStopRecording: () -> Void
    let onClearError: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            content
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { _ in
                            if editState == .idle {
                                onStartRecording()
                            }
                        }
                        .onEnded { _ in
                            onStopRecording()
                        }
                )

            if let errorMessage {
                errorView(errorMessage)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch editState {
        case .idle:
            micButtonContent

        case .recording:
            waveformView

        case .transcribing:
            processingView(text: "Transcribing...")

        case .editing:
            processingView(text: "Editing...")
        }
    }

    private var micButtonContent: some View {
        VStack(spacing: 12) {
            Text(micButtonLabel)
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

    private var waveformView: some View {
        VStack(spacing: 8) {
            ZStack {
                PulsingCircles(audioLevel: audioLevel)
                    .frame(width: 80, height: 80)

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

    private func processingView(text: String) -> some View {
        VStack(spacing: 12) {
            RotatingArc()
                .frame(width: 56, height: 56)
                .id("rotating-\(editState)")

            Text(text)
                .foregroundColor(.secondary)
                .font(.system(size: 13))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
    }

    private func errorView(_ text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12))
            Text(text)
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
                onClearError()
            }
        }
    }
}

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
            Circle()
                .fill(Color.weChatGreen)
                .frame(width: 64, height: 64)
                .scaleEffect(scale1)
                .opacity(opacity1)

            Circle()
                .fill(Color.weChatGreen)
                .frame(width: 64, height: 64)
                .scaleEffect(scale2)
                .opacity(opacity2)

            Circle()
                .fill(Color.weChatGreen)
                .frame(width: 64, height: 64)
                .scaleEffect(scale3)
                .opacity(opacity3)

            Circle()
                .fill(Color.weChatGreen)
                .frame(width: 56, height: 56)
                .shadow(color: Color.weChatGreen.opacity(0.6), radius: 12, x: 0, y: 0)
        }
        .onAppear {
            withAnimation(.easeOut(duration: 1.5).repeatForever(autoreverses: false)) {
                scale1 = 2.5
                opacity1 = 0
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                withAnimation(.easeOut(duration: 1.5).repeatForever(autoreverses: false)) {
                    scale2 = 2.5
                    opacity2 = 0
                }
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                withAnimation(.easeOut(duration: 1.5).repeatForever(autoreverses: false)) {
                    scale3 = 2.5
                    opacity3 = 0
                }
            }
        }
    }
}

private struct RotatingArc: View {
    @State private var rotation: Double = 0

    var body: some View {
        Circle()
            .trim(from: 0, to: 0.75)
            .stroke(Color.weChatGreen, style: StrokeStyle(lineWidth: 4, lineCap: .round))
            .frame(width: 56, height: 56)
            .rotationEffect(.degrees(rotation))
        .onAppear {
            withAnimation(.linear(duration: 1.0).repeatForever(autoreverses: false)) {
                rotation = 360
            }
        }
    }
}
