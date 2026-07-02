import AppKit

/// Geometry of the built-in display's notch, if any.
struct Notch {
    /// Right edge of the notch dead zone in global x coordinates. Menu bar
    /// items are laid out right-to-left; anything whose center would fall
    /// left of this edge is not rendered.
    let rightEdge: CGFloat
    let screenXRange: ClosedRange<CGFloat>

    static func detect() -> Notch? {
        for screen in NSScreen.screens {
            if screen.auxiliaryTopLeftArea != nil, let right = screen.auxiliaryTopRightArea {
                return Notch(
                    rightEdge: right.minX,
                    screenXRange: screen.frame.minX...screen.frame.maxX
                )
            }
        }
        return nil
    }

    func hides(_ frame: CGRect) -> Bool {
        guard frame.minX.isFinite, screenXRange.contains(frame.midX) else { return false }
        return frame.midX < rightEdge
    }
}
