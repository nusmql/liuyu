// Sources/LiuyuLib/UI/RecordingPanelView.swift
import SwiftUI

/// Combined view that handles both recording and processing states with smooth transition
struct RecordingPanelView: View {
    let state: PanelState
    let onClose: () -> Void

    // Animation states - rings only 10% larger than center circle
    @State private var ringScales: [CGFloat] = [1.1, 1.1, 1.1]
    @State private var ringOpacities: [Double] = [0.5, 0.5, 0.5]
    @State private var arrowRotation: Double = 0
    @State private var showMic: Bool = true
    @State private var showArrow: Bool = false

    var body: some View {
        HStack(spacing: 16) {
            // WeChat-style animation area
            ZStack {
                // White contracting rings (recording: from outside to inside)
                ForEach(0..<3) { i in
                    Circle()
                        .stroke(Color.white.opacity(0.6), lineWidth: 2)
                        .frame(width: 36, height: 36)
                        .scaleEffect(ringScales[i])
                        .opacity(ringOpacities[i])
                }

                // Center circle (always present)
                Circle()
                    .fill(Color.weChatGreen)
                    .frame(width: 36, height: 36)

                // Microphone icon (recording phase)
                if showMic {
                    Image(nsImage: IconManager.shared.mic)
                        .renderingMode(.template)
                        .resizable()
                        .frame(width: 16, height: 16)
                        .foregroundColor(.white)
                        .transition(.opacity)
                }

                // Arrow icon (processing phase) - rotates
                if showArrow {
                    Image(systemName: "arrow.clockwise")
                        .resizable()
                        .frame(width: 16, height: 16)
                        .foregroundColor(.white)
                        .rotationEffect(.degrees(arrowRotation))
                        .transition(.opacity)
                }
            }
            .frame(width: 36, height: 36)
            .onAppear {
                startAnimation()
            }
            .onChange(of: state) { newState in
                handleStateChange(newState)
            }

            // Text content
            VStack(alignment: .leading, spacing: 4) {
                switch state {
                case .recording:
                    Text("Recording...")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.white)
                    Text("Release to send")
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.7))
                case .processing:
                    Text("Processing...")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.white)
                    Text("Please wait")
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.7))
                default:
                    EmptyView()
                }
            }

            Spacer()

            // Close button (only during recording)
            if case .recording = state {
                Button(action: onClose) {
                    Image(nsImage: IconManager.shared.x)
                        .resizable()
                        .frame(width: 14, height: 14)
                        .foregroundColor(.white.opacity(0.8))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .frame(width: 280, height: 80)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.black.opacity(0.75))
        )
    }

    private func startAnimation() {
        // Recording: rings contract from outside to inside
        for i in 0..<3 {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.3) {
                // Start from expanded (10% larger)
                ringScales[i] = 1.1
                ringOpacities[i] = 0.5

                // Animate inward (contracting) - from 1.1 to 0.9
                withAnimation(.easeIn(duration: 1.0).repeatForever(autoreverses: false)) {
                    ringScales[i] = 0.9
                    ringOpacities[i] = 0
                }
            }
        }
    }

    private func handleStateChange(_ newState: PanelState) {
        switch newState {
        case .processing:
            // Processing: mic fades out, arrow fades in and rotates
            withAnimation(.easeOut(duration: 0.3)) {
                showMic = false
            }

            // Show arrow and start rotation
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                showArrow = true
                withAnimation(.linear(duration: 1.0).repeatForever(autoreverses: false)) {
                    arrowRotation = 360
                }
            }

        default:
            break
        }
    }
}
