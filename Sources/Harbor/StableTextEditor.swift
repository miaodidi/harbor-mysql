import SwiftUI
import AppKit

struct StableTextEditor: NSViewRepresentable {
    @Binding var text: String
    var isEditable = true
    var fontSize: CGFloat = 12
    var minimumHeight: CGFloat = 58
    var editorID: String

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: StableTextEditor
        private let history = UndoManager()
        weak var textView: NSTextView?
        init(_ parent: StableTextEditor) {
            self.parent = parent
            super.init()
            NotificationCenter.default.addObserver(self, selector: #selector(historyChanged), name: .NSUndoManagerDidUndoChange, object: history)
            NotificationCenter.default.addObserver(self, selector: #selector(historyChanged), name: .NSUndoManagerDidRedoChange, object: history)
        }
        deinit { NotificationCenter.default.removeObserver(self) }
        @objc private func historyChanged() {
            if let textView, parent.text != textView.string { parent.text = textView.string }
        }
        func undoManager(for view: NSTextView) -> UndoManager? { history }
        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            if parent.text != view.string { parent.text = view.string }
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        let textView = NSTextView()
        context.coordinator.textView = textView
        textView.delegate = context.coordinator; textView.isEditable = isEditable
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 600, height: CGFloat.greatestFiniteMagnitude)
        textView.setAccessibilityIdentifier(editorID)
        textView.isRichText = false; textView.font = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
        textView.textColor = .labelColor; textView.backgroundColor = .clear
        textView.textContainerInset = NSSize(width: 4, height: 4)
        textView.isVerticallyResizable = true; textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = NSSize(width: 0, height: minimumHeight); textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.frame = NSRect(x: 0, y: 0, width: 600, height: minimumHeight)
        textView.string = text
        scroll.documentView = textView
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        // Delegate callbacks must use the current binding after a SwiftUI update.
        context.coordinator.parent = self
        guard let textView = scroll.documentView as? NSTextView else { return }
        textView.isEditable = isEditable
        // SwiftUI may redraw this view after every keystroke. Only replace the
        // text when an external value changed, preserving the insertion point.
        if !textView.hasMarkedText(), textView.string != text {
            let selection = textView.selectedRange()
            textView.string = text
            let start = min(selection.location, text.utf16.count)
            textView.setSelectedRange(NSRange(location: start, length: min(selection.length, text.utf16.count - start)))
            textView.undoManager?.removeAllActions()
        }
    }
}

