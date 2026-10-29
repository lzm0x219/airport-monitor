import Foundation
import CoreGraphics

/// All rectangles use AppKit screen coordinates (origin at the lower left).
enum PanelPlacement {
    static let width: CGFloat = 320
    static let height: CGFloat = 500
    static func frame(anchor: CGRect, visibleFrame: CGRect, desiredHeight: CGFloat = Self.height) -> CGRect {
        let margin: CGFloat = 8
        let gap: CGFloat = 6
        let width = Self.width
        let top = min(anchor.minY, visibleFrame.maxY) - gap
        let bottom = visibleFrame.minY + margin
        let height = min(max(1, desiredHeight), max(1, top - bottom))
        let left = visibleFrame.minX + margin
        let right = max(left, visibleFrame.maxX - margin - width)
        let x = min(max(anchor.midX - width / 2, left), right)
        return CGRect(x: x, y: top - height, width: width, height: height)
    }
}
