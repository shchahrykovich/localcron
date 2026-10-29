import CoreGraphics
import XCTest
@testable import LocalCronKit

final class StatusIconLayoutTests: XCTestCase {
    private let clock = CGSize(width: 17, height: 16)
    private let play = CGSize(width: 7, height: 8)

    func testThePlayBadgeSitsOnTheClocksBottomRightCorner() throws {
        let layout = StatusIconLayout(clock: clock, play: play, column: 0)
        let badge = try XCTUnwrap(layout.play)
        XCTAssertEqual(badge.minY, 0, "at the bottom")
        XCTAssertEqual(badge.maxX, clock.width + StatusIconLayout.overhang, "at the right edge, a little past it")
        XCTAssertGreaterThan(badge.minX, clock.width / 2, "in the right half of the clock")
        XCTAssertTrue(layout.playHalo!.contains(badge))
    }

    func testRunningDoesNotWidenTheIconByTheBadge() {
        let idle = StatusIconLayout(clock: clock, play: nil, column: 0)
        let running = StatusIconLayout(clock: clock, play: play, column: 0)
        XCTAssertEqual(running.size.width - idle.size.width, StatusIconLayout.overhang)
        XCTAssertLessThan(running.size.width, clock.width + play.width, "not a badge next to the clock")
    }

    func testTheColumnStaysToTheRight() throws {
        let layout = StatusIconLayout(clock: clock, play: play, column: 6)
        XCTAssertGreaterThanOrEqual(layout.columnX, try XCTUnwrap(layout.play).maxX)
        XCTAssertEqual(layout.size.width, (layout.columnX + 6).rounded(.up))
    }
}
