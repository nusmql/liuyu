import SwiftUI

struct EditActionBar: View {
    let hasText: Bool
    let clearButtonLabel: String
    let onClear: () -> Void
    let onCopy: () -> Void
    let onInsert: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Spacer()

            Button(action: onClear) {
                Label {
                    Text(clearButtonLabel)
                } icon: {
                    Image(nsImage: IconManager.shared.trash2)
                        .resizable()
                        .frame(width: 16, height: 16)
                }
                .font(.system(size: 16))
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .disabled(!hasText)

            Button(action: onCopy) {
                Label {
                    Text("Copy (⌘C)")
                } icon: {
                    Image(nsImage: IconManager.shared.clipboardCopy)
                        .resizable()
                        .frame(width: 16, height: 16)
                }
                .font(.system(size: 16))
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .disabled(!hasText)

            Button(action: onInsert) {
                Label {
                    Text("Insert")
                } icon: {
                    Image(nsImage: IconManager.shared.cornerDownLeft)
                        .resizable()
                        .frame(width: 16, height: 16)
                }
                .font(.system(size: 16))
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .disabled(!hasText)
        }
    }
}
