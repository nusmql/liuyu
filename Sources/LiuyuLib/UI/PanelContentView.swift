import SwiftUI

struct PanelContentView: View {
    @ObservedObject var viewModel: PanelViewModel

    var body: some View {
        RecordingPanelView(viewModel: viewModel)
    }
}
