import SwiftUI

struct ProcessingView: View {
    @State private var rotation: Double = 0
    @State private var isAnimating = false

    var body: some View {
        HStack(spacing: 16) {
            // Rotating arc only (no mic)
            Circle()
                .trim(from: 0, to: 0.75)
                .stroke(Color.weChatGreen, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .frame(width: 44, height: 44)
                .rotationEffect(.degrees(isAnimating ? 360 : 0))
                .animation(.linear(duration: 1.0).repeatForever(autoreverses: false), value: isAnimating)
                .frame(width: 50, height: 50)
                .onAppear {
                    // Delay slightly to ensure view is rendered before starting animation
                    DispatchQueue.main.async {
                        isAnimating = true
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
