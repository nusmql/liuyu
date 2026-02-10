import SwiftUI

struct PanelContentView: View {
    @ObservedObject var viewModel: PanelViewModel

    var body: some View {
        switch viewModel.state {
        case .hidden:
            EmptyView()
        case .recording(let audioLevel):
            RecordingView(audioLevel: audioLevel, onClose: viewModel.cancel)
        case .processing:
            ProcessingView()
        case .result(let text):
            ResultView(
                text: text,
                onInsert: viewModel.insertText,
                onCopy: viewModel.copyText,
                onClear: viewModel.clearResult
            )
        }
    }
}
