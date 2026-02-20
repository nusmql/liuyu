import SwiftUI
import LucideIcons

struct RecordingView: View {
    let audioLevel: Float
    let onClose: () -> Void

    @State private var scale1: CGFloat = 1.0
    @State private var opacity1: Double = 0.6
    @State private var scale2: CGFloat = 1.0
    @State private var opacity2: Double = 0.6
    @State private var scale3: CGFloat = 1.0
    @State private var opacity3: Double = 0.6

    var body: some View {
        HStack(spacing: 16) {
            // WeChat-style mic with pulsing circles
            ZStack {
                // Outer pulsing ring
                Circle()
                    .fill(Color.weChatGreen)
                    .frame(width: 36, height: 36)
                    .scaleEffect(scale1)
                    .opacity(opacity1)

                // Middle pulsing ring
                Circle()
                    .fill(Color.weChatGreen)
                    .frame(width: 36, height: 36)
                    .scaleEffect(scale2)
                    .opacity(opacity2)

                // Inner pulsing ring
                Circle()
                    .fill(Color.weChatGreen)
                    .frame(width: 36, height: 36)
                    .scaleEffect(scale3)
                    .opacity(opacity3)

                // Center solid with mic
                Circle()
                    .fill(Color.weChatGreen)
                    .frame(width: 36, height: 36)

                Image(nsImage: {
                    let img = Lucide.mic.copy() as! NSImage
                    img.isTemplate = true
                    return img
                }())
                    .resizable()
                    .frame(width: 16, height: 16)
                    .foregroundColor(.white)
            }
            .frame(width: 50, height: 50)
            .onAppear {
                // Animate ring 1
                withAnimation(.easeOut(duration: 1.2).repeatForever(autoreverses: false)) {
                    scale1 = 1.5
                    opacity1 = 0
                }

                // Animate ring 2 (delayed)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    withAnimation(.easeOut(duration: 1.2).repeatForever(autoreverses: false)) {
                        scale2 = 1.5
                        opacity2 = 0
                    }
                }

                // Animate ring 3 (more delayed)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    withAnimation(.easeOut(duration: 1.2).repeatForever(autoreverses: false)) {
                        scale3 = 1.5
                        opacity3 = 0
                    }
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Recording...")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.white)

                Text("Release to send")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.7))
            }

            Spacer()

            Button(action: {
                onClose()
            }) {
                Image(nsImage: Lucide.x)
                    .resizable()
                    .frame(width: 14, height: 14)
                    .foregroundColor(.white.opacity(0.8))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .frame(width: 280, height: 80)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.black.opacity(0.75))
        )
    }
}
