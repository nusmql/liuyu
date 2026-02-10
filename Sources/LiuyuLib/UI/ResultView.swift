import SwiftUI

struct ResultView: View {
    let text: String
    let onInsert: () -> Void
    let onCopy: () -> Void
    let onClear: () -> Void
    var body: some View { Text(text) }
}
