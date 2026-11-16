import AppKit
import SwiftUI
import XCTest
@testable import LocalCronKit

@MainActor
final class WindowContentTests: XCTestCase {
    /// A long text in a scroll view, with buttons under it: the shape of the
    /// Allow Secrets window.
    @Observable final class Lines {
        var count: Int
        init(_ count: Int) { self.count = count }
    }

    private struct Tall: View {
        let model: Lines
        init(lines: Int) { model = Lines(lines) }
        init(model: Lines) { self.model = model }
        private var lines: Int { model.count }
        var body: some View {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading) {
                        ForEach(0..<lines, id: \.self) { Text("line \($0)") }
                    }
                }
                Divider()
                HStack(spacing: 12) {
                    Text("The job can do anything with these values, also send them elsewhere. Allow it only if you understand what it runs.")
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Button("Cancel") {}
                    Button("Allow with Touch ID…") {}
                }
                .padding()
            }
        }
    }

    private func window() -> NSWindow {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                         styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: true)
        w.isReleasedWhenClosed = false
        return w
    }

    private func contentHeight(_ w: NSWindow) -> CGFloat {
        w.orderFront(nil)
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        w.layoutIfNeeded()
        defer { w.orderOut(nil) }
        return w.contentRect(forFrameRect: w.frame).height
    }

    func testLongContentScrollsAndDoesNotGrowTheWindow() {
        let w = window()
        WindowContent.host(Tall(lines: 400), in: w, size: NSSize(width: 400, height: 300))
        XCTAssertEqual(contentHeight(w), 300, accuracy: 1)
    }

    /// The review of Claude ends after the window is open and makes the view
    /// longer: the window must not grow past the screen to show it all.
    func testContentThatGrowsLaterDoesNotGrowTheWindow() {
        let w = window()
        let model = Lines(5)
        WindowContent.host(Tall(model: model), in: w, size: NSSize(width: 400, height: 300))
        XCTAssertEqual(contentHeight(w), 300, accuracy: 1)
        model.count = 400
        XCTAssertEqual(contentHeight(w), 300, accuracy: 1)
    }

    func testTheWindowFitsOnTheScreen() throws {
        let screen = try XCTUnwrap(NSScreen.main)
        let w = window()
        WindowContent.host(Tall(lines: 5), in: w, size: NSSize(width: 400, height: 10_000))
        XCTAssertLessThanOrEqual(w.frame.height, screen.visibleFrame.height)
    }

    func testTheWindowStillResizes() {
        let w = window()
        WindowContent.host(Tall(lines: 400), in: w, size: NSSize(width: 400, height: 300))
        w.setContentSize(NSSize(width: 500, height: 420))
        XCTAssertEqual(contentHeight(w), 420, accuracy: 1)
    }
}
