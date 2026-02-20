import SwiftUI
import LucideIcons

struct ProcessingView: View {
    @State private var rotation: Double = 0

    var body: some View {
        HStack(spacing: 16) {
            // Rotating arc around mic
            ZStack {
                // Rotating arc - larger and behind the mic
                TimelineView(.animation(minimumInterval: 1/60, paused: false)) { _ in
                    Circle()
                        .trim(from: 0, to: 0.75)
                        .stroke(Color.weChatGreen, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                        .frame(width: 56, height: 56)
                        .rotationEffect(.degrees(rotation))
                }

                // Mic icon with background circle
                Circle()
                    .fill(Color.weChatGreen)
                    .frame(width: 40, height: 40)

                Image(nsImage: {
                    let img = Lucide.mic.copy() as! NSImage
                    img.isTemplate = true
                    return img
                }())
                    .resizable()
                    .frame(width: 18, height: 18)
                    .foregroundColor(.white)
            }
            .frame(width: 50, height: 50)
            .onAppear {
                // Start a continuous rotation animation
                withAnimation(.linear(duration: 1.0).repeatForever(autoreverses: false)) {
                    rotation = 360
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Processing...")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.white)

                Text("Please wait")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.7))
            }

            Spacer()
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
