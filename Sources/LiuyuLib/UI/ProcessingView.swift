import SwiftUI
import LucideIcons

struct ProcessingView: View {
    var body: some View {
        HStack(spacing: 16) {
            // Rotating arc around mic using TimelineView
            TimelineView(.animation(minimumInterval: 0.016, paused: false)) { timeline in
                ZStack {
                    Canvas { context, size in
                        let center = CGPoint(x: size.width / 2, y: size.height / 2)
                        let time = timeline.date.timeIntervalSinceReferenceDate
                        let rotation = time * 360 // One rotation per second

                        // Draw rotating arc
                        let radius = 20.0
                        let startAngle = Angle(degrees: rotation)
                        let endAngle = Angle(degrees: rotation + 270)

                        var path = Path()
                        path.addArc(center: center, radius: radius,
                                   startAngle: startAngle, endAngle: endAngle,
                                   clockwise: false)

                        context.stroke(path, with: .color(Color.weChatGreen),
                                     lineWidth: 3)
                    }
                    .frame(width: 44, height: 44)

                    // Mic icon centered
                    Image(nsImage: {
                        let img = Lucide.mic.copy() as! NSImage
                        img.isTemplate = true
                        return img
                    }())
                        .resizable()
                        .frame(width: 16, height: 16)
                        .foregroundColor(.white)
                }
            }
            .frame(width: 50, height: 50)

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
