import XCTest
@testable import LocalCronKit

final class EditorRouteTests: XCTestCase {
    // The bug: Edit… in a run's menu on the Logs page set the editor but
    // left the window on Logs, so nothing happened.
    func testAnEditFromAnotherPageShowsTheEditorPageAndGoesBack() {
        let route = EditorRoute(editorPage: "Jobs", current: "Logs")
        XCTAssertEqual(route.show, "Jobs")
        XCTAssertEqual(route.back, "Logs")
    }

    func testAnEditOnTheEditorPageStaysThere() {
        let route = EditorRoute(editorPage: "Jobs", current: "Jobs")
        XCTAssertEqual(route.show, "Jobs")
        XCTAssertNil(route.back)
    }

    func testAGivenOriginWinsOverTheCurrentPage() {
        let route = EditorRoute(editorPage: "Jobs", current: "Runs", from: "Chat")
        XCTAssertEqual(route.show, "Jobs")
        XCTAssertEqual(route.back, "Chat")
    }
}
