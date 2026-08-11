import XCTest
@testable import Headroom

final class MenuBarIconStyleTests: XCTestCase {
    func testPaceOffsetIsZeroOnPace() {
        XCTAssertEqual(
            MenuBarIconStyle.paceOffset(used: 40, pace: 40),
            0,
            accuracy: 1e-9
        )
    }

    func testPaceOffsetIsOdd() {
        let over = MenuBarIconStyle.paceOffset(used: 48, pace: 40)
        let under = MenuBarIconStyle.paceOffset(used: 32, pace: 40)
        XCTAssertEqual(over, -under, accuracy: 1e-9)
        XCTAssertGreaterThan(over, 0)
    }

    func testPaceOffsetInvertFlipsSign() {
        let over = MenuBarIconStyle.paceOffset(used: 48, pace: 40)
        let flipped = MenuBarIconStyle.paceOffset(
            used: 48, pace: 40, invert: true)
        XCTAssertEqual(flipped, -over, accuracy: 1e-9)
    }

    func testSmallGapsMoveMoreThanLinearClipWould() {
        // ±3 pts should already leave the rail; with scale 8, tanh(3/8) ≈ 0.36.
        let small = MenuBarIconStyle.paceOffset(used: 43, pace: 40)
        XCTAssertEqual(small, tanh(3.0 / 8.0), accuracy: 1e-9)
        XCTAssertGreaterThan(abs(small), 0.3)
    }

    func testLargeGapsAsymptoteBelowOne() {
        let huge = MenuBarIconStyle.paceOffset(used: 90, pace: 40)
        XCTAssertLessThan(huge, 1)
        XCTAssertGreaterThan(huge, 0.99)
    }

    func testDefaultStyleIsRemaining() {
        XCTAssertEqual(MenuBarIconStyle.remaining.rawValue, "remaining")
        XCTAssertEqual(MenuBarIconStyle.pace.rawValue, "pace")
    }
}
