import SwiftUI
import LucideIcons

struct RecordingView: View {
    let audioLevel: Float
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 16) {
            // WeChat-style mic with pulsing circles using TimelineView
            TimelineView(.animation(minimumInterval: 0.05, paused: false)) { timeline in
                Canvas { context, size in
                    let center = CGPoint(x: size.width / 2, y: size.height / 2)
                    let time = timeline.date.timeIntervalSinceReferenceDate

                    // Draw pulsing circles
                    for i in 0..<3 {
                        let delay = Double(i) * 0.4
                        let phase = fmod(time - delay, 1.2) / 1.2
                        let radius = 18 + phase * 15
                        let opacity = 1.0 - phase

                        var path = Path()
                        path.addEllipse(in: CGRect(x: center.x - radius, y: center.y - radius,
                                                   width: radius * 2, height: radius * 2))
                        context.fill(path, with: .color(Color.weChatGreen.opacity(opacity * 0.3)))
                    }

                    // Draw center circle
                    var centerPath = Path()
                    centerPath.addEllipse(in: CGRect(x: center.x - 18, y: center.y - 18, width: 36, height: 36))
                    context.fill(centerPath, with: .color(Color.weChatGreen))
                }
            }
            .frame(width: 50, height: 50)

            // Mic icon overlay
            Image(nsImage: {
                let img = Lucide.mic.copy() as! NSImage
                img.isTemplate = true
                return img
            }())
                .resizable()
                .frame(width: 16, height: 16)
                .foregroundColor(.white)
                .offset(x: -33) // Center over the canvas

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
