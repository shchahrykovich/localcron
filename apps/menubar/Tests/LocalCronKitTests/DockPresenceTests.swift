import AppKit
import XCTest
@testable import LocalCronKit

@MainActor
final class DockPresenceTests: XCTestCase {
    private func window(titled: Bool = true) -> NSWindow {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
                         styleMask: titled ? [.titled, .closable, .miniaturizable] : [.borderless],
                         backing: .buffered, defer: true)
        w.isReleasedWhenClosed = false
        return w
    }

    func testNoWindowsMeansNoDockIcon() {
        XCTAssertFalse(DockPresence.needsDock([], closing: nil))
    }

    func testAnOpenWindowNeedsTheDockIcon() {
        let w = window()
        w.orderFront(nil)
        defer { w.close() }
        XCTAssertTrue(DockPresence.needsDock([w], closing: nil))
    }

    func testTheWindowThatClosesDoesNotCount() {
        let w = window()
        w.orderFront(nil)
        defer { w.close() }
        XCTAssertFalse(DockPresence.needsDock([w], closing: w))
    }

    func testHiddenAndUntitledWindowsDoNotCount() {
        // A closed window, and a borderless one like the popover's.
        let hidden = window()
        let popover = window(titled: false)
        popover.orderFront(nil)
        defer { popover.close() }
        XCTAssertFalse(DockPresence.needsDock([hidden, popover], closing: nil))
    }

    func testAnotherOpenWindowKeepsTheDockIcon() {
        let a = window(), b = window()
        a.orderFront(nil)
        b.orderFront(nil)
        defer { a.close(); b.close() }
        XCTAssertTrue(DockPresence.needsDock([a, b], closing: a))
    }
}
