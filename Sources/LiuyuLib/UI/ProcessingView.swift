import SwiftUI
import LucideIcons

struct ProcessingView: View {
    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: Lucide.mic)
                .resizable()
                .frame(width: 20, height: 20)
                .foregroundStyle(.secondary)

            ProgressView()
                .scaleEffect(0.8)

            Text("Transcribing...")
                .foregroundStyle(.secondary)
                .font(.system(size: 13))

            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .frame(width: 280, height: 80)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }
}
