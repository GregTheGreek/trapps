import Testing
import Foundation
@testable import trapps

struct NotchTests {
    // A notch whose dead zone ends at x=200, on a screen spanning 0...1000.
    let notch = Notch(rightEdge: 200, screenXRange: 0...1000)

    @Test func hidesItemLeftOfRightEdge() {
        // midX = 150 < 200 -> occluded by the notch.
        #expect(notch.hides(CGRect(x: 100, y: 0, width: 100, height: 24)))
    }

    @Test func doesNotHideItemRightOfRightEdge() {
        // midX = 350 >= 200 -> visible.
        #expect(!notch.hides(CGRect(x: 300, y: 0, width: 100, height: 24)))
    }

    @Test func itemExactlyAtRightEdgeIsNotHidden() {
        // midX == rightEdge is not strictly less-than, so it stays visible.
        #expect(!notch.hides(CGRect(x: 150, y: 0, width: 100, height: 24)))
    }

    @Test func unknownFrameIsNotHidden() {
        // Items whose position couldn't be read get a non-finite minX.
        let unknown = CGRect(x: CGFloat.greatestFiniteMagnitude, y: 0, width: 0, height: 0)
        #expect(!notch.hides(unknown))
    }

    @Test func itemOnAnotherScreenIsNotHidden() {
        // midX outside the notched screen's x range is never considered hidden.
        #expect(!notch.hides(CGRect(x: 1500, y: 0, width: 100, height: 24)))
    }
}
