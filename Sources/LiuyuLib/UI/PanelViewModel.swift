import Foundation
import AppKit
import Combine

public enum PanelState {
    case hidden
    case recording(audioLevel: Float)
    case processing
    case result(text: String)
}

public enum PanelAction {
    case insert(String)
    case copy(String)
    case clear
    case cancel
}

@MainActor
public class PanelViewModel: ObservableObject {
    @Published public var state: PanelState = .hidden
    public let actions = PassthroughSubject<PanelAction, Never>()

    private var autoDismissTimer: Timer?
    private let autoDismissInterval: TimeInterval = 10.0

    public init() {}

    public func showRecording() {
        cancelAutoDismiss()
        state = .recording(audioLevel: 0)
    }

    public func updateAudioLevel(_ level: Float) {
        state = .recording(audioLevel: level)
    }

    public func showProcessing() {
        cancelAutoDismiss()
        state = .processing
    }

    public func showResult(_ text: String) {
        state = .result(text: text)
        startAutoDismiss()
    }

    public func hide() {
        cancelAutoDismiss()
        state = .hidden
    }

    // User Actions
    public func insertText() {
        guard case .result(let text) = state else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        actions.send(.insert(text))
        hide()
    }

    public func copyText() {
        guard case .result(let text) = state else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        actions.send(.copy(text))
    }

    public func clearResult() {
        actions.send(.clear)
        hide()
    }

    public func cancel() {
        actions.send(.cancel)
        hide()
    }

    private func startAutoDismiss() {
        cancelAutoDismiss()
        autoDismissTimer = Timer.scheduledTimer(withTimeInterval: autoDismissInterval, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.cancel()
            }
        }
    }

    private func cancelAutoDismiss() {
        autoDismissTimer?.invalidate()
        autoDismissTimer = nil
    }
}
