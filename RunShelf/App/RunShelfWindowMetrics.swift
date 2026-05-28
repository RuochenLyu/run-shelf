import AppKit

enum RunShelfWindowMetrics {
    static let gateWidth: CGFloat = 480
    static let gateHeight: CGFloat = 380
    static let mainMinWidth: CGFloat = 1120
    static let mainMinHeight: CGFloat = 680

    static var gateContentSize: NSSize {
        NSSize(width: gateWidth, height: gateHeight)
    }

    static var mainContentSize: NSSize {
        NSSize(width: mainMinWidth, height: mainMinHeight)
    }
}
