import SwiftUI
import LucideIcons

struct RecordingView: View {
    let audioLevel: Float
    let onClose: () -> Void

    @State private var levels: [Float] = Array(repeating: 0, count: 7)
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: {
                let img = Lucide.mic.copy() as! NSImage
                img.isTemplate = true
                return img
            }())
                .resizable()
                .frame(width: 20, height: 20)
                .foregroundColor(.white)

            HStack(spacing: 3) {
                ForEach(0..<7, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.white.opacity(0.8))
                        .frame(width: 4, height: CGFloat(8 + levels[index] * 32))
                        .animation(.easeInOut(duration: 0.08), value: levels[index])
                }
            }

            Spacer()

            Button(action: {
                onClose()
            }) {
                Image(nsImage: Lucide.x)
                    .resizable()
                    .frame(width: 14, height: 14)
                    .foregroundColor(.white)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .frame(width: 280, height: 80)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.black.opacity(colorScheme == .dark ? 0.6 : 0.4))
        )
        .onChange(of: audioLevel) { newValue in
            levels.removeFirst()
            levels.append(newValue)
        }
    }
}
