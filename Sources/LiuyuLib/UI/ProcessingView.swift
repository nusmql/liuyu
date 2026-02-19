import SwiftUI
import LucideIcons

struct ProcessingView: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: Lucide.mic)
                .resizable()
                .frame(width: 20, height: 20)
                .foregroundColor(.white)

            ProgressView()
                .scaleEffect(0.8)
                .colorScheme(.light)

            Text("Transcribing...")
                .foregroundColor(.white)
                .font(.system(size: 13))

            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .frame(width: 280, height: 80)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.black.opacity(colorScheme == .dark ? 0.6 : 0.4))
        )
    }
}
