import SwiftUI
import LucideIcons

struct RecordingView: View {
    let audioLevel: Float
    let onClose: () -> Void

    @State private var pulse1: Bool = false
    @State private var pulse2: Bool = false

    var body: some View {
        HStack(spacing: 16) {
            // WeChat-style mic with pulsing circles
            ZStack {
                // Outer pulsing circle
                Circle()
                    .fill(Color.weChatGreen.opacity(0.2))
                    .frame(width: 50, height: 50)
                    .scaleEffect(pulse1 ? 1.4 : 1.0)
                    .opacity(pulse1 ? 0 : 0.6)

                // Middle pulsing circle
                Circle()
                    .fill(Color.weChatGreen.opacity(0.3))
                    .frame(width: 40, height: 40)
                    .scaleEffect(pulse2 ? 1.2 : 0.9)
                    .opacity(pulse2 ? 0.3 : 0.8)

                // Inner solid circle with mic
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
        .onAppear {
            withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: false)) {
                pulse1 = true
            }
            withAnimation(.easeInOut(duration: 1.2).delay(0.4).repeatForever(autoreverses: false)) {
                pulse2 = true
            }
        }
    }
}
