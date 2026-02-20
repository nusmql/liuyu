import SwiftUI
import LucideIcons

struct ProcessingView: View {
    @State private var rotation: Double = 0

    var body: some View {
        HStack(spacing: 16) {
            // Rotating arc around mic
            ZStack {
                TimelineView(.animation(minimumInterval: 1/60, paused: false)) { _ in
                    Circle()
                        .trim(from: 0, to: 0.75)
                        .stroke(Color.weChatGreen, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .frame(width: 44, height: 44)
                        .rotationEffect(.degrees(rotation))
                }

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
