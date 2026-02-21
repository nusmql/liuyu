import SwiftUI

struct PanelContentView: View {
    @ObservedObject var viewModel: PanelViewModel

    var body: some View {
        ZStack {
            switch viewModel.state {
            case .hidden:
                EmptyView()
            case .recording(let audioLevel):
                RecordingView(audioLevel: audioLevel, onClose: viewModel.cancel)
                    .transition(.opacity)
            case .processing:
                ProcessingView()
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: viewModel.state)
    }
}
