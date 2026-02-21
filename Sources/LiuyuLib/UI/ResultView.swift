import SwiftUI

struct ResultView: View {
    let text: String
    let onInsert: () -> Void
    let onCopy: () -> Void
    let onClear: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(nsImage: IconManager.shared.mic)
                    .resizable()
                    .frame(width: 16, height: 16)
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)

                Text(text)
                    .font(.system(size: 14))
                    .foregroundStyle(.primary)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: 8) {
                Spacer()

                Button(action: onClear) {
                    Label {
                        Text("Clear")
                    } icon: {
                        Image(nsImage: IconManager.shared.trash2)
                            .resizable()
                            .frame(width: 12, height: 12)
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)

                Button(action: onCopy) {
                    Label {
                        Text("Copy")
                    } icon: {
                        Image(nsImage: IconManager.shared.clipboardCopy)
                            .resizable()
                            .frame(width: 12, height: 12)
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)

                Button(action: onInsert) {
                    Label {
                        Text("Insert")
                    } icon: {
                        Image(nsImage: IconManager.shared.cornerDownLeft)
                            .resizable()
                            .frame(width: 12, height: 12)
                    }
                    .font(.system(size: 12))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
        .padding(16)
        .frame(width: 400, height: 120)
        .background(.ultraThickMaterial, in: RoundedRectangle(cornerRadius: 16))
    }
}
