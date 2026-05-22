import AppKit
import Foundation

enum ShellSyntaxHighlighter {
    static func highlightedString(_ source: String, font: NSFont) -> NSAttributedString {
        let fullRange = NSRange(location: 0, length: (source as NSString).length)
        let attributed = NSMutableAttributedString(
            string: source,
            attributes: [
                .font: font,
                .foregroundColor: NSColor.labelColor
            ]
        )

        apply(pattern: #"#.*$"#, color: .secondaryLabelColor, to: attributed, source: source)
        apply(pattern: #""([^"\\]|\\.)*""#, color: .systemGreen, to: attributed, source: source)
        apply(pattern: #"'[^']*'"#, color: .systemGreen, to: attributed, source: source)
        apply(pattern: #"\$[A-Za-z_][A-Za-z0-9_]*|\$\{[^}]+\}"#, color: .systemOrange, to: attributed, source: source)
        apply(pattern: #"\b(cd|source|export|curl|python|node|git|rsync|exec|echo|exit|sleep|awk|df)\b"#, color: .systemBlue, to: attributed, source: source)
        apply(pattern: #"(rm\s+-rf|sudo|chmod\s+-R|chown\s+-R|curl\b.*\|\s*sh)"#, color: .systemRed, to: attributed, source: source)

        attributed.addAttribute(.font, value: font, range: fullRange)
        return attributed
    }

    private static func apply(
        pattern: String,
        color: NSColor,
        to attributed: NSMutableAttributedString,
        source: String
    ) {
        guard let expression = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) else {
            return
        }

        let range = NSRange(location: 0, length: (source as NSString).length)
        expression.enumerateMatches(in: source, range: range) { match, _, _ in
            guard let matchRange = match?.range else { return }
            attributed.addAttribute(.foregroundColor, value: color, range: matchRange)
        }
    }
}
