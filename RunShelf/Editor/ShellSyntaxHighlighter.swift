import AppKit
import Foundation

enum ShellSyntaxHighlighter {
    private static let maxHighlightedBytes = 200_000

    private static let rules: [(expression: NSRegularExpression, color: NSColor)] = [
        (try! NSRegularExpression(pattern: #"#.*$"#, options: [.anchorsMatchLines]), .secondaryLabelColor),
        (try! NSRegularExpression(pattern: #""([^"\\]|\\.)*""#, options: [.anchorsMatchLines]), .systemGreen),
        (try! NSRegularExpression(pattern: #"'[^']*'"#, options: [.anchorsMatchLines]), .systemGreen),
        (try! NSRegularExpression(pattern: #"\$[A-Za-z_][A-Za-z0-9_]*|\$\{[^}]+\}"#, options: [.anchorsMatchLines]), .systemOrange),
        (try! NSRegularExpression(pattern: #"\b(cd|source|export|curl|python|node|git|rsync|exec|echo|exit|sleep|awk|df)\b"#, options: [.anchorsMatchLines]), .systemBlue),
        (try! NSRegularExpression(pattern: #"(rm\s+-rf|sudo|chmod\s+-R|chown\s+-R|curl\b.*\|\s*sh)"#, options: [.anchorsMatchLines]), .systemRed)
    ]

    static func highlightedString(_ source: String, font: NSFont) -> NSAttributedString {
        let fullRange = NSRange(location: 0, length: (source as NSString).length)
        let attributed = NSMutableAttributedString(
            string: source,
            attributes: [
                .font: font,
                .foregroundColor: NSColor.labelColor
            ]
        )

        guard source.utf8.count <= maxHighlightedBytes else {
            return attributed
        }

        for rule in rules {
            apply(expression: rule.expression, color: rule.color, to: attributed, source: source)
        }

        attributed.addAttribute(.font, value: font, range: fullRange)
        return attributed
    }

    private static func apply(
        expression: NSRegularExpression,
        color: NSColor,
        to attributed: NSMutableAttributedString,
        source: String
    ) {
        let range = NSRange(location: 0, length: (source as NSString).length)
        expression.enumerateMatches(in: source, range: range) { match, _, _ in
            guard let matchRange = match?.range else { return }
            attributed.addAttribute(.foregroundColor, value: color, range: matchRange)
        }
    }
}
