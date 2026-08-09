import AppKit
import SwiftUI

/// A reusable AppKit text surface for logs. NSTextView lays out long text lazily,
/// keeps selection/copy support, and lets each run retain its own scroll position.
struct LogTextView: NSViewRepresentable {
    struct Content: Equatable {
        var stdout: String
        var stderr: String
        var stdoutNotice: String?
        var stderrNotice: String?
    }

    var content: Content
    var scrollKey: String
    var scrollStore: LogScrollStore

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder

        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 20, height: 14)
        textView.frame = NSRect(origin: .zero, size: scrollView.contentSize)
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.minSize = NSSize(width: 0, height: scrollView.contentSize.height)
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: 0,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.layoutManager?.allowsNonContiguousLayout = true
        textView.setAccessibilityLabel("日志输出")

        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }

        let coordinator = context.coordinator
        let currentOrigin = scrollView.contentView.bounds.origin
        if let currentKey = coordinator.currentKey {
            scrollStore.record(origin: currentOrigin, for: currentKey)
        }

        let switchedRun = coordinator.currentKey != scrollKey
        let changedContent = coordinator.content != content
        coordinator.currentKey = scrollKey

        if changedContent {
            textView.textStorage?.setAttributedString(attributedContent)
            coordinator.content = content
        }

        guard switchedRun || changedContent else { return }
        if !switchedRun {
            scrollView.contentView.scroll(to: currentOrigin)
            scrollView.reflectScrolledClipView(scrollView.contentView)
            return
        }

        let targetOrigin = scrollStore.beginRestore(for: scrollKey)
        DispatchQueue.main.async { [weak scrollView, weak textView, weak coordinator, weak scrollStore] in
            guard let scrollView, let textView, let coordinator, let scrollStore else { return }
            guard coordinator.currentKey == scrollKey else { return }
            // Do not force layout of the full log. AppKit can keep non-contiguous
            // layout lazy while we clamp against the document view's current frame.
            let documentHeight = textView.frame.height
            let viewportHeight = scrollView.contentView.bounds.height
            let maximumY = max(documentHeight - viewportHeight, 0)
            let constrainedOrigin = NSPoint(
                x: 0,
                y: min(max(targetOrigin.y, 0), maximumY)
            )
            scrollView.contentView.scroll(to: constrainedOrigin)
            scrollView.reflectScrolledClipView(scrollView.contentView)
            scrollStore.completeRestore(for: scrollKey)
        }
    }

    private var attributedContent: NSAttributedString {
        let result = NSMutableAttributedString()
        let bodyAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular),
            .foregroundColor: NSColor.labelColor
        ]
        let noticeAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.secondaryLabelColor
        ]

        if let stdoutNotice = content.stdoutNotice {
            result.append(NSAttributedString(string: stdoutNotice + "\n\n", attributes: noticeAttributes))
        }
        result.append(NSAttributedString(string: content.stdout, attributes: bodyAttributes))

        if !content.stderr.isEmpty {
            if result.length > 0 {
                result.append(NSAttributedString(string: "\n\n"))
            }
            let headingAttributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold),
                .foregroundColor: NSColor.systemOrange
            ]
            result.append(NSAttributedString(string: "标准错误\n", attributes: headingAttributes))
            if let stderrNotice = content.stderrNotice {
                result.append(NSAttributedString(string: stderrNotice + "\n", attributes: noticeAttributes))
            }
            result.append(NSAttributedString(
                string: content.stderr,
                attributes: bodyAttributes.merging([.foregroundColor: NSColor.systemRed]) { _, new in new }
            ))
        }

        return result
    }

    final class Coordinator {
        var currentKey: String?
        var content: Content?
    }
}
