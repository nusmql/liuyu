import SwiftUI
import LucideIcons

struct ProcessingView: View {
    @State private var rotation: Double = 0

    var body: some View {
        HStack(spacing: 16) {
            // Rotating arc around mic
            ZStack {
                Circle()
                    .trim(from: 0, to: 0.75)
                    .stroke(Color.weChatGreen, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .frame(width: 44, height: 44)
                    .rotationEffect(.degrees(rotation))

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
                // Use a timer for smooth rotation
                Timer.scheduledTimer(withTimeInterval: 0.016, repeats: true) { _ in
                    MainActor.assumeIsolated {
                        rotation += 6 // 360 degrees in 1 second at 60fps
                        if rotation >= 360 {
                            rotation = 0
                        }
                    }
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
