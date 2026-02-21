import AppKit
import Combine

public enum PanelState: Equatable {
    case hidden
    case recording(audioLevel: Float)
    case processing
}

public enum PanelAction {
    case cancel
}

@MainActor
public class PanelViewModel: ObservableObject {
    @Published public var state: PanelState = .hidden
    public let actions = PassthroughSubject<PanelAction, Never>()

    public init() {}

    public func showRecording() {
        state = .recording(audioLevel: 0)
    }

    public func updateAudioLevel(_ level: Float) {
        state = .recording(audioLevel: level)
    }

    public func showProcessing() {
        state = .processing
    }

    public func hide() {
        state = .hidden
    }

    // User Actions
    public func cancel() {
        actions.send(.cancel)
        hide()
    }
}
