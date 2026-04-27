import SwiftUI

/// A macOS-native text editor that properly handles the Return key.
struct MacTextEditor: NSViewRepresentable {
    @Binding var text: String
    var onReturn: () -> Void

    func makeNSView(context: Context) -> NSScrollView {
        Logger.debug("MacTextEditor makeNSView", category: .ui)
        let scrollView = NSTextView.scrollableTextView()
        let textView = scrollView.documentView as! NSTextView

        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isSelectable = true
        textView.isEditable = true
        textView.backgroundColor = .clear
        textView.autoresizingMask = [.width, .height]

        Logger.debug("MacTextEditor: delegate set to coordinator", category: .ui)

        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        let textView = nsView.documentView as! NSTextView
        Logger.debug("MacTextEditor updateNSView: text='\(text.prefix(20))...', textView.string='\(textView.string.prefix(20))...'", category: .ui)
        if textView.string != text {
            textView.string = text
        }
        context.coordinator.updateParent(self)

        if let window = textView.window, window.isKeyWindow, window.firstResponder !== textView {
            Logger.debug("MacTextEditor: Making textView first responder", category: .ui)
            window.makeFirstResponder(textView)
        }
    }

    func makeCoordinator() -> Coordinator {
        Logger.debug("MacTextEditor makeCoordinator", category: .ui)
        return Coordinator(self)
    }

    class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MacTextEditor

        init(_ parent: MacTextEditor) {
            self.parent = parent
        }

        func updateParent(_ parent: MacTextEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            Logger.debug("MacTextEditor doCommandBy: \(commandSelector)", category: .ui)
            if commandSelector == #selector(NSResponder.insertNewline(_:)) ||
               commandSelector == #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)) ||
               commandSelector == #selector(NSResponder.insertLineBreak(_:)) {
                Logger.debug("MacTextEditor: Return key intercepted, calling onReturn", category: .ui)
                parent.onReturn()
                return true
            }
            return false
        }
    }
}
