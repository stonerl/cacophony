import AppKit

enum PanelMetrics {
    static let contentWidth: CGFloat = 300
    static let padding: CGFloat = 14
    static let verticalPadding = padding * 2
    static let minimumHeight: CGFloat = 80
    static let maximumHeight: CGFloat = 680
    static let cornerRadius: CGFloat = 16
}

@MainActor
final class StatusPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
