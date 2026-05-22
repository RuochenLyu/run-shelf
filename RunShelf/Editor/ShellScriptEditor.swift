import AppKit
import SwiftUI

struct ShellScriptEditor: NSViewRepresentable {
    @Binding var text: String

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = false
        scrollView.borderType = .noBorder

        let textView = NSTextView()
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.isEditable = true
        textView.isSelectable = true
        textView.font = Self.editorFont
        textView.textContainerInset = NSSize(width: 12, height: 12)
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isHorizontallyResizable = true
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = false
        textView.delegate = context.coordinator
        textView.textStorage?.delegate = context.coordinator
        context.coordinator.textView = textView

        scrollView.documentView = textView
        context.coordinator.apply(text: text, to: textView)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        if textView.string != text {
            context.coordinator.apply(text: text, to: textView)
        }
    }

    private static var editorFont: NSFont {
        NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    }

    final class Coordinator: NSObject, NSTextViewDelegate, NSTextStorageDelegate {
        private var parent: ShellScriptEditor
        private var isApplyingHighlight = false
        weak var textView: NSTextView?

        init(_ parent: ShellScriptEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView, !isApplyingHighlight else { return }
            syncFromTextView(textView)
        }

        func textStorage(
            _ textStorage: NSTextStorage,
            didProcessEditing editedMask: NSTextStorageEditActions,
            range editedRange: NSRange,
            changeInLength delta: Int
        ) {
            guard editedMask.contains(.editedCharacters), !isApplyingHighlight, let textView else { return }
            syncFromTextView(textView)
        }

        func apply(text: String, to textView: NSTextView) {
            let selectedRanges = textView.selectedRanges
            isApplyingHighlight = true
            let highlighted = ShellSyntaxHighlighter.highlightedString(text, font: ShellScriptEditor.editorFont)
            textView.textStorage?.setAttributedString(highlighted)
            textView.selectedRanges = selectedRanges
            isApplyingHighlight = false
        }

        private func syncFromTextView(_ textView: NSTextView) {
            parent.text = textView.string
            apply(text: textView.string, to: textView)
        }
    }
}
